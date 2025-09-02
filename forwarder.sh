#!/bin/bash
# 多功能端口转发脚本 v5 - 彻底修复协议选择显示问题
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
SOCAT_SERVICE_TEMPLATE=$(mktemp)

# 创建socat服务模板
cat << EOF > "$SOCAT_SERVICE_TEMPLATE"
[Unit]
Description=Socat forward service for {proto} {local_port} to {target_ip}:{target_port}
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat {proto_type}-LISTEN:{local_port},reuseaddr,fork {proto_type}:{target_ip}:{target_port}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 安装必要依赖
install_dependencies() {
    echo "正在安装必要依赖..."
    case $OS in
        alpine)
            apk update && apk add --no-cache iptables nftables socat curl wget libc6-compat openrc
            ;;
        debian)
            apt update && apt install -y iptables nftables socat curl wget systemd
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
    
    # 创建socat服务目录
    mkdir -p "$SOCAT_SERVICE_DIR"
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

# 选择协议类型 - 重写版本，确保显示选项
select_protocol() {
    # 直接打印选项，不使用循环嵌套
    echo -e "\n协议类型选择："
    echo "1) TCP"
    echo "2) UDP"
    echo "3) 同时支持TCP和UDP"
    
    # 读取用户输入
    read -p "请选择 [1-3]: " proto_choice
    
    # 判断输入并返回对应值
    case $proto_choice in
        1) return 0 ;;  # TCP
        2) return 1 ;;  # UDP
        3) return 2 ;;  # ALL
        *) 
            echo "错误：请输入1、2或3"
            return 3     # 无效
            ;;
    esac
}

# 添加iptables转发规则
add_iptables_rule() {
    echo "===== 添加iptables转发规则 ====="
    
    # 调用协议选择函数并处理结果
    select_protocol
    proto_result=$?
    
    # 根据返回值确定协议
    case $proto_result in
        0) proto="tcp" ;;
        1) proto="udp" ;;
        2) proto="all" ;;
        3) return ;;  # 无效输入，返回
    esac
    
    read -p "请输入本地端口: " local_port
    read -p "请输入目标IP: " target_ip
    read -p "请输入目标端口: " target_port

    # 保存规则注释
    rule_comment="iptables|$proto|$local_port|$target_ip|$target_port"
    echo "$rule_comment" >> "$IPTABLES_RULES_FILE.comment"

    # 添加对应规则
    case $proto in
        tcp)
            iptables -t nat -A PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $target_ip:$target_port -m comment --comment "$rule_comment"
            ;;
        udp)
            iptables -t nat -A PREROUTING -p udp --dport $local_port -j DNAT --to-destination $target_ip:$target_port -m comment --comment "$rule_comment"
            ;;
        all)
            iptables -t nat -A PREROUTING -p tcp --dport $local_port -j DNAT --to-destination $target_ip:$target_port -m comment --comment "$rule_comment"
            iptables -t nat -A PREROUTING -p udp --dport $local_port -j DNAT --to-destination $target_ip:$target_port -m comment --comment "$rule_comment"
            ;;
    esac
    
    # 确保有MASQUERADE规则
    if ! iptables -t nat -C POSTROUTING -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -j MASQUERADE
    fi
    
    echo "iptables 转发规则已添加: $local_port -> $target_ip:$target_port ($proto)"
    
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
}

# 添加nftables转发规则
add_nftables_rule() {
    echo "===== 添加nftables转发规则 ====="
    
    # 调用协议选择函数
    select_protocol
    proto_result=$?
    
    # 处理选择结果
    case $proto_result in
        0) proto="tcp" ;;
        1) proto="udp" ;;
        2) proto="all" ;;
        3) return ;;  # 无效输入
    esac
    
    read -p "请输入本地端口: " local_port
    read -p "请输入目标IP: " target_ip
    read -p "请输入目标端口: " target_port

    # 初始化nftables
    nft add table ip nat 2>/dev/null
    nft add chain ip nat prerouting '{ type nat hook prerouting priority 0; policy accept; }' 2>/dev/null
    nft add chain ip nat postrouting '{ type nat hook postrouting priority 100; policy accept; }' 2>/dev/null

    # 保存规则信息
    rule_handle="nftables|$proto|$local_port|$target_ip|$target_port"
    echo "$rule_handle" >> "$NFTABLES_RULES_FILE.comment"

    # 添加规则
    case $proto in
        tcp)
            nft add rule ip nat prerouting tcp dport $local_port dnat to $target_ip:$target_port comment "\"$rule_handle\""
            ;;
        udp)
            nft add rule ip nat prerouting udp dport $local_port dnat to $target_ip:$target_port comment "\"$rule_handle\""
            ;;
        all)
            nft add rule ip nat prerouting tcp dport $local_port dnat to $target_ip:$target_port comment "\"$rule_handle\""
            nft add rule ip nat prerouting udp dport $local_port dnat to $target_ip:$target_port comment "\"$rule_handle\""
            ;;
    esac
    
    # 确保有masquerade规则
    if ! nft list rule ip nat postrouting | grep -q "masquerade" 2>/dev/null; then
        nft add rule ip nat postrouting masquerade
    fi
    
    echo "nftables 转发规则已添加: $local_port -> $target_ip:$target_port ($proto)"
    
    # 保存规则并设置开机启动
    nft list ruleset > "$NFTABLES_RULES_FILE"
    
    case $OS in
        alpine)
            rc-update add nftables default
            ;;
        debian|centos)
            systemctl enable nftables
            ;;
    esac
}

