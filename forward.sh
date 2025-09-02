#!/bin/sh
# Alpine Socat端口转发管理工具
# 轻量稳定，兼容各种Alpine环境

# 配置文件和工作目录
CONFIG_FILE="/etc/socat_forward.conf"
PID_DIR="/var/run/socat_forward"
LOG_DIR="/var/log/socat_forward"

# 确保目录存在
mkdir -p "$PID_DIR" "$LOG_DIR"

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

# 安装socat（多种安装方式）
install_socat() {
    # 先检查是否已安装
    if command -v socat >/dev/null 2>&1; then
        return 0
    fi

    check_network
    echo "正在安装socat..."

    # 尝试默认源安装
    apk add socat >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "socat安装成功"
        return 0
    fi

    # 尝试更换国内源安装
    echo "尝试更换国内源安装..."
    if [ ! -f "/etc/apk/repositories.bak" ]; then
        cp /etc/apk/repositories /etc/apk/repositories.bak
    fi
    echo "https://mirrors.aliyun.com/alpine/v$(cat /etc/alpine-release | cut -d '.' -f 1,2)/main/" > /etc/apk/repositories
    echo "https://mirrors.aliyun.com/alpine/v$(cat /etc/alpine-release | cut -d '.' -f 1,2)/community/" >> /etc/apk/repositories
    apk update >/dev/null 2>&1
    apk add socat >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "socat安装成功"
        return 0
    fi

    # 手动编译安装的指引
    echo "自动安装失败，请尝试手动安装："
    echo "1. 更新源: apk update"
    echo "2. 安装依赖: apk add socat"
    echo "如果仍失败，请手动下载编译"
    exit 1
}

# 确保配置文件存在
init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "# Socat转发规则配置" > "$CONFIG_FILE"
        echo "# 格式: 本地IP 本地端口 目标IP 目标端口 协议(TCP/UDP)" >> "$CONFIG_FILE"
    fi
}

# 显示当前规则
show_rules() {
    echo -e "\n===== 当前转发规则 ====="
    # 过滤注释和空行并编号
    grep -v '^#\|^$' "$CONFIG_FILE" | nl
    if [ $? -ne 0 ]; then
        echo "没有配置转发规则"
    fi
    echo "======================="
}

# 生成规则ID
generate_id() {
    echo "$1_$2_$5" | tr '.' '_' | tr ':' '_'
}

# 启动单个转发规则
start_single_rule() {
    local_ip=$1
    local_port=$2
    remote_ip=$3
    remote_port=$4
    protocol=$5
    id=$(generate_id "$local_ip" "$local_port" "$protocol")
    pid_file="$PID_DIR/$id.pid"
    log_file="$LOG_DIR/$id.log"

    # 检查是否已在运行
    if [ -f "$pid_file" ] && ps -p $(cat "$pid_file") >/dev/null 2>&1; then
        return 0
    fi

    # 启动转发进程
    if [ "$protocol" = "TCP" ]; then
        socat TCP-LISTEN:$local_port,bind=$local_ip,reuseaddr,fork TCP:$remote_ip:$remote_port > "$log_file" 2>&1 &
    else
        socat UDP-LISTEN:$local_port,bind=$local_ip,reuseaddr,fork UDP:$remote_ip:$remote_port > "$log_file" 2>&1 &
    fi

    # 记录PID
    echo $! > "$pid_file"
    echo "启动转发: $local_ip:$local_port ($protocol) -> $remote_ip:$remote_port (PID: $(cat "$pid_file"))"
}

# 停止单个转发规则
stop_single_rule() {
    local_ip=$1
    local_port=$2
    protocol=$3
    id=$(generate_id "$local_ip" "$local_port" "$protocol")
    pid_file="$PID_DIR/$id.pid"

    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file")
        if ps -p $pid >/dev/null 2>&1; then
            kill $pid >/dev/null 2>&1
            sleep 1
            # 强制杀死残留进程
            if ps -p $pid >/dev/null 2>&1; then
                kill -9 $pid >/dev/null 2>&1
            fi
        fi
        rm -f "$pid_file"
        echo "停止转发: $local_ip:$local_port ($protocol)"
    fi
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
    
    read -p "请输入协议 (TCP/UDP，默认: TCP): " protocol
    protocol=${protocol:-TCP}
    if [ "$protocol" != "TCP" ] && [ "$protocol" != "UDP" ]; then
        echo "无效的协议，只能是TCP或UDP"
        return 1
    fi
    
    # 检查端口是否已被使用
    if grep -qE "^[[:space:]]*$local_ip[[:space:]]+$local_port[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]*$protocol[[:space:]]*$" "$CONFIG_FILE"; then
        echo "错误：$protocol 本地端口 $local_port 已被使用"
        return 1
    fi
    
    # 添加规则到配置文件
    echo "$local_ip $local_port $remote_ip $remote_port $protocol" >> "$CONFIG_FILE"
    echo "规则添加成功：$local_ip:$local_port ($protocol) -> $remote_ip:$remote_port"
    
    # 立即启动该规则
    start_single_rule "$local_ip" "$local_port" "$remote_ip" "$remote_port" "$protocol"
}

