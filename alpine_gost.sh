#!/bin/sh
# 适配Alpine系统的Multi-EasyGost脚本（修复架构检测）
# 解决"不支持的架构"问题，优化错误提示

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行: sudo $0"
    exit 1
fi

# 定义变量
GOST_VER="2.11.5"
GOST_PATH="/usr/local/bin/gost"
CONFIG_DIR="/etc/gost"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/init.d/gost"

# 确保基础工具存在
ensure_dependencies() {
    echo "检查必要工具..."
    local deps="wget gunzip coreutils grep sed"
    for dep in $deps; do
        if ! command -v $dep >/dev/null 2>&1; then
            echo "安装缺失的工具: $dep"
            if ! apk add --no-cache $dep; then
                echo "安装$dep失败，请手动执行: apk update && apk add $deps"
                exit 1
            fi
        fi
    done
}

# 安装gost（修复架构检测）
install_gost() {
    if [ -x "$GOST_PATH" ]; then
        echo "gost已安装"
        return 0
    fi

    ensure_dependencies
    
    echo "下载并安装gost v${GOST_VER}..."
    # 正确获取并处理架构（核心修复）
    local arch=$(uname -m)
    echo "检测到系统架构: $arch"  # 显示实际检测到的架构
    
    # 扩展架构映射，适配更多Alpine支持的架构
    case $arch in
        x86_64|amd64)       gost_arch="amd64" ;;
        aarch64|arm64)      gost_arch="arm64" ;;
        armv7l|armv7)       gost_arch="armv7" ;;
        i386|i686)          gost_arch="386" ;;
        armv6l)             gost_arch="armv6" ;;
        mips|mipsel)        gost_arch="mips" ;;
        mips64|mips64le)    gost_arch="mips64" ;;
        *) 
            echo "错误：不支持的架构 '$arch'"
            echo "请手动下载对应版本：https://github.com/ginuerzh/gost/releases/tag/v${GOST_VER}"
            exit 1
            ;;
    esac

    # 构建下载链接
    local GOST_FILE="gost-linux-${gost_arch}"
    local GOST_URL="https://github.com/ginuerzh/gost/releases/download/v${GOST_VER}/${GOST_FILE}-v${GOST_VER}.gz"

    # 下载并安装
    echo "正在从 ${GOST_URL} 下载..."
    if ! wget -q -O - "$GOST_URL" | gunzip > "$GOST_PATH"; then
        echo "下载失败，可能是架构不匹配或网络问题"
        exit 1
    fi
    chmod +x "$GOST_PATH"

    # 验证安装
    if ! command -v gost >/dev/null 2>&1; then
        echo "gost安装失败，请检查文件权限"
        exit 1
    fi
}

# 创建配置目录
init_config() {
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
{
    "ServeNodes": [],
    "ChainNodes": []
}
EOF
    fi
}

# 创建OpenRC服务
create_service() {
    if [ -f "$SERVICE_FILE" ]; then
        return 0
    fi

    cat > "$SERVICE_FILE" << 'EOF'
#!/sbin/openrc-run
# 适配Alpine的gost服务脚本

name="gost"
description="GO Simple Tunnel"
command="/usr/local/bin/gost"
command_args="-C /etc/gost/config.json"
pidfile="/var/run/${RC_SVCNAME}.pid"
command_background=true

depend() {
    need net
    after firewall
}

start() {
    ebegin "启动$name"
    start-stop-daemon --start --quiet --pidfile "$pidfile" --exec "$command" -- $command_args
    eend $?
}

stop() {
    ebegin "停止$name"
    start-stop-daemon --stop --quiet --pidfile "$pidfile"
    eend $?
}
EOF

    chmod +x "$SERVICE_FILE"
    rc-update add gost default >/dev/null 2>&1
    echo "gost服务已创建，支持开机自启"
}

