#!/bin/bash
# 多功能流量转发脚本
# 支持 iptables/socat/nftables 三种方案
# 支持 TCP/UDP/混合模式/加密隧道
# 自动实现规则持久化，重启不丢失

# 配置存储路径
CONFIG_DIR="/etc/forwarder"
RULES_FILE="$CONFIG_DIR/rules.txt"
SERVICE_FILE="/etc/init.d/forwarder"

# 初始化
init() {
    # 创建配置目录
    mkdir -p $CONFIG_DIR
    touch $RULES_FILE
    
    # 安装必要依赖
    if ! command -v iptables &> /dev/null; then
        apk add iptables iptables-save
    fi
    if ! command -v socat &> /dev/null; then
        apk add socat
    fi
    if ! command -v nft &> /dev/null; then
        apk add nftables
    fi
    
    # 创建服务文件实现开机自启
    create_service
    chmod +x $SERVICE_FILE
    rc-update add forwarder default
}

# 创建服务文件
create_service() {
    cat > $SERVICE_FILE << EOF
#!/sbin/openrc-run
description="Traffic forwarder service"

start() {
    ebegin "Starting forwarder"
    $0 start_all
    eend \$?
}

stop() {
    ebegin "Stopping forwarder"
    $0 stop_all
    eend \$?
}

restart() {
    stop
    start
}
EOF
}

# 选择转发方案
select_method() {
    echo "请选择转发方案:"
    echo "1) iptables (适合简单端口转发)"
    echo "2) socat (适合复杂转发场景)"
    echo "3) nftables (新一代防火墙，功能强大)"
    read -p "请输入选项 [1-3]: " method
    case $method in
        1) METHOD="iptables" ;;
        2) METHOD="socat" ;;
        3) METHOD="nftables" ;;
        *) echo "无效选项"; select_method ;;
    esac
}

# 选择协议类型
select_proto() {
    echo "请选择协议类型:"
    echo "1) TCP"
    echo "2) UDP"
    echo "3) TCP+UDP"
    echo "4) 加密隧道 (仅socat支持)"
    read -p "请输入选项 [1-4]: " proto
    case $proto in
        1) PROTO="tcp" ;;
        2) PROTO="udp" ;;
        3) PROTO="both" ;;
        4) PROTO="tunnel"; METHOD="socat" ;;  # 加密隧道强制使用socat
        *) echo "无效选项"; select_proto ;;
    esac
}

# 添加转发规则
add_rule() {
    select_method
    select_proto
    
    read -p "请输入本地监听端口: " local_port
    read -p "请输入远程IP地址: " remote_ip
    read -p "请输入远程端口: " remote_port
    
    # 生成唯一ID
    RULE_ID=$(date +%s)
    
    # 保存规则到配置文件
    echo "$RULE_ID|$METHOD|$PROTO|$local_port|$remote_ip|$remote_port" >> $RULES_FILE
    
    # 立即应用规则
    apply_rule $RULE_ID $METHOD $PROTO $local_port $remote_ip $remote_port
    
    echo "已添加转发规则 ID: $RULE_ID"
    echo "本地端口 $local_port -> 远程 $remote_ip:$remote_port ($PROTO)"
}