# 删除单个规则
delete_rule() {
    show_rules
    
    read -p "请输入要删除的规则编号: " rule_num
    if [ -z "$rule_num" ] || ! echo "$rule_num" | grep -qE '^[0-9]+$'; then
        echo "无效的规则编号"
        return 1
    fi
    
    # 获取要删除的行
    line=$(grep -v '^#\|^$' "$CONFIG_FILE" | sed -n "${rule_num}p")
    if [ -z "$line" ]; then
        echo "规则编号不存在"
        return 1
    fi
    
    # 解析规则信息并停止该规则
    local_ip=$(echo "$line" | awk '{print $1}')
    local_port=$(echo "$line" | awk '{print $2}')
    protocol=$(echo "$line" | awk '{print $5}')
    stop_single_rule "$local_ip" "$local_port" "$protocol"
    
    # 备份并删除规则
    cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
    grep -vF "$line" "$CONFIG_FILE.bak" > "$CONFIG_FILE"
    rm -f "$CONFIG_FILE.bak"
    
    echo "已删除规则: $line"
}

# 清除所有规则
clear_all_rules() {
    read -p "确定要清除所有转发规则吗？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消操作"
        return 0
    fi
    
    # 先停止所有规则
    stop_service
    
    # 备份配置文件
    cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
    
    # 重建配置文件
    echo "# Socat转发规则配置" > "$CONFIG_FILE"
    echo "# 格式: 本地IP 本地端口 目标IP 目标端口 协议(TCP/UDP)" >> "$CONFIG_FILE"
    
    echo "所有转发规则已清除"
}

# 启动所有规则
start_service() {
    echo "启动所有转发规则..."
    # 读取配置文件中的所有规则并启动
    while IFS= read -r line; do
        # 跳过注释和空行
        echo "$line" | grep -q '^#\|^$' && continue
        # 解析规则
        local_ip=$(echo "$line" | awk '{print $1}')
        local_port=$(echo "$line" | awk '{print $2}')
        remote_ip=$(echo "$line" | awk '{print $3}')
        remote_port=$(echo "$line" | awk '{print $4}')
        protocol=$(echo "$line" | awk '{print $5}')
        # 启动规则
        start_single_rule "$local_ip" "$local_port" "$remote_ip" "$remote_port" "$protocol"
    done < "$CONFIG_FILE"
    echo "所有规则启动完成"
}

# 停止所有规则
stop_service() {
    echo "停止所有转发规则..."
    # 停止所有正在运行的转发进程
    for pid_file in "$PID_DIR"/*.pid; do
        if [ -f "$pid_file" ]; then
            pid=$(cat "$pid_file")
            if ps -p $pid >/dev/null 2>&1; then
                kill $pid >/dev/null 2>&1
                sleep 0.5
                if ps -p $pid >/dev/null 2>&1; then
                    kill -9 $pid >/dev/null 2>&1
                fi
            fi
            rm -f "$pid_file"
        fi
    done
    echo "所有规则已停止"
}

# 重启所有规则
restart_service() {
    stop_service
    sleep 1
    start_service
}

# 设置开机自启
setup_autostart() {
    # 创建启动脚本
    if [ ! -f "/etc/init.d/socat_forward" ]; then
        cat > "/etc/init.d/socat_forward" << EOF
#!/sbin/openrc-run
command="$0"
command_args="start"
EOF
        chmod +x "/etc/init.d/socat_forward"
        rc-update add socat_forward default >/dev/null 2>&1
        echo "已设置开机自启"
    fi
}

# 显示菜单
show_menu() {
    clear
    echo "===================== Alpine Socat转发管理工具 ====================="
    echo "基于socat实现，支持TCP/UDP多端口转发，规则自动持久化"
    echo "================================================================="
    echo "1. 添加转发规则"
    echo "2. 删除单个规则"
    echo "3. 清除所有规则"
    echo "4. 启动所有转发规则"
    echo "5. 停止所有转发规则"
    echo "6. 重启所有转发规则"
    echo "7. 查看当前规则"
    echo "8. 设置开机自启"
    echo "0. 退出"
    echo "================================================================="
    read -p "请选择操作 [0-8]: " choice
}

# 主程序
main() {
    install_socat
    init_config
    
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
            8) setup_autostart ;;
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
