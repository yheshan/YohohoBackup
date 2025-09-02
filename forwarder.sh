#!/bin/bash
# 简化版端口转发脚本
# 仅支持 iptables 和 socat
# 支持 TCP、UDP、TCP+UDP
# 配置自动持久化，重启后生效

# 配置文件路径
CONFIG_DIR="/etc/forwarding"
CONFIG_FILE="$CONFIG_DIR/rules.conf"
SERVICE_FILE="/etc/init.d/forwarding"

# 确保配置目录存在
mkdir -p $CONFIG_DIR

# 初始化配置文件
if [ ! -f $CONFIG_FILE ]; then
    echo "# 转发规则配置文件" > $CONFIG_FILE
    echo "# 格式: 工具类型 协议 本地端口 目标IP 目标端口 备注" >> $CONFIG_FILE
    echo "# 工具类型: iptables, socat" >> $CONFIG_FILE
    echo "# 协议: tcp, udp, tcp+udp" >> $CONFIG_FILE
fi

# 初始化服务
init_service() {
    if [ ! -f $SERVICE_FILE ]; then
        cat << EOF > $SERVICE_FILE
#!/sbin/openrc-run
description="Port forwarding service"
start() {
    ebegin "Starting port forwarding"
    $0 start_all
    eend \$?
}
stop() {
    ebegin "Stopping port forwarding"
    $0 stop_all
    eend \$?
}
EOF
        chmod +x $SERVICE_FILE
        rc-update add forwarding default
    fi
}

# 显示菜单
show_menu() {
    clear
    echo "============================================="
    echo "           端口转发管理脚本 (精简版)         "
    echo "============================================="
    echo "1. 添加新转发规则"
    echo "2. 查看所有转发规则"
    echo "3. 删除指定转发规则"
    echo "4. 启动所有转发规则"
    echo "5. 停止所有转发规则"
    echo "6. 重启所有转发规则"
    echo "7. 一键清除所有规则"
    echo "0. 退出"
    echo "============================================="
    read -p "请选择操作 [0-7]: " choice
}

# 添加规则
add_rule() {
    echo "============================================="
    echo "               添加新转发规则                "
    echo "============================================="
    
    # 选择工具
    echo "选择转发工具:"
    echo "1. iptables (简单端口转发，性能好)"
    echo "2. socat (灵活，支持多种转发类型)"
    read -p "请选择 [1-2]: " tool_choice
    
    case $tool_choice in
        1) tool="iptables" ;;
        2) tool="socat" ;;
        *) echo "无效选择"; sleep 2; return ;;
    esac
    
    # 选择协议
    echo -e "\n选择协议类型:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP+UDP"
    read -p "请选择 [1-3]: " proto_choice
    
    case $proto_choice in
        1) proto="tcp" ;;
        2) proto="udp" ;;
        3) proto="tcp+udp" ;;
        *) echo "无效选择"; sleep 2; return ;;
    esac
    
    # 输入端口和目标
    read -p "请输入本地监听端口: " local_port
    read -p "请输入目标IP地址: " dest_ip
    read -p "请输入目标端口: " dest_port
    read -p "请输入备注(可选): " comment
    
    # 保存规则到配置文件
    echo "$tool $proto $local_port $dest_ip $dest_port $comment" >> $CONFIG_FILE
    
    rule_number=$(grep -c '^[^#]' $CONFIG_FILE)
    echo -e "\n规则已添加，编号为: $rule_number"
    
    # 默认自动启动规则，只需按回车或输入n取消
    read -p "是否立即启动该规则? (y/n，默认y): " start_now
    # 如果用户直接回车或输入y/Y，都启动规则
    if [ -z "$start_now" ] || [ "$start_now" = "y" ] || [ "$start_now" = "Y" ]; then
        start_rule $rule_number
    else
        echo "规则未立即启动，可稍后手动启动"
    fi
    read -p "按任意键返回菜单..."
}

