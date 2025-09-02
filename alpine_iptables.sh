#!/bin/sh
# Alpine iptables端口转发工具（二进制版）
# 直接使用二进制文件，解决无法通过apk安装的问题

# 配置和工具路径
IPTABLES_BIN="/usr/local/sbin/iptables"
IPTABLES_SAVE_BIN="/usr/local/sbin/iptables-save"
IPTABLES_RESTORE_BIN="/usr/local/sbin/iptables-restore"
RULES_FILE="/etc/iptables/forward_rules.v4"
SAVE_FILE="/etc/iptables/rules.v4"

# 创建必要目录
mkdir -p /etc/iptables /usr/local/sbin

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请以root权限运行 (sudo $0)"
    exit 1
fi

# 检查命令是否存在
command_exists() {
    [ -x "$1" ]
}

# 下载iptables二进制文件（核心改进）
download_iptables() {
    echo "正在准备iptables二进制文件..."
    
    # 检测系统架构
    arch=$(uname -m)
    case $arch in
        x86_64)
            iptables_url="https://github.com/iproute2/iproute2/releases/download/v6.1.0/iptables-x86_64"
            iptables_save_url="https://github.com/iproute2/iproute2/releases/download/v6.1.0/iptables-save-x86_64"
            iptables_restore_url="https://github.com/iproute2/iproute2/releases/download/v6.1.0/iptables-restore-x86_64"
            ;;
        aarch64)
            iptables_url="https://github.com/iproute2/iproute2/releases/download/v6.1.0/iptables-aarch64"
            iptables_save_url="https://github.com/iproute2/iproute2/releases/download/v6.1.0/iptables-save-aarch64"
            iptables_restore_url="https://github.com/iproute2/iproute2/releases/download/v6.1.0/iptables-restore-aarch64"
            ;;
        *)
            echo "不支持的架构: $arch"
            exit 1
            ;;
    esac

    # 下载二进制文件
    download_file() {
        local url=$1
        local path=$2
        
        if ! wget --no-check-certificate -O "$path" "$url" >/dev/null 2>&1; then
            echo "下载失败: $url"
            return 1
        fi
        chmod +x "$path"
        return 0
    }

    # 下载主程序
    if ! command_exists "$IPTABLES_BIN"; then
        echo "下载iptables二进制文件..."
        if ! download_file "$iptables_url" "$IPTABLES_BIN"; then
            echo "尝试备用链接..."
            iptables_url="https://raw.githubusercontent.com/alpinelinux/aports/master/main/iptables/bin/iptables"
            if ! download_file "$iptables_url" "$IPTABLES_BIN"; then
                echo "无法下载iptables，请手动放置到$IPTABLES_BIN"
                exit 1
            fi
        fi
    fi

    # 下载save工具
    if ! command_exists "$IPTABLES_SAVE_BIN"; then
        echo "下载iptables-save..."
        if ! download_file "$iptables_save_url" "$IPTABLES_SAVE_BIN"; then
            ln -s "$IPTABLES_BIN" "$IPTABLES_SAVE_BIN" 2>/dev/null
        fi
    fi

    # 下载restore工具
    if ! command_exists "$IPTABLES_RESTORE_BIN"; then
        echo "下载iptables-restore..."
        if ! download_file "$iptables_restore_url" "$IPTABLES_RESTORE_BIN"; then
            ln -s "$IPTABLES_BIN" "$IPTABLES_RESTORE_BIN" 2>/dev/null
        fi
    fi

    # 最终检查
    if ! command_exists "$IPTABLES_BIN"; then
        echo "=============================================="
        echo "ERROR: 无法安装iptables，请手动执行："
        echo ""
        echo "1. 下载适合你架构的iptables二进制文件"
        echo "2. 复制到$IPTABLES_BIN并赋予执行权限"
        echo "3. 同样安装iptables-save和iptables-restore"
        echo "=============================================="
        exit 1
    fi
}

# 启用IP转发
enable_ip_forward() {
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -ne 1 ]; then
        echo "启用IPv4转发..."
        echo 1 > /proc/sys/net/ipv4/ip_forward
        # 持久化配置
        if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        fi
        sysctl -p >/dev/null 2>&1
    fi
}

# 初始化
init() {
    # 确保iptables可用
    download_iptables
    
    # 启用IP转发
    enable_ip_forward
    
    # 初始化规则文件
    [ ! -f "$RULES_FILE" ] && touch "$RULES_FILE"
}

# 保存规则
save_rules() {
    "$IPTABLES_SAVE_BIN" > "$SAVE_FILE"
    # 创建启动脚本确保开机加载
    cat > /etc/init.d/iptables_forward << EOF
#!/sbin/openrc-run
start() {
    $IPTABLES_RESTORE_BIN < $SAVE_FILE
}
EOF
    chmod +x /etc/init.d/iptables_forward
    rc-update add iptables_forward default >/dev/null 2>&1
}

# 加载规则
load_rules() {
    if [ -f "$SAVE_FILE" ]; then
        "$IPTABLES_RESTORE_BIN" < "$SAVE_FILE"
        echo "已加载保存的规则"
    else
        echo "没有找到保存的规则文件"
    fi
}

# 显示规则
show_rules() {
    echo -e "\n===== 当前转发规则 ====="
    "$IPTABLES_BIN" -t nat -L PREROUTING --line-numbers | grep -v '^Chain\|^target\|^$'
    echo -e "\n说明: dpt=本地端口, to=目标IP:端口"
}

