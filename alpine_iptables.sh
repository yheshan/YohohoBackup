#!/bin/sh
# Alpine iptables端口转发工具（最终语法修复版）
# 完全兼容ash shell，解决所有括号和语法错误

RULES_FILE="/etc/iptables/forward_rules.v4"
CHAIN_NAME="PORT_FORWARD"

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "请用root权限运行: sudo $0"
    exit 1
fi

# 安装iptables
install_iptables() {
    echo "检查iptables环境..."
    if ! command -v iptables >/dev/null 2>&1; then
        echo "正在安装iptables..."
        if ! apk add iptables >/dev/null 2>&1; then
            echo "安装失败，请手动执行: apk update && apk add iptables"
            exit 1
        fi
    fi
}

# 确保自定义链存在
ensure_chain_exists() {
    # 检查链是否存在
    if ! iptables -t nat -L $CHAIN_NAME >/dev/null 2>&1; then
        echo "创建自定义链 $CHAIN_NAME..."
        # 强制创建链
        if ! iptables -t nat -N $CHAIN_NAME; then
            echo "创建链失败，尝试清理残留规则..."
            # 清理可能存在的残留引用
            iptables -t nat -D PREROUTING -j $CHAIN_NAME 2>/dev/null
            # 再次尝试创建
            if ! iptables -t nat -N $CHAIN_NAME; then
                echo "无法创建自定义链，请手动执行以下命令后重试:"
                echo "iptables -t nat -N $CHAIN_NAME"
                exit 1
            fi
        fi
    fi

    # 确保链已添加到PREROUTING
    if ! iptables -t nat -C PREROUTING -j $CHAIN_NAME 2>/dev/null; then
        echo "将链添加到PREROUTING..."
        if ! iptables -t nat -A PREROUTING -j $CHAIN_NAME; then
            echo "添加链到PREROUTING失败"
            exit 1
        fi
    fi
}

# 初始化环境
init_env() {
    install_iptables
    mkdir -p /etc/iptables
    
    # 启用IP转发
    echo 1 > /proc/sys/net/ipv4/ip_forward
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    
    # 确保链存在
    ensure_chain_exists
}

# 保存规则
save_rules() {
    iptables-save -t nat | grep "$CHAIN_NAME" > "$RULES_FILE"
    echo "规则已保存到 $RULES_FILE"
}

# 加载规则
load_rules() {
    if [ -f "$RULES_FILE" ]; then
        # 先确保链存在再加载规则
        ensure_chain_exists
        iptables-restore -t nat < "$RULES_FILE"
        echo "已加载保存的规则"
    else
        echo "没有保存的规则"
    fi
}

# 显示规则
show_rules() {
    echo -e "\n===== 当前转发规则 ====="
    iptables -t nat -L $CHAIN_NAME --line-numbers | grep -v "Chain\|target\|^$\|RETURN" | nl
    if [ $? -ne 0 ]; then
        echo "没有配置转发规则"
    fi
    echo "======================="
}

# 添加规则
add_rule() {
    # 再次确认链存在
    ensure_chain_exists
    
    echo -e "\n===== 添加新转发规则 ====="
    
    read -p "本地监听端口: " local_port
    if ! echo "$local_port" | grep -qE '^[0-9]+$' || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo "无效的本地端口"
        return 1
    fi
    
    read -p "目标服务器IP: " remote_ip
    if [ -z "$remote_ip" ] || ! echo "$remote_ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        echo "无效的目标IP"
        return 1
    fi
    
    read -p "目标服务器端口: " remote_port
    if ! echo "$remote_port" | grep -qE '^[0-9]+$' || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo "无效的目标端口"
        return 1
    fi
    
    read -p "协议 (TCP/UDP，默认: TCP): " protocol
    protocol=${protocol:-TCP}
    if [ "$protocol" != "TCP" ] && [ "$protocol" != "UDP" ]; then
        echo "无效的协议"
        return 1
    fi
    
    # 检查规则是否存在
    if iptables -t nat -C $CHAIN_NAME -p $protocol --dport $local_port -j DNAT --to-destination $remote_ip:$remote_port 2>/dev/null; then
        echo "规则已存在"
        return 1
    fi
    
    # 添加nat规则
    echo "添加转发规则..."
    if iptables -t nat -A $CHAIN_NAME -p $protocol --dport $local_port -j DNAT --to-destination $remote_ip:$remote_port; then
        # 添加filter规则
        iptables -A INPUT -p $protocol --dport $local_port -j ACCEPT
        iptables -A FORWARD -p $protocol --dport $remote_port -d $remote_ip -j ACCEPT
        echo "规则添加成功：$protocol $local_port -> $remote_ip:$remote_port"
        save_rules
    else
        echo "添加规则失败，请检查链是否存在："
        echo "当前nat表中的链："
        iptables -t nat -L | grep "Chain"
        return 1
    fi
}

# 删除规则（彻底修复语法错误）
delete_rule() {
    show_rules
    
    read -p "请输入要删除的规则编号: " rule_num
    if ! echo "$rule_num" | grep -qE '^[0-9]+$'; then
        echo "无效的编号"
        return 1
    fi
    
    rule_line=$(iptables -t nat -L $CHAIN_NAME --line-numbers | grep -v "Chain\|target\|^$\|RETURN" | sed -n "${rule_num}p")
    if [ -z "$rule_line" ]; then
        echo "编号不存在"
        return 1
    fi
    
    protocol=$(echo "$rule_line" | awk '{print $2}')
    local_port=$(echo "$rule_line" | awk '{print $9}')
    remote_ip=$(echo "$rule_line" | awk '{print $12}' | cut -d: -f1)
    remote_port=$(echo "$rule_line" | awk '{print $12}' | cut -d: -f2)
    
    if iptables -t nat -D $CHAIN_NAME $rule_num; then
        iptables -D INPUT -p $protocol --dport $local_port -j ACCEPT 2>/dev/null
        iptables -D FORWARD -p $protocol --dport $remote_port -d $remote_ip -j ACCEPT 2>/dev/null
        echo "已删除规则：$rule_line"
        save_rules
    else
        echo "删除规则失败"
    fi
}

# 清除所有规则
clear_all_rules() {
    read -p "确定清除所有规则？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消操作"
        return 0
    fi
    
    iptables -t nat -F $CHAIN_NAME
    iptables -F INPUT
    iptables -F FORWARD
    rm -f "$RULES_FILE"
    echo "所有规则已清除"
}

# 启动转发
start_forward() {
    init_env
    load_rules
    echo "转发已启动"
}

# 停止转发
stop_forward() {
    iptables -t nat -F $CHAIN_NAME
    iptables -F INPUT
    iptables -F FORWARD
    echo "转发已停止"
}

# 显示菜单
show_menu() {
    clear
    echo "===================== iptables端口转发工具 ====================="
    echo "1. 添加转发规则"
    echo "2. 删除单个规则"
    echo "3. 清除所有规则"
    echo "4. 启动转发"
    echo "5. 停止转发"
    echo "6. 查看规则"
    echo "0. 退出"
    echo "============================================="
    read -p "请选择操作 [0-6]: " choice
}

# 主程序
main() {
    init_env
    while true; do
        show_menu
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) clear_all_rules ;;
            4) start_forward ;;
            5) stop_forward ;;
            6) show_rules ;;
            0) exit 0 ;;
            *) echo "无效选择" ;;
        esac
        read -p "按任意键继续..." -n 1
    done
}

main
