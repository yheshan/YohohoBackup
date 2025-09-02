#!/bin/sh
# Alpine iptables端口转发管理工具（完整版）
# 自动安装iptables环境，解决命令缺失问题

# 配置文件路径
RULES_FILE="/etc/iptables/forward_rules.v4"
CHAIN_NAME="PORT_FORWARD"

# 检查root权限
[ "$(id -u)" -ne 0 ] && { echo "请用root权限运行: sudo $0"; exit 1; }

# 安装iptables及相关工具（核心修复）
install_iptables() {
    echo "检查iptables环境..."
    # 检查关键命令是否存在
    if ! command -v iptables >/dev/null 2>&1 || ! command -v iptables-save >/dev/null 2>&1; then
        echo "正在安装iptables工具..."
        # 安装iptables核心包（包含所有必需命令）
        if apk add iptables >/dev/null 2>&1; then
            echo "iptables安装成功"
        else
            # 安装失败时提供手动命令
            echo "自动安装失败，请先手动执行："
            echo "apk update && apk add iptables"
            exit 1
        fi
    fi
}

# 初始化环境
init_env() {
    # 优先确保iptables已安装
    install_iptables
    
    # 确保iptables目录存在
    mkdir -p /etc/iptables
    
    # 启用IP转发（临时生效）
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # 永久启用IP转发（Alpine专用）
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    
    # 创建自定义链（避免污染系统默认链）
    iptables -N $CHAIN_NAME 2>/dev/null
    # 将自定义链加入PREROUTING
    iptables -t nat -C PREROUTING -j $CHAIN_NAME 2>/dev/null || {
        iptables -t nat -A PREROUTING -j $CHAIN_NAME
    }
}

# 保存规则（持久化）
save_rules() {
    # 只保存自定义链的转发规则
    iptables-save -t nat | grep "$CHAIN_NAME" > "$RULES_FILE"
    echo "规则已保存到 $RULES_FILE"
}

# 加载规则（重启后恢复）
load_rules() {
    if [ -f "$RULES_FILE" ]; then
        iptables-restore -t nat < "$RULES_FILE"
        echo "已加载保存的规则"
    else
        echo "没有保存的规则"
    fi
}

# 显示当前转发规则
show_rules() {
    echo -e "\n===== 当前转发规则（编号仅用于删除操作） ====="
    # 提取自定义链中的转发规则并编号
    iptables -t nat -L $CHAIN_NAME --line-numbers | grep -v "Chain\|target\|^$\|RETURN" | nl
    if [ $? -ne 0 ]; then
        echo "没有配置转发规则"
    fi
    echo "============================================="
}

# 添加转发规则（增加错误检查）
add_rule() {
    echo -e "\n===== 添加新转发规则 ====="
    
    read -p "本地监听端口: " local_port
    if ! echo "$local_port" | grep -qE '^[0-9]+$' || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo "无效的本地端口（1-65535）"
        return 1
    fi
    
    read -p "目标服务器IP: " remote_ip
    if [ -z "$remote_ip" ] || ! echo "$remote_ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        echo "无效的目标IP地址"
        return 1
    fi
    
    read -p "目标服务器端口: " remote_port
    if ! echo "$remote_port" | grep -qE '^[0-9]+$' || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo "无效的目标端口（1-65535）"
        return 1
    fi
    
    read -p "协议 (TCP/UDP，默认: TCP): " protocol
    protocol=${protocol:-TCP}
    if [ "$protocol" != "TCP" ] && [ "$protocol" != "UDP" ]; then
        echo "无效的协议，只能是TCP或UDP"
        return 1
    fi
    
    # 检查规则是否已存在
    if iptables -t nat -C $CHAIN_NAME -p $protocol --dport $local_port -j DNAT --to-destination $remote_ip:$remote_port 2>/dev/null; then
        echo "错误：$protocol $local_port -> $remote_ip:$remote_port 规则已存在"
        return 1
    fi
    
    # 添加nat转发规则（增加错误检查）
    if ! iptables -t nat -A $CHAIN_NAME -p $protocol --dport $local_port -j DNAT --to-destination $remote_ip:$remote_port; then
        echo "添加nat规则失败"
        return 1
    fi
    
    # 添加filter表允许规则
    if ! iptables -A INPUT -p $protocol --dport $local_port -j ACCEPT; then
        echo "添加INPUT规则失败"
        return 1
    fi
    
    if ! iptables -A FORWARD -p $protocol --dport $remote_port -d $remote_ip -j ACCEPT; then
        echo "添加FORWARD规则失败"
        return 1
    fi
    
    echo "规则添加成功：$protocol $local_port -> $remote_ip:$remote_port"
    save_rules  # 自动保存
}

