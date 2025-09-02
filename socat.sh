#!/bin/sh
# Socat端口转发一键管理脚本 (Alpine Linux专用) - ash兼容版
# 支持TCP/UDP协议，规则持久化，多端口转发

# 配置变量
RULES_FILE="/etc/socat-rules.conf"
SERVICE_FILE="/etc/init.d/socat-forward"
PID_DIR="/var/run/socat"
SCRIPT_PATH=$(readlink -f "$0")  # 获取当前脚本的绝对路径

# 确保必要目录和文件存在
init_env() {
    # 创建PID目录
    mkdir -p $PID_DIR
    chmod 755 $PID_DIR
    
    # 创建规则文件
    if [ ! -f $RULES_FILE ]; then
        touch $RULES_FILE
        chmod 644 $RULES_FILE
    fi
    
    # 创建服务文件
    create_service_file
}

# 创建系统服务文件
create_service_file() {
    if [ ! -f $SERVICE_FILE ]; then
        cat > $SERVICE_FILE << EOF
#!/sbin/openrc-run
# 提供socat转发服务的openrc服务脚本

RULES_FILE="$RULES_FILE"
PID_DIR="$PID_DIR"
SCRIPT_PATH="$SCRIPT_PATH"

depend() {
    need net
    after firewall
}

start() {
    ebegin "Starting socat forward services"
    
    # 确保PID目录存在
    mkdir -p \$PID_DIR
    chmod 755 \$PID_DIR
    
    # 启动所有规则
    \$SCRIPT_PATH --start-all
    eend \$?
}

stop() {
    ebegin "Stopping socat forward services"
    
    # 停止所有规则
    \$SCRIPT_PATH --stop-all
    eend \$?
}

restart() {
    stop
    start
}
EOF
        chmod 755 $SERVICE_FILE
        # 确保服务脚本有执行权限
        chmod +x $SERVICE_FILE
    fi
}

# 安装必要工具（使用ash兼容语法）
install_dependencies() {
    echo "正在检查并安装必要工具..."
    
    # 检查并安装socat
    if ! command -v socat >/dev/null 2>&1; then
        echo "安装 socat..."
        if ! apk add --no-cache socat >/dev/null; then
            echo "错误：无法安装socat，请检查网络"
            exit 1
        fi
    fi
    
    # 检查并安装net-tools（包含netstat）
    if ! command -v netstat >/dev/null 2>&1; then
        echo "安装 net-tools (包含netstat)..."
        if ! apk add --no-cache net-tools >/dev/null; then
            echo "错误：无法安装net-tools，请检查网络"
            exit 1
        fi
    fi
    
    echo "必要工具已准备就绪"
}

# 检查端口是否被占用（使用netstat）
is_port_in_use() {
    local port=$1
    # 检查TCP和UDP端口是否被占用
    if netstat -tuln | grep -q ":$port "; then
        return 0  # 端口已占用
    else
        return 1  # 端口未占用
    fi
}

# 获取下一个规则ID
get_next_id() {
    if [ ! -s $RULES_FILE ]; then
        echo 1
        return
    fi
    last_id=$(awk '{print $1}' $RULES_FILE | sort -n | tail -1)
    echo $((last_id + 1))
}

