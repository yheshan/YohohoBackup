#!/bin/sh
# Alpine Socat端口转发管理工具（修复版）
# 解决删除规则后仍通畅的问题，支持TCP/UDP独立配置

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

# 安装socat
install_socat() {
    if command -v socat >/dev/null 2>&1; then
        return 0
    fi

    echo "正在安装socat..."
    apk add socat >/dev/null 2>&1 || {
        echo "更换国内源重试..."
        [ ! -f "/etc/apk/repositories.bak" ] && cp /etc/apk/repositories /etc/apk/repositories.bak
        echo "https://mirrors.aliyun.com/alpine/v$(cat /etc/alpine-release | cut -d '.' -f 1,2)/main/" > /etc/apk/repositories
        echo "https://mirrors.aliyun.com/alpine/v$(cat /etc/alpine-release | cut -d '.' -f 1,2)/community/" >> /etc/apk/repositories
        apk update >/dev/null 2>&1 && apk add socat >/dev/null 2>&1
    }

    if ! command -v socat >/dev/null 2>&1; then
        echo "请手动安装：apk update && apk add socat"
        exit 1
    fi
}

# 初始化配置文件
init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "# 格式: 本地IP 本地端口 目标IP 目标端口 协议(TCP/UDP) 规则ID" > "$CONFIG_FILE"
    fi
}

# 生成唯一规则ID
generate_id() {
    echo "$1_$2_$5_$(date +%s%N | cut -c1-12)"
}

# 显示当前规则
show_rules() {
    echo -e "\n===== 当前转发规则 ====="
    grep -v '^#\|^$' "$CONFIG_FILE" | nl
    [ $? -ne 0 ] && echo "没有配置转发规则"
    echo "======================="
}

# 启动单个规则
start_single_rule() {
    local_ip=$1
    local_port=$2
    remote_ip=$3
    remote_port=$4
    protocol=$5
    rule_id=$6
    pid_file="$PID_DIR/$rule_id.pid"
    log_file="$LOG_DIR/$rule_id.log"

    # 确保没有残留进程
    stop_single_rule "$rule_id" "$local_ip" "$local_port" "$protocol"

    # 启动转发
    if [ "$protocol" = "TCP" ]; then
        socat TCP-LISTEN:$local_port,bind=$local_ip,reuseaddr,fork TCP:$remote_ip:$remote_port > "$log_file" 2>&1 &
    else
        socat UDP-LISTEN:$local_port,bind=$local_ip,reuseaddr,fork UDP:$remote_ip:$remote_port > "$log_file" 2>&1 &
    fi

    echo $! > "$pid_file"
    echo "已启动: $local_ip:$local_port ($protocol) -> $remote_ip:$remote_port"
}

# 停止单个规则（核心修复：双重检查进程）
stop_single_rule() {
    rule_id=$1
    local_ip=$2
    local_port=$3
    protocol=$4
    pid_file="$PID_DIR/$rule_id.pid"

    # 1. 通过PID文件终止
    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file")
        if ps -p $pid >/dev/null 2>&1; then
            kill $pid >/dev/null 2>&1
            sleep 1
            [ ps -p $pid >/dev/null 2>&1 ] && kill -9 $pid >/dev/null 2>&1
        fi
        rm -f "$pid_file"
    fi

    # 2. 通过端口和协议强制终止残留进程（关键修复）
    if [ "$protocol" = "TCP" ]; then
        pids=$(netstat -tulnp 2>/dev/null | grep ":$local_port" | grep "socat" | awk '{print $7}' | cut -d'/' -f1)
    else
        pids=$(netstat -tulnp 2>/dev/null | grep ":$local_port" | grep "socat" | awk '{print $7}' | cut -d'/' -f1)
    fi
    for pid in $pids; do
        [ -n "$pid" ] && kill -9 $pid >/dev/null 2>&1
    done
}