# 显示所有规则
show_rules() {
    echo "============================================="
    echo "               所有转发规则                  "
    echo "============================================="
    echo "编号  工具        协议      本地端口 -> 目标IP:目标端口  备注"
    echo "---------------------------------------------------------"
    
    rule_num=0
    while IFS= read -r line; do
        # 跳过注释和空行
        [[ $line =~ ^# || -z $line ]] && continue
        
        ((rule_num++))
        tool=$(echo $line | awk '{print $1}')
        proto=$(echo $line | awk '{print $2}')
        local_port=$(echo $line | awk '{print $3}')
        dest_ip=$(echo $line | awk '{print $4}')
        dest_port=$(echo $line | awk '{print $5}')
        comment=$(echo $line | awk '{$1=$2=$3=$4=$5=""; print $0}' | xargs)
        
        # 检查规则是否正在运行
        status="停止"
        if is_running $rule_num; then
            status="运行中"
        fi
        
        printf "%-5d %-10s %-9s %-5s -> %-15s:%-5s  %s (状态: %s)\n" \
            $rule_num $tool $proto $local_port $dest_ip $dest_port "$comment" "$status"
    done < $CONFIG_FILE
    
    echo "============================================="
    read -p "按任意键返回菜单..."
}

# 检查规则是否运行
is_running() {
    rule_num=$1
    get_rule $rule_num
    if [ -z "$tool" ]; then return 1; fi
    
    case $tool in
        iptables)
            if [ "$proto" = "tcp" ] || [ "$proto" = "tcp+udp" ]; then
                iptables -t nat -C PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $dest_ip:$dest_port >/dev/null 2>&1
                if [ $? -eq 0 ]; then return 0; fi
            fi
            if [ "$proto" = "udp" ] || [ "$proto" = "tcp+udp" ]; then
                iptables -t nat -C PREROUTING -p udp --dport $local_port -j DNAT --to-destination $dest_ip:$dest_port >/dev/null 2>&1
                if [ $? -eq 0 ]; then return 0; fi
            fi
            ;;
        socat)
            pgrep -f "socat .*LISTEN:$local_port" >/dev/null 2>&1
            if [ $? -eq 0 ]; then return 0; fi
            ;;
    esac
    return 1
}

# 获取规则详情
get_rule() {
    rule_num=$1
    # 重置变量
    tool=""
    proto=""
    local_port=""
    dest_ip=""
    dest_port=""
    comment=""
    
    current_num=0
    while IFS= read -r line; do
        [[ $line =~ ^# || -z $line ]] && continue
        
        ((current_num++))
        if [ $current_num -eq $rule_num ]; then
            tool=$(echo $line | awk '{print $1}')
            proto=$(echo $line | awk '{print $2}')
            local_port=$(echo $line | awk '{print $3}')
            dest_ip=$(echo $line | awk '{print $4}')
            dest_port=$(echo $line | awk '{print $5}')
            comment=$(echo $line | awk '{$1=$2=$3=$4=$5=""; print $0}' | xargs)
            break
        fi
    done < $CONFIG_FILE
}

# 启动指定规则
start_rule() {
    rule_num=$1
    get_rule $rule_num
    
    if [ -z "$tool" ]; then
        echo "规则不存在"
        return 1
    fi
    
    # 检查是否已运行
    if is_running $rule_num; then
        echo "规则 $rule_num 已在运行"
        return 0
    fi
    
    echo "启动规则 $rule_num: $tool $proto $local_port -> $dest_ip:$dest_port"
    
    case $tool in
        iptables)
            # 启用IP转发
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
            sysctl -p >/dev/null
            
            # 添加TCP规则
            if [ "$proto" = "tcp" ] || [ "$proto" = "tcp+udp" ]; then
                iptables -t nat -A PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $dest_ip:$dest_port
                iptables -t nat -A POSTROUTING -p tcp -d $dest_ip --dport $dest_port -j MASQUERADE
            fi
            
            # 添加UDP规则
            if [ "$proto" = "udp" ] || [ "$proto" = "tcp+udp" ]; then
                iptables -t nat -A PREROUTING -p udp --dport $local_port -j DNAT --to-destination $dest_ip:$dest_port
                iptables -t nat -A POSTROUTING -p udp -d $dest_ip --dport $dest_port -j MASQUERADE
            fi
            
            # 保存规则
            iptables-save > /etc/iptables/rules.v4
            ;;
            
        socat)
            # 安装socat（如果未安装）
            if ! command -v socat &> /dev/null; then
                echo "正在安装socat..."
                apk add --no-cache socat
            fi
            
            # 启动转发（后台运行）
            if [ "$proto" = "tcp" ] || [ "$proto" = "tcp+udp" ]; then
                nohup socat TCP4-LISTEN:$local_port,fork,reuseaddr TCP4:$dest_ip:$dest_port > $CONFIG_DIR/socat_tcp_$local_port.log 2>&1 &
                echo $! > $CONFIG_DIR/socat_tcp_$local_port.pid
            fi
            
            if [ "$proto" = "udp" ] || [ "$proto" = "tcp+udp" ]; then
                nohup socat UDP4-LISTEN:$local_port,fork,reuseaddr UDP4:$dest_ip:$dest_port > $CONFIG_DIR/socat_udp_$local_port.log 2>&1 &
                echo $! > $CONFIG_DIR/socat_udp_$local_port.pid
            fi
            ;;
    esac
    
    echo "规则 $rule_num 启动成功"
}

