#!/bin/bash
# 多功能端口转发脚本 - 修复版
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

# 规则存储文件
IPTABLES_RULES_FILE="/etc/iptables/rules.v4"
NFTABLES_RULES_FILE="/etc/nftables.conf"
SOCAT_SERVICE_DIR="/etc/socat-services"

# 安装必要依赖
install_dependencies() {
    echo "正在安装必要依赖..."
    case $OS in
        alpine)
            apk update && apk add --no-cache iptables nftables socat curl wget libc6-compat openrc
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
    
    # 创建socat服务目录并设置权限
    mkdir -p "$SOCAT_SERVICE_DIR"
    chmod 755 "$SOCAT_SERVICE_DIR"
}

# 启用IP转发并持久化
enable_ip_forward() {
    echo "启用IP转发..."
    # 临时启用
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # 永久生效
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    sysctl -p > /dev/null
}

# 显示菜单
show_menu() {
    clear
    echo "==================== 端口转发工具 ===================="
    echo "1. iptables 转发 (简单端口映射，高性能)"
    echo "2. nftables 转发 (新一代防火墙，支持复杂规则)"
    echo "3. socat 转发 (灵活的端口转发，支持多种协议)"
    echo "4. 查看当前转发规则"
    echo "5. 删除指定转发规则"
    echo "6. 清除所有转发规则"
    echo "0. 退出"
    echo "======================================================"
    read -p "请选择功能 [0-6]: " choice
}

# 选择协议类型 - 修复显示问题
select_protocol() {
    # 保存当前输出缓冲区设置
    local old_stty=$(stty -g)
    
    # 显示选项
    echo -e "\n请选择协议类型:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. ALL (同时支持TCP和UDP)"
    
    # 读取输入
    read -p "请输入数字 [1-3]: " proto_choice
    
    # 恢复终端设置
    stty $old_stty
    
    # 判断输入
    case $proto_choice in
        1)
            echo "tcp"
            ;;
        2)
            echo "udp"
            ;;
        3)
            echo "all"
            ;;
        *)
            echo "invalid"
            ;;
    esac
}

# 添加iptables转发规则 - 修复显示问题
add_iptables_rule() {
    echo "===== 添加iptables转发规则 ====="
    
    # 获取协议选择
    proto=$(select_protocol)
    if [ "$proto" = "invalid" ]; then
        echo "无效的协议选择，请重试"
        return 1
    fi
    
    # 读取端口和IP
    read -p "请输入本地端口: " local_port
    read -p "请输入目标IP: " target_ip
    read -p "请输入目标端口: " target_port

    # 验证输入
    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || ! [[ "$target_port" =~ ^[0-9]+$ ]]; then
        echo "错误：端口必须是数字"
        return 1
    fi

    if ! [[ "$target_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "错误：无效的IP地址格式"
        return 1
    fi

    # 添加规则
    case $proto in
        tcp)
            iptables -t nat -A PREROUTING -p tcp --dport "$local_port" -j DNAT --to-destination "$target_ip:$target_port"
            ;;
        udp)
            iptables -t nat -A PREROUTING -p udp --dport "$local_port" -j DNAT --to-destination "$target_ip:$target_port"
            ;;
        all)
            iptables -t nat -A PREROUTING -p tcp --dport "$local_port" -j DNAT --to-destination "$target_ip:$target_port"
            iptables -t nat -A PREROUTING -p udp --dport "$local_port" -j DNAT --to-destination "$target_ip:$target_port"
            ;;
    esac
    
    # 确保有MASQUERADE规则
    if ! iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -j MASQUERADE
    fi
    
    # 保存规则
    case $OS in
        alpine)
            iptables-save > "$IPTABLES_RULES_FILE"
            ;;
        debian)
            iptables-save > "$IPTABLES_RULES_FILE"
            if ! grep -q "iptables-restore < $IPTABLES_RULES_FILE" /etc/rc.local; then
                echo "iptables-restore < $IPTABLES_RULES_FILE" >> /etc/rc.local
                chmod +x /etc/rc.local
            fi
            ;;
        centos)
            service iptables save
            ;;
    esac
    
    # 清晰显示结果
    echo -e "\niptables 转发规则已添加:"
    echo "本地端口: $local_port -> 目标: $target_ip:$target_port (协议: $proto)"
}

