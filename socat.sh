#!/bin/sh
# Socat 端口转发发管理脚本
# 支持 TCP/UDP/加密隧道 转发，自动开机启动，多规则管理

# 配置存储路径
CONFIG_DIR="/etc/socat-forward"
SERVICE_FILE="/etc/init.d/socat-forward"
RULES_FILE="$CONFIG_DIR/rules.conf"

# 初始化环境
init_env() {
    # 安装必要组件
    if ! command -v socat &> /dev/null; then
        echo "正在安装 socat..."
        apk add --no-cache socat
    fi
    
    # 创建配置目录
    mkdir -p $CONFIG_DIR
    touch $RULES_FILE
    
    # 创建服务文件
    if [ ! -f $SERVICE_FILE ]; then
        cat > $SERVICE_FILE << EOF
#!/sbin/openrc-run
description="Socat port forwarding service"
command="/bin/sh"
command_args="$0 start"
pidfile="/var/run/socat-forward.pid"
EOF
        chmod +x $SERVICE_FILE
        rc-update add socat-forward default
        echo "已配置开机启动"
    fi
}

# 添加转发规则
add_rule() {
    echo "===== 添加新转发规则 ====="
    read -p "请输入本地端口: " local_port
    read -p "请输入目标IP: " target_ip
    read -p "请输入目标端口: " target_port
    
    echo "协议选项: "
    echo "1. TCP (默认)"
    echo "2. UDP"
    echo "3. TCP+UDP"
    echo "4. 加密隧道 (TCP+SSL)"
    read -p "请选择协议(1-4): " proto_choice
    proto_choice=${proto_choice:-1}
    
    # 生成规则ID
    rule_id="$(date +%s)-$local_port"
    
    # 构建转发命令
    case $proto_choice in
        1)
            cmd="socat TCP-LISTEN:$local_port,reuseaddr,fork TCP:$target_ip:$target_port"
            proto="tcp"
            ;;
        2)
            cmd="socat UDP-LISTEN:$local_port,reuseaddr,fork UDP:$target_ip:$target_port"
            proto="udp"
            ;;
        3)
            cmd="socat TCP-LISTEN:$local_port,reuseaddr,fork TCP:$target_ip:$target_port & "
            cmd="$cmd socat UDP-LISTEN:$local_port,reuseaddr,fork UDP:$target_ip:$target_port"
            proto="tcp+udp"
            ;;
        4)
            read -p "请输入SSL证书路径(默认: 自动生成临时证书): " cert_path
            cert_path=${cert_path:-$CONFIG_DIR/temp_cert.pem}
            
            # 生成临时证书
            if [ ! -f $cert_path ]; then
                apk add --no-cache openssl
                openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
                    -subj "/CN=socat-forward" \
                    -keyout $cert_path -out $cert_path
            fi
            
            cmd="socat OPENSSL-LISTEN:$local_port,cert=$cert_path,verify=0,fork TCP:$target_ip:$target_port"
            proto="ssl-tcp"
            ;;
    esac
    
    # 保存规则
    echo "$rule_id|$local_port|$target_ip:$target_port|$proto|$cmd" >> $RULES_FILE
    echo "已添加规则 [ID: $rule_id]"
    echo "本地端口: $local_port -> 目标: $target_ip:$target_port ($proto)"
    
    # 立即启动
    eval "$cmd &"
    echo $! > "$CONFIG_DIR/$rule_id.pid"
}

# 列出所有规则
list_rules() {
    echo "===== 当前转发规则 ====="
    echo "ID                 本地端口  目标地址           协议"
    echo "--------------------------------------------------------"
    while IFS='|' read -r id lport target proto _; do
        if [ -n "$id" ]; then
            printf "%-18s %-8s %-20s %s\n" "$id" "$lport" "$target" "$proto"
        fi
    done < $RULES_FILE
}

# 删除指定规则
delete_rule() {
    read -p "请输入要删除的规则ID: " rule_id
    if grep -q "^$rule_id|" $RULES_FILE; then
        # 停止进程
        if [ -f "$CONFIG_DIR/$rule_id.pid" ]; then
            kill $(cat "$CONFIG_DIR/$rule_id.pid") 2>/dev/null
            rm -f "$CONFIG_DIR/$rule_id.pid"
        fi
        
        # 删除规则
        sed -i "/^$rule_id|/d" $RULES_FILE
        echo "已删除规则 $rule_id"
    else
        echo "未找到规则 $rule_id"
    fi
}

# 清除所有规则
clear_all() {
    read -p "确定要删除所有规则吗? (y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        # 停止所有进程
        for pidfile in $CONFIG_DIR/*.pid; do
            if [ -f "$pidfile" ]; then
                kill $(cat "$pidfile") 2>/dev/null
                rm -f "$pidfile"
            fi
        done
        
        # 清空规则文件
        > $RULES_FILE
        echo "已清除所有规则"
    fi
}

# 启动所有规则
start_rules() {
    echo "启动所有转发规则..."
    while IFS='|' read -r id _ _ _ cmd; do
        if [ -n "$id" ]; then
            eval "$cmd &"
            echo $! > "$CONFIG_DIR/$id.pid"
            echo "启动规则 $id"
        fi
    done < $RULES_FILE
    echo "所有规则已启动"
}

# 停止所有规则
stop_rules() {
    echo "停止所有转发规则..."
    for pidfile in $CONFIG_DIR/*.pid; do
        if [ -f "$pidfile" ]; then
            kill $(cat "$pidfile") 2>/dev/null
            rm -f "$pidfile"
            echo "停止规则 $(basename $pidfile .pid)"
        fi
    done
}

# 显示帮助
show_help() {
    echo "Socat 端口转发管理脚本"
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  add      - 添加新转发规则"
    echo "  list     - 列出所有转发规则"
    echo "  delete   - 删除指定规则"
    echo "  clear    - 清除所有规则"
    echo "  start    - 启动所有规则"
    echo "  stop     - 停止所有规则"
    echo "  restart  - 重启所有规则"
    echo "  help     - 显示帮助信息"
}

# 主逻辑
init_env

case "$1" in
    add)
        add_rule
        ;;
    list)
        list_rules
        ;;
    delete)
        delete_rule
        ;;
    clear)
        clear_all
        ;;
    start)
        start_rules
        ;;
    stop)
        stop_rules
        ;;
    restart)
        stop_rules
        start_rules
        ;;
    help|*)
        show_help
        ;;
esac