# 添加规则（支持TCP/UDP独立配置）
add_rule() {
    echo -e "\n===== 添加新转发规则 ====="
    
    read -p "监听IP（默认: 0.0.0.0）: " local_ip
    local_ip=${local_ip:-0.0.0.0}
    
    read -p "本地端口: " local_port
    if ! echo "$local_port" | grep -qE '^[0-9]+$' || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo "无效端口（1-65535）"
        return 1
    fi
    
    read -p "目标IP: " remote_ip
    [ -z "$remote_ip" ] && { echo "目标IP不能为空"; return 1; }
    
    read -p "目标端口: " remote_port
    if ! echo "$remote_port" | grep -qE '^[0-9]+$' || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo "无效端口（1-65535）"
        return 1
    fi
    
    read -p "协议 (TCP/UDP，默认TCP): " protocol
    protocol=${protocol:-TCP}
    [ "$protocol" != "TCP" ] && [ "$protocol" != "UDP" ] && { echo "只能是TCP或UDP"; return 1; }
    
    # 生成唯一ID
    rule_id=$(generate_id "$local_ip" "$local_port" "$protocol")
    
    # 添加到配置
    echo "$local_ip $local_port $remote_ip $remote_port $protocol $rule_id" >> "$CONFIG_FILE"
    start_single_rule "$local_ip" "$local_port" "$remote_ip" "$remote_port" "$protocol" "$rule_id"
}

# 删除单个规则（确保彻底终止）
delete_rule() {
    show_rules
    
    read -p "删除规则编号: " rule_num
    if ! echo "$rule_num" | grep -qE '^[0-9]+$'; then
        echo "无效编号"
        return 1
    fi
    
    # 获取规则信息
    line=$(grep -v '^#\|^$' "$CONFIG_FILE" | sed -n "${rule_num}p")
    [ -z "$line" ] && { echo "编号不存在"; return 1; }
    
    # 解析规则参数
    local_ip=$(echo "$line" | awk '{print $1}')
    local_port=$(echo "$line" | awk '{print $2}')
    protocol=$(echo "$line" | awk '{print $5}')
    rule_id=$(echo "$line" | awk '{print $6}')
    
    # 彻底停止进程（双重保障）
    stop_single_rule "$rule_id" "$local_ip" "$local_port" "$protocol"
    
    # 从配置文件删除
    cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
    grep -vF "$line" "$CONFIG_FILE.bak" > "$CONFIG_FILE"
    rm -f "$CONFIG_FILE.bak"
    
    echo "已删除规则: $line"
}

# 清除所有规则（强制终止所有进程）
clear_all_rules() {
    read -p "确定清除所有规则？(y/n): " confirm
    [ "$confirm" != "y" ] && { echo "取消操作"; return 0; }
    
    # 1. 终止所有转发进程
    pids=$(ps aux | grep "socat" | grep -v "grep" | awk '{print $1}')
    for pid in $pids; do
        [ -n "$pid" ] && kill -9 $pid >/dev/null 2>&1
    done
    
    # 2. 清空PID文件
    rm -f "$PID_DIR"/*.pid
    
    # 3. 备份并清空配置
    cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
    echo "# 格式: 本地IP 本地端口 目标IP 目标端口 协议(TCP/UDP) 规则ID" > "$CONFIG_FILE"
    
    echo "所有规则已清除"
}

# 启动所有规则
start_all_rules() {
    echo "启动所有规则..."
    while IFS= read -r line; do
        echo "$line" | grep -q '^#\|^$' && continue
        local_ip=$(echo "$line" | awk '{print $1}')
        local_port=$(echo "$line" | awk '{print $2}')
        remote_ip=$(echo "$line" | awk '{print $3}')
        remote_port=$(echo "$line" | awk '{print $4}')
        protocol=$(echo "$line" | awk '{print $5}')
        rule_id=$(echo "$line" | awk '{print $6}')
        start_single_rule "$local_ip" "$local_port" "$remote_ip" "$remote_port" "$protocol" "$rule_id"
    done < "$CONFIG_FILE"
}

# 显示菜单
show_menu() {
    clear
    echo "===================== Socat转发管理工具 ====================="
    echo "支持TCP/UDP独立配置，删除规则立即生效"
    echo "------------------------------------------------------------"
    echo "1. 添加转发规则（可分别创建TCP和UDP规则）"
    echo "2. 删除单个规则"
    echo "3. 清除所有规则"
    echo "4. 启动所有规则（重启后执行）"
    echo "5. 查看当前规则"
    echo "0. 退出"
    echo "============================================================"
    read -p "选择操作 [0-5]: " choice
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
            4) start_all_rules ;;
            5) show_rules ;;
            0) exit 0 ;;
            *) echo "无效选择" ;;
        esac
        read -p "按任意键继续..." -n 1
    done
}

main