# 应用规则
apply_rule() {
    local id=$1
    local method=$2
    local proto=$3
    local lport=$4
    local rhost=$5
    local rport=$6
    
    case $method in
        iptables)
            # 启用IP转发
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
            sysctl -p
            
            # 应用TCP规则
            if [ "$proto" = "tcp" ] || [ "$proto" = "both" ]; then
                iptables -t nat -A PREROUTING -p tcp --dport $lport -j DNAT --to-destination $rhost:$rport
                iptables -t nat -A POSTROUTING -p tcp -d $rhost --dport $rport -j MASQUERADE
            fi
            
            # 应用UDP规则
            if [ "$proto" = "udp" ] || [ "$proto" = "both" ]; then
                iptables -t nat -A PREROUTING -p udp --dport $lport -j DNAT --to-destination $rhost:$rport
                iptables -t nat -A POSTROUTING -p udp -d $rhost --dport $rport -j MASQUERADE
            fi
            
            # 保存iptables规则
            iptables-save > /etc/iptables/rules.v4
            ;;
            
        socat)
            # 创建日志目录
            mkdir -p /var/log/forwarder
            
            # 启动命令前缀
            cmd_prefix="socat -d -d -lf /var/log/forwarder/$id.log"
            
            # 应用TCP规则
            if [ "$proto" = "tcp" ] || [ "$proto" = "both" ]; then
                $cmd_prefix TCP4-LISTEN:$lport,fork TCP4:$rhost:$rport &
                echo $! > $CONFIG_DIR/$id-tcp.pid
            fi
            
            # 应用UDP规则
            if [ "$proto" = "udp" ] || [ "$proto" = "both" ]; then
                $cmd_prefix UDP4-LISTEN:$lport,fork UDP4:$rhost:$rport &
                echo $! > $CONFIG_DIR/$id-udp.pid
            fi
            
            # 应用加密隧道
            if [ "$proto" = "tunnel" ]; then
                read -p "请设置加密密码: " tunnel_pass
                $cmd_prefix OPENSSL-LISTEN:$lport,cert=/etc/ssl/certs/localhost.crt,key=/etc/ssl/private/localhost.key,cipher=AES256-SHA,fork OPENSSL:$rhost:$rport,cert=/etc/ssl/certs/localhost.crt,key=/etc/ssl/private/localhost.key,cipher=AES256-SHA &
                echo $! > $CONFIG_DIR/$id-tunnel.pid
                # 保存密码（实际应用中建议使用更安全的方式）
                echo "$tunnel_pass" > $CONFIG_DIR/$id-pass.txt
                chmod 600 $CONFIG_DIR/$id-pass.txt
            fi
            ;;
            
        nftables)
            # 创建nftables规则集
            nft add table ip forward_table 2>/dev/null
            nft add chain ip forward_table prerouting '{ type nat hook prerouting priority 0; policy accept; }' 2>/dev/null
            nft add chain ip forward_table postrouting '{ type nat hook postrouting priority 100; policy accept; }' 2>/dev/null
            
            # 应用TCP规则
            if [ "$proto" = "tcp" ] || [ "$proto" = "both" ]; then
                nft add rule ip forward_table prerouting tcp dport $lport dnat to $rhost:$rport
                nft add rule ip forward_table postrouting ip daddr $rhost tcp dport $rport masquerade
            fi
            
            # 应用UDP规则
            if [ "$proto" = "udp" ] || [ "$proto" = "both" ]; then
                nft add rule ip forward_table prerouting udp dport $lport dnat to $rhost:$rport
                nft add rule ip forward_table postrouting ip daddr $rhost udp dport $rport masquerade
            fi
            
            # 保存nftables规则
            nft list ruleset > /etc/nftables.conf
            ;;
    esac
}

# 显示所有规则
list_rules() {
    echo "当前转发规则列表:"
    echo "ID | 方法 | 协议 | 本地端口 | 远程地址:端口"
    echo "-----------------------------------------"
    while IFS='|' read -r id method proto lport rhost rport; do
        if [ -n "$id" ]; then
            echo "$id | $method | $proto | $lport | $rhost:$rport"
        fi
    done < $RULES_FILE
}

