#!/bin/sh
# Socat 端口转发管理脚本 (最终修复版)
# 支持 TCP/UDP/加密隧道，自动后台运行和开机启动

# 配置存储路径
CONFIG_DIR="/etc/socat-forward"
SERVICE_FILE="/etc/init.d/socat-forward"
RULES_FILE="$CONFIG_DIR/rules.conf"
PID_DIR="$CONFIG_DIR/pids"

# 初始化环境
init_env() {
    # 安装必要工具
    apk add --no-cache socat openssl psmisc >/dev/null 2>&1
    
    # 创建配置目录和文件
    mkdir -p $CONFIG_DIR
    mkdir -p $PID_DIR
    [ -f "$RULES_FILE" ] || touch "$RULES_FILE"
    chmod +x "$RULES_FILE"
    
    # 创建服务文件（OpenRC）
    if [ ! -f "$SERVICE_FILE" ]; then
        cat > "$SERVICE_FILE" << 'EOF'
#!/sbin/openrc-run
# 开机启动 socat 转发规则

depend() {
    need net
    after firewall
}

start() {
    ebegin "Starting socat forward rules"
    /usr/local/bin/socat-manager.sh start
    eend $?
}

stop() {
    ebegin "Stopping socat forward rules"
    /usr/local/bin/socat-manager.sh stop
    eend $?
}
EOF
        chmod +x "$SERVICE_FILE"
        rc-update add socat-forward default >/dev/null 2>&1
    fi
}

# 显示当前规则
show_rules() {
    echo -e "\n===== 当前转发规则 ====="
    if [ -s "$RULES_FILE" ]; then
        # 显示规则ID和详情
        awk -F'|' '$1 ~ /^[0-9]+$/ {printf "%2d) ID: %s | %s | 本地 %s -> 远程 %s:%s\n", NR, $1, $2, $3, $4, $5}' "$RULES_FILE"
    else
        echo "没有配置任何转发规则"
    fi
    echo "=========================="
}

# 启动指定ID的规则
start_rule() {
    local rule_id=$1
    # 从规则文件获取规则详情
    local rule=$(grep "^$rule_id|" "$RULES_FILE")
    if [ -z "$rule" ]; then
        echo "规则 $rule_id 不存在"
        return 1
    fi
    
    # 解析规则
    local proto=$(echo "$rule" | cut -d'|' -f2)
    local local_port=$(echo "$rule" | cut -d'|' -f3)
    local remote_addr=$(echo "$rule" | cut -d'|' -f4)
    local remote_port=$(echo "$rule" | cut -d'|' -f5)
    
    # 构建启动命令
    local cmd=""
    case $proto in
        "TCP")
            cmd="socat TCP-LISTEN:$local_port,reuseaddr,fork TCP:$remote_addr:$remote_port"
            ;;
        "UDP")
            cmd="socat UDP-LISTEN:$local_port,reuseaddr,fork UDP:$remote_addr:$remote_port"
            ;;
        "TCP+UDP")
            cmd="socat TCP-LISTEN:$local_port,reuseaddr,fork TCP:$remote_addr:$remote_port & "
            cmd="$cmd socat UDP-LISTEN:$local_port,reuseaddr,fork UDP:$remote_addr:$remote_port"
            ;;
        "SSL-TCP")
            # 确保证书存在
            [ -f "$CONFIG_DIR/cert.pem" ] || openssl req -x509 -newkey rsa:4096 -nodes \
                -keyout "$CONFIG_DIR/key.pem" -out "$CONFIG_DIR/cert.pem" \
                -days 365 -subj "/CN=socat-forward" >/dev/null 2>&1
            cmd="socat TCP-LISTEN:$local_port,reuseaddr,fork OPENSSL:$remote_addr:$remote_port,verify=0"
            ;;
    esac
    
    # 启动并记录PID
    if [ -n "$cmd" ]; then
        nohup sh -c "$cmd" >/dev/null 2>&1 &
        echo $! > "$PID_DIR/$rule_id.pid"
        echo "规则 $rule_id 已启动 (PID: $(cat "$PID_DIR/$rule_id.pid"))"
    fi
}

# 停止指定ID的规则
stop_rule() {
    local rule_id=$1
    if [ -f "$PID_DIR/$rule_id.pid" ]; then
        # 终止进程
        local pids=$(cat "$PID_DIR/$rule_id.pid")
        # 处理TCP+UDP的多个PID
        for pid in $pids; do
            if ps -p $pid >/dev/null; then
                kill $pid >/dev/null 2>&1
                echo "已终止进程 $pid"
            fi
        done
        rm -f "$PID_DIR/$rule_id.pid"
    fi
}

