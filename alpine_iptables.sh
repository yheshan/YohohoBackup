#!/bin/sh
# Alpine iptables端口转发管理工具（修复版）
# 解决iptables: not found错误

# 配置文件路径
RULES_FILE="/etc/iptables/forward_rules.v4"
SAVE_FILE="/etc/iptables/rules.v4"

# 确保目录存在
mkdir -p /etc/iptables

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请以root权限运行 (sudo $0)"
    exit 1
fi

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 安装必要工具（增强版）
install_tools() {
    echo "正在检查必要工具..."
    
    # 检查iptables是否已安装
    if ! command_exists iptables || ! command_exists iptables-save; then
        echo "检测到未安装iptables，开始安装..."
        
        # 保存原始源
        if [ ! -f "/etc/apk/repositories.bak" ]; then
            cp /etc/apk/repositories /etc/apk/repositories.bak
        fi
        
        # 尝试多种源安装
        install_success=0
        
        # 尝试默认源
        echo "尝试默认源安装..."
        apk update >/dev/null 2>&1 && apk add iptables >/dev/null 2>&1 && install_success=1
        
        # 尝试阿里云源
        if [ $install_success -eq 0 ]; then
            echo "默认源安装失败，尝试阿里云源..."
            echo "https://mirrors.aliyun.com/alpine/v$(cat /etc/alpine-release | cut -d '.' -f 1,2)/main/" > /etc/apk/repositories
            echo "https://mirrors.aliyun.com/alpine/v$(cat /etc/alpine-release | cut -d '.' -f 1,2)/community/" >> /etc/apk/repositories
            apk update >/dev/null 2>&1 && apk add iptables >/dev/null 2>&1 && install_success=1
        fi
        
        # 尝试华为云源
        if [ $install_success -eq 0 ]; then
            echo "阿里云源安装失败，尝试华为云源..."
            echo "https://repo.huaweicloud.com/alpine/v$(cat /etc/alpine-release | cut -d '.' -f 1,2)/main/" > /etc/apk/repositories
            echo "https://repo.huaweicloud.com/alpine/v$(cat /etc/alpine-release | cut -d '.' -f 1,2)/community/" >> /etc/apk/repositories
            apk update >/dev/null 2>&1 && apk add iptables >/dev/null 2>&1 && install_success=1
        fi
        
        # 检查是否安装成功
        if [ $install_success -eq 0 ] || ! command_exists iptables; then
            echo "=============================================="
            echo "ERROR: 自动安装iptables失败，请手动执行以下命令："
            echo ""
            echo "1. 恢复源配置："
            echo "   cp /etc/apk/repositories.bak /etc/apk/repositories 2>/dev/null || true"
            echo ""
            echo "2. 手动安装："
            echo "   apk update && apk add iptables"
            echo ""
            echo "3. 安装成功后再运行本脚本"
            echo "=============================================="
            exit 1
        fi
    fi

    # 启用IP转发并持久化
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -ne 1 ]; then
        echo "启用IPv4转发..."
        echo 1 > /proc/sys/net/ipv4/ip_forward
        # 持久化配置
        if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        fi
        sysctl -p >/dev/null 2>&1
    fi

    # 初始化规则文件
    [ ! -f "$RULES_FILE" ] && touch "$RULES_FILE"
}

# 保存当前规则
save_rules() {
    # 保存所有iptables规则
    iptables-save > "$SAVE_FILE"
    # 设置开机自动加载
    if ! rc-update show | grep -q "iptables"; then
        rc-update add iptables default >/dev/null 2>&1
    fi
    echo "规则已保存"
}

# 加载保存的规则
load_rules() {
    if [ -f "$SAVE_FILE" ]; then
        iptables-restore < "$SAVE_FILE"
        echo "已加载保存的规则"
    else
        echo "没有找到保存的规则文件"
    fi
}

# 显示当前转发规则
show_rules() {
    echo -e "\n===== 当前IPv4转发规则 ====="
    # 显示nat表中的PREROUTING链规则（端口转发规则）
    iptables -t nat -L PREROUTING --line-numbers | grep -v '^Chain\|^target\|^$'
    echo -e "\n===== 规则说明 ====="
    echo "num: 规则编号"
    echo "prot: 协议(TCP/UDP)"
    echo "dpt: 本地端口"
    echo "to: 目标服务器(IP:端口)"
}

