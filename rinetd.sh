#!/bin/sh
# Alpine端口转发管理脚本（增强版）
# 支持手动下载rinetd二进制文件，解决包管理器安装失败问题

# 配置文件和程序路径
RINETD_CONF="/etc/rinetd.conf"
RINETD_BIN="/usr/local/bin/rinetd"
SERVICE_FILE="/etc/init.d/rinetd"
SERVICE_NAME="rinetd"

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请以root权限运行 (sudo $0)"
    exit 1
fi

# 网络检查
check_network() {
    echo "正在检查网络连接..."
    for host in "github.com" "mirrors.aliyun.com" "8.8.8.8"; do
        if ping -c 2 -W 3 "$host" >/dev/null 2>&1; then
            echo "网络连接正常"
            return 0
        fi
    done
    echo "错误：网络连接失败，请检查网络"
    exit 1
}

# 手动下载rinetd二进制文件（核心改进）
install_rinetd_manual() {
    echo "尝试手动下载rinetd二进制文件..."
    
    # 根据架构选择下载链接（支持x86_64和arm64）
    arch=$(uname -m)
    case $arch in
        x86_64)
            rinetd_url="https://github.com/alpinelinux/aports/raw/master/main/rinetd/rinetd"
            ;;
        aarch64)
            rinetd_url="https://github.com/alpinelinux/aports/raw/master/main/rinetd/rinetd"
            ;;
        *)
            echo "不支持的架构: $arch，请手动下载rinetd"
            exit 1
            ;;
    esac
    
    # 下载二进制文件
    wget --no-check-certificate -O "$RINETD_BIN" "$rinetd_url" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "直接下载失败，尝试备用链接..."
        rinetd_url="https://raw.githubusercontent.com/sgerrand/alpine-pkg-rinetd/master/bin/rinetd"
        wget --no-check-certificate -O "$RINETD_BIN" "$rinetd_url" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "手动下载失败，请手动执行以下命令安装："
            echo "wget --no-check-certificate -O $RINETD_BIN https://github.com/alpinelinux/aports/raw/master/main/rinetd/rinetd"
            echo "chmod +x $RINETD_BIN"
            exit 1
        fi
    fi
    
    # 设置执行权限
    chmod +x "$RINETD_BIN"
    
    # 创建服务配置文件
    create_service_file
}

# 创建rinetd服务文件
create_service_file() {
    echo "创建服务配置文件..."
    cat > "$SERVICE_FILE" << EOF
#!/sbin/openrc-run
command="$RINETD_BIN"
command_args="-c $RINETD_CONF"
pidfile="/var/run/rinetd.pid"
EOF
    chmod +x "$SERVICE_FILE"
    
    # 确保配置文件存在
    if [ ! -f "$RINETD_CONF" ]; then
        echo "# rinetd configuration" > "$RINETD_CONF"
        echo "logfile /var/log/rinetd.log" >> "$RINETD_CONF"
    fi
    
    # 设置开机自启
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
}

# 安装rinetd（先尝试包管理器，失败则手动下载）
install_rinetd() {
    check_network
    
    # 先尝试包管理器安装
    if ! command -v rinetd >/dev/null 2>&1 && [ ! -f "$RINETD_BIN" ]; then
        echo "尝试通过包管理器安装rinetd..."
        apk add rinetd >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            RINETD_BIN=$(command -v rinetd)
            create_service_file
            return 0
        fi
        
        # 包管理器失败，使用手动安装
        install_rinetd_manual
    fi
}

# 显示当前规则
show_rules() {
    echo -e "\n===== 当前转发规则 ====="
    grep -v '^#\|^$' "$RINETD_CONF" | grep -v 'logfile' | nl
    if [ $? -ne 0 ]; then
        echo "没有配置转发规则"
    fi
    echo "======================="
}

