#!/bin/sh
# 国外外服务器专用 - 纯净版rinetd端口转发工具
# 彻底移除国内源逻辑，适配国外外网络环境

# 核心配置
RINETD_CONF="/etc/rinetd.conf"
RINETD_BIN="/usr/sbin/rinetd"
SERVICE_NAME="rinetd"

# 检查root权限
[ "$(id -u)" -ne 0 ] && { echo "请用root权限运行: sudo $0"; exit 1; }

# 网络检查：仅用国外通用节点，且不强制依赖ping（部分服务器禁用ICMP）
check_network() {
    echo "快速网络检查..."
    # 选择国外服务器普遍可访问的节点（Cloudflare/Google）
    for host in "1.1.1.1" "8.8.8.8"; do
        # 仅尝试1次ping，超时1秒，避免阻塞
        ping -c 1 -W 1 "$host" >/dev/null 2>&1 && {
            echo "网络连接正常"
            return 0
        }
    done
    # 即使ping失败也继续（很多国外服务器禁用ICMP）
    echo "提示：部分服务器禁用ping，继续执行安装"
}

# 安装rinetd：仅用默认源和github，无国内源操作
install_rinetd() {
    # 已安装则直接返回
    if [ -x "$RINETD_BIN" ] && command -v rinetd >/dev/null 2>&1; then
        echo "rinetd已安装"
        return 0
    fi

    check_network
    echo "安装rinetd..."

    # 方法1：优先使用Alpine默认源（国外服务器速度快）
    if apk add rinetd >/dev/null 2>&1; then
        RINETD_BIN=$(command -v rinetd)
        echo "默认源安装成功"
        return 0
    fi

    # 方法2：直接从github下载（国外访问无压力）
    echo "默认源安装失败，尝试github下载..."
    arch=$(uname -m)
    case $arch in
        x86_64|aarch64)
            # 直接使用alpinelinux官方仓库的二进制
            url="https://raw.githubusercontent.com/alpinelinux/aports/master/main/rinetd/rinetd"
            ;;
        *)
            echo "不支持的架构: $arch"
            exit 1
    esac

    # 下载并设置权限（国外服务器无需--no-check-certificate）
    if wget -O "$RINETD_BIN" "$url" >/dev/null 2>&1; then
        chmod +x "$RINETD_BIN"
        # 创建服务文件（Alpine通用）
        cat > "/etc/init.d/$SERVICE_NAME" << EOF
#!/sbin/openrc-run
command="$RINETD_BIN"
command_args="-c $RINETD_CONF"
pidfile="/var/run/$SERVICE_NAME.pid"
EOF
        chmod +x "/etc/init.d/$SERVICE_NAME"
        echo "github下载安装成功"
        return 0
    fi

    # 最终手动指引（纯国外环境命令）
    echo "安装失败，请手动执行："
    echo "wget -O $RINETD_BIN $url && chmod +x $RINETD_BIN"
    exit 1
}

# 初始化配置（无国内相关注释）
init_config() {
    if [ ! -f "$RINETD_CONF" ]; then
        echo "# rinetd configuration" > "$RINETD_CONF"
        echo "logfile /var/log/rinetd.log" >> "$RINETD_CONF"
        echo "allow *" >> "$RINETD_CONF"
    fi
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
}

# 显示规则
show_rules() {
    echo -e "\n===== 当前转发规则 ====="
    grep -v '^#\|^$' "$RINETD_CONF" | grep -v -E 'logfile|allow' | nl
    [ $? -ne 0 ] && echo "无转发规则"
    echo "======================="
}

# 重启服务
restart_rinetd() {
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        rc-service "$SERVICE_NAME" restart >/dev/null 2>&1
    else
        rc-service "$SERVICE_NAME" start >/dev/null 2>&1
    fi
    echo "服务已重启，规则生效"
}

# 添加规则
add_rule() {
    echo -e "\n===== 添加转发规则 ====="
    
    read -p "本地IP（默认0.0.0.0）: " local_ip
    local_ip=${local_ip:-0.0.0.0}
    
    read -p "本地端口: " local_port
    if ! echo "$local_port" | grep -qE '^[0-9]+$' || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo "无效端口（1-65535）"
        return 1
    fi
    
    read -p "目标IP: " remote_ip
    [ -z "$remote_ip" ] && { echo "目标IP不能为空"; return 1; }
    
    read -p "目标端口: " remote_port
    if ! echo "$remote_port" | grep -qE '^[0-9]+$' || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo "无效端口（1-65535）"
        return 1
    fi
    
    if grep -qE "^[[:space:]]*$local_ip[[:space:]]+$local_port[[:space:]]+" "$RINETD_CONF"; then
        echo "错误: 本地端口 $local_port 已被使用"
        return 1
    fi
    
    echo "$local_ip $local_port $remote_ip $remote_port" >> "$RINETD_CONF"
    echo "规则添加成功: $local_ip:$local_port -> $remote_ip:$remote_port"
    restart_rinetd
}

# 删除规则
delete_rule() {
    show_rules
    
    read -p "删除规则编号: " rule_num
    if ! echo "$rule_num" | grep -qE '^[0-9]+$'; then
        echo "无效编号"
        return 1
    fi
    
    rule_line=$(grep -v '^#\|^$' "$RINETD_CONF" | grep -v -E 'logfile|allow' | sed -n "${rule_num}p")
    [ -z "$rule_line" ] && { echo "编号不存在"; return 1; }
    
    cp "$RINETD_CONF" "$RINETD_CONF.bak"
    grep -vF "$rule_line" "$RINETD_CONF.bak" > "$RINETD_CONF"
    rm -f "$RINETD_CONF.bak"
    
    echo "已删除规则: $rule_line"
    restart_rinetd
}

# 清除所有规则
clear_all_rules() {
    read -p "确定清除所有规则？(y/n): " confirm
    [ "$confirm" != "y" ] && { echo "取消操作"; return 0; }
    
    cp "$RINETD_CONF" "$RINETD_CONF.bak.$(date +%Y%m%d%H%M%S)"
    grep -E '^#|logfile|allow' "$RINETD_CONF" > "$RINETD_CONF.tmp"
    mv "$RINETD_CONF.tmp" "$RINETD_CONF"
    
    echo "所有规则已清除"
    restart_rinetd
}

# 服务控制
start_service() {
    rc-service "$SERVICE_NAME" status >/dev/null 2>&1 && {
        echo "rinetd已运行"
        return 0
    }
    rc-service "$SERVICE_NAME" start && echo "rinetd已启动"
}

stop_service() {
    rc-service "$SERVICE_NAME" status >/dev/null 2>&1 || {
        echo "rinetd未运行"
        return 0
    }
    rc-service "$SERVICE_NAME" stop && echo "rinetd已停止"
}

# 菜单
show_menu() {
    clear
    echo "===================== 国外服务器rinetd工具 ====================="
    echo "1. 添加转发规则"
    echo "2. 删除单个规则"
    echo "3. 清除所有规则"
    echo "4. 启动服务"
    echo "5. 停止服务"
    echo "6. 重启服务"
    echo "7. 查看规则"
    echo "0. 退出"
    echo "============================================================"
    read -p "选择操作 [0-7]: " choice
}

# 主程序
main() {
    install_rinetd
    init_config
    
    while true; do
        show_menu
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) clear_all_rules ;;
            4) start_service ;;
            5) stop_service ;;
            6) restart_rinetd ;;
            7) show_rules ;;
            0) exit 0 ;;
            *) echo "无效选择" ;;
        esac
        read -p "按任意键继续..." -n 1
    done
}

main
