#!/bin/bash
# Socat端口转发一键管理脚本
# 支持TCP/UDP协议，自动后台运行，系统重启自动恢复

# 配置文件路径（修复变量名拼写错误）
CONFIG_FILE="/etc/socat-forward.conf"
service_file=""
rc_local="/etc/rc.local"

# 检查系统类型并设置服务管理器
detect_system() {
    if [ -f "/etc/alpine-release" ]; then
        echo "检测到Alpine系统"
        service_file="/etc/init.d/socat-forward"
        # 确保openrc和rc.local启用
        if ! command -v rc-update &> /dev/null; then
            echo "安装openrc..."
            apk add openrc >/dev/null 2>&1
        fi
        # 确保rc.local服务启用
        if ! rc-update show | grep -q "rc.local"; then
            # 修复Alpine系统下rc.local启用命令
            rc-update add local default >/dev/null 2>&1
            # 确保rc.local文件存在并可执行
            if [ ! -f "$rc_local" ]; then
                echo "#!/bin/sh" > "$rc_local"
                chmod +x "$rc_local"
            fi
        fi
    elif [ -f "/etc/systemd/system.conf" ]; then
        echo "检测到Systemd系统"
        service_file="/etc/systemd/system/socat-forward.service"
    else
        echo "检测到SysVinit系统"
        service_file="/etc/init.d/socat-forward"
    fi
}

# 检查socat是否安装
check_socat() {
    if ! command -v socat &> /dev/null; then
        echo "未检测到socat，正在安装..."
        if command -v apk &> /dev/null; then
            apk add --no-cache socat >/dev/null 2>&1
        elif command -v apt &> /dev/null; then
            apt update >/dev/null 2>&1 && apt install -y socat >/dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y socat >/dev/null 2>&1
        else
            echo "无法自动安装socat，请手动安装后重试"
            exit 1
        fi
    fi
}

# 创建配置文件
create_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "# 格式: 协议 本地端口 远程IP 远程端口 备注" > "$CONFIG_FILE"
        echo "# 示例: tcp 8080 192.168.1.100 80 网站转发" >> "$CONFIG_FILE"
        echo "# 协议支持: tcp, udp, tcp+udp" >> "$CONFIG_FILE"
    fi
}

# 创建服务文件
create_service() {
    if [ -f "/etc/systemd/system.conf" ]; then
        # Systemd服务
        cat > "$service_file" << EOF
[Unit]
Description=Socat Port Forwarding Service
After=network.target

[Service]
Type=forking
ExecStart=/bin/bash $0 start
ExecStop=/bin/bash $0 stop
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable socat-forward >/dev/null 2>&1
    elif [ -f "/etc/alpine-release" ]; then
        # OpenRC服务（优化Alpine支持）
        cat > "$service_file" << EOF
#!/sbin/openrc-run
description="Socat Port Forwarding Service"
start() {
    ebegin "Starting socat-forward"
    /bin/bash $0 start
    eend \$?
}
stop() {
    ebegin "Stopping socat-forward"
    /bin/bash $0 stop
    eend \$?
}
restart() {
    ebegin "Restarting socat-forward"
    /bin/bash $0 restart
    eend \$?
}
EOF
        chmod +x "$service_file"
        rc-update add socat-forward default >/dev/null 2>&1
    else
        # SysVinit服务
        cat > "$service_file" << EOF
#!/bin/bash
case "\$1" in
    start)
        /bin/bash $0 start
        ;;
    stop)
        /bin/bash $0 stop
        ;;
    restart)
        /bin/bash $0 restart
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart}"
        exit 1
        ;;
esac
EOF
        chmod +x "$service_file"
        update-rc.d socat-forward defaults >/dev/null 2>&1
    fi
}

# 添加转发规则
add_rule() {
    echo "===== 添加新转发规则 ====="
    read -p "请选择协议 (tcp/udp/tcp+udp) [默认: tcp]: " proto
    proto=${proto:-tcp}
    
    read -p "请输入本地端口: " local_port
    if [ -z "$local_port" ]; then
        echo "本地端口不能为空!"
        return 1
    fi
    
    read -p "请输入远程IP地址: " remote_ip
    if [ -z "$remote_ip" ]; then
        echo "远程IP不能为空!"
        return 1
    fi
    
    read -p "请输入远程端口: " remote_port
    if [ -z "$remote_port" ]; then
        echo "远程端口不能为空!"
        return 1
    fi
    
    read -p "请输入备注 (可选): " comment
    
    # 检查规则是否已存在
    if grep -qE "^${proto} +${local_port} +${remote_ip} +${remote_port}" "$CONFIG_FILE"; then
        echo "该转发规则已存在!"
        return 1
    fi
    
    # 添加到配置文件
    echo "${proto} ${local_port} ${remote_ip} ${remote_port} ${comment}" >> "$CONFIG_FILE"
    echo "规则添加成功!"
    
    # 立即启动该规则
    start_single_rule "$proto" "$local_port" "$remote_ip" "$remote_port"
}

