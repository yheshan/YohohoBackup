#!/bin/sh
# Alpine rinetd端口转发工具（最终优化版）
# 解决规则删除不生效问题，确保稳定运行

# 核心配置
RINETD_CONF="/etc/rinetd.conf"
RINETD_BIN="/usr/sbin/rinetd"
SERVICE_NAME="rinetd"

# 检查root权限
[ "$(id -u)" -ne 0 ] && { echo "请用root权限运行: sudo $0"; exit 1; }

# 网络检查
check_network() {
    echo "检查网络连接..."
    for host in "github.com" "mirrors.aliyun.com" "8.8.8.8"; do
        ping -c 2 -W 3 "$host" >/dev/null 2>&1 && return 0
    done
    echo "网络连接失败，请检查网络"
    exit 1
}

# 安装rinetd（多重保障）
install_rinetd() {
    # 检查是否已安装
    if [ -x "$RINETD_BIN" ] && command -v rinetd >/dev/null 2>&1; then
        return 0
    fi

    check_network
    echo "安装rinetd..."

    # 方法1: 包管理器安装
    apk add rinetd >/dev/null 2>&1 && {
        RINETD_BIN=$(command -v rinetd)
        return 0
    }

    # 方法2: 更换国内源重试
    echo "尝试国内源安装..."
    [ ! -f "/etc/apk/repositories.bak" ] && cp /etc/apk/repositories /etc/apk/repositories.bak
    echo "https://mirrors.aliyun.com/alpine/v$(cat /etc/alpine-release | cut -d '.' -f 1,2)/main/" > /etc/apk/repositories
    echo "https://mirrors.aliyun.com/alpine/v$(cat /etc/alpine-release | cut -d '.' -f 1,2)/community/" >> /etc/apk/repositories
    apk update >/dev/null 2>&1 && apk add rinetd >/dev/null 2>&1 && {
        RINETD_BIN=$(command -v rinetd)
        return 0
    }

    # 方法3: 手动下载二进制文件
    echo "尝试手动下载rinetd..."
    arch=$(uname -m)
    case $arch in
        x86_64)
            url="https://github.com/alpinelinux/aports/raw/master/main/rinetd/rinetd"
            ;;
        aarch64)
            url="https://github.com/alpinelinux/aports/raw/master/main/rinetd/rinetd"
            ;;
        *)
            echo "不支持的架构: $arch"
            exit 1
    esac

    wget --no-check-certificate -O "$RINETD_BIN" "$url" >/dev/null 2>&1 && {
        chmod +x "$RINETD_BIN"
        # 创建服务文件
        cat > "/etc/init.d/$SERVICE_NAME" << EOF
#!/sbin/openrc-run
command="$RINETD_BIN"
command_args="-c $RINETD_CONF"
pidfile="/var/run/$SERVICE_NAME.pid"
EOF
        chmod +x "/etc/init.d/$SERVICE_NAME"
        return 0
    }

    echo "安装失败，请手动执行:"
    echo "wget --no-check-certificate -O $RINETD_BIN $url && chmod +x $RINETD_BIN"
    exit 1
}

# 初始化配置
init_config() {
    if [ ! -f "$RINETD_CONF" ]; then
        echo "# rinetd配置" > "$RINETD_CONF"
        echo "logfile /var/log/rinetd.log" >> "$RINETD_CONF"
        echo "allow *" >> "$RINETD_CONF"
    fi
    # 设置开机自启
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
}

# 显示规则
show_rules() {
    echo -e "\n===== 当前转发规则 ====="
    grep -v '^#\|^$' "$RINETD_CONF" | grep -v -E 'logfile|allow|deny' | nl
    [ $? -ne 0 ] && echo "无转发规则"
    echo "======================="
}

# 重启服务（使配置生效）
restart_rinetd() {
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        rc-service "$SERVICE_NAME" restart >/dev/null 2>&1
    else
        rc-service "$SERVICE_NAME" start >/dev/null 2>&1
    fi
    # 验证服务状态
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        echo "服务已重启，规则生效"
    else
        echo "警告: 服务启动失败，尝试手动启动: $RINETD_BIN -c $RINETD_CONF"
    fi
}

