#!/bin/bash
# 功能：nftables 端口转发管理（支持TCP/UDP/TCP+UDP）
# 特点：IP:端口直显、协议可选、极简删除

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_root() {
    [ "$(id -u)" != "0" ] && echo -e "${RED}错误：请使用 root 运行！${NC}" && exit 1
}

install_deps() {
    if ! command -v nft &>/dev/null; then
        if grep -qi "alpine" /etc/os-release; then
            apk add --no-cache nftables
        else
            apt-get update || yum install -y nftables
        fi
    fi
}

nftables_save() {
    nft list ruleset > /etc/nftables.conf 2>/dev/null || true
}

forward() {
    read -p "本地端口: " LOCAL_PORT
    read -p "远程地址 (IP): " TARGET_IP
    read -p "远程端口: " TARGET_PORT

    echo -e "\n${YELLOW}选择协议类型:${NC}"
    echo "1) TCP"
    echo "2) UDP"
    echo "3) TCP+UDP"
    read -p "请选择 [1-3]: " PROTOCOL_CHOICE

    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    case $PROTOCOL_CHOICE in
        1) PROTOCOLS=("tcp") ;;
        2) PROTOCOLS=("udp") ;;
        3) PROTOCOLS=("tcp" "udp") ;;
        *) echo -e "${RED}无效选择！${NC}" && return ;;
    esac

    RULES="table ip nat {\n    chain prerouting {\n        type nat hook prerouting priority 0;"
    for PROTOCOL in "${PROTOCOLS[@]}"; do
        RULES+="\n        $PROTOCOL dport $LOCAL_PORT dnat to $TARGET_IP:$TARGET_PORT"
    done
    RULES+="\n    }\n    chain postrouting {\n        type nat hook postrouting priority 100;\n        masquerade\n    }\n}"

    echo -e "$RULES" > /etc/nftables.conf
    nft -f /etc/nftables.conf
    nftables_save
    echo -e "${GREEN}规则已添加: ${LOCAL_PORT} -> ${TARGET_IP}:${TARGET_PORT} (${PROTOCOLS[*]})${NC}"
}

show_rules() {
    echo -e "\n${BLUE}=== 当前 nftables 规则 ===${NC}"
    nft list table ip nat 2>/dev/null | grep -A2 "dnat to" | awk '{
        if ($0 ~ /tcp|udp/) { proto=$1 }
        if ($0 ~ /dport/) { port=$2 }
        if ($0 ~ /dnat to/) { split($3, target, ":"); ip=target[1]; port_dst=target[2] }
        if (proto && port && ip && port_dst) {
            printf "  %s %s -> %s:%s\n", proto, port, ip, port_dst
        }
    }'
}

delete_rule() {
    show_rules
    read -p "输入要删除的规则行号: " NUM
    HANDLE=$(nft -a list chain ip nat prerouting | awk -v line=$((NUM*3-1)) 'NR==line{print $NF}')
    nft delete rule ip nat prerouting handle $HANDLE
    nftables_save
    echo -e "${GREEN}规则已删除！${NC}"
}

flush_rules() {
    echo -e "\n${RED}=== 警告：即将清空所有 nftables 规则 ===${NC}"
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
    echo "3) 删除单条规则"
    echo "4) 清空所有规则"
    echo -e "${RED}q) 退出${NC}"
    read -p "请选择操作 [1-4/q]: " CHOICE

    case $CHOICE in
        1) forward ;;
        2) show_rules ;;
        3) delete_rule ;;
        4) flush_rules ;;
        q) exit 0 ;;
        *) echo -e "${RED}无效操作！${NC}" ;;
    esac
}

check_root
install_deps
while true; do
    main_menu
done
