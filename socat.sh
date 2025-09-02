#!/bin/bash
# Socat端口转发一键管理脚本
# 支持TCP、UDP协议，多端口转发，开机自启，规则管理

# 配置文件路径
CONFIG_FILE="/etc/socat-forward.conf"
SYSTEMD_SERVICE="/etc/systemd/system/socat-forward@.service"

# 检查socat是否安装
check_socat() {
    if ! command -v socat &> /dev/null; then
        echo "未检测到socat，正在安装..."
        if [ -f /etc/alpine-release ]; then
            apk add --no-cache socat
        elif [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y socat
        elif [ -f /etc/redhat-release ]; then
            yum install -y socat
        else
            echo "不支持的操作系统，请手动安装socat"
            exit 1
        fi
    fi
}

# 检查并创建配置文件
check_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        touch "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    fi
}

# 创建systemd服务文件
create_service() {
    if [ ! -f "$SYSTEMD_SERVICE" ]; then
        cat > "$SYSTEMD_SERVICE" << EOF
[Unit]
Description=Socat port forwarding instance %I
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat %I
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
}

# 显示菜单
show_menu() {
    clear
    echo "============================================="
    echo "           Socat端口转发管理脚本              "
    echo "============================================="
    echo "1. 添加转发规则"
    echo "2. 查看所有规则"
    echo "3. 启动指定规则"
    echo "4. 停止指定规则"
    echo "5. 重启指定规则"
    echo "6. 删除指定规则"
    echo "7. 一键启动所有规则"
    echo "8. 一键停止所有规则"
    echo "9. 一键重启所有规则"
    echo "10. 一键清空所有规则"
    echo "0. 退出脚本"
    echo "============================================="
    read -p "请选择操作 [0-10]: " choice
}

# 添加转发规则
add_rule() {
    echo "===== 添加新的转发规则 ====="
    
    # 选择协议类型
    echo "请选择协议类型:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP+UDP"
    read -p "请选择 [1-3]: " proto_choice
    
    case $proto_choice in
        1) protos=("tcp") ;;
        2) protos=("udp") ;;
        3) protos=("tcp" "udp") ;;
        *) echo "无效选择"; return 1 ;;
    esac
    
    # 输入本地端口
    read -p "请输入本地监听端口: " local_port
    if ! [[ $local_port =~ ^[0-9]+$ ]] || [ $local_port -lt 1 ] || [ $local_port -gt 65535 ]; then
        echo "无效的端口号"
        return 1
    fi
    
    # 输入远程地址和端口
    read -p "请输入远程服务器IP: " remote_ip
    read -p "请输入远程服务器端口: " remote_port
    if ! [[ $remote_port =~ ^[0-9]+$ ]] || [ $remote_port -lt 1 ] || [ $remote_port -gt 65535 ]; then
        echo "无效的端口号"
        return 1
    fi
    
    # 生成规则ID
    rule_id="$(date +%s)_${local_port}_${remote_ip}_${remote_port}"
    
    # 添加规则到配置文件
    for proto in "${protos[@]}"; do
        # Socat命令格式
        if [ "$proto" = "tcp" ]; then
            cmd="TCP4-LISTEN:$local_port,reuseaddr,fork TCP4:$remote_ip:$remote_port"
        else
            cmd="UDP4-LISTEN:$local_port,reuseaddr,fork UDP4:$remote_ip:$remote_port"
        fi
        
        # 写入配置文件
        echo "$rule_id|$proto|$local_port|$remote_ip|$remote_port|$cmd" >> "$CONFIG_FILE"
        
        # 启动服务并设置开机自启
        systemctl start socat-forward@"$(systemd-escape "$cmd")".service
        systemctl enable socat-forward@"$(systemd-escape "$cmd")".service
        
        echo "已添加并启动 $proto 转发规则: $local_port -> $remote_ip:$remote_port"
    done
}

# 查看所有规则
list_rules() {
    echo "===== 所有转发规则 ====="
    echo "ID | 协议 | 本地端口 | 远程服务器:端口 | 状态"
    echo "------------------------------------------------"
    
    if [ ! -s "$CONFIG_FILE" ]; then
        echo "没有任何转发规则"
        return 0
    fi
    
    while IFS='|' read -r rule_id proto local_port remote_ip remote_port cmd; do
        if [ -z "$rule_id" ]; then continue; fi
        
        # 检查服务状态
        escaped_cmd=$(systemd-escape "$cmd")
        if systemctl is-active --quiet socat-forward@"$escaped_cmd".service; then
            status="运行中"
        else
            status="已停止"
        fi
        
        echo "$rule_id | $proto | $local_port | $remote_ip:$remote_port | $status"
    done < "$CONFIG_FILE"
}

# 启动指定规则
start_rule() {
    list_rules
    read -p "请输入要启动的规则ID: " target_id
    
    found=0
    while IFS='|' read -r rule_id proto local_port remote_ip remote_port cmd; do
        if [ "$rule_id" = "$target_id" ]; then
            escaped_cmd=$(systemd-escape "$cmd")
            systemctl start socat-forward@"$escaped_cmd".service
            systemctl enable socat-forward@"$escaped_cmd".service
            echo "已启动规则 $rule_id: $proto $local_port -> $remote_ip:$remote_port"
            found=1
        fi
    done < "$CONFIG_FILE"
    
    if [ $found -eq 0 ]; then
        echo "未找到ID为 $target_id 的规则"
    fi
}

