#!/bin/bash
# 功能：iptables 端口转发管理（零错误协议显示 + 特征删除）

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_root() {
    [ "$(id -u)" != "0" ] && echo -e "${RED}错误：请使用 root 运行！${NC}" && exit 1
}

install_deps() {
    command -v iptables &>/dev/null || {
        if grep -qi "alpine" /etc/os-release; then
            apk add --no-cache iptables
        else
            apt-get update || yum install -y iptables
        fi
    }
}

iptables_save() {
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
}

forward() {
    read -p "本地端口: " LOCAL_PORT
    read -p "远程地址 (IP): " TARGET_IP
    read -p "远程端口: " TARGET_PORT

    echo -e "\n${YELLOW}选择协议类型:${NC}"
    echo "1) TCP"
    echo "2) UDP"
    read -p "请选择 [1-2]: " PROTOCOL_CHOICE

    case $PROTOCOL_CHOICE in
        1) PROTOCOL="tcp" ;;
        2) PROTOCOL="udp" ;;
        *) echo -e "${RED}无效选择！${NC}" && return ;;
    esac

    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    iptables -t nat -A PREROUTING -p $PROTOCOL --dport $LOCAL_PORT -j DNAT --to-destination $TARGET_IP:$TARGET_PORT
    iptables -t nat -A POSTROUTING -j MASQUERADE
    iptables_save

    echo -e "${GREEN}成功: ${PROTOCOL^^} ${LOCAL_PORT} -> ${TARGET_IP}:${TARGET_PORT}${NC}"
}

show_rules() {
    echo -e "\n${BLUE}=== 当前转发规则 ===${NC}"
    iptables-save -t nat | grep -E 'PREROUTING.*dport' | awk -F'[ :]+' '{
        split($0, parts, " ");
        for(i=1; i<=length(parts); i++){
            if(parts[i] == "-p") proto = toupper(parts[++i]);
            if(parts[i] == "--dport") port = parts[++i];
            if(parts[i] == "--to-destination") target = parts[++i];
        }
        printf "  %-5s %-6s -> %s\n", proto, port, target
    }'
}

delete_rule() {
    show_rules
    read -p "输入要删除的本地端口号: " PORT
    read -p "输入协议类型(tcp/udp): " PROTOCOL

    RULE_LINE=$(iptables-save -t nat | grep -n "PREROUTING.*-p $PROTOCOL --dport $PORT" | cut -d: -f1)
    [ -z "$RULE_LINE" ] && {
        echo -e "${RED}未找到匹配规则！${NC}"
        return
    }

    iptables -t nat -D PREROUTING -p $PROTOCOL --dport $PORT -j DNAT --to-destination $(iptables-save -t nat | sed -n "${RULE_LINE}p" | grep -oP '(?<=--to-destination )[\d.:]+')
    iptables_save
    echo -e "${GREEN}规则已删除！${NC}"
}

flush_rules() {
    echo -e "\n${RED}=== 警告：将清空所有转发规则 ===${NC}"
    read -p "确认操作？(y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && return
    
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    iptables_save
    echo -e "${GREEN}所有规则已清空！${NC}"
}

main_menu() {
    echo -e "\n${YELLOW}==== iptables 转发管理 ====${NC}"
    echo "1) 添加转发规则"
    echo "2) 查看规则"
    echo "3) 删除规则"
    echo "4) 清空所有规则"
    echo -e "${RED}0) 退出${NC}"
    read -p "请选择: " CHOICE

    case $CHOICE in
        1) forward ;;
        2) show_rules ;;
        3) delete_rule ;;
        4) flush_rules ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择！${NC}" ;;
    esac
}

check_root
install_deps
while true; do
    main_menu
done