# 删除单个规则
delete_rule() {
    show_rules
    
    read -p "请输入要删除的规则编号: " rule_num
    if [ -z "$rule_num" ] || ! echo "$rule_num" | grep -qE '^[0-9]+$'; then
        echo "无效的规则编号"
        return 1
    fi
    
    # 获取要删除的规则详情
    rule_line=$(iptables -t nat -L $CHAIN_NAME --line-numbers | grep -v "Chain\|target\|^$\|RETURN" | sed -n "${rule_num}p")
    if [ -z "$rule_line" ]; then
        echo "规则编号不存在"
        return 1
    fi
    
    # 解析规则参数
    protocol=$(echo "$rule_line" | awk '{print $2}')
    local_port=$(echo "$rule_line" | awk '{print $9}')
    remote_ip=$(echo "$rule_line" | awk '{print $12}' | cut -d: -f1)
    remote_port=$(echo "$rule_line" | awk '{print $12}' | cut -d: -f2)
    
    # 删除nat表中的规则
    if ! iptables -t nat -D $CHAIN_NAME $rule_num; then
        echo "删除nat规则失败"
        return 1
    fi
    
    # 删除filter表中的对应允许规则
    iptables -D INPUT -p $protocol --dport $local_port -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p $protocol --dport $remote_port -d $remote_ip -j ACCEPT 2>/dev/null
    
    echo "已删除规则：$rule_line"
    save_rules  # 自动保存
}

# 清除所有规则
clear_all_rules() {
    read -p "确定要清除所有转发规则吗？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消操作"
        return 0
    fi
    
    # 清空自定义链
    iptables -t nat -F $CHAIN_NAME
    # 清除对应的filter规则
    iptables -F INPUT
    iptables -F FORWARD
    
    # 删除规则文件
    rm -f "$RULES_FILE"
    
    echo "所有转发规则已清除"
}

# 启动转发（加载保存的规则）
start_forward() {
    init_env  # 确保IP转发已启用
    load_rules
    echo "转发已启动"
}

# 停止转发（临时禁用，不删除规则文件）
stop_forward() {
    # 清空自定义链但保留链结构
    iptables -t nat -F $CHAIN_NAME
    # 清空filter表中相关规则
    iptables -F INPUT
    iptables -F FORWARD
    echo "转发已停止（规则仍保存在文件中）"
}

# 显示菜单
show_menu() {
    clear
    echo "===================== iptables端口转发工具 ====================="
    echo "自动安装依赖，支持TCP/UDP，规则自动持久化"
    echo "----------------------------------------------------------------"
    echo "1. 添加转发规则（支持TCP/UDP）"
    echo "2. 删除单个规则"
    echo "3. 清除所有规则"
    echo "4. 启动转发（加载保存的规则）"
    echo "5. 停止转发（临时禁用）"
    echo "6. 查看当前规则"
    echo "0. 退出"
    echo "================================================================="
    read -p "请选择操作 [0-6]: " choice
}

# 主程序
main() {
    init_env  # 初始化环境（包含iptables安装）
    
    while true; do
        show_menu
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) clear_all_rules ;;
            4) start_forward ;;
            5) stop_forward ;;
            6) show_rules ;;
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
