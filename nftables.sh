#!/bin/bash
# 功能：nftables 端口转发管理（强制显示 + 句柄删除）

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_root() {
    [ "$(id -u)" != "0" ] && echo -e "${RED}错误：请使用 root 运行！${NC}" && exit 1
}

install_deps() {
    command -v nft &>/dev/null || {
        if grep -qi "alpine" /etc/os-release; then
            apk add --no-cache nftables
        else
            apt-get update || yum install -y nftables
        fi
    }
}

nftables_save() {
    nft list ruleset > /etc/nftables.conf
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

    nft add table ip nat
    nft add chain ip nat prerouting { type nat hook prerouting priority 0 \; }
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }
    
    nft add rule ip nat prerouting $PROTOCOL dport $LOCAL_PORT dnat to $TARGET_IP:$TARGET_PORT
    nft add rule ip nat postrouting masquerade
    nftables_save

    echo -e "${GREEN}成功: ${PROTOCOL^^} ${LOCAL_PORT} -> ${TARGET_IP}:${TARGET_PORT}${NC}"
}

show_rules() {
    echo -e "\n${BLUE}=== 当前转发规则 ===${NC}"
    nft list table ip nat 2>/dev/null | grep -E 'tcp|udp' -A1 | awk '{
        if ($0 ~ /tcp|udp/) {
            proto = toupper($1);
            port = $3;
        }
        if ($0 ~ /dnat/) {
            target = $4;
            printf "  %-5s %-6s -> %s\n", proto, port, target
        }
    }'
}

delete_rule() {
    show_rules
    read -p "输入要删除的本地端口号: " PORT
    read -p "输入协议类型(tcp/udp): " PROTOCOL

    HANDLE=$(nft -a list chain ip nat prerouting | grep "$PROTOCOL dport $PORT" -A1 | grep -oP '(?<=handle )\d+')
    [ -z "$HANDLE" ] && {
        echo -e "${RED}未找到匹配规则！${NC}"
        return
    }

    nft delete rule ip nat prerouting handle $HANDLE
    nftables_save
    echo -e "${GREEN}规则已删除！${NC}"
}

flush_rules() {
    echo -e "\n${RED}=== 警告：将清空所有规则 ===${NC}"
    read -p "确认操作？(y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && return
    
    nft flush ruleset
    rm -f /etc/nftables.conf
    echo -e "${GREEN}所有规则已清空！${NC}"
}

main_menu() {
    echo -e "\n${YELLOW}==== nftables 转发管理 ====${NC}"
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
