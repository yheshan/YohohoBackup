#!/bin/bash
# 功能：iptables/nftables 流量转发，同时支持 TCP/UDP，默认持久化
# 特点：双协议支持、自动保存规则、简洁管理

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
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

# 获取本机IP
get_local_ip() {
    LOCAL_IP=$(ip route get 1 | awk '{print $7}' | head -1)
    [ -z "$LOCAL_IP" ] && LOCAL_IP="0.0.0.0"
    echo "$LOCAL_IP"
}

# 持久化 iptables 规则
iptables_save() {
    if grep -qi "alpine" /etc/os-release; then
        iptables-save > /etc/iptables.rules
        echo "iptables-restore < /etc/iptables.rules" >> /etc/local.d/iptables.start
        chmod +x /etc/local.d/iptables.start
        rc-update add local >/dev/null
    else
        iptables-save | tee /etc/iptables/rules.v4 >/dev/null
        systemctl enable netfilter-persistent >/dev/null
    fi
}

# 持久化 nftables 规则
nftables_save() {
    if [ -f /etc/nftables.conf ]; then
        nft list ruleset > /etc/nftables.conf
        systemctl enable nftables >/dev/null 2>&1 || true
    fi
}

#--------------------- 核心转发函数 ---------------------
# 1. iptables 转发（TCP+UDP）
iptables_forward() {
    read -p "本地端口: " LOCAL_PORT
    read -p "远程地址 (IP): " TARGET_IP
    read -p "远程端口: " TARGET_PORT

    # 启用IP转发
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # 添加TCP和UDP规则
    for PROTOCOL in tcp udp; do
        iptables -t nat -A PREROUTING -p $PROTOCOL --dport "$LOCAL_PORT" -j DNAT --to-destination "$TARGET_IP:$TARGET_PORT"
    done
    iptables -t nat -A POSTROUTING -j MASQUERADE

    # 持久化
    iptables_save
    echo -e "${GREEN}iptables 规则已添加: ${LOCAL_IP}:${LOCAL_PORT} (TCP+UDP) -> ${TARGET_IP}:${TARGET_PORT}${NC}"
}

# 2. nftables 转发（TCP+UDP）
nftables_forward() {
    read -p "本地端口: " LOCAL_PORT
    read -p "远程地址 (IP): " TARGET_IP
    read -p "远程端口: " TARGET_PORT

    # 启用IP转发
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # 生成nftables配置（同时监听TCP/UDP）
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
    echo -e "${GREEN}nftables 规则已添加: ${LOCAL_IP}:${LOCAL_PORT} (TCP+UDP) -> ${TARGET_IP}:${TARGET_PORT}${NC}"
}

#--------------------- 规则管理 ---------------------
# 查看规则
show_rules() {
    echo -e "\n${YELLOW}=== 当前转发规则 ===${NC}"
    echo -e "${GREEN}[iptables]${NC}"
    iptables -t nat -L PREROUTING -n --line-numbers | grep -E "DNAT.*to:"
    echo -e "\n${GREEN}[nftables]${NC}"
    nft list ruleset | grep -A2 "dnat to"
}

# 删除规则
delete_rules() {
    echo -e "\n${YELLOW}=== 删除规则 ===${NC}"
    echo "1) iptables"
    echo "2) nftables"
    read -p "选择类型 [1-2]: " CHOICE

    case $CHOICE in
        1)
            iptables -t nat -L PREROUTING -n --line-numbers
            read -p "输入要删除的规则编号: " NUM
            iptables -t nat -D PREROUTING "$NUM"
            iptables_save
            ;;
        2)
            nft flush ruleset
            rm -f /etc/nftables.conf
            ;;
        *) echo -e "${RED}无效选择！${NC}" ;;
    esac
    echo -e "${GREEN}规则已删除！${NC}"
}

# 主菜单
main_menu() {
    echo -e "\n${YELLOW}==== 流量转发管理 ====${NC}"
    echo "1) iptables 转发 (TCP+UDP)"
    echo "2) nftables 转发 (TCP+UDP)"
    echo "3) 查看所有规则"
    echo "4) 删除规则"
    echo -e "${RED}q) 退出${NC}"
    read -p "请选择操作 [1-4/q]: " CHOICE

    case $CHOICE in
        1) iptables_forward ;;
        2) nftables_forward ;;
        3) show_rules ;;
        4) delete_rules ;;
        q) exit 0 ;;
        *) echo -e "${RED}无效操作！${NC}" ;;
    esac
}

# 初始化
check_root
install_deps
LOCAL_IP=$(get_local_ip)
while true; do
    main_menu
done
