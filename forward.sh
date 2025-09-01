#!/bin/bash
# 一键流量转发脚本（支持 iptables/GOST/socat/Docker/nftables）
# 用法：./forward.sh [方案类型] [参数]
# 示例：./forward.sh gost -L=:8080 -F=tls://1.1.1.1:443

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误：必须使用 root 用户运行此脚本！${NC}" >&2
        exit 1
    fi
}

# 安装依赖
install_deps() {
    if grep -qi "alpine" /etc/os-release; then
        echo -e "${YELLOW}[Alpine] 安装依赖中...${NC}"
        apk add --no-cache bash iptables socat docker nftables gcompat curl wget
    else
        echo -e "${YELLOW}[非 Alpine] 安装依赖中...${NC}"
        apt-get update || yum install -y bash iptables socat docker.io nftables curl wget
    fi
}

# 方案 1: iptables 转发
iptables_forward() {
    read -p "本地监听端口: " LOCAL_PORT
    read -p "目标地址 (IP:端口): " TARGET
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    iptables -t nat -A PREROUTING -p tcp --dport "$LOCAL_PORT" -j DNAT --to-destination "$TARGET"
    iptables -t nat -A POSTROUTING -j MASQUERADE
    echo -e "${GREEN}iptables 转发已设置: 本地 $LOCAL_PORT -> $TARGET${NC}"
}

# 方案 2: GOST 转发 (自动处理 musl libc)
gost_forward() {
    GOST_ARGS="$*"
    if ! command -v gost &>/dev/null; then
        echo -e "${YELLOW}正在安装 GOST...${NC}"
        ARCH=$(uname -m)
        if [ "$ARCH" = "x86_64" ]; then
            GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-alpine-amd64-2.11.5.gz"
        else
            GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-alpine-arm64-2.11.5.gz"
        fi
        wget -qO- "$GOST_URL" | gunzip > /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
    fi
    nohup gost $GOST_ARGS > /var/log/gost.log 2>&1 &
    echo -e "${GREEN}GOST 已启动: $GOST_ARGS${NC}"
}

# 方案 3: socat 转发
socat_forward() {
    read -p "本地监听端口: " LOCAL_PORT
    read -p "目标地址 (IP:端口): " TARGET
    nohup socat TCP-LISTEN:"$LOCAL_PORT",fork TCP:"$TARGET" > /dev/null 2>&1 &
    echo -e "${GREEN}socat 已启动: 本地 $LOCAL_PORT -> $TARGET${NC}"
}

# 方案 4: Docker 转发
docker_forward() {
    read -p "本地监听端口: " LOCAL_PORT
    read -p "目标地址 (IP:端口): " TARGET
    if ! systemctl is-active --quiet docker; then
        echo -e "${YELLOW}正在启动 Docker...${NC}"
        systemctl start docker
    fi
    docker run -d --restart always --network host ginuerzh/gost -L="tcp://:$LOCAL_PORT" -F="tcp://$TARGET"
    echo -e "${GREEN}Docker GOST 已启动: 本地 $LOCAL_PORT -> $TARGET${NC}"
}

# 方案 5: nftables 转发
nftables_forward() {
    read -p "本地监听端口: " LOCAL_PORT
    read -p "目标地址 (IP:端口): " TARGET
    sysctl -w net.ipv4.ip_forward=1
    cat > /etc/nftables.conf <<EOF
table ip nat {
    chain prerouting {
        type nat hook prerouting priority 0;
        tcp dport $LOCAL_PORT dnat to $TARGET
    }
    chain postrouting {
        type nat hook postrouting priority 100;
        masquerade
    }
}
EOF
    nft -f /etc/nftables.conf
    echo -e "${GREEN}nftables 转发已设置: 本地 $LOCAL_PORT -> $TARGET${NC}"
}

# 主菜单
main_menu() {
    echo -e "\n${YELLOW}==== 流量转发方案选择 ====${NC}"
    echo "1) iptables 端口转发 (无加密)"
    echo "2) GOST 加密转发 (支持 WS/TLS/KCP)"
    echo "3) socat 临时转发 (调试用)"
    echo "4) Docker 容器转发 (隔离环境)"
    echo "5) nftables 转发 (现代替代方案)"
    echo -e "${RED}q) 退出${NC}"
    read -p "请选择方案 [1-5]: " CHOICE

    case $CHOICE in
        1) iptables_forward ;;
        2) 
            read -p "输入 GOST 参数 (如 -L=:8080 -F=tls://1.1.1.1:443): " GOST_ARGS
            gost_forward $GOST_ARGS 
            ;;
        3) socat_forward ;;
        4) docker_forward ;;
        5) nftables_forward ;;
        q) exit 0 ;;
        *) echo -e "${RED}无效选择！${NC}" && main_menu ;;
    esac
}

# 初始化
check_root
install_deps
main_menu

echo -e "\n${GREEN}✔ 转发规则已部署！${NC}"
echo -e "查看日志: ${YELLOW}tail -f /var/log/gost.log (GOST)${NC}"
echo -e "停止转发: ${YELLOW}killall gost socat || docker stop \$(docker ps -q)${NC}"
