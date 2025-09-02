#!/bin/bash

# 配置文件目录
CONFIG_DIR="/etc/socat-forward"
RULES_FILE="$CONFIG_DIR/rules.conf"
LOG_FILE="/var/log/socat-forward.log"

# 初始化配置
init() {
    mkdir -p "$CONFIG_DIR"
    touch "$RULES_FILE"
    echo "初始化完成！配置目录: $CONFIG_DIR"
}

# 添加转发规则
add_rule() {
    echo ">>> 选择协议类型:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP+UDP (双栈)"
    read -p "输入选项 (默认1): " protocol
    case "$protocol" in
        1) PROTOCOL="tcp";;
        2) PROTOCOL="udp";;
        3) PROTOCOL="tcp,udp";;
        *) PROTOCOL="tcp";;
    esac

    read -p "本地监听端口 (例如 8080): " LOCAL_PORT
    read -p "远程目标地址 (例如 1.1.1.1:80): " REMOTE_ADDR

    # 是否启用加密
    read -p "启用 OpenSSL 加密？ [y/N]: " USE_SSL
    if [[ "$USE_SSL" =~ [yY] ]]; then
        SSL_OPT="openssl-connect"
        echo "注意: 目标需支持 SSL 连接。"
    else
        SSL_OPT=""
    fi

    # 生成规则
    RULE="$PROTOCOL:$LOCAL_PORT:$REMOTE_ADDR:$SSL_OPT"
    echo "$RULE" >> "$RULES_FILE"
    echo "规则已添加: $RULE"

    # 启动转发
    start_rule "$RULE"
}

# 启动单条规则
start_rule() {
    RULE=$1
    IFS=':' read -r PROTOCOL LOCAL_PORT REMOTE_ADDR SSL_OPT <<< "$RULE"

    if [[ "$PROTOCOL" == "tcp" ]]; then
        SOCAT_CMD="socat TCP-LISTEN:$LOCAL_PORT,fork,reuseaddr"
    elif [[ "$PROTOCOL" == "udp" ]]; then
        SOCAT_CMD="socat UDP-LISTEN:$LOCAL_PORT,fork,reuseaddr"
    else
        SOCAT_CMD="socat TCP-LISTEN:$LOCAL_PORT,fork,reuseaddr UDP-LISTEN:$LOCAL_PORT,fork,reuseaddr"
    fi

    if [[ -n "$SSL_OPT" ]]; then
        SOCAT_CMD="$SOCAT_CMD openssl-connect:$REMOTE_ADDR,verify=0"
    else
        SOCAT_CMD="$SOCAT_CMD TCP:$REMOTE_ADDR"
    fi

    # 后台运行并记录 PID
    nohup $SOCAT_CMD >> "$LOG_FILE" 2>&1 &
    echo $! >> "$CONFIG_DIR/pids.txt"
    echo "转发已启动: $SOCAT_CMD"
}

# 启动所有规则
start_all() {
    while read -r RULE; do
        start_rule "$RULE"
    done < "$RULES_FILE"
}

# 删除规则
delete_rule() {
    echo "当前规则:"
    cat -n "$RULES_FILE"
    read -p "输入要删除的规则编号: " RULE_NUM
    sed -i "${RULE_NUM}d" "$RULES_FILE"
    echo "规则已删除！"
}

# 清除所有规则
clear_all() {
    kill $(cat "$CONFIG_DIR/pids.txt" 2>/dev/null) 2>/dev/null
    rm -f "$CONFIG_DIR/pids.txt"
    echo "" > "$RULES_FILE"
    echo "所有规则已清除！"
}

# 持久化配置（重启后自动运行）
enable_persistence() {
    if command -v systemctl >/dev/null; then
        # Systemd 服务
        cat > /etc/systemd/system/socat-forward.service <<EOF
[Unit]
Description=Socat Port Forwarding
After=network.target

[Service]
ExecStart=/bin/bash -c "$(realpath $0) --start"
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable socat-forward.service
        systemctl start socat-forward.service
        echo "已启用 systemd 持久化！"
    else
        # rc.local 方式
        echo "/bin/bash $(realpath $0) --start" >> /etc/rc.local
        chmod +x /etc/rc.local
        echo "已添加到 rc.local！"
    fi
}

# 主菜单
menu() {
    echo "=== Socat 一键转发脚本 ==="
    echo "1. 添加转发规则"
    echo "2. 查看当前规则"
    echo "3. 删除单个规则"
    echo "4. 一键清除所有规则"
    echo "5. 启用持久化（重启后自动运行）"
    echo "6. 退出"
    read -p "输入选项: " CHOICE

    case "$CHOICE" in
        1) add_rule;;
        2) cat "$RULES_FILE";;
        3) delete_rule;;
        4) clear_all;;
        5) enable_persistence;;
        6) exit 0;;
        *) echo "无效选项！";;
    esac
}

# 初始化
init

# 命令行参数
case "$1" in
    "--start") start_all;;
    *) menu;;
esac