# 添加nftables转发规则 - 修复语法错误
add_nftables_rule() {
    echo "===== 添加nftables转发规则 ====="
    
    # 获取协议选择
    proto=$(select_protocol)
    if [ "$proto" = "invalid" ]; then
        echo "无效的协议选择，请重试"
        return 1
    fi
    
    # 读取端口和IP
    read -p "请输入本地端口: " local_port
    read -p "请输入目标IP: " target_ip
    read -p "请输入目标端口: " target_port

    # 验证输入
    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || ! [[ "$target_port" =~ ^[0-9]+$ ]]; then
        echo "错误：端口必须是数字"
        return 1
    fi

    if ! [[ "$target_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "错误：无效的IP地址格式"
        return 1
    fi

    # 初始化nftables（使用正确的语法）
    if ! nft list table ip nat >/dev/null 2>&1; then
        nft add table ip nat
        nft add chain ip nat prerouting '{ type nat hook prerouting priority 0; policy accept; }'
        nft add chain ip nat postrouting '{ type nat hook postrouting priority 100; policy accept; }'
    fi

    # 添加规则（修复语法错误）
    case $proto in
        tcp)
            nft add rule ip nat prerouting tcp dport "$local_port" dnat to "$target_ip:$target_port"
            ;;
        udp)
            nft add rule ip nat prerouting udp dport "$local_port" dnat to "$target_ip:$target_port"
            ;;
        all)
            nft add rule ip nat prerouting tcp dport "$local_port" dnat to "$target_ip:$target_port"
            nft add rule ip nat prerouting udp dport "$local_port" dnat to "$target_ip:$target_port"
            ;;
    esac
    
    # 确保有masquerade规则
    if ! nft list chain ip nat postrouting | grep -q "masquerade" 2>/dev/null; then
        nft add rule ip nat postrouting masquerade
    fi
    
    # 保存规则并设置开机启动
    nft list ruleset > "$NFTABLES_RULES_FILE"
    
    case $OS in
        alpine)
            if ! rc-update -s | grep -q "nftables.*default"; then
                rc-update add nftables default
            fi
            ;;
        debian|centos)
            systemctl enable nftables
            ;;
    esac
    
    # 清晰显示结果
    echo -e "\nnftables 转发规则已添加:"
    echo "本地端口: $local_port -> 目标: $target_ip:$target_port (协议: $proto)"
}

# 添加socat转发规则 - 修复服务创建问题
add_socat_rule() {
    echo "===== 添加socat转发规则 ====="
    
    # 获取协议选择
    proto=$(select_protocol)
    if [ "$proto" = "invalid" ]; then
        echo "无效的协议选择，请重试"
        return 1
    fi
    
    # 读取端口和IP
    read -p "请输入本地端口: " local_port
    read -p "请输入目标IP: " target_ip
    read -p "请输入目标端口: " target_port

    # 验证输入
    if ! [[ "$local_port" =~ ^[0-9]+$ ]] || ! [[ "$target_port" =~ ^[0-9]+$ ]]; then
        echo "错误：端口必须是数字"
        return 1
    fi

    if ! [[ "$target_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "错误：无效的IP地址格式"
        return 1
    fi

    if [ "$proto" = "all" ]; then
        echo "socat将为TCP和UDP分别创建转发服务"
        create_socat_service "tcp" "$local_port" "$target_ip" "$target_port"
        create_socat_service "udp" "$local_port" "$target_ip" "$target_port"
    else
        create_socat_service "$proto" "$local_port" "$target_ip" "$target_port"
    fi
}

# 创建socat服务的辅助函数 - 修复服务名称和权限问题
create_socat_service() {
    local proto=$1
    local local_port=$2
    local target_ip=$3
    local target_port=$4
    
    # 确保参数有效
    if [ -z "$proto" ] || [ -z "$local_port" ] || [ -z "$target_ip" ] || [ -z "$target_port" ]; then
        echo "错误：无效的参数"
        return 1
    fi
    
    service_name="socat-${proto}-${local_port}.service"
    service_path="$SOCAT_SERVICE_DIR/$service_name"
    proto_upper=$(echo "$proto" | tr '[:lower:]' '[:upper:]')
    
    # 创建系统服务文件
    cat << EOF > "$service_path"
[Unit]
Description=Socat forward service for $proto $local_port to $target_ip:$target_port
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat $proto_upper-LISTEN:$local_port,reuseaddr,fork $proto_upper:$target_ip:$target_port
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    
    # 设置文件权限
    chmod 644 "$service_path"
    
    # 设置服务
    case $OS in
        alpine)
            # 确保服务可执行
            ln -sf "$service_path" "/etc/init.d/$service_name"
            chmod +x "/etc/init.d/$service_name"
            
            # 添加到启动项并启动
            if ! rc-update -s | grep -q "$service_name.*default"; then
                rc-update add "$service_name" default
            fi
            rc-service "$service_name" start
            ;;
        debian|centos)
            ln -sf "$service_path" "/etc/systemd/system/$service_name"
            systemctl daemon-reload
            systemctl enable "$service_name"
            systemctl start "$service_name"
            ;;
    esac
    
    echo "socat $proto 转发已启动: $local_port -> $target_ip:$target_port (后台运行)"
}