# 删除单个规则
delete_rule() {
    list_rules
    read -p "请输入要删除的规则ID: " id
    
    # 查找规则
    rule=$(grep "^$id|" $RULES_FILE)
    if [ -z "$rule" ]; then
        echo "未找到ID为 $id 的规则"
        return 1
    fi
    
    # 解析规则
    IFS='|' read -r rid method proto lport rhost rport <<< "$rule"
    
    # 删除规则
    case $method in
        iptables)
            # 删除TCP规则
            if [ "$proto" = "tcp" ] || [ "$proto" = "both" ]; then
                iptables -t nat -D PREROUTING -p tcp --dport $lport -j DNAT --to-destination $rhost:$rport
                iptables -t nat -D POSTROUTING -p tcp -d $rhost --dport $rport -j MASQUERADE
            fi
            
            # 删除UDP规则
            if [ "$proto" = "udp" ] || [ "$proto" = "both" ]; then
                iptables -t nat -D PREROUTING -p udp --dport $lport -j DNAT --to-destination $rhost:$rport
                iptables -t nat -D POSTROUTING -p udp -d $rhost --dport $rport -j MASQUERADE
            fi
            
            # 保存iptables规则
            iptables-save > /etc/iptables/rules.v4
            ;;
            
        socat)
            # 停止进程
            if [ -f "$CONFIG_DIR/$id-tcp.pid" ]; then
                kill $(cat $CONFIG_DIR/$id-tcp.pid)
                rm $CONFIG_DIR/$id-tcp.pid
            fi
            if [ -f "$CONFIG_DIR/$id-udp.pid" ]; then
                kill $(cat $CONFIG_DIR/$id-udp.pid)
                rm $CONFIG_DIR/$id-udp.pid
            fi
            if [ -f "$CONFIG_DIR/$id-tunnel.pid" ]; then
                kill $(cat $CONFIG_DIR/$id-tunnel.pid)
                rm $CONFIG_DIR/$id-tunnel.pid
                rm -f $CONFIG_DIR/$id-pass.txt
            fi
            ;;
            
        nftables)
            # 删除TCP规则
            if [ "$proto" = "tcp" ] || [ "$proto" = "both" ]; then
                nft delete rule ip forward_table prerouting tcp dport $lport dnat to $rhost:$rport
                nft delete rule ip forward_table postrouting ip daddr $rhost tcp dport $rport masquerade
            fi
            
            # 删除UDP规则
            if [ "$proto" = "udp" ] || [ "$proto" = "both" ]; then
                nft delete rule ip forward_table prerouting udp dport $lport dnat to $rhost:$rport
                nft delete rule ip forward_table postrouting ip daddr $rhost udp dport $rport masquerade
            fi
            
            # 保存nftables规则
            nft list ruleset > /etc/nftables.conf
            ;;
    esac
    
    # 从配置文件中删除
    sed -i "/^$id|/d" $RULES_FILE
    echo "已删除规则 ID: $id"
}

# 清除所有规则
clear_all() {
    read -p "确定要清除所有转发规则吗? [y/N] " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "操作已取消"
        return 1
    fi
    
    # 清除iptables规则
    iptables -t nat -F
    iptables -t nat -X
    iptables-save > /etc/iptables/rules.v4
    
    # 清除nftables规则
    nft flush table ip forward_table 2>/dev/null
    
    # 停止所有socat进程
    pkill -f "socat.*forwarder"
    rm -f $CONFIG_DIR/*.pid
    rm -f $CONFIG_DIR/*-pass.txt
    
    # 清空规则文件
    > $RULES_FILE
    
    echo "已清除所有转发规则"
}

# 启动所有规则
start_all() {
    echo "启动所有转发规则..."
    while IFS='|' read -r id method proto lport rhost rport; do
        if [ -n "$id" ]; then
            apply_rule $id $method $proto $lport $rhost $rport
        fi
    done < $RULES_FILE
    echo "所有规则已启动"
}

# 停止所有规则
stop_all() {
    echo "停止所有转发规则..."
    # 保存当前规则但不删除配置
    temp_file=$(mktemp)
    cp $RULES_FILE $temp_file
    
    # 清除所有规则但保留配置
    iptables -t nat -F
    iptables -t nat -X
    iptables-save > /etc/iptables/rules.v4
    
    nft flush table ip forward_table 2>/dev/null
    
    pkill -f "socat.*forwarder"
    rm -f $CONFIG_DIR/*.pid
    
    # 恢复配置文件
    mv $temp_file $RULES_FILE
    
    echo "所有规则已停止"
}

# 显示帮助
show_help() {
    echo "流量转发一键脚本"
    echo "用法: $0 [选项]"
    echo "选项:"
    echo "  add       - 添加新的转发规则"
    echo "  list      - 显示所有转发规则"
    echo "  delete    - 删除指定转发规则"
    echo "  clear     - 清除所有转发规则"
    echo "  start     - 启动所有转发规则"
    echo "  stop      - 停止所有转发规则"
    echo "  restart   - 重启所有转发规则"
    echo "  help      - 显示帮助信息"
}

# 初始化脚本
init

# 处理命令行参数
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
        start_all
        ;;
    stop)
        stop_all
        ;;
    restart)
        stop_all
        start_all
        ;;
    help|*)
        show_help
        ;;
esac