# 显示所有规则
show_rules() {
    echo "===== 当前转发规则 ====="
    echo "序号 | 协议 | 本地端口 | 远程IP | 远程端口 | 状态 | 备注"
    echo "--------------------------------------------------------"
    count=1
    while IFS= read -r line; do
        # 跳过注释和空行
        [[ "$line" =~ ^# || -z "$line" ]] && continue
        
        proto=$(echo "$line" | awk '{print $1}')
        local_port=$(echo "$line" | awk '{print $2}')
        remote_ip=$(echo "$line" | awk '{print $3}')
        remote_port=$(echo "$line" | awk '{print $4}')
        comment=$(echo "$line" | cut -d' ' -f5-)
        
        # 检查进程是否运行
        if pgrep -f "socat .*${local_port}.*${remote_ip}:${remote_port}" >/dev/null; then
            status="运行中"
        else
            status="已停止"
        fi
        
        echo "${count} | ${proto} | ${local_port} | ${remote_ip} | ${remote_port} | ${status} | ${comment}"
        ((count++))
    done < "$CONFIG_FILE"
}

# 启动单个规则
start_single_rule() {
    proto=$1
    local_port=$2
    remote_ip=$3
    remote_port=$4
    
    # 停止已存在的相同规则
    stop_single_rule "$proto" "$local_port" "$remote_ip" "$remote_port"
    
    # 启动TCP转发
    if [ "$proto" = "tcp" ] || [ "$proto" = "tcp+udp" ]; then
        nohup socat TCP4-LISTEN:${local_port},reuseaddr,fork TCP4:${remote_ip}:${remote_port} >/dev/null 2>&1 &
        echo "TCP转发已启动: ${local_port} -> ${remote_ip}:${remote_port}"
    fi
    
    # 启动UDP转发
    if [ "$proto" = "udp" ] || [ "$proto" = "tcp+udp" ]; then
        nohup socat UDP4-LISTEN:${local_port},reuseaddr,fork UDP4:${remote_ip}:${remote_port} >/dev/null 2>&1 &
        echo "UDP转发已启动: ${local_port} -> ${remote_ip}:${remote_port}"
    fi
}

# 停止单个规则
stop_single_rule() {
    proto=$1
    local_port=$2
    remote_ip=$3
    remote_port=$4
    
    # 停止TCP转发
    if [ "$proto" = "tcp" ] || [ "$proto" = "tcp+udp" ]; then
        if pgrep -f "socat TCP4-LISTEN:${local_port},reuseaddr,fork TCP4:${remote_ip}:${remote_port}" >/dev/null; then
            pkill -f "socat TCP4-LISTEN:${local_port},reuseaddr,fork TCP4:${remote_ip}:${remote_port}"
            echo "TCP转发已停止: ${local_port} -> ${remote_ip}:${remote_port}"
        fi
    fi
    
    # 停止UDP转发
    if [ "$proto" = "udp" ] || [ "$proto" = "tcp+udp" ]; then
        if pgrep -f "socat UDP4-LISTEN:${local_port},reuseaddr,fork UDP4:${remote_ip}:${remote_port}" >/dev/null; then
            pkill -f "socat UDP4-LISTEN:${local_port},reuseaddr,fork UDP4:${remote_ip}:${remote_port}"
            echo "UDP转发已停止: ${local_port} -> ${remote_ip}:${remote_port}"
        fi
    fi
}

# 启动所有规则
start_all() {
    echo "===== 启动所有转发规则 ====="
    while IFS= read -r line; do
        [[ "$line" =~ ^# || -z "$line" ]] && continue
        
        proto=$(echo "$line" | awk '{print $1}')
        local_port=$(echo "$line" | awk '{print $2}')
        remote_ip=$(echo "$line" | awk '{print $3}')
        remote_port=$(echo "$line" | awk '{print $4}')
        
        start_single_rule "$proto" "$local_port" "$remote_ip" "$remote_port"
    done < "$CONFIG_FILE"
}

# 停止所有规则
stop_all() {
    echo "===== 停止所有转发规则 ====="
    # 停止所有socat转发进程
    if pgrep socat >/dev/null; then
        pkill -f "socat (TCP4|UDP4)-LISTEN"
        echo "所有转发已停止"
    else
        echo "没有运行中的转发规则"
    fi
}

# 删除单个规则
delete_rule() {
    show_rules
    read -p "请输入要删除的规则序号: " num
    
    # 获取要删除的行
    line=$(sed -n "${num}p" "$CONFIG_FILE" | grep -v '^#')
    if [ -z "$line" ]; then
        echo "无效的序号!"
        return 1
    fi
    
    proto=$(echo "$line" | awk '{print $1}')
    local_port=$(echo "$line" | awk '{print $2}')
    remote_ip=$(echo "$line" | awk '{print $3}')
    remote_port=$(echo "$line" | awk '{print $4}')
    
    # 停止该规则
    stop_single_rule "$proto" "$local_port" "$remote_ip" "$remote_port"
    
    # 从配置文件中删除
    sed -i "${num}d" "$CONFIG_FILE"
    echo "规则已删除"
}

# 清空所有规则
clear_all() {
    read -p "确定要删除所有规则吗? (y/n) " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        stop_all
        # 保留注释行
        grep '^#' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
        mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        echo "所有规则已清空"
    else
        echo "操作已取消"
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n===== Socat端口转发管理 ====="
        echo "1. 添加转发规则"
        echo "2. 显示所有规则"
        echo "3. 启动全部规则"
        echo "4. 停止全部规则"
        echo "5. 重启全部规则"
        echo "6. 删除单个规则"
        echo "7. 清空所有规则"
        echo "8. 退出"
        read -p "请选择操作 [1-8]: " choice
        
        case $choice in
            1) add_rule ;;
            2) show_rules ;;
            3) start_all ;;
            4) stop_all ;;
            5) stop_all; start_all ;;
            6) delete_rule ;;
            7) clear_all ;;
            8) echo "再见!"; exit 0 ;;
            *) echo "无效的选择，请重试" ;;
        esac
    done
}

# 初始化
init() {
    detect_system
    check_socat
    create_config
    create_service
}

# 处理命令行参数
if [ $# -gt 0 ]; then
    case $1 in
        start)
            detect_system
            start_all
            ;;
        stop)
            detect_system
            stop_all
            ;;
        restart)
            detect_system
            stop_all
            start_all
            ;;
        *)
            echo "用法: $0 [start|stop|restart]"
            exit 1
            ;;
    esac
else
    init
    main_menu
fi