# 检查规则运行状态
check_rule_status() {
    local rule_id=$1
    local proto=$2
    
    local tcp_running=0
    local udp_running=0
    
    # 检查TCP状态
    if [ "$proto" = "tcp" ] || [ "$proto" = "both" ]; then
        if [ -f "$PID_DIR/socat-tcp-$rule_id.pid" ]; then
            pid=$(cat "$PID_DIR/socat-tcp-$rule_id.pid")
            if ps -p $pid >/dev/null 2>&1; then
                tcp_running=1
            else
                # 清理无效PID文件
                rm -f "$PID_DIR/socat-tcp-$rule_id.pid"
            fi
        fi
    fi
    
    # 检查UDP状态
    if [ "$proto" = "udp" ] || [ "$proto" = "both" ]; then
        if [ -f "$PID_DIR/socat-udp-$rule_id.pid" ]; then
            pid=$(cat "$PID_DIR/socat-udp-$rule_id.pid")
            if ps -p $pid >/dev/null 2>&1; then
                udp_running=1
            else
                # 清理无效PID文件
                rm -f "$PID_DIR/socat-udp-$rule_id.pid"
            fi
        fi
    fi
    
    # 返回状态文本
    if [ "$proto" = "tcp" ]; then
        if [ $tcp_running -eq 1 ]; then
            echo "运行中"
        else
            echo "已停止"
        fi
    elif [ "$proto" = "udp" ]; then
        if [ $udp_running -eq 1 ]; then
            echo "运行中"
        else
            echo "已停止"
        fi
    else # both
        if [ $tcp_running -eq 1 ] && [ $udp_running -eq 1 ]; then
            echo "全部运行"
        elif [ $tcp_running -eq 1 ] || [ $udp_running -eq 1 ]; then
            echo "部分运行"
        else
            echo "已停止"
        fi
    fi
}

# 添加转发规则
add_rule() {
    echo "===== 添加新转发规则 ====="
    
    # 选择协议
    echo "请选择协议类型:"
    echo "1) TCP"
    echo "2) UDP"
    echo "3) 同时支持TCP和UDP"
    read -p "请输入选项 [1-3, 默认1]: " proto_choice
    proto_choice=${proto_choice:-1}
    
    case $proto_choice in
        1) proto="tcp" ;;
        2) proto="udp" ;;
        3) proto="both" ;;
        *) echo "无效选项"; return ;;
    esac
    
    # 输入本地端口
    while true; do
        read -p "请输入本地监听端口 [1-65535]: " local_port
        if [[ $local_port =~ ^[0-9]+$ ]] && [ $local_port -ge 1 ] && [ $local_port -le 65535 ]; then
            # 检查端口是否已被占用
            if is_port_in_use $local_port; then
                echo "端口 $local_port 已被占用，请选择其他端口"
            else
                break
            fi
        else
            echo "无效的端口号，请重新输入"
        fi
    done
    
    # 输入远程主机
    read -p "请输入远程主机IP或域名: " remote_host
    if [ -z "$remote_host" ]; then
        echo "远程主机不能为空"
        return
    fi
    
    # 输入远程端口
    while true; do
        read -p "请输入远程端口 [1-65535]: " remote_port
        if [[ $remote_port =~ ^[0-9]+$ ]] && [ $remote_port -ge 1 ] && [ $remote_port -le 65535 ]; then
            break
        else
            echo "无效的端口号，请重新输入"
        fi
    done
    
    # 获取规则ID并添加到文件
    rule_id=$(get_next_id)
    echo "$rule_id $proto $local_port $remote_host $remote_port" >> $RULES_FILE
    echo "规则添加成功 (ID: $rule_id)"
    
    # 立即启动该规则
    start_single_rule $rule_id
}

# 显示所有规则
show_rules() {
    echo "===== 当前转发规则 ====="
    echo "ID  协议      状态      本地端口 -> 远程主机:端口"
    echo "------------------------------------------------"
    
    if [ ! -s $RULES_FILE ]; then
        echo "没有任何转发规则"
        return
    fi
    
    while IFS= read -r rule; do
        # 跳过空行和注释
        [ -z "$rule" ] || [ "${rule#\#}" != "$rule" ] && continue
        
        id=$(echo "$rule" | awk '{print $1}')
        proto=$(echo "$rule" | awk '{print $2}')
        local_port=$(echo "$rule" | awk '{print $3}')
        remote_host=$(echo "$rule" | awk '{print $4}')
        remote_port=$(echo "$rule" | awk '{print $5}')
        
        # 格式化协议显示
        case $proto in
            tcp) proto_display="TCP       " ;;
            udp) proto_display="UDP       " ;;
            both) proto_display="TCP+UDP   " ;;
        esac
        
        # 获取状态
        status=$(check_rule_status $id $proto)
        
        echo "$id   $proto_display $status   $local_port -> $remote_host:$remote_port"
    done < $RULES_FILE
}