# 添加转发规则
add_rule() {
    echo -e "\n===== 添加新转发规则 ====="
    
    read -p "请输入本地监听IP（默认: 0.0.0.0）: " local_ip
    local_ip=${local_ip:-0.0.0.0}
    
    read -p "请输入本地监听端口: " local_port
    if ! echo "$local_port" | grep -qE '^[0-9]+$' || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo "无效的本地端口（1-65535）"
        return 1
    fi
    
    read -p "请输入目标服务器IP: " remote_ip
    if [ -z "$remote_ip" ]; then
        echo "目标IP不能为空"
        return 1
    fi
    
    read -p "请输入目标服务器端口: " remote_port
    if ! echo "$remote_port" | grep -qE '^[0-9]+$' || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo "无效的目标端口（1-65535）"
        return 1
    fi
    
    read -p "请输入协议 (TCP/UDP，默认: TCP): " protocol
    protocol=${protocol:-TCP}
    if [ "$protocol" != "TCP" ] && [ "$protocol" != "UDP" ]; then
        echo "无效的协议，只能是TCP或UDP"
        return 1
    fi

    # 添加nat转发规则（PREROUTING链）
    if ! iptables -t nat -A PREROUTING -p "$protocol" --dport "$local_port" -d "$local_ip" -j DNAT --to-destination "$remote_ip:$remote_port"; then
        echo "添加nat规则失败"
        return 1
    fi
    
    # 添加转发允许规则（FORWARD链）
    if ! iptables -A FORWARD -p "$protocol" --dport "$remote_port" -d "$remote_ip" -j ACCEPT; then
        echo "添加转发入站规则失败"
        return 1
    fi
    
    if ! iptables -A FORWARD -p "$protocol" --sport "$remote_port" -s "$remote_ip" -j ACCEPT; then
        echo "添加转发出站规则失败"
        return 1
    fi
    
    # 保存规则到文件
    echo "$protocol $local_ip $local_port $remote_ip $remote_port" >> "$RULES_FILE"
    save_rules
    
    echo "规则添加成功：$local_ip:$local_port ($protocol) -> $remote_ip:$remote_port"
}

# 删除单个规则
delete_rule() {
    show_rules
    
    read -p "请输入要删除的规则编号: " rule_num
    if ! echo "$rule_num" | grep -qE '^[0-9]+$'; then
        echo "无效的规则编号"
        return 1
    fi

    # 获取要删除的规则详情
    rule=$(iptables -t nat -L PREROUTING --line-numbers | grep -v '^Chain\|^target\|^$' | sed -n "${rule_num}p")
    if [ -z "$rule" ]; then
        echo "规则编号不存在"
        return 1
    fi

    # 提取协议和端口信息
    protocol=$(echo "$rule" | awk '{print $3}')
    local_port=$(echo "$rule" | grep -oP 'dpt:\K\d+')
    remote_ip=$(echo "$rule" | grep -oP 'to:\K[^:]+')
    remote_port=$(echo "$rule" | grep -oP 'to:[^:]+:\K\d+')

    # 删除nat表中的PREROUTING规则
    if ! iptables -t nat -D PREROUTING "$rule_num"; then
        echo "删除nat规则失败"
        return 1
    fi
    
    # 删除对应的FORWARD规则
    # 查找并删除入站规则
    forward_num=$(iptables -L FORWARD --line-numbers | grep "$protocol" | grep "dpt:$remote_port" | grep "$remote_ip" | awk '{print $1}' | head -n 1)
    if [ -n "$forward_num" ]; then
        iptables -D FORWARD "$forward_num"
    fi
    
    # 查找并删除出站规则
    forward_num=$(iptables -L FORWARD --line-numbers | grep "$protocol" | grep "spt:$remote_port" | grep "$remote_ip" | awk '{print $1}' | head -n 1)
    if [ -n "$forward_num" ]; then
        iptables -D FORWARD "$forward_num"
    fi

    # 从规则文件中删除
    sed -i "/$protocol.*$local_port.*$remote_ip.*$remote_port/d" "$RULES_FILE"
    
    # 保存修改
    save_rules
    
    echo "已删除规则：$rule"
}

# 清除所有转发规则
clear_all_rules() {
    read -p "确定要清除所有转发规则吗？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消操作"
        return 0
    fi

    # 清除nat表中的所有PREROUTING转发规则
    while iptables -t nat -L PREROUTING --line-numbers | grep -q 'DNAT'; do
        rule_num=$(iptables -t nat -L PREROUTING --line-numbers | grep 'DNAT' | head -n 1 | awk '{print $1}')
        iptables -t nat -D PREROUTING "$rule_num"
    done

    # 清除对应的FORWARD规则
    while iptables -L FORWARD --line-numbers | grep -q 'ACCEPT'; do
        rule_num=$(iptables -L FORWARD --line-numbers | grep 'ACCEPT' | head -n 1 | awk '{print $1}')
        iptables -D FORWARD "$rule_num"
    done

    # 清空规则文件
    > "$RULES_FILE"
    
    # 保存修改
    save_rules
    
    echo "所有转发规则已清除"
}

# 显示菜单
show_menu() {
    clear
    echo "===================== iptables端口转发管理工具 ====================="
    echo "基于系统原生iptables，高效稳定，支持TCP/UDP转发"
    echo "================================================================="
    echo "1. 添加转发规则（TCP/UDP可选）"
    echo "2. 删除单个规则"
    echo "3. 清除所有规则"
    echo "4. 加载保存的规则（重启后执行）"
    echo "5. 查看当前规则"
    echo "0. 退出"
    echo "================================================================="
    read -p "请选择操作 [0-5]: " choice
}

# 主程序
main() {
    install_tools
    
    while true; do
        show_menu
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) clear_all_rules ;;
            4) load_rules ;;
            5) show_rules ;;
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
