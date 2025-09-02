#!/bin/sh
# Alpine端口转发一键管理脚本
# 基于rinetd实现，支持多端口转发、规则持久化

# 配置文件路径
RINETD_CONF="/etc/rinetd.conf"
SERVICE_NAME="rinetd"

# 检查是否以root权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请以root权限运行此脚本 (sudo $0)"
    exit 1
fi

# 安装rinetd（如果未安装）
install_rinetd() {
    if ! command -v rinetd >/dev/null 2>&1; then
        echo "正在安装rinetd..."
        apk update >/dev/null 2>&1
        apk add rinetd >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "安装rinetd失败，请检查网络连接"
            exit 1
        fi
    fi
    
    # 确保配置文件存在
    if [ ! -f "$RINETD_CONF" ]; then
        echo "# rinetd configuration" > "$RINETD_CONF"
        echo "logfile /var/log/rinetd.log" >> "$RINETD_CONF"
    fi
    
    # 设置开机自启
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
}

# 显示当前规则
show_rules() {
    echo -e "\n===== 当前转发规则 ====="
    # 过滤掉注释和空行
    grep -v '^#\|^$' "$RINETD_CONF" | grep -v 'logfile' | nl
    if [ $? -ne 0 ]; then
        echo "没有配置转发规则"
    fi
    echo "======================="
}

# 添加转发规则
add_rule() {
    echo -e "\n===== 添加新转发规则 ====="
    
    # 获取用户输入，提供默认值
    read -p "请输入监听IP（默认: 0.0.0.0）: " local_ip
    local_ip=${local_ip:-0.0.0.0}
    
    read -p "请输入本地监听端口: " local_port
    if [ -z "$local_port" ]; then
        echo "本地端口不能为空"
        return 1
    fi
    
    read -p "请输入目标服务器IP: " remote_ip
    if [ -z "$remote_ip" ]; then
        echo "目标IP不能为空"
        return 1
    fi
    
    read -p "请输入目标服务器端口: " remote_port
    if [ -z "$remote_port" ]; then
        echo "目标端口不能为空"
        return 1
    fi
    
    # 检查端口是否已被使用
    if grep -qE "^[[:space:]]*$local_ip[[:space:]]+$local_port[[:space:]]+" "$RINETD_CONF"; then
        echo "错误：本地端口 $local_port 已被使用"
        return 1
    fi
    
    # 添加规则到配置文件
    echo "$local_ip $local_port $remote_ip $remote_port" >> "$RINETD_CONF"
    echo "规则添加成功：$local_ip:$local_port -> $remote_ip:$remote_port"
    
    # 重启服务使规则生效
    restart_service
}

# 删除单个规则
delete_rule() {
    show_rules
    
    read -p "请输入要删除的规则编号: " rule_num
    if [ -z "$rule_num" ] || ! echo "$rule_num" | grep -qE '^[0-9]+$'; then
        echo "无效的规则编号"
        return 1
    fi
    
    # 获取要删除的行
    line=$(grep -v '^#\|^$' "$RINETD_CONF" | grep -v 'logfile' | sed -n "${rule_num}p")
    if [ -z "$line" ]; then
        echo "规则编号不存在"
        return 1
    fi
    
    # 备份配置文件
    cp "$RINETD_CONF" "$RINETD_CONF.bak"
    
    # 删除指定规则
    grep -vF "$line" "$RINETD_CONF.bak" > "$RINETD_CONF"
    rm -f "$RINETD_CONF.bak"
    
    echo "已删除规则: $line"
    
    # 重启服务使更改生效
    restart_service
}

# 清除所有规则
clear_all_rules() {
    read -p "确定要清除所有转发规则吗？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消操作"
        return 0
    fi
    
    # 备份配置文件
    cp "$RINETD_CONF" "$RINETD_CONF.bak.$(date +%Y%m%d%H%M%S)"
    
    # 保留日志配置，清除所有转发规则
    grep 'logfile' "$RINETD_CONF" > "$RINETD_CONF.tmp"
    mv "$RINETD_CONF.tmp" "$RINETD_CONF"
    
    echo "所有转发规则已清除"
    
    # 重启服务
    restart_service
}

# 启动服务
start_service() {
    if rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        echo "$SERVICE_NAME 已在运行"
        return 0
    fi
    
    echo "启动 $SERVICE_NAME..."
    rc-service "$SERVICE_NAME" start
    if [ $? -eq 0 ]; then
        echo "$SERVICE_NAME 启动成功"
    else
        echo "$SERVICE_NAME 启动失败"
    fi
}

# 停止服务
stop_service() {
    if ! rc-service "$SERVICE_NAME" status >/dev/null 2>&1; then
        echo "$SERVICE_NAME 未在运行"
        return 0
    fi
    
    echo "停止 $SERVICE_NAME..."
    rc-service "$SERVICE_NAME" stop
    if [ $? -eq 0 ]; then
        echo "$SERVICE_NAME 已停止"
    else
        echo "$SERVICE_NAME 停止失败"
    fi
}

# 重启服务
restart_service() {
    echo "重启 $SERVICE_NAME..."
    rc-service "$SERVICE_NAME" restart >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "$SERVICE_NAME 重启成功"
    else
        echo "$SERVICE_NAME 重启失败"
    fi
}

# 显示菜单
show_menu() {
    clear
    echo "===================== Alpine端口转发管理工具 ====================="
    echo "基于rinetd实现，支持多端口转发，规则自动持久化（重启不丢失）"
    echo "================================================================="
    echo "1. 添加转发规则"
    echo "2. 删除单个规则"
    echo "3. 清除所有规则"
    echo "4. 启动所有转发规则"
    echo "5. 停止所有转发规则"
    echo "6. 重启所有转发规则"
    echo "7. 查看当前规则"
    echo "0. 退出"
    echo "================================================================="
    read -p "请选择操作 [0-7]: " choice
}

# 主程序
main() {
    # 安装必要组件
    install_rinetd
    
    while true; do
        show_menu
        case $choice in
            1) add_rule ;;
            2) delete_rule ;;
            3) clear_all_rules ;;
            4) start_service ;;
            5) stop_service ;;
            6) restart_service ;;
            7) show_rules ;;
            0) 
                echo "感谢使用，再见！"
                exit 0 
                ;;
            *) 
                echo "无效的选择，请重试"
                ;;
        esac
        read -p "按任意键继续..." -n 1
    done
}

# 启动主程序
main
