#!/bin/bash
# 功能：iptables 端口转发管理（100%准确协议显示 + 精准删除）

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_root() {
    [ "$(id -u)" != "0" ] && echo -e "${RED}错误：请使用 root 运行！${NC}" && exit 1
}

install_deps() {
    if ! command -v iptables &>/dev/null; then
        if grep -qi "alpine" /etc/os-release; then
            apk add --no-cache iptables
        else
            apt-get update || yum install -y iptables
        fi
    fi
}

iptables_save() {
    if grep -qi "alpine" /etc/os-release; then
        iptables-save > /etc/iptables.rules
    else
        iptables-save | tee /etc/iptables/rules.v4 >/dev/null
    fi
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

    for PROTOCOL in "${PROTOCOLS[@]}"; do
        iptables -t nat -A PREROUTING -p $PROTOCOL --dport "$LOCAL_PORT" -j DNAT --to-destination "$TARGET_IP:$TARGET_PORT"
    done
    iptables -t nat -A POSTROUTING -j MASQUERADE

    iptables_save
    echo -e "${GREEN}规则已添加: ${LOCAL_PORT} -> ${TARGET_IP}:${TARGET_PORT} (${PROTOCOLS[*]})${NC}"
}

show_rules() {
    echo -e "\n${BLUE}=== 当前 iptables 规则 ===${NC}"
    iptables-save -t nat | awk -F'[ :]+' '
    /PREROUTING.*dport/ {
        proto = ($4 == "-p") ? toupper($5) : "UNKNOWN";
        port = $8;
        split($0, dest, "to:");
        printf "  %s %s -> %s\n", proto, port, dest[2]
    }'
}

delete_rule() {
    show_rules
    RULE_COUNT=$(iptables-save -t nat | grep -c "PREROUTING.*dport")
    [ "$RULE_COUNT" -eq 0 ] && {
        echo -e "${RED}无规则可删！${NC}"
        return
    }
    read -p "输入要删除的规则行号: " NUM
    [ "$NUM" -gt "$RULE_COUNT" ] && {
        echo -e "${RED}无效行号！当前共有 $RULE_COUNT 条规则${NC}"
        return
    }
    
    # 获取协议和端口用于精准删除
    TARGET_RULE=$(iptables-save -t nat | grep "PREROUTING.*dport" | sed -n "${NUM}p")
    PROTO=$(echo "$TARGET_RULE" | grep -oP '(?<=-p )\w+')
    PORT=$(echo "$TARGET_RULE" | grep -oP '(?<=--dport )\d+')
    
    iptables -t nat -D PREROUTING -p $PROTO --dport $PORT -j DNAT --to-destination $(echo "$TARGET_RULE" | grep -oP '(?<=to:)[\d.:]+')
    iptables_save
    echo -e "${GREEN}规则已删除！${NC}"
}

flush_rules() {
    echo -e "\n${RED}=== 警告：即将清空所有 iptables 规则 ===${NC}"
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