# 删除指定规则
delete_rule() {
    show_rules
    if [ ! -s $RULES_FILE ]; then
        return
    fi
    
    read -p "请输入要删除的规则ID: " rule_id
    if [ -z "$rule_id" ] || ! [[ $rule_id =~ ^[0-9]+$ ]]; then
        echo "无效的规则ID"
        return
    fi
    
    # 检查规则是否存在
    if ! grep -q "^$rule_id " $RULES_FILE; then
        echo "规则ID $rule_id 不存在"
        return
    fi
    
    # 停止该规则的进程
    stop_single_rule $rule_id
    
    # 从规则文件中删除
    sed -i "/^$rule_id /d" $RULES_FILE
    echo "规则ID $rule_id 已删除"
}

# 清空所有规则
clear_all_rules() {
    if [ ! -s $RULES_FILE ]; then
        echo "没有任何规则可清除"
        return
    fi
    
    read -p "确定要删除所有转发规则吗? [y/N]: " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        # 停止所有进程
        stop_all_rules
        
        # 清空规则文件
        > $RULES_FILE
        echo "所有规则已清除"
    else
        echo "操作已取消"
    fi
}

# 启动单个规则
start_single_rule() {
    local rule_id=$1
    local rule=$(grep "^$rule_id " $RULES_FILE)
    
    if [ -z "$rule" ]; then
        echo "规则ID $rule_id 不存在"
        return
    fi
    
    proto=$(echo "$rule" | awk '{print $2}')
    local_port=$(echo "$rule" | awk '{print $3}')
    remote_host=$(echo "$rule" | awk '{print $4}')
    remote_port=$(echo "$rule" | awk '{print $5}')
    
    # 启动TCP转发
    if [ "$proto" = "tcp" ] || [ "$proto" = "both" ]; then
        if ! pgrep -F $PID_DIR/socat-tcp-$rule_id.pid >/dev/null 2>&1; then
            # 检查端口是否已被占用
            if is_port_in_use $local_port; then
                echo "警告: 端口 $local_port 已被占用，TCP转发启动失败"
            else
                socat TCP4-LISTEN:$local_port,reuseaddr,fork TCP4:$remote_host:$remote_port &
                echo $! > $PID_DIR/socat-tcp-$rule_id.pid
                echo "已启动 TCP 转发: $local_port -> $remote_host:$remote_port"
            fi
        else
            echo "TCP 转发 $local_port -> $remote_host:$remote_port 已在运行"
        fi
    fi
    
    # 启动UDP转发
    if [ "$proto" = "udp" ] || [ "$proto" = "both" ]; then
        if ! pgrep -F $PID_DIR/socat-udp-$rule_id.pid >/dev/null 2>&1; then
            # 检查端口是否已被占用
            if is_port_in_use $local_port; then
                echo "警告: 端口 $local_port 已被占用，UDP转发启动失败"
            else
                socat UDP4-LISTEN:$local_port,reuseaddr,fork UDP4:$remote_host:$remote_port &
                echo $! > $PID_DIR/socat-udp-$rule_id.pid
                echo "已启动 UDP 转发: $local_port -> $remote_host:$remote_port"
            fi
        else
            echo "UDP 转发 $local_port -> $remote_host:$remote_port 已在运行"
        fi
    fi
}

