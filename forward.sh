#!/bin/bash
# 功能：支持 iptables/GOST/socat/Docker/nftables 多方案转发 + 多目标管理
# 特点：分步输入、多端口转发、规则查看/删除

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
    if grep -qi "alpine" /etc/os-release; then
        apk add --no-cache bash iptables socat docker nftables gcompat curl wget
    else
        apt-get update || yum install -y bash iptables socat docker.io nftables curl wget
    fi
}

# 获取本机IP
get_local_ip() {
    LOCAL_IP=$(ip route get 1 | awk '{print $7}' | head -1)
    [ -z "$LOCAL_IP" ] && LOCAL_IP="0.0.0.0"
    echo "$LOCAL_IP"
}

#--------------------- 核心转发函数 ---------------------
# 1. iptables 转发
iptables_forward() {
    read -p "本地端口: " LOCAL_PORT
    read -p "远程地址 (IP): " TARGET_IP
    read -p "远程端口: " TARGET_PORT
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    iptables -t nat -A PREROUTING -p tcp --dport "$LOCAL_PORT" -j DNAT --to-destination "$TARGET_IP:$TARGET_PORT"
    iptables -t nat -A POSTROUTING -j MASQUERADE
    echo -e "${GREEN}iptables 规则已添加: ${LOCAL_IP}:${LOCAL_PORT} -> ${TARGET_IP}:${TARGET_PORT}${NC}"
}

# 2. GOST 转发（支持多目标）
gost_forward() {
    read -p "本地端口: " LOCAL_PORT
    read -p "协议 (默认 tcp，可选 tcp/udp/ws/tls/kcp): " PROTOCOL
    PROTOCOL=${PROTOCOL:-tcp}
    
    # 多目标输入
    TARGETS=""
    while true; do
        read -p "远程地址 (IP，留空结束): " TARGET_IP
        [ -z "$TARGET_IP" ] && break
        read -p "远程端口: " TARGET_PORT
        TARGETS+="${PROTOCOL}://${TARGET_IP}:${TARGET_PORT},"
    done
    TARGETS=${TARGETS%,}  # 删除末尾逗号

    # 安装 GOST（Alpine 自动适配）
    if ! command -v gost &>/dev/null; then
        ARCH=$(uname -m)
        [ "$ARCH" = "x86_64" ] && ARCH="amd64" || ARCH="arm64"
        wget -qO- "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-alpine-${ARCH}-2.11.5.gz" | gunzip > /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
    fi

    nohup gost -L=":${LOCAL_PORT}" -F="${TARGETS}" > /var/log/gost.log 2>&1 &
    echo -e "${GREEN}GOST 已启动: 本地 ${LOCAL_PORT} -> 多目标 ${TARGETS}${NC}"
}

# 3. socat 转发
socat_forward() {
    read -p "本地端口: " LOCAL_PORT
    read -p "远程地址 (IP): " TARGET_IP
    read -p "远程端口: " TARGET_PORT
    nohup socat TCP-LISTEN:"${LOCAL_PORT}",fork TCP:"${TARGET_IP}:${TARGET_PORT}" > /dev/null 2>&1 &
    echo -e "${GREEN}socat 已启动: 本地 ${LOCAL_PORT} -> ${TARGET_IP}:${TARGET_PORT}${NC}"
}

# 4. Docker 转发
docker_forward() {
    read -p "本地端口: " LOCAL_PORT
    read -p "远程地址 (IP): " TARGET_IP
    read -p "远程端口: " TARGET_PORT
    docker run -d --restart always --network host ginuerzh/gost -L="tcp://:${LOCAL_PORT}" -F="tcp://${TARGET_IP}:${TARGET_PORT}"
    echo -e "${GREEN}Docker GOST 已启动: 本地 ${LOCAL_PORT} -> ${TARGET_IP}:${TARGET_PORT}${NC}"
}

# 5. nftables 转发
nftables_forward() {
    read -p "本地端口: " LOCAL_PORT
    read -p "远程地址 (IP): " TARGET_IP
    read -p "远程端口: " TARGET_PORT
    sysctl -w net.ipv4.ip_forward=1
    cat > /etc/nftables.conf <<EOF
table ip nat {
    chain prerouting {
        type nat hook prerouting priority 0;
        tcp dport $LOCAL_PORT dnat to $TARGET_IP:$TARGET_PORT
    }
    chain postrouting {
        type nat hook postrouting priority 100;
        masquerade
    }
}
EOF
    nft -f /etc/nftables.conf
    echo -e "${GREEN}nftables 规则已添加: ${LOCAL_IP}:${LOCAL_PORT} -> ${TARGET_IP}:${TARGET_PORT}${NC}"
}

#--------------------- 规则管理 ---------------------
# 查看规则
show_rules() {
    echo -e "\n${YELLOW}=== 当前转发规则 ===${NC}"
    echo -e "${GREEN}[iptables]${NC}"
    iptables -t nat -L PREROUTING --line-numbers
    echo -e "\n${GREEN}[GOST]${NC}"
    pgrep -af gost || echo "无运行中的 GOST 进程"
    echo -e "\n${GREEN}[socat]${NC}"
    pgrep -af socat || echo "无运行中的 socat 进程"
    echo -e "\n${GREEN}[Docker]${NC}"
    docker ps --filter "ancestor=ginuerzh/gost" --format "{{.Ports}}"
    echo -e "\n${GREEN}[nftables]${NC}"
    nft list ruleset
}

# 删除规则
delete_rules() {
    echo -e "\n${YELLOW}=== 删除规则 ===${NC}"
    echo "1) iptables"
    echo "2) GOST"
    echo "3) socat"
    echo "4) Docker 容器"
    echo "5) nftables"
    read -p "选择要删除的类型 [1-5]: " CHOICE

    case $CHOICE in
        1) 
            iptables -t nat -L PREROUTING --line-numbers
            read -p "输入要删除的规则编号: " NUM
            iptables -t nat -D PREROUTING "$NUM"
            ;;
        2) pkill -9 gost ;;
        3) pkill -9 socat ;;
        4) docker stop $(docker ps -q --filter "ancestor=ginuerzh/gost") ;;
        5) nft flush ruleset ;;
        *) echo -e "${RED}无效选择！${NC}" ;;
    esac
    echo -e "${GREEN}规则已删除！${NC}"
}

# 主菜单
main_menu() {
    echo -e "\n${YELLOW}==== 流量转发管理 ====${NC}"
    echo "1) 添加转发规则"
    echo "2) 查看所有规则"
    echo "3) 删除规则"
    echo -e "${RED}q) 退出${NC}"
    read -p "请选择操作 [1-3/q]: " CHOICE

    case $CHOICE in
        1)
            echo -e "\n${YELLOW}==== 选择转发方案 ====${NC}"
            echo "1) iptables (无加密)"
            echo "2) GOST (加密)"
            echo "3) socat (调试)"
            echo "4) Docker (隔离环境)"
            echo "5) nftables (现代替代)"
            read -p "选择方案 [1-5]: " METHOD
            case $METHOD in
                1) iptables_forward ;;
                2) gost_forward ;;
                3) socat_forward ;;
                4) docker_forward ;;
                5) nftables_forward ;;
                *) echo -e "${RED}无效选择！${NC}" ;;
            esac
            ;;
        2) show_rules ;;
        3) delete_rules ;;
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
