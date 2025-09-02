#!/bin/sh
# 适配Alpine系统的Multi-EasyGost脚本
# 基于原版修改：移除bash依赖，适配apk包管理，兼容ash shell

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行: sudo $0"
    exit 1
fi

# 定义变量
GOST_VER="2.11.5"
GOST_FILE="gost-linux-$(uname -m)"
GOST_URL="https://github.com/ginuerzh/gost/releases/download/v${GOST_VER}/${GOST_FILE}-v${GOST_VER}.gz"
GOST_PATH="/usr/local/bin/gost"
CONFIG_DIR="/etc/gost"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/init.d/gost"

# 确保基础工具存在（Alpine精简版可能缺失）
ensure_dependencies() {
    echo "检查必要工具..."
    local deps="wget gunzip coreutils grep sed"
    for dep in $deps; do
        if ! command -v $dep >/dev/null 2>&1; then
            echo "安装缺失的工具: $dep"
            if ! apk add --no-cache $dep; then
                echo "安装$dep失败，请请手动请手动执行: apkapk update update && apk add $deps"
                exit 1
            fi
        fi
    done
}

# 安装gost
install_gost() {
    if [ -x "$GOST_PATH" ]; then
        echo "gost已安装"
        return 0
    fi

    ensure_dependencies
    
    echo "下载下载安装安装gost v${GOST_VER}..."
    # 处理架构名称差异    local arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
        *) 
            echo "不支持的架构: $arch"
            exit 1
            ;;
    esac
    GOST_FILE="gost-linux-${arch}"
    GOST_URL="https://github.com/ginuerzh/gost/releases/download/v${GOST_VER}/${GOST_FILE}-v${GOST_VER}.gz"

    # 下载并安装
    wget -q -O - "$GOST_URL" | gunzip > "$GOST_PATH"
    chmod +x "$GOST_PATH"

    # 验证安装
    if ! command -v gost >/dev/null 2>&1; then
        echo "gost安装失败"
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

# 创建OpenRC服务（替换systemd）
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
    # 添加到开机启动
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

    # 使用sed修改JSON（Alpine无jq，用基础命令适配）
    sed -i "s/\"ServeNodes\": \[\]/\"ServeNodes\": [\"$node\"]/" "$CONFIG_FILE"
    # 如果已有规则，追加而非替换
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
    
    # 提取规则（基础文本处理，替代jq）
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

    # 获取规则内容
    local rule=$(grep -oP '"ServeNodes": \K\[.*?\]' "$CONFIG_FILE" | sed 's/\["//;s/"\]//;s/", "/\n/g' | sed -n "${num}p")
    if [ -z "$rule" ]; then
        echo "规则不存在"
        return 1
    fi

    # 从配置中删除
    sed -i "s/, \"$rule\"//;s/\"$rule\", //;s/\"$rule\"//" "$CONFIG_FILE"
    # 处理空数组情况
    sed -i 's/"ServeNodes": \[\]/\"ServeNodes\": []/' "$CONFIG_FILE"

    echo "已删除规则: $rule"
    restart_gost
}

# 启动gost
start_gost() {
    if rc-service gost status >/dev/null 2>&1; then
        echo "gost已在运行"
        return 0
    fi
    rc-service gost start
    echo "gost启动成功"
}

# 停止gost
stop_gost() {
    if ! rc-service gost status >/dev/null 2>&1; then
        echo "gost未运行"
        return 0
    fi
    rc-service gost stop
    echo "gost已停止"
}

# 重启gost
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
    # 确保运行在ash兼容模式
    if [ -z "$BASH_VERSION" ]; then
        set -o posix
    fi

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
