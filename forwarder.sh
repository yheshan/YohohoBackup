#!/bin/bash
# 多功能端口转发脚本
# 支持 iptables、socat、nftables
# 支持 TCP、UDP、TCP+UDP、加密隧道
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
    echo "# 工具类型: iptables, socat, nftables, ssh_tunnel" >> $CONFIG_FILE
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
    echo "           多功能端口转发管理脚本            "
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
    echo "3. nftables (新一代防火墙，支持复杂规则)"
    echo "4. ssh_tunnel (加密隧道转发)"
    read -p "请选择 [1-4]: " tool_choice
    
    case $tool_choice in
        1) tool="iptables" ;;
        2) tool="socat" ;;
        3) tool="nftables" ;;
        4) tool="ssh_tunnel" ;;
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
    
    # 特殊处理ssh隧道
    if [ "$tool" = "ssh_tunnel" ]; then
        read -p "请输入SSH服务器用户名@IP: " ssh_server
        read -p "是否使用密钥认证? (y/n，默认n): " use_key
        [ "$use_key" = "y" ] && read -p "请输入私钥路径(默认~/.ssh/id_rsa): " key_path
    fi
    
    # 保存规则到配置文件
    echo "$tool $proto $local_port $dest_ip $dest_port $comment" >> $CONFIG_FILE
    if [ "$tool" = "ssh_tunnel" ]; then
        echo "  ssh_server=$ssh_server" >> $CONFIG_FILE
        [ "$use_key" = "y" ] && echo "  key_path=${key_path:-~/.ssh/id_rsa}" >> $CONFIG_FILE
    fi
    
    echo -e "\n规则已添加，编号为: $(grep -c '^[^#]' $CONFIG_FILE)"
    read -p "是否立即启动该规则? (y/n): " start_now
    if [ "$start_now" = "y" ]; then
        start_rule $(grep -c '^[^#]' $CONFIG_FILE)
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
        
        # 处理常规规则行
        if [[ ! $line =~ ^[[:space:]] ]]; then
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
        fi
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
        nftables)
            nft list ruleset | grep "dport $local_port" | grep "dnat to $dest_ip:$dest_port" >/dev/null 2>&1
            if [ $? -eq 0 ]; then return 0; fi
            ;;
        ssh_tunnel)
            pgrep -f "ssh .* -L $local_port:$dest_ip:$dest_port" >/dev/null 2>&1
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
    ssh_server=""
    key_path=""
    
    current_num=0
    while IFS= read -r line; do
        [[ $line =~ ^# || -z $line ]] && continue
        
        if [[ ! $line =~ ^[[:space:]] ]]; then
            ((current_num++))
            if [ $current_num -eq $rule_num ]; then
                tool=$(echo $line | awk '{print $1}')
                proto=$(echo $line | awk '{print $2}')
                local_port=$(echo $line | awk '{print $3}')
                dest_ip=$(echo $line | awk '{print $4}')
                dest_port=$(echo $line | awk '{print $5}')
                comment=$(echo $line | awk '{$1=$2=$3=$4=$5=""; print $0}' | xargs)
            elif [ $current_num -gt $rule_num ]; then
                break
            fi
        else
            # 处理缩进的附加参数
            if [ $current_num -eq $rule_num ]; then
                if [[ $line =~ ssh_server= ]]; then
                    ssh_server=$(echo $line | sed 's/.*ssh_server=//')
                elif [[ $line =~ key_path= ]]; then
                    key_path=$(echo $line | sed 's/.*key_path=//')
                fi
            fi
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
            
        nftables)
            # 安装nftables（如果未安装）
            if ! command -v nft &> /dev/null; then
                echo "正在安装nftables..."
                apk add --no-cache nftables
                rc-update add nftables default
                service nftables start
            fi
            
            # 启用IP转发
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
            sysctl -p >/dev/null
            
            # 创建表和链（如果不存在）
            nft add table ip nat 2>/dev/null
            nft add chain ip nat prerouting '{ type nat hook prerouting priority 0; policy accept; }' 2>/dev/null
            nft add chain ip nat postrouting '{ type nat hook postrouting priority 100; policy accept; }' 2>/dev/null
            
            # 添加TCP规则
            if [ "$proto" = "tcp" ] || [ "$proto" = "tcp+udp" ]; then
                nft add rule ip nat prerouting tcp dport $local_port dnat to $dest_ip:$dest_port
                nft add rule ip nat postrouting ip daddr $dest_ip tcp dport $dest_port masquerade
            fi
            
            # 添加UDP规则
            if [ "$proto" = "udp" ] || [ "$proto" = "tcp+udp" ]; then
                nft add rule ip nat prerouting udp dport $local_port dnat to $dest_ip:$dest_port
                nft add rule ip nat postrouting ip daddr $dest_ip udp dport $dest_port masquerade
            fi
            
            # 保存规则
            nft list ruleset > /etc/nftables.conf
            ;;
            
        ssh_tunnel)
            # 安装ssh（如果未安装）
            if ! command -v ssh &> /dev/null; then
                echo "正在安装openssh-client..."
                apk add --no-cache openssh-client
            fi
            
            # 构建SSH命令
            ssh_cmd="ssh -N -L $local_port:$dest_ip:$dest_port $ssh_server"
            [ -n "$key_path" ] && ssh_cmd="ssh -i $key_path -N -L $local_port:$dest_ip:$dest_port $ssh_server"
            
            # 启动加密隧道（后台运行）
            nohup $ssh_cmd > $CONFIG_DIR/ssh_tunnel_$local_port.log 2>&1 &
            echo $! > $CONFIG_DIR/ssh_tunnel_$local_port.pid
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
            
        nftables)
            # 删除TCP规则
            if [ "$proto" = "tcp" ] || [ "$proto" = "tcp+udp" ]; then
                nft delete rule ip nat prerouting tcp dport $local_port dnat to $dest_ip:$dest_port
                nft delete rule ip nat postrouting ip daddr $dest_ip tcp dport $dest_port masquerade
            fi
            
            # 删除UDP规则
            if [ "$proto" = "udp" ] || [ "$proto" = "tcp+udp" ]; then
                nft delete rule ip nat prerouting udp dport $local_port dnat to $dest_ip:$dest_port
                nft delete rule ip nat postrouting ip daddr $dest_ip udp dport $dest_port masquerade
            fi
            
            # 保存规则
            nft list ruleset > /etc/nftables.conf
            ;;
            
        ssh_tunnel)
            # 停止SSH隧道
            if [ -f "$CONFIG_DIR/ssh_tunnel_$local_port.pid" ]; then
                kill $(cat $CONFIG_DIR/ssh_tunnel_$local_port.pid) >/dev/null 2>&1
                rm -f $CONFIG_DIR/ssh_tunnel_$local_port.pid
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
        
        if [[ ! $line =~ ^[[:space:]] ]]; then
            ((current_num++))
            if [ $current_num -ne $rule_num ]; then
                echo "$line" >> $tmp_file
            fi
        else
            # 只保留当前规则的附加参数
            if [ $current_num -ne $rule_num ]; then
                echo "$line" >> $tmp_file
            fi
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