# 添加规则
add_rule() {
    echo -e "\n===== 添加新转发规则 ====="
    
    read -p "本地监听IP（默认: 0.0.0.0）: " local_ip
    local_ip=${local_ip:-0.0.0.0}
    
    read -p "本地监听端口: " local_port
    if ! echo "$local_port" | grep -qE '^[0-9]+$' || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo "无效端口（1-65535）"
        return 1
    fi
    
    read -p "目标服务器IP: " remote_ip
    [ -z "$remote_ip" ] && { echo "目标IP不能为空"; return 1; }
    
    read -p "目标服务器端口: " remote_port
    if ! echo "$remote_port" | grep -qE '^[0-9]+$' || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo "无效端口（1-65535）"
        return 1
    fi
    
    read -p "协议 (TCP/UDP，默认TCP): " protocol
    protocol=${protocol:-TCP}
    [ "$protocol" != "TCP" ] && [ "$protocol" != "UDP" ] && { echo "只能是TCP或UDP"; return 1; }

    # 添加规则（使用完整路径执行）
    if ! "$IPTABLES_BIN" -t nat -A PREROUTING -p "$protocol" --dport "$local_port" -d "$local_ip" -j DNAT --to-destination "$remote_ip:$remote_port"; then
        echo "添加转发规则失败"
        return 1
    fi
    
    if ! "$IPTABLES_BIN" -A FORWARD -p "$protocol" --dport "$remote_port" -d "$remote_ip" -j ACCEPT; then
        echo "添加入站规则失败"
        return 1
    fi
    
    if ! "$IPTABLES_BIN" -A FORWARD -p "$protocol" --sport "$remote_port" -s "$remote_ip" -j ACCEPT; then
        echo "添加出站规则失败"
        return 1
    fi
    
    # 保存规则
    echo "$protocol $local_ip $local_port $remote_ip $remote_port" >> "$RULES_FILE"
    save_rules
    
    echo "规则添加成功：$local_ip:$local_port ($protocol) -> $remote_ip:$remote_port"
}

# 删除规则
delete_rule() {
    show_rules
    
    read -p "删除规则编号: " rule_num
    if ! echo "$rule_num" | grep -qE '^[0-9]+$'; then
        echo "无效编号"
        return 1
    fi

    rule=$("$IPTABLES_BIN" -t nat -L PREROUTING --line-numbers | grep -v '^Chain\|^target\|^$' | sed -n "${rule_num}p")
    [ -z "$rule" ] && { echo "编号不存在"; return 1; }

    # 提取规则信息
    protocol=$(echo "$rule" | awk '{print $3}')
    local_port=$(echo "$rule" | grep -oP 'dpt:\K\d+')
    remote_ip=$(echo "$rule" | grep -oP 'to:\K[^:]+')
    remote_port=$(echo "$rule" | grep -oP 'to:[^:]+:\K\d+')

    # 删除规则
    if ! "$IPTABLES_BIN" -t nat -D PREROUTING "$rule_num"; then
        echo "删除nat规则失败"
        return 1
    fi
    
    # 删除转发规则
    forward_num=$("$IPTABLES_BIN" -L FORWARD --line-numbers | grep "$protocol" | grep "dpt:$remote_port" | grep "$remote_ip" | awk '{print $1}' | head -n 1)
    [ -n "$forward_num" ] && "$IPTABLES_BIN" -D FORWARD "$forward_num"
    
    forward_num=$("$IPTABLES_BIN" -L FORWARD --line-numbers | grep "$protocol" | grep "spt:$remote_port" | grep "$remote_ip" | awk '{print $1}' | head -n 1)
    [ -n "$forward_num" ] && "$IPTABLES_BIN" -D FORWARD "$forward_num"

    # 更新规则文件
    sed -i "/$protocol.*$local_port.*$remote_ip.*$remote_port/d" "$RULES_FILE"
    save_rules
    
    echo "已删除规则：$rule"
}

# 清除所有规则
clear_all_rules() {
    read -p "确定清除所有规则？(y/n): " confirm
    [ "$confirm" != "y" ] && { echo "取消操作"; return 0; }

    # 清除nat规则
    while "$IPTABLES_BIN" -t nat -L PREROUTING --line-numbers | grep -q 'DNAT'; do
        rule_num=$("$IPTABLES_BIN" -t nat -L PREROUTING --line-numbers | grep 'DNAT' | head -n 1 | awk '{print $1}')
        "$IPTABLES_BIN" -t nat -D PREROUTING "$rule_num"
    done

    # 清除转发规则
    while "$IPTABLES_BIN" -L FORWARD --line-numbers | grep -q 'ACCEPT'; do
        rule_num=$("$IPTABLES_BIN" -L FORWARD --line-numbers | grep 'ACCEPT' | head -n 1 | awk '{print $1}')
        "$IPTABLES_BIN" -D FORWARD "$rule_num"
    done

    # 清空规则文件
    > "$RULES_FILE"
    save_rules
    
    echo "所有规则已清除"
}

# 显示菜单
show_menu() {
    clear
    echo "===================== iptables二进制版转发工具 ====================="
    echo "直接使用二进制文件，不依赖包管理器"
    echo "================================================================="
    echo "1. 添加转发规则"
    echo "2. 删除单个规则"
    echo "3. 清除所有规则"
    echo "4. 加载保存的规则"
    echo "5. 查看当前规则"
    echo "0. 退出"
    echo "================================================================="
    read -p "选择操作 [0-5]: " choice
}

# 主程序
main() {
    init
    
    while true; do
        show_menu
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) clear_all_rules ;;
            4) load_rules ;;
            5) show_rules ;;
            0) exit 0 ;;
            *) echo "无效选择" ;;
        esac
        read -p "按任意键继续..." -n 1
    done
}

main
