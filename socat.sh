#!/bin/ash

# 配置文件目录
CONF_DIR="/etc/socat-forward"
RULES_FILE="$CONF_DIR/rules.conf"
PID_DIR="/var/run/socat"
LOG_FILE="/var/log/socat.log"

# 初始化环境
init() {
    # 安装依赖
    apk add --no-cache socat >/dev/null 2>&1
    
    # 创建目录
    mkdir -p "$CONF_DIR" "$PID_DIR"
    touch "$RULES_FILE" "$LOG_FILE"
    
    # 启用IP转发
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p >/dev/null
}

# 添加转发规则
add_rule() {
    echo ">>> 添加转发规则 (输入q退出)"
    while true; do
        read -p "本地监听端口: " LOCAL_PORT
        [ "$LOCAL_PORT" = "q" ] && break
        
        read -p "远程服务器IP: " REMOTE_IP
        read -p "远程端口: " REMOTE_PORT
        read -p "协议类型 [tcp/udp/both]: " PROTO
        
        # 验证输入
        case "$PROTO" in
            tcp|udp|both) ;;
            *) echo "错误协议! 使用 tcp/udp/both"; continue ;;
        esac
        
        # 保存规则
        echo "$LOCAL_PORT:$REMOTE_IP:$REMOTE_PORT:$PROTO" >> "$RULES_FILE"
        echo "规则已添加: $LOCAL_PORT → $REMOTE_IP:$REMOTE_PORT ($PROTO)"
    done
}

# 启动转发
start_all() {
    stop_all >/dev/null
    while IFS=: read -r LOCAL_PORT REMOTE_IP REMOTE_PORT PROTO; do
        case "$PROTO" in
            tcp)
                socat TCP-LISTEN:$LOCAL_PORT,fork,reuseaddr TCP:$REMOTE_IP:$REMOTE_PORT >> "$LOG_FILE" 2>&1 &
                echo $! > "$PID_DIR/tcp_$LOCAL_PORT.pid"
                ;;
            udp)
                socat UDP-LISTEN:$LOCAL_PORT,fork,reuseaddr UDP:$REMOTE_IP:$REMOTE_PORT >> "$LOG_FILE" 2>&1 &
                echo $! > "$PID_DIR/udp_$LOCAL_PORT.pid"
                ;;
            both)
                socat TCP-LISTEN:$LOCAL_PORT,fork,reuseaddr TCP:$REMOTE_IP:$REMOTE_PORT >> "$LOG_FILE" 2>&1 &
                echo $! > "$PID_DIR/tcp_$LOCAL_PORT.pid"
                socat UDP-LISTEN:$LOCAL_PORT,fork,reuseaddr UDP:$REMOTE_IP:$REMOTE_PORT >> "$LOG_FILE" 2>&1 &
                echo $! > "$PID_DIR/udp_$LOCAL_PORT.pid"
                ;;
        esac
    done < "$RULES_FILE"
    echo "所有规则已启动"
}

# 停止转发
stop_all() {
    for pidfile in "$PID_DIR"/*.pid; do
        [ -f "$pidfile" ] && kill $(cat "$pidfile") 2>/dev/null
    done
    rm -f "$PID_DIR"/*.pid
    echo "所有规则已停止"
}

# 删除规则
delete_rules() {
    echo "1) 删除单条规则"
    echo "2) 删除所有规则"
    read -p "选择操作: " choice
    
    case $choice in
        1)
            echo "当前规则:"
            nl -w3 -s': ' "$RULES_FILE"
            read -p "输入要删除的规则号: " num
            sed -i "${num}d" "$RULES_FILE"
            ;;
        2)
            > "$RULES_FILE"
            echo "所有规则已删除"
            ;;
    esac
}

# 查看状态
status() {
    echo "===== 活动转发进程 ====="
    pgrep -lf socat | grep -v "socat.sh"
    
    echo -e "\n===== 配置规则 ====="
    [ -s "$RULES_FILE" ] && cat -n "$RULES_FILE" || echo "无配置规则"
}

# 创建系统服务
create_service() {
    cat > /etc/init.d/socat-forward <<EOF
#!/sbin/openrc-run
name="socat-forward"
description="Socat port forwarding service"

pidfile="/var/run/\$RC_SVCNAME.pid"
command="/usr/local/bin/socat-forward"
command_args="--start"
command_background=true

depend() {
    need net
}
EOF

    chmod +x /etc/init.d/socat-forward
    rc-update add socat-forward default >/dev/null
    echo "系统服务已创建: 开机自动启动"
}

# 主菜单
menu() {
    echo -e "\n===== Socat转发管理器 ====="
    echo "1) 添加转发规则"
    echo "2) 启动所有转发"
    echo "3) 停止所有转发"
    echo "4) 重启所有转发"
    echo "5) 删除转发规则"
    echo "6) 查看当前状态"
    echo "7) 创建开机服务"
    echo "8) 退出"
}

# 参数处理
case "$1" in
    --start) start_all; exit ;;
    --stop) stop_all; exit ;;
    --restart) stop_all; start_all; exit ;;
    *) ;;
esac

# 初始化环境
init

# 显示菜单
while true; do
    menu
    read -p "请选择操作: " choice
    case $choice in
        1) add_rule ;;
        2) start_all ;;
        3) stop_all ;;
        4) stop_all; start_all ;;
        5) delete_rules ;;
        6) status ;;
        7) create_service ;;
        8) exit 0 ;;
        *) echo "无效选择!" ;;
    esac
done
