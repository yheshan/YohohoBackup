#!/bin/bash
# 多功能端口转发脚本 - 支持多协议和多目标
# 兼容 Alpine、Debian/Ubuntu、CentOS

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行脚本"
    exit 1
fi

# 检测操作系统
detect_os() {
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/centos-release ]; then
        echo "centos"
    else
        echo "unknown"
    fi
}

OS=$(detect_os)

# 安装必要依赖
install_dependencies() {
    echo "正在安装必要依赖..."
    case $OS in
        alpine)
            apk update && apk add --no-cache iptables nftables socat curl wget libc6-compat
            ;;
        debian)
            apt update && apt install -y iptables nftables socat curl wget
            ;;
        centos)
            yum install -y iptables-services nftables socat curl wget
            systemctl enable iptables
            ;;
        *)
            echo "不支持的操作系统"
            exit 1
            ;;
    esac
}

# 安装GOST
install_gost() {
    if ! command -v gost &> /dev/null; then
        echo "正在安装GOST..."
        GOST_URL="https://github.com/ginuerzh/gost/releases/latest/download/gost-linux-amd64"
        if [ "$OS" = "alpine" ]; then
            GOST_URL="https://github.com/ginuerzh/gost/releases/latest/download/gost-linux-amd64-musl"
        fi
        wget -q --no-check-certificate -O /usr/local/bin/gost $GOST_URL
        chmod +x /usr/local/bin/gost
    fi
}

# 启用IP转发
enable_ip_forward() {
    echo "启用IP转发..."
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p > /dev/null
}

# 显示菜单
show_menu() {
    clear
    echo "==================== 端口转发工具 ===================="
    echo "1. iptables 转发 (简单端口映射，高性能)"
    echo "2. nftables 转发 (新一代防火墙，支持复杂规则)"
    echo "3. socat 转发 (灵活的端口转发，支持多种协议)"
    echo "4. GOST 转发 (支持加密隧道，多协议)"
    echo "5. 查看当前转发规则"
    echo "6. 清除所有转发规则"
    echo "0. 退出"
    echo "======================================================"
    read -p "请选择功能 [0-6]: " choice
}

# 添加iptables转发规则
add_iptables_rule() {
    read -p "请输入协议类型 (tcp/udp/all): " proto
    read -p "请输入本地端口: " local_port
    read -p "请输入目标IP: " target_ip
    read -p "请输入目标端口: " target_port

    case $proto in
        tcp)
            iptables -t nat -A PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $target_ip:$target_port
            ;;
        udp)
            iptables -t nat -A PREROUTING -p udp --dport $local_port -j DNAT --to-destination $target_ip:$target_port
            ;;
        all)
            iptables -t nat -A PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $target_ip:$target_port
            iptables -t nat -A PREROUTING -p udp --dport $local_port -j DNAT --to-destination $target_ip:$target_port
            ;;
        *)
            echo "无效的协议类型"
            return
            ;;
    esac
    
    iptables -t nat -A POSTROUTING -j MASQUERADE
    echo "iptables 转发规则已添加: $local_port -> $target_ip:$target_port ($proto)"
    
    # 保存规则
    case $OS in
        alpine)
            iptables-save > /etc/iptables/rules.v4
            ;;
        debian)
            iptables-save > /etc/iptables/rules.v4
            ;;
        centos)
            service iptables save
            ;;
    esac
}

# 添加nftables转发规则
add_nftables_rule() {
    read -p "请输入协议类型 (tcp/udp/all): " proto
    read -p "请输入本地端口: " local_port
    read -p "请输入目标IP: " target_ip
    read -p "请输入目标端口: " target_port

    # 初始化nftables
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting '{ type nat hook prerouting priority 0; policy accept; }' 2>/dev/null
    nft add chain ip nat postrouting '{ type nat hook postrouting priority 100; policy accept; }' 2>/dev/null

    case $proto in
        tcp)
            nft add rule ip nat prerouting tcp dport $local_port dnat to $target_ip:$target_port
            ;;
        udp)
            nft add rule ip nat prerouting udp dport $local_port dnat to $target_ip:$target_port
            ;;
        all)
            nft add rule ip nat prerouting tcp dport $local_port dnat to $target_ip:$target_port
            nft add rule ip nat prerouting udp dport $local_port dnat to $target_ip:$target_port
            ;;
        *)
            echo "无效的协议类型"
            return
            ;;
    esac
    
    nft add rule ip nat postrouting masquerade 2>/dev/null
    echo "nftables 转发规则已添加: $local_port -> $target_ip:$target_port ($proto)"
    
    # 保存规则
    nft list ruleset > /etc/nftables.conf
}