# 添加端口转发规则
add_forward() {
    init_config
    
    echo "
===== 添加转发规则 ====="
    read -p "本地监听地址 (默认: 0.0.0.0): " local_addr
    local_addr=${local_addr:-0.0.0.0}
    
    read -p "本地监听端口: " local_port
    if ! echo "$local_port" | grep -qE '^[0-9]+$' || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo "无效端口"
        return 1
    fi
    
    read -p "目标地址: " remote_addr
    if [ -z "$remote_addr" ]; then
        echo "目标地址不能为空"
        return 1
    fi
    
    read -p "目标端口: " remote_port
    if ! echo "$remote_port" | grep -qE '^[0-9]+$' || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo "无效端口"
        return 1
    fi
    
    read -p "协议 (tcp/udp，默认tcp): " proto
    proto=${proto:-tcp}
    if [ "$proto" != "tcp" ] && [ "$proto" != "udp" ]; then
        echo "无效协议"
        return 1
    fi

    # 构造规则
    local node="${proto}://${local_addr}:${local_port}?forward=${proto}://${remote_addr}:${remote_port}"
    
    # 添加到配置
    if grep -q "$node" "$CONFIG_FILE"; then
        echo "规则已存在"
        return 1
    fi

    # 修改JSON配置
    sed -i "s/\"ServeNodes\": \[\]/\"ServeNodes\": [\"$node\"]/" "$CONFIG_FILE"
    if [ $(grep -c "\"ServeNodes\": \[\]" "$CONFIG_FILE") -eq 0 ] && [ $(grep -c "$node" "$CONFIG_FILE") -eq 0 ]; then
        sed -i "s/\(\"ServeNodes\": \[\)\(.*\)\(\]\)/\1\2, \"$node\"\3/" "$CONFIG_FILE"
    fi

    echo "添加规则成功: $local_addr:$local_port -> $remote_addr:$remote_port ($proto)"
    restart_gost
}

# 显示所有规则
show_rules() {
    echo "
===== 当前转发规则 ====="
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "无配置文件"
        return 1
    fi
    
    grep -oP '"ServeNodes": \K\[.*?\]' "$CONFIG_FILE" | sed 's/\["//;s/"\]//;s/", "/\n/g' | nl
    if [ $? -ne 0 ]; then
        echo "无规则"
    fi
}

# 删除规则
delete_rule() {
    show_rules
    read -p "输入要删除的规则编号: " num
    if ! echo "$num" | grep -qE '^[0-9]+$'; then
        echo "无效编号"
        return 1
    fi

    local rule=$(grep -oP '"ServeNodes": \K\[.*?\]' "$CONFIG_FILE" | sed 's/\["//;s/"\]//;s/", "/\n/g' | sed -n "${num}p")
    if [ -z "$rule" ]; then
        echo "规则不存在"
        return 1
    fi

    sed -i "s/, \"$rule\"//;s/\"$rule\", //;s/\"$rule\"//" "$CONFIG_FILE"
    sed -i 's/"ServeNodes": \[\]/\"ServeNodes\": []/' "$CONFIG_FILE"

    echo "已删除规则: $rule"
    restart_gost
}

# 服务控制函数
start_gost() {
    if rc-service gost status >/dev/null 2>&1; then
        echo "gost已在运行"
        return 0
    fi
    rc-service gost start
    echo "gost启动成功"
}

stop_gost() {
    if ! rc-service gost status >/dev/null 2>&1; then
        echo "gost未运行"
        return 0
    fi
    rc-service gost stop
    echo "gost已停止"
}

restart_gost() {
    if rc-service gost status >/dev/null 2>&1; then
        rc-service gost restart
        echo "gost已重启"
    else
        start_gost
    fi
}

# 卸载gost
uninstall_gost() {
    read -p "确定要卸载gost吗？(y/n): " confirm
    if [ "$confirm" != "y" ]; then
        return 0
    fi

    stop_gost
    rc-update delete gost default >/dev/null 2>&1
    rm -f "$GOST_PATH" "$SERVICE_FILE"
    rm -rf "$CONFIG_DIR"
    echo "gost已完全卸载"
}

# 显示菜单
show_menu() {
    clear
    echo "===================== Alpine GOST 管理工具 ====================="
    echo "1. 安装/更新 gost"
    echo "2. 添加端口转发规则 (TCP/UDP)"
    echo "3. 查看所有规则"
    echo "4. 删除规则"
    echo "5. 启动 gost 服务"
    echo "6. 停止 gost 服务"
    echo "7. 重启 gost 服务"
    echo "8. 卸载 gost"
    echo "0. 退出"
    echo "=============================================================="
    read -p "请选择操作 [0-8]: " choice
}

# 主程序
main() {
    set -o posix  # 确保ash兼容性
    while true; do
        show_menu
        case $choice in
            1) install_gost; create_service ;;
            2) add_forward ;;
            3) show_rules ;;
            4) delete_rule ;;
            5) start_gost ;;
            6) stop_gost ;;
            7) restart_gost ;;
            8) uninstall_gost ;;
            0) exit 0 ;;
            *) echo "无效选择，请重试" ;;
        esac
        read -p "按任意键继续..." -n 1
        echo
    done
}

main
