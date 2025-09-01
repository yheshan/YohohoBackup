#!/bin/bash
# 功能：iptables/nftables 规则管理（完美显示 + 极简操作）
# 特点：规则显示完整、nftables直接显示IP:端口、一键清空

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查 root
check_root() {
    [ "$(id -u)" != "0" ] && echo -e "${RED}错误：请使用 root 运行！${NC}" && exit 1
}

# 安装依赖
install_deps() {
    if ! command -v iptables &>/dev/null || ! command -v nft &>/dev/null; then
        if grep -qi "alpine" /etc/os-release; then
            apk add --no-cache iptables nftables
        else
            apt-get update || yum install -y iptables nftables
        fi
    fi
}

# 持久化 iptables 规则
iptables_save() {
    if grep -qi "alpine" /etc/os-release; then
        iptables-save > /etc/iptables.rules
    else
        iptables-save | tee /etc/iptables/rules.v4 >/dev/null
    fi
}

# 持久化 nftables 规则
nftables_save() {
    nft list ruleset > /etc/nftables.conf 2>/dev/null || true
}

#--------------------- 核心转发函数 ---------------------
# 1. iptables 转发（TCP+UDP）
iptables_forward() {
    read -p "本地端口: " LOCAL_PORT
    read -p "远程地址 (IP): " TARGET_IP
    read -p "远程端口: " TARGET_PORT

    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    for PROTOCOL in tcp udp; do
        iptables -t nat -A PREROUTING -p $PROTOCOL --dport "$LOCAL_PORT" -j DNAT --to-destination "$TARGET_IP:$TARGET_PORT"
    done
    iptables -t nat -A POSTROUTING -j MASQUERADE

    iptables_save
    echo -e "${GREEN}iptables 规则已添加: ${LOCAL_IP}:${LOCAL_PORT} -> ${TARGET_IP}:${TARGET_PORT} (TCP+UDP)${NC}"
}

# 2. nftables 转发（TCP+UDP）
nftables_forward() {
    read -p "本地端口: " LOCAL_PORT
    read -p "远程地址 (IP): " TARGET_IP
    read -p "远程端口: " TARGET_PORT

    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    cat > /etc/nftables.conf <<EOF
table ip nat {
    chain prerouting {
        type nat hook prerouting priority 0;
        tcp dport $LOCAL_PORT dnat to $TARGET_IP:$TARGET_PORT
        udp dport $LOCAL_PORT dnat to $TARGET_IP:$TARGET_PORT
    }
    chain postrouting {
        type nat hook postrouting priority 100;
        masquerade
    }
}
EOF
    nft -f /etc/nftables.conf
    nftables_save
    echo -e "${GREEN}nftables 规则已添加: ${LOCAL_IP}:${LOCAL_PORT} -> ${TARGET_IP}:${TARGET_PORT} (TCP+UDP)${NC}"
}

#--------------------- 规则查看 ---------------------
# 查看 iptables 规则（终极修复版）
show_iptables_rules() {
    echo -e "\n${BLUE}=== iptables 规则 ===${NC}"
    iptables -t nat -L PREROUTING -n --line-numbers | grep -E "DNAT" | awk '{
        split($12, parts, ":");
        printf "  %s %s %s -> %s:%s\n", $1, $7, $11, parts[1], parts[2]
    }'
}

# 查看 nftables 规则（直接显示IP:端口）
show_nftables_rules() {
    echo -e "\n${BLUE}=== nftables 规则 ===${NC}"
    nft list table ip nat 2>/dev/null | grep -A2 "dnat to" | awk '{
        if ($0 ~ /tcp|udp/) { proto=$1 }
        if ($0 ~ /dport/) { port=$2 }
        if ($0 ~ /dnat to/) { split($3, target, ":"); ip=target[1]; port_dst=target[2] }
        if (proto && port && ip && port_dst) {
            printf "  %s %s -> %s:%s\n", proto, port, ip, port_dst
        }
    }'
}

# 选择查看规则类型
show_rules() {
    echo -e "\n${YELLOW}=== 查看规则 ===${NC}"
    echo "1) iptables 规则"
    echo "2) nftables 规则"
    read -p "请选择 [1-2]: " CHOICE

    case $CHOICE in
        1) show_iptables_rules ;;
        2) show_nftables_rules ;;
        *) echo -e "${RED}无效选择！${NC}" ;;
    esac
}

#--------------------- 规则管理 ---------------------
# 删除单条规则（极简版）
delete_single_rule() {
    echo -e "\n${YELLOW}=== 删除单条规则 ===${NC}"
    echo "1) iptables"
    echo "2) nftables"
    read -p "选择类型 [1-2]: " CHOICE

    case $CHOICE in
        1)
            show_iptables_rules
            read -p "输入要删除的规则编号: " NUM
            iptables -t nat -D PREROUTING "$NUM"
            iptables_save
            ;;
        2)
            show_nftables_rules
            read -p "输入要删除的规则行号: " NUM
            HANDLE=$(nft -a list chain ip nat prerouting | awk -v line=$((NUM*3-1)) 'NR==line{print $NF}')
            nft delete rule ip nat prerouting handle $HANDLE
            nftables_save
            ;;
        *) echo -e "${RED}无效选择！${NC}" ;;
    esac
    echo -e "${GREEN}规则已删除！${NC}"
}

# 清除所有规则
flush_all_rules() {
    echo -e "\n${RED}=== 警告：即将清除所有转发规则 ===${NC}"
    read -p "确认操作？(y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && return

    # 清除 iptables
    iptables -t nat -F PREROUTING
    iptables -t nat -F POSTROUTING
    iptables_save

    # 清除 nftables
    nft flush ruleset
    rm -f /etc/nftables.conf

    echo -e "${GREEN}所有规则已清除！${NC}"
}

# 主菜单
main_menu() {
    echo -e "\n${YELLOW}==== 流量转发管理 ====${NC}"
    echo "1) iptables 转发 (TCP+UDP)"
    echo "2) nftables 转发 (TCP+UDP)"
    echo "3) 查看规则"
    echo "4) 删除单条规则"
    echo "5) 清除所有规则"
    echo -e "${RED}q) 退出${NC}"
    read -p "请选择操作 [1-5/q]: " CHOICE

    case $CHOICE in
        1) iptables_forward ;;
        2) nftables_forward ;;
        3) show_rules ;;
        4) delete_single_rule ;;
        5) flush_all_rules ;;
        q) exit 0 ;;
        *) echo -e "${RED}无效操作！${NC}" ;;
    esac
}

# 初始化
check_root
install_deps
LOCAL_IP=$(hostname -I | awk '{print $1}')
while true; do
    main_menu
done
