#!/bin/bash
# 高级Socat端口转发管理脚本
# 支持TCP/UDP/混合/加密隧道，多端口转发，自动后台运行，规则持久化

# 配置与服务文件路径
CONFIG_DIR="/etc/socat-rules"
CONFIG_FILE="$CONFIG_DIR/rules.conf"
SERVICE_TEMPLATE="/etc/systemd/system/socat@.service"
SYSTEMD_ESCAPE=$(command -v systemd-escape)

# 确保系统支持的函数
check_compatibility() {
    # 检查root权限
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误：请使用root权限运行此脚本"
        exit 1
    fi

    # 检查系统是否支持systemd
    if ! command -v systemctl &> /dev/null; then
        echo "错误：此脚本需要systemd支持（如Debian 9+、CentOS 7+、Alpine 3.8+等）"
        exit 1
    fi

    # 安装socat（自动适配不同系统）
    if ! command -v socat &> /dev/null; then
        echo "正在安装socat..."
        if [ -f /etc/alpine-release ]; then
            apk add --no-cache socat
        elif [ -f /etc/debian_version ]; then
            apt-get update >/dev/null && apt-get install -y socat >/dev/null
        elif [ -f /etc/redhat-release ]; then
            yum install -y socat >/dev/null
        else
            echo "错误：不支持的操作系统，请手动安装socat"
            exit 1
        fi
    fi

    # 创建配置目录
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << EOF
# Socat转发规则配置
# 格式: 规则ID 协议类型 本地地址 本地端口 目标地址 目标端口 [加密参数]
# 示例: web1 tcp 0.0.0.0 80 192.168.1.100 8080
# 加密示例: secure1 tcp 0.0.0.0 443 203.0.113.5 443 aes256:mypass
EOF
    fi

    # 创建systemd服务模板
    if [ ! -f "$SERVICE_TEMPLATE" ]; then
        cat > "$SERVICE_TEMPLATE" << EOF
[Unit]
Description=Socat port forwarding service for %I
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/socat %I
Restart=always
RestartSec=3
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
}

# 添加单个转发规则
add_single_rule() {
    local rule_id=$1
    local proto=$2
    local local_addr=$3
    local local_port=$4
    local target_addr=$5
    local target_port=$6
    local encrypt=$7

    # 检查规则ID是否已存在
    if grep -q "^$rule_id " "$CONFIG_FILE"; then
        echo "错误：规则ID '$rule_id' 已存在，请使用其他名称"
        return 1
    fi

    # 构建socat参数
    local listen_part
    local target_part
    
    case $proto in
        tcp)
            listen_part="TCP-LISTEN:$local_port,bind=$local_addr,reuseaddr,fork"
            target_part="TCP:$target_addr:$target_port"
            ;;
        udp)
            listen_part="UDP-LISTEN:$local_port,bind=$local_addr,reuseaddr,fork"
            target_part="UDP:$target_addr:$target_port"
            ;;
        *)
            echo "错误：不支持的协议类型"
            return 1
    esac

    # 添加加密参数
    if [ -n "$encrypt" ] && [ "$proto" = "tcp" ]; then
        IFS=':' read -r cipher pass <<< "$encrypt"
        target_part="OPENSSL:$target_addr:$target_port,cipher=$cipher,verify=0,password=$pass"
    fi

    # 保存规则到配置文件
    echo "$rule_id $proto $local_addr $local_port $target_addr $target_port $encrypt" >> "$CONFIG_FILE"

    # 启动并设置开机自启
    local escaped_args=$($SYSTEMD_ESCAPE "$listen_part $target_part")
    systemctl start socat@"$escaped_args".service
    systemctl enable socat@"$escaped_args".service >/dev/null

    echo "规则 '$rule_id' 已添加并启动 [${proto}:${local_addr}:${local_port} -> ${target_addr}:${target_port}]"
}

# 批量添加规则
add_rules() {
    echo -e "\n===== 添加转发规则 ====="
    echo "支持批量添加多个端口转发规则"
    
    # 协议选择
    echo -e "\n1. TCP"
    echo "2. UDP"
    echo "3. TCP+UDP (同时创建两种协议)"
    echo "4. 加密TCP隧道 (AES加密)"
    read -p "请选择协议类型 [1-4]: " proto_choice
    case $proto_choice in
        1) protos=("tcp") ;;
        2) protos=("udp") ;;
        3) protos=("tcp" "udp") ;;
        4) protos=("tcp"); use_encrypt=1 ;;
        *) echo "无效选择"; return 1 ;;
    esac

    # 加密设置
    local encrypt_params=""
    if [ "$use_encrypt" = 1 ]; then
        read -p "请设置加密密码: " encrypt_pass
        encrypt_params="aes256:${encrypt_pass}"
    fi

    # 公共设置
    read -p "本地监听地址 (默认: 0.0.0.0): " local_addr
    local_addr=${local_addr:-0.0.0.0}
    read -p "目标服务器地址: " target_addr
    read -p "需要转发的端口数量: " port_count

    # 批量添加端口
    for ((i=1; i<=port_count; i++)); do
        echo -e "\n----- 端口 $i/$port_count -----"
        read -p "本地端口 $i: " local_port
        read -p "目标端口 $i: " target_port
        read -p "规则标识ID (如 rule$i): " rule_id
        rule_id=${rule_id:-"rule$i"}

        # 为每个协议添加规则
        for proto in "${protos[@]}"; do
            add_single_rule "$rule_id-$proto" "$proto" "$local_addr" "$local_port" "$target_addr" "$target_port" "$encrypt_params"
        done
    done
}