# 停止指定规则
stop_rule() {
    list_rules
    read -p "请输入要停止的规则ID: " target_id
    
    found=0
    while IFS='|' read -r rule_id proto local_port remote_ip remote_port cmd; do
        if [ "$rule_id" = "$target_id" ]; then
            escaped_cmd=$(systemd-escape "$cmd")
            systemctl stop socat-forward@"$escaped_cmd".service
            systemctl disable socat-forward@"$escaped_cmd".service
            echo "已停止规则 $rule_id: $proto $local_port -> $remote_ip:$remote_port"
            found=1
        fi
    done < "$CONFIG_FILE"
    
    if [ $found -eq 0 ]; then
        echo "未找到ID为 $target_id 的规则"
    fi
}

# 重启指定规则
restart_rule() {
    list_rules
    read -p "请输入要重启的规则ID: " target_id
    
    found=0
    while IFS='|' read -r rule_id proto local_port remote_ip remote_port cmd; do
        if [ "$rule_id" = "$target_id" ]; then
            escaped_cmd=$(systemd-escape "$cmd")
            systemctl restart socat-forward@"$escaped_cmd".service
            echo "已重启规则 $rule_id: $proto $local_port -> $remote_ip:$remote_port"
            found=1
        fi
    done < "$CONFIG_FILE"
    
    if [ $found -eq 0 ]; then
        echo "未找到ID为 $target_id 的规则"
    fi
}

# 删除指定规则
delete_rule() {
    list_rules
    read -p "请输入要删除的规则ID: " target_id
    
    found=0
    temp_file=$(mktemp)
    
    while IFS='|' read -r rule_id proto local_port remote_ip remote_port cmd; do
        if [ "$rule_id" = "$target_id" ]; then
            escaped_cmd=$(systemd-escape "$cmd")
            systemctl stop socat-forward@"$escaped_cmd".service
            systemctl disable socat-forward@"$escaped_cmd".service
            echo "已删除规则 $rule_id: $proto $local_port -> $remote_ip:$remote_port"
            found=1
        else
            echo "$rule_id|$proto|$local_port|$remote_ip|$remote_port|$cmd" >> "$temp_file"
        fi
    done < "$CONFIG_FILE"
    
    mv "$temp_file" "$CONFIG_FILE"
    
    if [ $found -eq 0 ]; then
        echo "未找到ID为 $target_id 的规则"
    fi
}

# 一键启动所有规则
start_all() {
    echo "正在启动所有规则..."
    while IFS='|' read -r rule_id proto local_port remote_ip remote_port cmd; do
        if [ -z "$rule_id" ]; then continue; fi
        
        escaped_cmd=$(systemd-escape "$cmd")
        systemctl start socat-forward@"$escaped_cmd".service
        systemctl enable socat-forward@"$escaped_cmd".service
        echo "已启动规则 $rule_id: $proto $local_port -> $remote_ip:$remote_port"
    done < "$CONFIG_FILE"
    echo "所有规则启动完成"
}

# 一键停止所有规则
stop_all() {
    echo "正在停止所有规则..."
    while IFS='|' read -r rule_id proto local_port remote_ip remote_port cmd; do
        if [ -z "$rule_id" ]; then continue; fi
        
        escaped_cmd=$(systemd-escape "$cmd")
        systemctl stop socat-forward@"$escaped_cmd".service
        systemctl disable socat-forward@"$escaped_cmd".service
        echo "已停止规则 $rule_id: $proto $local_port -> $remote_ip:$remote_port"
    done < "$CONFIG_FILE"
    echo "所有规则停止完成"
}

# 一键重启所有规则
restart_all() {
    echo "正在重启所有规则..."
    while IFS='|' read -r rule_id proto local_port remote_ip remote_port cmd; do
        if [ -z "$rule_id" ]; then continue; fi
        
        escaped_cmd=$(systemd-escape "$cmd")
        systemctl restart socat-forward@"$escaped_cmd".service
        echo "已重启规则 $rule_id: $proto $local_port -> $remote_ip:$remote_port"
    done < "$CONFIG_FILE"
    echo "所有规则重启完成"
}

# 一键清空所有规则
clear_all() {
    read -p "确定要删除所有规则吗? [y/N] " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        # 停止所有服务
        while IFS='|' read -r rule_id proto local_port remote_ip remote_port cmd; do
            if [ -z "$rule_id" ]; then continue; fi
            
            escaped_cmd=$(systemd-escape "$cmd")
            systemctl stop socat-forward@"$escaped_cmd".service
            systemctl disable socat-forward@"$escaped_cmd".service
        done < "$CONFIG_FILE"
        
        # 清空配置文件
        > "$CONFIG_FILE"
        echo "所有规则已清空"
    else
        echo "操作已取消"
    fi
}

# 主程序
main() {
    # 初始化检查
    check_socat
    check_config
    create_service
    
    while true; do
        show_menu
        case $choice in
            1) add_rule ;;
            2) list_rules ;;
            3) start_rule ;;
            4) stop_rule ;;
            5) restart_rule ;;
            6) delete_rule ;;
            7) start_all ;;
            8) stop_all ;;
            9) restart_all ;;
            10) clear_all ;;
            0) echo "退出脚本"; exit 0 ;;
            *) echo "无效选择，请重试" ;;
        esac
        read -p "按任意键继续..." -n 1 -s
    done
}

# 启动主程序
main
