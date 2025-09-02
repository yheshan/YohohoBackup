#!/bin/bash
# Socat端口转发一键管理脚本
# 支持TCP/UDP/加密隧道，自动后台运行，规则持久化

# 配置文件路径
CONFIG_FILE="/etc/socat_forward_rules.conf"
SERVICE_FILE="/etc/systemd/system/socat-forward@.service"

# 检查系统是否支持socat
check_dependency() {
    if ! command -v socat &> /dev/null; then
        echo "检测到未安装socat，正在尝试安装..."
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            if [[ $ID == "debian" || $ID == "ubuntu" || $ID == "raspbian" ]]; then
                apt-get update && apt-get install -y socat
            elif [[ $ID == "centos" || $ID == "rhel" || $ID == "fedora" ]]; then
                yum install -y socat
            elif [[ $ID == "alpine" ]]; then
                apk add --no-cache socat
            else
                echo "不支持的操作系统，请手动安装socat后再运行脚本"
                exit 1
            fi
        else
            echo "无法识别操作系统，请手动安装socat后再运行脚本"
            exit 1
        fi
    fi

    # 检查systemd
    if ! command -v systemctl &> /dev/null; then
        echo "此脚本需要systemd支持，请使用带有systemd的系统"
        exit 1
    fi
}

# 创建systemd服务文件
create_service() {
    if [ ! -f "$SERVICE_FILE" ]; then
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Socat port forwarding service for %I
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

# 初始化配置文件
init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        touch "$CONFIG_FILE"
        echo "# Socat转发规则配置文件" > "$CONFIG_FILE"
        echo "# 格式: 规则名称 监听协议:监听地址:监听端口 目标协议:目标地址:目标端口 [加密参数]" >> "$CONFIG_FILE"
    fi
}

# 添加转发规则
add_rule() {
    echo -e "\n===== 添加新转发规则 ====="
    
    # 选择协议类型
    echo "请选择协议类型:"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP+UDP (分别创建两条规则)"
    echo "4. 加密TCP隧道 (使用openssl)"
    read -p "请输入选项 [1-4]: " proto_choice
    
    # 获取基本信息
    read -p "请输入规则名称(用于标识，如web_forward): " rule_name
    read -p "请输入本地监听地址(默认0.0.0.0): " listen_addr
    listen_addr=${listen_addr:-0.0.0.0}
    read -p "请输入本地监听端口: " listen_port
    read -p "请输入目标服务器地址: " target_addr
    read -p "请输入目标服务器端口: " target_port

    # 处理不同协议
    case $proto_choice in
        1)  # TCP
            listen_spec="TCP-LISTEN:$listen_port,bind=$listen_addr,reuseaddr"
            target_spec="TCP:$target_addr:$target_port"
            add_single_rule "$rule_name" "$listen_spec" "$target_spec"
            ;;
        2)  # UDP
            listen_spec="UDP-LISTEN:$listen_port,bind=$listen_addr,reuseaddr"
            target_spec="UDP:$target_addr:$target_port"
            add_single_rule "$rule_name" "$listen_spec" "$target_spec"
            ;;
        3)  # TCP+UDP
            # 添加TCP规则
            add_single_rule "${rule_name}_tcp" "TCP-LISTEN:$listen_port,bind=$listen_addr,reuseaddr" "TCP:$target_addr:$target_port"
            # 添加UDP规则
            add_single_rule "${rule_name}_udp" "UDP-LISTEN:$listen_port,bind=$listen_addr,reuseaddr" "UDP:$target_addr:$target_port"
            ;;
        4)  # 加密TCP隧道
            read -p "请设置加密密码: " encrypt_pass
            listen_spec="TCP-LISTEN:$listen_port,bind=$listen_addr,reuseaddr"
            target_spec="OPENSSL:$target_addr:$target_port,cipher=AES256-SHA,verify=0,password=$encrypt_pass"
            add_single_rule "$rule_name" "$listen_spec" "$target_spec" "encrypt"
            ;;
        *)
            echo "无效的选项"
            return 1
            ;;
    esac
}