# 显示所有规则
list_rules() {
    echo -e "\n===== 当前转发规则 ====="
    echo "ID           协议  本地地址:端口        目标地址:端口        状态"
    echo "--------------------------------------------------------------"
    
    # 跳过注释行和空行处理规则
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^# && -n "$line" ]]; then
            # 解析规则
            IFS=' ' read -r rule_id proto local_addr local_port target_addr target_port encrypt <<< "$line"
            
            # 构建参数检查状态
            case $proto in
                tcp) listen_part="TCP-LISTEN:$local_port,bind=$local_addr,reuseaddr,fork" ;;
                udp) listen_part="UDP-LISTEN:$local_port,bind=$local_addr,reuseaddr,fork" ;;
            esac
            
            target_part="$proto:$target_addr:$target_port"
            if [ -n "$encrypt" ]; then
                target_part="OPENSSL:$target_addr:$target_port,cipher=$(echo $encrypt | cut -d: -f1),verify=0,password=$(echo $encrypt | cut -d: -f2)"
            fi
            
            # 检查服务状态
            escaped_args=$($SYSTEMD_ESCAPE "$listen_part $target_part")
            status=$(systemctl is-active socat@"$escaped_args".service 2>/dev/null)
            status=${status:-"inactive"}
            
            # 格式化输出
            printf "%-12s %-4s  %-18s  %-18s  %s\n" \
                "$rule_id" "$proto" "$local_addr:$local_port" "$target_addr:$target_port" "$status"
        fi
    done < "$CONFIG_FILE"
}

# 删除单个规则
delete_rule() {
    echo -e "\n===== 删除转发规则 ====="
    list_rules
    
    read -p $'\n请输入要删除的规则ID: ' rule_id
    if [ -z "$rule_id" ]; then
        echo "规则ID不能为空"
        return 1
    fi

    # 查找并删除规则
    found=0
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^# && -n "$line" ]]; then
            current_id=$(echo "$line" | awk '{print $1}')
            if [ "$current_id" = "$rule_id" ]; then
                # 解析规则参数
                IFS=' ' read -r rid proto local_addr local_port target_addr target_port encrypt <<< "$line"
                
                # 停止并禁用服务
                case $proto in
                    tcp) listen_part="TCP-LISTEN:$local_port,bind=$local_addr,reuseaddr,fork" ;;
                    udp) listen_part="UDP-LISTEN:$local_port,bind=$local_addr,reuseaddr,fork" ;;
                esac
                
                target_part="$proto:$target_addr:$target_port"
                if [ -n "$encrypt" ]; then
                    target_part="OPENSSL:$target_addr:$target_port,cipher=$(echo $encrypt | cut -d: -f1),verify=0,password=$(echo $encrypt | cut -d: -f2)"
                fi
                
                escaped_args=$($SYSTEMD_ESCAPE "$listen_part $target_part")
                systemctl stop socat@"$escaped_args".service >/dev/null
                systemctl disable socat@"$escaped_args".service >/dev/null
                
                found=1
            else
                echo "$line" >> "$CONFIG_FILE.tmp"
            fi
        else
            echo "$line" >> "$CONFIG_FILE.tmp"
        fi
    done < "$CONFIG_FILE"

    # 替换配置文件
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    if [ $found -eq 1 ]; then
        echo "规则 '$rule_id' 已删除"
    else
        echo "未找到规则 '$rule_id'"
    fi
}

# 清空所有规则
clear_all_rules() {
    echo -e "\n===== 清空所有规则 ====="
    read -p "确定要删除所有转发规则吗? [y/N] " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        # 停止所有socat服务
        systemctl stop socat@*.service >/dev/null
        systemctl disable socat@*.service >/dev/null
        
        # 保留配置文件头部说明
        head -n 5 "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
        mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        
        echo "所有转发规则已清除"
    else
        echo "操作已取消"
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n===== Socat多端口转发管理工具 ====="
        echo "1. 添加转发规则 (支持批量添加多个端口)"
        echo "2. 查看所有规则状态"
        echo "3. 删除单个规则"
        echo "4. 清空所有规则"
        echo "5. 退出"
        read -p "请选择操作 [1-5]: " choice
        
        case $choice in
            1) add_rules ;;
            2) list_rules ;;
            3) delete_rule ;;
            4) clear_all_rules ;;
            5) echo "感谢使用，再见！"; exit 0 ;;
            *) echo "无效选项，请重新输入" ;;
        esac
    done
}

# 程序入口
check_compatibility
main_menu
    