# 添加socat转发规则
add_socat_rule() {
    read -p "请输入协议类型 (tcp/udp): " proto
    read -p "请输入本地端口: " local_port
    read -p "请输入目标IP: " target_ip
    read -p "请输入目标端口: " target_port
    read -p "是否后台运行? (y/n): " background

    bg_flag=""
    if [ "$background" = "y" ] || [ "$background" = "Y" ]; then
        bg_flag="nohup"
        log_file="/var/log/socat_${proto}_${local_port}.log"
    fi

    case $proto in
        tcp)
            cmd="$bg_flag socat TCP-LISTEN:$local_port,reuseaddr,fork TCP:$target_ip:$target_port"
            ;;
        udp)
            cmd="$bg_flag socat UDP-LISTEN:$local_port,reuseaddr,fork UDP:$target_ip:$target_port"
            ;;
        *)
            echo "无效的协议类型"
            return
            ;;
    esac

    if [ "$background" = "y" ] || [ "$background" = "Y" ]; then
        $cmd > $log_file 2>&1 &
        echo "socat 转发已在后台启动: $local_port -> $target_ip:$target_port ($proto)"
        echo "日志文件: $log_file"
    else
        echo "启动 socat 转发 (按Ctrl+C停止):"
        $cmd
    fi
}

# 添加GOST转发规则
add_gost_rule() {
    read -p "请输入协议类型 (tcp/udp/all): " proto
    read -p "请输入本地端口: " local_port
    read -p "请输入目标IP: " target_ip
    read -p "请输入目标端口: " target_port
    read -p "是否使用加密隧道? (y/n): " encrypt
    read -p "是否后台运行? (y/n): " background

    proto_flag=""
    case $proto in
        tcp)
            proto_flag="tcp"
            ;;
        udp)
            proto_flag="udp"
            ;;
        all)
            proto_flag="tcp+udp"
            ;;
        *)
            echo "无效的协议类型"
            return
            ;;
    esac

    # 基础转发规则
    forward_rule="${proto_flag}://:${local_port}/${target_ip}:${target_port}"
    
    # 如果需要加密
    if [ "$encrypt" = "y" ] || [ "$encrypt" = "Y" ]; then
        read -p "请设置加密密钥: " secret
        forward_rule="tls://:${local_port}?sni=example.com&secret=${secret}->${proto_flag}://${target_ip}:${target_port}"
    fi

    bg_flag=""
    if [ "$background" = "y" ] || [ "$background" = "Y" ]; then
        bg_flag="nohup"
        log_file="/var/log/gost_${proto}_${local_port}.log"
    fi

    cmd="$bg_flag gost -L $forward_rule"

    if [ "$background" = "y" ] || [ "$background" = "Y" ]; then
        $cmd > $log_file 2>&1 &
        echo "GOST 转发已在后台启动: $local_port -> $target_ip:$target_port ($proto)"
        echo "日志文件: $log_file"
    else
        echo "启动 GOST 转发 (按Ctrl+C停止):"
        $cmd
    fi
}

# 查看当前规则
show_rules() {
    echo "===== iptables 规则 ====="
    iptables -t nat -L PREROUTING --line-numbers
    
    echo -e "\n===== nftables 规则 ====="
    nft list ruleset 2>/dev/null
    
    echo -e "\n===== socat 进程 ====="
    ps aux | grep socat | grep -v grep
    
    echo -e "\n===== GOST 进程 ====="
    ps aux | grep gost | grep -v grep
    
    read -p "按任意键继续..."
}

# 清除所有规则
clear_rules() {
    read -p "确定要清除所有转发规则吗? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        return
    fi

    # 清除iptables规则
    iptables -t nat -F
    iptables -t nat -X
    case $OS in
        alpine)
            iptables-save > /etc/iptables/rules.v4
            ;;
        debian)
            iptables-save > /etc/iptables/rules.v4
            ;;
        centos)
            service iptables save
            ;;
    esac

    # 清除nftables规则
    nft flush ruleset 2>/dev/null
    echo "" > /etc/nftables.conf 2>/dev/null

    # 终止socat和gost进程
    pkill socat
    pkill gost

    echo "所有转发规则已清除"
    read -p "按任意键继续..."
}

# 主程序
main() {
    install_dependencies
    enable_ip_forward
    install_gost

    while true; do
        show_menu
        case $choice in
            1)
                add_iptables_rule
                read -p "按任意键继续..."
                ;;
            2)
                add_nftables_rule
                read -p "按任意键继续..."
                ;;
            3)
                add_socat_rule
                read -p "按任意键继续..."
                ;;
            4)
                add_gost_rule
                read -p "按任意键继续..."
                ;;
            5)
                show_rules
                ;;
            6)
                clear_rules
                ;;
            0)
                echo "退出脚本"
                exit 0
                ;;
            *)
                echo "无效选择，请重试"
                read -p "按任意键继续..."
                ;;
        esac
    done
}

# 启动主程序
main