# 添加转发规则
add_rule() {
    echo -e "\n===== 添加新转发规则 ====="
    
    read -p "请输入监听IP（默认: 0.0.0.0）: " local_ip
    local_ip=${local_ip:-0.0.0.0}
    
    read -p "请输入本地监听端口: " local_port
    if [ -z "$local_port" ] || ! echo "$local_port" | grep -qE '^[0-9]+$' || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo "无效的本地端口（1-65535）"
        return 1
    fi
    
    read -p "请输入目标服务器IP: " remote_ip
    if [ -z "$remote_ip" ]; then
        echo "目标IP不能为空"
        return 1
    fi
    
    read -p "请输入目标服务器端口: " remote_port
    if [ -z "$remote_port" ] || ! echo "$remote_port" | grep -qE '^[0-9]+$' || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo "无效的目标端口（1-65535）"
        return 1
    fi
    
    # 检查端口是否已被使用
    if grep -qE "^[[:space:]]*$local_ip[[:space:]]+$local_port[[:space:]]+" "$RINETD_CONF"; then
        echo "错误：本地端口 $local_port 已被使用"
        return 1
    fi
    
    echo "$local_ip $local_port $remote_ip $remote_port" >> "$RINETD_CONF"
    echo "规则添加成功：$local_ip:$local_port -> $remote_ip:$remote_port"
    restart_service
}

# 删除单个规则
delete_rule() {
    show_rules
    
    read -p "请输入要删除的规则编号: " rule_num
    if [ -z "$rule_num" ] || ! echo "$rule_num" | grep -qE '^[0-9]+$'; then
        echo "无效的规则编号"
        return 1
    fi
    
    line=$(grep -v '^#\|^$' "$RINETD_CONF" | grep -v 'logfile' | sed -n "${rule_num}p")
    if [ -z "$line" ]; then
        echo "规则编号不存在"
        return 1
    fi
    
    cp "$RINETD_CONF" "$RINETD_CONF.bak"
    grep -vF "$line" "$RINETD_CONF.bak" > "$RINETD_CONF"
    rm -f "$RINETD_CONF.bak"
    
    echo "已删除规则: $line"
    restart_service
}

# 清除所有规则
clear_all_rules() {
    read -p "确定要清除所有转发规则吗？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消操作"
        return 0
    fi
    
    cp "$RINETD_CONF" "$RINETD_CONF.bak.$(date +%Y%m%d%H%M%S)"
    grep 'logfile' "$RINETD_CONF" > "$RINETD_CONF.tmp"
    mv "$RINETD_CONF.tmp" "$RINETD_CONF"
    
    echo "所有转发规则已清除"
    restart_service
}

# 服务控制函数
start_service() {
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        echo "$SERVICE_NAME 已在运行"
        return 0
    fi
    
    echo "启动 $SERVICE_NAME..."
    rc-service "$SERVICE_NAME" start
    if [ $? -eq 0 ]; then
        echo "$SERVICE_NAME 启动成功"
    else
        echo "启动失败，尝试直接运行: $RINETD_BIN -c $RINETD_CONF"
    fi
}

stop_service() {
    if ! rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        echo "$SERVICE_NAME 未在运行"
        return 0
    fi
    
    echo "停止 $SERVICE_NAME..."
    rc-service "$SERVICE_NAME" stop
    if [ $? -eq 0 ]; then
        echo "$SERVICE_NAME 已停止"
    else
        pkill -f "$RINETD_BIN" >/dev/null 2>&1
        echo "$SERVICE_NAME 已强制停止"
    fi
}

restart_service() {
    echo "重启 $SERVICE_NAME..."
    if rc-service "$SERVICE_NAME" restart >/dev/null 2>&1; then
        echo "$SERVICE_NAME 重启成功"
    else
        pkill -f "$RINETD_BIN" >/dev/null 2>&1
        $RINETD_BIN -c $RINETD_CONF >/dev/null 2>&1
        echo "$SERVICE_NAME 已重新启动"
    fi
}

# 显示菜单
show_menu() {
    clear
    echo "===================== Alpine端口转发管理工具 ====================="
    echo "支持多端口转发，规则持久化，兼容各种网络环境"
    echo "================================================================="
    echo "1. 添加转发规则"
    echo "2. 删除单个规则"
    echo "3. 清除所有规则"
    echo "4. 启动所有转发规则"
    echo "5. 停止所有转发规则"
    echo "6. 重启所有转发规则"
    echo "7. 查看当前规则"
    echo "0. 退出"
    echo "================================================================="
    read -p "请选择操作 [0-7]: " choice
}

# 主程序
main() {
    install_rinetd
    while true; do
        show_menu
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) clear_all_rules ;;
            4) start_service ;;
            5) stop_service ;;
            6) restart_service ;;
            7) show_rules ;;
            0) 
                echo "感谢使用，再见！"
                exit 0 
                ;;
            *) 
                echo "无效的选择，请重试"
                ;;
        esac
        read -p "按任意键继续..." -n 1
    done
}

main