# 停止单个规则
stop_single_rule() {
    local rule_id=$1
    
    # 停止TCP进程
    if [ -f $PID_DIR/socat-tcp-$rule_id.pid ]; then
        pid=$(cat $PID_DIR/socat-tcp-$rule_id.pid)
        if ps -p $pid >/dev/null 2>&1; then
            kill $pid >/dev/null 2>&1
            echo "已停止 TCP 转发 (ID: $rule_id)"
        fi
        rm -f $PID_DIR/socat-tcp-$rule_id.pid
    fi
    
    # 停止UDP进程
    if [ -f $PID_DIR/socat-udp-$rule_id.pid ]; then
        pid=$(cat $PID_DIR/socat-udp-$rule_id.pid)
        if ps -p $pid >/dev/null 2>&1; then
            kill $pid >/dev/null 2>&1
            echo "已停止 UDP 转发 (ID: $rule_id)"
        fi
        rm -f $PID_DIR/socat-udp-$rule_id.pid
    fi
}

# 启动所有规则（供服务调用）
start_all_rules() {
    if [ ! -s $RULES_FILE ]; then
        echo "没有转发规则可启动"
        return 0
    fi
    
    while IFS= read -r rule; do
        # 跳过空行和注释
        [ -z "$rule" ] || [ "${rule#\#}" != "$rule" ] && continue
        
        id=$(echo "$rule" | awk '{print $1}')
        start_single_rule $id
    done < $RULES_FILE
}

# 停止所有规则（供服务调用）
stop_all_rules() {
    # 停止所有转发进程
    for pidfile in $PID_DIR/*.pid; do
        if [ -f "$pidfile" ]; then
            pid=$(cat "$pidfile")
            if ps -p $pid >/dev/null 2>&1; then
                kill $pid >/dev/null 2>&1
                echo "已停止转发进程 (PID: $pid)"
            fi
            rm -f "$pidfile"
        fi
    done
    
    # 额外安全检查：终止所有可能残留的socat进程
    pkill -f "socat (TCP4|UDP4)-LISTEN" >/dev/null 2>&1
}

# 设置开机启动
enable_boot_start() {
    # 先删除可能存在的旧配置
    rc-update del socat-forward default >/dev/null 2>&1
    # 添加新配置
    rc-update add socat-forward default
    # 保存配置
    rc-update -u
    echo "已设置 socat 转发服务开机自启"
}

# 取消开机启动
disable_boot_start() {
    rc-update del socat-forward default
    rc-update -u
    echo "已取消 socat 转发服务开机自启"
}

# 命令行参数处理（供服务调用）
if [ "$1" = "--start-all" ]; then
    start_all_rules
    exit 0
elif [ "$1" = "--stop-all" ]; then
    stop_all_rules
    exit 0
fi

# 主菜单
show_menu() {
    clear
    echo "======================================"
    echo "      Socat 端口转发管理工具          "
    echo "           Alpine Linux 版            "
    echo "======================================"
    echo "1. 添加新转发规则"
    echo "2. 查看所有转发规则 (含状态)"
    echo "3. 删除指定转发规则"
    echo "4. 清空所有转发规则"
    echo "--------------------------------------"
    echo "5. 启动所有转发规则"
    echo "6. 停止所有转发规则"
    echo "7. 重启所有转发规则"
    echo "--------------------------------------"
    echo "8. 设置开机自启动"
    echo "9. 取消开机自启动"
    echo "--------------------------------------"
    echo "0. 退出"
    echo "======================================"
    read -p "请输入操作选项 [0-9]: " choice
}

# 主程序
main() {
    # 检查是否以root权限运行
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误: 此脚本需要以root权限运行"
        exit 1
    fi
    
    # 初始化环境
    init_env
    
    # 安装必要依赖
    install_dependencies
    
    # 主循环
    while true; do
        show_menu
        case $choice in
            1) add_rule ;;
            2) show_rules ;;
            3) delete_rule ;;
            4) clear_all_rules ;;
            5) start_all_rules ;;
            6) stop_all_rules ;;
            7) stop_all_rules; start_all_rules ;;
            8) enable_boot_start ;;
            9) disable_boot_start ;;
            0) echo "再见!"; exit 0 ;;
            *) echo "无效选项，请重新输入" ;;
        esac
        echo
        read -p "按回车键继续..." -n 1
    done
}

# 启动主程序
main