# 添加socat转发规则
add_socat_rule() {
    echo "===== 添加socat转发规则 ====="
    
    # 调用协议选择函数
    select_protocol
    proto_result=$?
    
    # 处理选择结果
    case $proto_result in
        0) proto="tcp" ;;
        1) proto="udp" ;;
        2) 
            echo "socat将分别创建TCP和UDP转发服务"
            proto="all" 
            ;;
        3) return ;;  # 无效输入
    esac
    
    read -p "请输入本地端口: " local_port
    read -p "请输入目标IP: " target_ip
    read -p "请输入目标端口: " target_port

    if [ "$proto" = "all" ]; then
        create_socat_service "tcp" $local_port $target_ip $target_port
        create_socat_service "udp" $local_port $target_ip $target_port
    else
        create_socat_service $proto $local_port $target_ip $target_port
    fi
}

# 创建socat服务的辅助函数
create_socat_service() {
    local proto=$1
    local local_port=$2
    local target_ip=$3
    local target_port=$4
    
    service_name="socat-${proto}-${local_port}.service"
    service_path="$SOCAT_SERVICE_DIR/$service_name"
    
    # 替换模板变量
    sed -e "s/{proto}/$proto/g" \
        -e "s/{local_port}/$local_port/g" \
        -e "s/{target_ip}/$target_ip/g" \
        -e "s/{target_port}/$target_port/g" \
        -e "s/{proto_type}/$(echo $proto | tr '[:lower:]' '[:upper:]')/g" \
        "$SOCAT_SERVICE_TEMPLATE" > "$service_path"
    
    # 链接到系统服务目录
    case $OS in
        alpine)
            ln -sf "$service_path" /etc/init.d/
            rc-update add "$service_name" default
            rc-service "$service_name" start
            ;;
        debian|centos)
            ln -sf "$service_path" /etc/systemd/system/
            systemctl daemon-reload
            systemctl enable "$service_name"
            systemctl start "$service_name"
            ;;
    esac
    
    echo "socat $proto 转发已启动: $local_port -> $target_ip:$target_port"
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
            rc-service --list | grep socat
            ;;
        debian|centos)
            systemctl list-units --type=service --full --all | grep socat
            ;;
    esac
    
    read -p "按任意键继续..."
}

# 删除指定规则
delete_rule() {
    echo "请选择要删除的规则类型:"
    echo "1) iptables 规则"
    echo "2) nftables 规则"
    echo "3) socat 服务"
    read -p "请选择 [1-3]: " type_choice

    case $type_choice in
        1) # 删除iptables规则
            echo "当前iptables规则:"
            iptables -t nat -L PREROUTING --line-numbers
            read -p "请输入要删除的规则编号: " rule_num
            if [ -n "$rule_num" ] && [ "$rule_num" -eq "$rule_num" ] 2>/dev/null; then
                iptables -t nat -D PREROUTING $rule_num
                case $OS in
                    alpine) iptables-save > "$IPTABLES_RULES_FILE" ;;
                    debian) iptables-save > "$IPTABLES_RULES_FILE" ;;
                    centos) service iptables save ;;
                esac
                echo "已删除iptables规则 #$rule_num"
            else
                echo "无效的规则编号"
            fi
            ;;
            
        2) # 删除nftables规则
            echo "当前nftables规则:"
            nft list ruleset
            read -p "请输入要删除的规则完整句柄 (例如: ip nat prerouting 1): " rule_handle
            if [ -n "$rule_handle" ]; then
                nft delete rule $rule_handle
                nft list ruleset > "$NFTABLES_RULES_FILE"
                echo "已删除nftables规则: $rule_handle"
            else
                echo "无效的规则句柄"
            fi
            ;;
            
        3) # 删除socat服务
            echo "当前socat服务:"
            case $OS in
                alpine) rc-service --list | grep socat ;;
                debian|centos) systemctl list-units --type=service --full --all | grep socat ;;
            esac
            read -p "请输入要删除的服务名称 (例如: socat-tcp-8080.service): " service_name
            if [ -n "$service_name" ]; then
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
                rm -f "$SOCAT_SERVICE_DIR/$service_name"
                [ "$OS" != "alpine" ] && systemctl daemon-reload
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
        alpine) iptables-save > "$IPTABLES_RULES_FILE" ;;
        debian) iptables-save > "$IPTABLES_RULES_FILE" ;;
        centos) service iptables save ;;
    esac

    # 清除nftables规则
    nft flush ruleset 2>/dev/null
    echo "" > "$NFTABLES_RULES_FILE" 2>/dev/null

    # 清除socat服务
    case $OS in
        alpine)
            for service in $(rc-service --list | grep socat); do
                rc-service "$service" stop
                rc-update del "$service"
                rm -f "/etc/init.d/$service"
            done
            ;;
        debian|centos)
            for service in $(systemctl list-units --type=service --full --all | grep socat | awk '{print $1}'); do
                systemctl stop "$service"
                systemctl disable "$service"
                rm -f "/etc/systemd/system/$service"
            done
            systemctl daemon-reload
            ;;
    esac
    rm -rf "$SOCAT_SERVICE_DIR"/*

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
            1) add_iptables_rule; read -p "按任意键继续..." ;;
            2) add_nftables_rule; read -p "按任意键继续..." ;;
            3) add_socat_rule; read -p "按任意键继续..." ;;
            4) show_rules ;;
            5) delete_rule ;;
            6) clear_rules ;;
            0) 
                echo "退出脚本"
                rm -f "$SOCAT_SERVICE_TEMPLATE"
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
    