# 添加单条规则
add_single_rule() {
    local rule_name=$1
    local listen_spec=$2
    local target_spec=$3
    local encrypt_flag=${4:-""}
    
    # 检查规则名称是否已存在
    if grep -q "^$rule_name " "$CONFIG_FILE"; then
        echo "错误: 规则名称 '$rule_name' 已存在"
        return 1
    fi
    
    # 构建socat参数
    local socat_args="$listen_spec,fork $target_spec"
    if [ -n "$encrypt_flag" ]; then
        socat_args="$socat_args"
    fi
    
    # 保存规则到配置文件
    echo "$rule_name $listen_spec $target_spec $encrypt_flag" >> "$CONFIG_FILE"
    
    # 启动服务并设置开机自启
    systemctl start socat-forward@"$(systemd-escape "$socat_args")".service
    systemctl enable socat-forward@"$(systemd-escape "$socat_args")".service
    
    echo "规则 '$rule_name' 添加成功，已设置开机自启"
}

# 显示所有规则
list_rules() {
    echo -e "\n===== 当前转发规则 ====="
    if [ ! -s "$CONFIG_FILE" ]; then
        echo "没有任何转发规则"
        return 0
    fi
    
    # 显示规则列表
    awk 'NR==1 || NR==2 {print; next} !/^#/ && $0!="" {print NR-2 ". " $0}' "$CONFIG_FILE"
    
    # 显示运行状态
    echo -e "\n===== 运行状态 ====="
    systemctl list-units --type=service --full --all | grep "socat-forward@" | grep -v "loaded"
}

# 删除单个规则
delete_rule() {
    echo -e "\n===== 删除转发规则 ====="
    list_rules
    
    if [ -s "$CONFIG_FILE" ]; then
        read -p "请输入要删除的规则序号: " rule_num
        # 获取规则行号（跳过前两行注释）
        line_num=$((rule_num + 2))
        # 获取规则名称
        rule_name=$(sed -n "${line_num}p" "$CONFIG_FILE" | awk '{print $1}')
        # 获取socat参数
        socat_args=$(sed -n "${line_num}p" "$CONFIG_FILE" | awk '{print $2 " " $3}')
        
        if [ -n "$rule_name" ]; then
            # 停止并禁用服务
            systemctl stop socat-forward@"$(systemd-escape "$socat_args")".service
            systemctl disable socat-forward@"$(systemd-escape "$socat_args")".service
            
            # 从配置文件中删除
            sed -i "${line_num}d" "$CONFIG_FILE"
            echo "规则 '$rule_name' 已删除"
        else
            echo "无效的规则序号"
        fi
    fi
}

# 清空所有规则
clear_all_rules() {
    echo -e "\n===== 清空所有转发规则 ====="
    read -p "确定要删除所有规则吗? [y/N] " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        # 停止所有相关服务
        for service in $(systemctl list-units --type=service --full --all | grep "socat-forward@" | awk '{print $1}'); do
            systemctl stop "$service"
            systemctl disable "$service"
        done
        
        # 保留配置文件头部注释
        head -n 2 "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
        mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        
        echo "所有转发规则已清除"
    else
        echo "操作已取消"
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n===== Socat端口转发管理脚本 ====="
        echo "1. 添加转发规则"
        echo "2. 查看所有规则"
        echo "3. 删除单个规则"
        echo "4. 清空所有规则"
        echo "5. 退出"
        read -p "请输入选项 [1-5]: " choice
        
        case $choice in
            1) add_rule ;;
            2) list_rules ;;
            3) delete_rule ;;
            4) clear_all_rules ;;
            5) echo "再见!"; exit 0 ;;
            *) echo "无效的选项，请重新输入" ;;
        esac
    done
}

# 程序入口
check_dependency
init_config
create_service
main_menu