# 添加新规则
add_rule() {
    echo -e "\n----- 添加新转发规则 -----"
    
    # 选择协议类型
    echo "1) TCP"
    echo "2) UDP"
    echo "3) TCP+UDP"
    echo "4) 加密隧道 (TCP over SSL)"
    read -p "请选择协议类型 [1-4, 默认1]: " proto_choice
    proto_choice=${proto_choice:-1}

    # 映射协议名称
    case $proto_choice in
        1) proto="TCP" ;;
        2) proto="UDP" ;;
        3) proto="TCP+UDP" ;;
        4) proto="SSL-TCP" ;;
    esac

    # 获取本地端口
    read -p "请输入本地监听端口: " local_port
    while ! echo "$local_port" | grep -qE '^[0-9]+$' || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; do
        read -p "无效端口，请重新输入: " local_port
    done

    # 获取远程地址和端口
    read -p "请输入远程服务器IP或域名: " remote_addr
    read -p "请输入远程服务器端口: " remote_port
    while ! echo "$remote_port" | grep -qE '^[0-9]+$' || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; do
        read -p "无效端口，请重新输入: " remote_port
    done

    # 生成规则ID
    rule_id=$(date +%s)
    
    # 写入规则配置（使用分隔符格式，避免函数定义）
    echo "$rule_id|$proto|$local_port|$remote_addr|$remote_port" >> "$RULES_FILE"

    echo "规则添加成功！ID: $rule_id"
    start_rule $rule_id  # 立即启动
    read -p "按回车键返回主菜单..."
}

# 删除指定规则
delete_rule() {
    show_rules
    read -p "请输入要删除的规则序号: " rule_num
    if [ -z "$rule_num" ]; then
        echo "取消删除"
        read -p "按回车键返回主菜单..."
        return 1
    fi

    # 获取对应规则ID
    rule_id=$(awk -F'|' '$1 ~ /^[0-9]+$/ {print $1}' "$RULES_FILE" | sed -n "${rule_num}p")
    if [ -z "$rule_id" ]; then
        echo "无效的规则序号"
        read -p "按回车键返回主菜单..."
        return 1
    fi

    # 停止并删除规则
    stop_rule $rule_id
    # 删除规则行
    sed -i "/^$rule_id|/d" "$RULES_FILE"
    echo "规则 $rule_num (ID: $rule_id) 已删除"
    read -p "按回车键返回主菜单..."
}

# 清空所有规则
clear_all() {
    read -p "确定要删除所有规则吗？[y/N] " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        # 停止所有规则
        while read -r rule; do
            rule_id=$(echo "$rule" | cut -d'|' -f1)
            stop_rule $rule_id
        done < "$RULES_FILE"
        
        # 清空规则文件
        > "$RULES_FILE"
        echo "所有规则已清空"
    else
        echo "取消操作"
    fi
    read -p "按回车键返回主菜单..."
}

# 启动/停止所有规则
control_rules() {
    action=$1
    if [ "$action" = "start" ]; then
        echo "启动所有转发规则..."
        while read -r rule; do
            rule_id=$(echo "$rule" | cut -d'|' -f1)
            start_rule $rule_id
        done < "$RULES_FILE"
    elif [ "$action" = "stop" ]; then
        echo "停止所有转发规则..."
        while read -r rule; do
            rule_id=$(echo "$rule" | cut -d'|' -f1)
            stop_rule $rule_id
        done < "$RULES_FILE"
    fi
    read -p "按回车键返回主菜单..."
}

# 显示主菜单
show_menu() {
    clear
    echo "=============================="
    echo "      Socat 转发管理工具       "
    echo "=============================="
    echo "1. 添加新转发规则"
    echo "2. 查看所有转发规则"
    echo "3. 删除指定转发规则"
    echo "4. 清空所有转发规则"
    echo "5. 启动所有转发规则"
    echo "6. 停止所有转发规则"
    echo "7. 重启所有转发规则"
    echo "8. 退出"
    echo "=============================="
    read -p "请输入操作编号 [1-8]: " choice
}

# 主逻辑
main() {
    init_env  # 初始化环境
    
    # 处理直接执行的命令（用于服务启动）
    if [ "$1" = "start" ]; then
        control_rules start
        exit 0
    elif [ "$1" = "stop" ]; then
        control_rules stop
        exit 0
    fi
    
    while true; do
        show_menu
        case "$choice" in
            1)
                add_rule
                ;;
            2)
                show_rules
                read -p "按回车键返回主菜单..."
                ;;
            3)
                delete_rule
                ;;
            4)
                clear_all
                ;;
            5)
                control_rules start
                ;;
            6)
                control_rules stop
                ;;
            7)
                control_rules stop
                control_rules start
                echo "所有规则已重启"
                read -p "按回车键返回主菜单..."
                ;;
            8)
                echo "感谢使用，再见！"
                exit 0
                ;;
            *)
                echo "无效的选择，请输入 1-8 之间的数字"
                read -p "按回车键继续..."
                ;;
        esac
    done
}

# 执行主函数
main "$@"