# 停止指定规则
stop_rule() {
    rule_num=$1
    get_rule $rule_num
    
    if [ -z "$tool" ]; then
        echo "规则不存在"
        return 1
    fi
    
    # 检查是否运行中
    if ! is_running $rule_num; then
        echo "规则 $rule_num 未在运行"
        return 0
    fi
    
    echo "停止规则 $rule_num: $tool $proto $local_port -> $dest_ip:$dest_port"
    
    case $tool in
        iptables)
            # 删除TCP规则
            if [ "$proto" = "tcp" ] || [ "$proto" = "tcp+udp" ]; then
                iptables -t nat -D PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $dest_ip:$dest_port
                iptables -t nat -D POSTROUTING -p tcp -d $dest_ip --dport $dest_port -j MASQUERADE
            fi
            
            # 删除UDP规则
            if [ "$proto" = "udp" ] || [ "$proto" = "tcp+udp" ]; then
                iptables -t nat -D PREROUTING -p udp --dport $local_port -j DNAT --to-destination $dest_ip:$dest_port
                iptables -t nat -D POSTROUTING -p udp -d $dest_ip --dport $dest_port -j MASQUERADE
            fi
            
            # 保存规则
            iptables-save > /etc/iptables/rules.v4
            ;;
            
        socat)
            # 停止TCP转发
            if [ "$proto" = "tcp" ] || [ "$proto" = "tcp+udp" ] && [ -f "$CONFIG_DIR/socat_tcp_$local_port.pid" ]; then
                kill $(cat $CONFIG_DIR/socat_tcp_$local_port.pid) >/dev/null 2>&1
                rm -f $CONFIG_DIR/socat_tcp_$local_port.pid
            fi
            
            # 停止UDP转发
            if [ "$proto" = "udp" ] || [ "$proto" = "tcp+udp" ] && [ -f "$CONFIG_DIR/socat_udp_$local_port.pid" ]; then
                kill $(cat $CONFIG_DIR/socat_udp_$local_port.pid) >/dev/null 2>&1
                rm -f $CONFIG_DIR/socat_udp_$local_port.pid
            fi
            ;;
    esac
    
    echo "规则 $rule_num 已停止"
}

# 启动所有规则
start_all() {
    echo "启动所有转发规则..."
    total_rules=$(grep -c '^[^#]' $CONFIG_FILE)
    
    for ((i=1; i<=$total_rules; i++)); do
        start_rule $i
    done
    
    echo "所有规则启动完成"
}

# 停止所有规则
stop_all() {
    echo "停止所有转发规则..."
    total_rules=$(grep -c '^[^#]' $CONFIG_FILE)
    
    for ((i=1; i<=$total_rules; i++)); do
        stop_rule $i
    done
    
    echo "所有规则已停止"
}

# 删除指定规则
delete_rule() {
    read -p "请输入要删除的规则编号: " rule_num
    total_rules=$(grep -c '^[^#]' $CONFIG_FILE)
    
    if [ -z "$rule_num" ] || [ $rule_num -lt 1 ] || [ $rule_num -gt $total_rules ]; then
        echo "无效的规则编号"
        sleep 2
        return
    fi
    
    # 先停止规则
    stop_rule $rule_num
    
    # 从配置文件中删除
    tmp_file=$(mktemp)
    current_num=0
    while IFS= read -r line; do
        if [[ $line =~ ^# || -z $line ]]; then
            echo "$line" >> $tmp_file
            continue
        fi
        
        ((current_num++))
        if [ $current_num -ne $rule_num ]; then
            echo "$line" >> $tmp_file
        fi
    done < $CONFIG_FILE
    
    mv $tmp_file $CONFIG_FILE
    echo "规则 $rule_num 已删除"
    read -p "按任意键返回菜单..."
}

# 清除所有规则
clear_all() {
    read -p "确定要清除所有转发规则吗? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        echo "操作已取消"
        read -p "按任意键返回菜单..."
        return
    fi
    
    # 停止所有规则
    stop_all
    
    # 清空配置文件（保留注释）
    grep '^#' $CONFIG_FILE > $CONFIG_FILE.tmp
    mv $CONFIG_FILE.tmp $CONFIG_FILE
    
    echo "所有规则已清除"
    read -p "按任意键返回菜单..."
}

# 主程序
init_service

while true; do
    show_menu
    case $choice in
        1) add_rule ;;
        2) show_rules ;;
        3) delete_rule ;;
        4) start_all; read -p "按任意键返回菜单..." ;;
        5) stop_all; read -p "按任意键返回菜单..." ;;
        6) stop_all; start_all; read -p "按任意键返回菜单..." ;;
        7) clear_all ;;
        0) echo "退出脚本"; exit 0 ;;
        *) echo "无效选择，请重试"; sleep 2 ;;
    esac
done