# 查看当前规则
show_rules() {
    echo "===== iptables 规则 ====="
    iptables -t nat -L PREROUTING --line-numbers
    
    echo -e "\n===== nftables 规则 ====="
    nft list ruleset 2>/dev/null
    
    echo -e "\n===== socat 服务 ====="
    case $OS in
        alpine)
            rc-service --list | grep socat | grep -v "not found"
            ;;
        debian|centos)
            systemctl list-units --type=service --full --all | grep socat | grep -v "not found"
            ;;
    esac
    
    read -p "按任意键继续..."
}

# 删除指定规则
delete_rule() {
    echo "请选择要删除的规则类型:"
    echo "1. iptables 规则"
    echo "2. nftables 规则"
    echo "3. socat 服务"
    read -p "请输入数字 [1-3]: " type_choice

    case $type_choice in
        1) # 删除iptables规则
            echo "当前iptables规则:"
            iptables -t nat -L PREROUTING --line-numbers
            read -p "请输入要删除的规则编号: " rule_num
            if [ -n "$rule_num" ] && [ "$rule_num" -eq "$rule_num" ] 2>/dev/null; then
                iptables -t nat -D PREROUTING "$rule_num"
                # 保存更改
                case $OS in
                    alpine)
                        iptables-save > "$IPTABLES_RULES_FILE"
                        ;;
                    debian)
                        iptables-save > "$IPTABLES_RULES_FILE"
                        ;;
                    centos)
                        service iptables save
                        ;;
                esac
                echo "已删除iptables规则 #$rule_num"
            else
                echo "无效的规则编号"
            fi
            ;;
            
        2) # 删除nftables规则
            echo "当前nftables规则:"
            nft list chain ip nat prerouting
            read -p "请输入要删除的规则编号: " rule_num
            if [ -n "$rule_num" ] && [ "$rule_num" -eq "$rule_num" ] 2>/dev/null; then
                nft delete rule ip nat prerouting "$rule_num"
                nft list ruleset > "$NFTABLES_RULES_FILE"
                echo "已删除nftables规则 #$rule_num"
            else
                echo "无效的规则编号"
            fi
            ;;
            
        3) # 删除socat服务
            echo "当前socat服务:"
            case $OS in
                alpine)
                    rc-service --list | grep socat | grep -v "not found"
                    ;;
                debian|centos)
                    systemctl list-units --type=service --full --all | grep socat | grep -v "not found"
                    ;;
            esac
            read -p "请输入要删除的服务名称 (例如: socat-tcp-8080.service): " service_name
            if [ -n "$service_name" ] && [ -f "$SOCAT_SERVICE_DIR/$service_name" ]; then
                # 停止并禁用服务
                case $OS in
                    alpine)
                        rc-service "$service_name" stop
                        rc-update del "$service_name"
                        ;;
                    debian|centos)
                        systemctl stop "$service_name"
                        systemctl disable "$service_name"
                        ;;
                esac
                # 删除服务文件
                rm -f "$SOCAT_SERVICE_DIR/$service_name"
                rm -f "/etc/init.d/$service_name" 2>/dev/null
                rm -f "/etc/systemd/system/$service_name" 2>/dev/null
                
                case $OS in
                    debian|centos)
                        systemctl daemon-reload
                        ;;
                esac
                echo "已删除socat服务: $service_name"
            else
                echo "无效的服务名称"
            fi
            ;;
            
        *)
            echo "无效选择，请输入1、2或3"
            ;;
    esac
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
            iptables-save > "$IPTABLES_RULES_FILE"
            ;;
        debian)
            iptables-save > "$IPTABLES_RULES_FILE"
            ;;
        centos)
            service iptables save
            ;;
    esac

    # 清除nftables规则
    if nft list table ip nat >/dev/null 2>&1; then
        nft flush table ip nat
    fi
    echo "" > "$NFTABLES_RULES_FILE" 2>/dev/null

    # 清除socat服务
    case $OS in
        alpine)
            for service in $(rc-service --list | grep socat | grep -v "not found"); do
                rc-service "$service" stop
                rc-update del "$service"
                rm -f "/etc/init.d/$service"
                rm -f "$SOCAT_SERVICE_DIR/$service"
            done
            ;;
        debian|centos)
            for service in $(systemctl list-units --type=service --full --all | grep socat | grep -v "not found" | awk '{print $1}'); do
                systemctl stop "$service"
                systemctl disable "$service"
                rm -f "/etc/systemd/system/$service"
                rm -f "$SOCAT_SERVICE_DIR/$service"
            done
            systemctl daemon-reload
            ;;
    esac

    echo "所有转发规则已清除"
    read -p "按任意键继续..."
}

# 主程序
main() {
    install_dependencies
    enable_ip_forward

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
                show_rules
                ;;
            5)
                delete_rule
                ;;
            6)
                clear_rules
                ;;
            0)
                echo "退出脚本"
                exit 0
                ;;
            *)
                echo "无效选择，请输入0-6之间的数字"
                read -p "按任意键继续..."
                ;;
        esac
    done
}

# 启动主程序
main
    