# 添加规则
add_rule() {
    echo -e "\n===== 添加转发规则 ====="
    
    read -p "本地监听IP（默认0.0.0.0）: " local_ip
    local_ip=${local_ip:-0.0.0.0}
    
    read -p "本地端口: " local_port
    if ! echo "$local_port" | grep -qE '^[0-9]+$' || [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo "无效端口（1-65535）"
        return 1
    fi
    
    read -p "目标IP: " remote_ip
    [ -z "$remote_ip" ] && { echo "目标IP不能为空"; return 1; }
    
    read -p "目标端口: " remote_port
    if ! echo "$remote_port" | grep -qE '^[0-9]+$' || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo "无效端口（1-65535）"
        return 1
    fi
    
    # 检查端口是否已占用
    if grep -qE "^[[:space:]]*$local_ip[[:space:]]+$local_port[[:space:]]+" "$RINETD_CONF"; then
        echo "错误: 本地端口 $local_port 已被使用"
        return 1
    fi
    
    # 添加规则
    echo "$local_ip $local_port $remote_ip $remote_port" >> "$RINETD_CONF"
    echo "规则添加成功: $local_ip:$local_port -> $remote_ip:$remote_port"
    restart_rinetd
}

# 删除单个规则（确保生效）
delete_rule() {
    show_rules
    
    read -p "输入要删除的规则编号: " rule_num
    if ! echo "$rule_num" | grep -qE '^[0-9]+$'; then
        echo "无效编号"
        return 1
    fi
    
    # 获取规则内容
    rule_line=$(grep -v '^#\|^$' "$RINETD_CONF" | grep -v -E 'logfile|allow|deny' | sed -n "${rule_num}p")
    [ -z "$rule_line" ] && { echo "规则编号不存在"; return 1; }
    
    # 备份并删除规则
    cp "$RINETD_CONF" "$RINETD_CONF.bak"
    grep -vF "$rule_line" "$RINETD_CONF.bak" > "$RINETD_CONF"
    rm -f "$RINETD_CONF.bak"
    
    echo "已删除规则: $rule_line"
    # 强制重启服务，确保规则失效
    restart_rinetd
}

# 清除所有规则
clear_all_rules() {
    read -p "确定清除所有规则？(y/n): " confirm
    [ "$confirm" != "y" ] && { echo "取消操作"; return 0; }
    
    # 备份配置
    cp "$RINETD_CONF" "$RINETD_CONF.bak.$(date +%Y%m%d%H%M%S)"
    
    # 保留基础配置，清除转发规则
    grep -E '^#|logfile|allow|deny' "$RINETD_CONF" > "$RINETD_CONF.tmp"
    mv "$RINETD_CONF.tmp" "$RINETD_CONF"
    
    echo "所有转发规则已清除"
    restart_rinetd
}

# 服务控制
start_service() {
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        echo "rinetd 已在运行"
    else
        rc-service "$SERVICE_NAME" start
        echo "rinetd 已启动"
    fi
}

stop_service() {
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        rc-service "$SERVICE_NAME" stop
        echo "rinetd 已停止"
    else
        echo "rinetd 未在运行"
    fi
}

# 显示菜单
show_menu() {
    clear
    echo "===================== rinetd端口转发工具 ====================="
    echo "基于rinetd，支持TCP/UDP转发，规则自动持久化"
    echo "------------------------------------------------------------"
    echo "1. 添加转发规则"
    echo "2. 删除单个规则"
    echo "3. 清除所有规则"
    echo "4. 启动服务"
    echo "5. 停止服务"
    echo "6. 重启服务（使规则生效）"
    echo "7. 查看当前规则"
    echo "0. 退出"
    echo "============================================================"
    read -p "选择操作 [0-7]: " choice
}

# 主程序
main() {
    install_rinetd
    init_config
    
    while true; do
        show_menu
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) clear_all_rules ;;
            4) start_service ;;
            5) stop_service ;;
            6) restart_rinetd ;;
            7) show_rules ;;
            0) exit 0 ;;
            *) echo "无效选择，请重试" ;;
        esac
        read -p "按任意键继续..." -n 1
    done
}

main
