#!/bin/bash
# ============================================
# 脚本：1Panel OpenResty GeoIP2 管理面板
# 版本：5.3 (交互式优化版)
# 功能：提供一键配置与交互式编辑，统一返回选项为0，增加视觉空行
# ============================================

# 定义颜色代码
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
PURPLE='\033[1;35m'
BOLD='\033[1m'
NC='\033[0m'

# 全局路径变量
BASE_DIR="/opt/1panel/apps/openresty/openresty"
NGINX_CONF="${BASE_DIR}/conf/nginx.conf"
DEFAULT_CONF="${BASE_DIR}/conf/default/00.default.conf"
DOCKER_COMPOSE="${BASE_DIR}/docker-compose.yml"
GEOIP_DIR="${BASE_DIR}/geoip2"
GEOIP_DB_URL="https://raw.githubusercontent.com/bulesky89857/shX/refs/heads/main/GeoLite2-Country.mmdb"
GEOIP_DB_FILE="${GEOIP_DIR}/Geoip2_Country.mmdb"

RANDOM_PORT=""
BACKUP_SUFFIX=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/tmp/1panel_backup_${BACKUP_SUFFIX}"

# 全局跳过确认标志 (用于一键配置)
SKIP_CONFIRM=false

# 日志输出函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "\n${CYAN}>>>${NC} $1 ${CYAN}...${NC}"; }
log_divider() { echo -e "${CYAN}--------------------------------------------------${NC}"; }
log_banner() { 
    echo -e "\n${PURPLE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC}  ${GREEN}$1${NC}  ${PURPLE}║${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════╝${NC}"
}

# 检查命令执行结果
check_result() {
    if [ $? -ne 0 ]; then
        log_error "$1"
        return 1
    fi
    return 0
}

# 等待用户确认（受 SKIP_CONFIRM 控制）
confirm_continue() {
    local prompt=${1:-"是否继续？"}
    local default=${2:-"y"}
    
    if [ "$SKIP_CONFIRM" = true ]; then
        return 0  # 一键配置时自动确认
    fi
    
    if [ "$default" = "y" ]; then
        read -p "$prompt (Y/n): " confirm
        confirm=${confirm:-y}
    else
        read -p "$prompt (y/N): " confirm
        confirm=${confirm:-n}
    fi
    
    [[ "$confirm" =~ ^[Yy]$ ]]
}

# 创建备份目录
create_backup_dir() {
    mkdir -p "$BACKUP_DIR"
    log_info "备份目录: $BACKUP_DIR"
}

# 创建重要文件备份
backup_config_file() {
    local file="$1"
    local description="$2"
    
    if [ -f "$file" ]; then
        local filename=$(basename "$file")
        cp "$file" "${BACKUP_DIR}/${filename}.${BACKUP_SUFFIX}.bak"
        log_success "已备份: $description"
    fi
}

# 初始化脚本
init_script() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 sudo 运行此脚本！"
        echo -e "使用: ${CYAN}sudo bash $0${NC}\n"
        exit 1
    fi
    
    if [ ! -d "$BASE_DIR" ]; then
        log_error "1Panel OpenResty 目录不存在: $BASE_DIR"
        exit 1
    fi
    
    create_backup_dir
    backup_config_file "$NGINX_CONF" "Nginx 配置"
    backup_config_file "$DOCKER_COMPOSE" "Docker Compose 配置"
    backup_config_file "$DEFAULT_CONF" "默认站点配置"
    
    RANDOM_PORT=$(( 10000 + RANDOM % 55536 ))
}

# 步骤 1: 修改默认配置文件（无交互版，受 SKIP_CONFIRM 控制）
step_modify_default_conf() {
    log_banner "步骤 1/5: 修改默认配置"
    log_info "目标文件: ${DEFAULT_CONF}"
    
    if [ ! -f "$DEFAULT_CONF" ]; then
        log_error "配置文件不存在: $DEFAULT_CONF"
        return 1
    fi
    
    local port_count=$(grep -o "443" "$DEFAULT_CONF" | wc -l)
    if [ "$port_count" -eq 0 ]; then
        log_warn "未找到 443 端口，跳过替换"
        return 0
    fi
    
    if confirm_continue "是否将 ${port_count} 处 443 端口替换为 ${RANDOM_PORT}？" "y"; then
        sed -i "s/443/${RANDOM_PORT}/g" "$DEFAULT_CONF"
        check_result "替换端口失败" || return 1
        log_success "已将 443 端口替换为 ${RANDOM_PORT}"
    fi
    return 0
}

# 步骤 2: 下载 GeoIP2 数据库（无交互版）
step_deploy_geoip_database() {
    log_banner "步骤 2/5: 部署 GeoIP2 数据库"
    mkdir -p "$GEOIP_DIR"
    
    if [ -f "$GEOIP_DB_FILE" ]; then
        local size=$(du -h "$GEOIP_DB_FILE" 2>/dev/null | cut -f1)
        log_info "数据库已存在，大小: ${size}"
        if ! confirm_continue "是否重新下载？" "n"; then
            log_info "使用现有数据库文件"
            return 0
        fi
    fi
    
    log_info "正在下载 GeoIP2 数据库..."
    if command -v wget &> /dev/null; then
        wget -O "$GEOIP_DB_FILE" "$GEOIP_DB_URL" --timeout=30 --tries=3 --show-progress
    elif command -v curl &> /dev/null; then
        curl -L "$GEOIP_DB_URL" -o "$GEOIP_DB_FILE" --connect-timeout 30 --retry 2 --progress-bar
    else
        log_error "未找到 wget 或 curl"
        return 1
    fi
    
    if [ -s "$GEOIP_DB_FILE" ]; then
        log_success "数据库下载完成"
    else
        log_error "下载失败"
        return 1
    fi
    return 0
}

# 步骤 3: 修复 Docker Compose 格式（无交互版）
step_fix_docker_compose() {
    log_banner "步骤 3/5: 配置 Docker Compose"
    
    if [ ! -f "$DOCKER_COMPOSE" ]; then
        log_error "Docker Compose 文件不存在"
        return 1
    fi
    
    if grep -q "./geoip2:/usr/geoip2/" "$DOCKER_COMPOSE"; then
        log_info "GeoIP2 卷映射已存在"
        if ! confirm_continue "是否重新配置？" "n"; then
            return 0
        fi
        sed -i "/\.\/geoip2:\/usr\/geoip2\//d" "$DOCKER_COMPOSE"
    fi
    
    local volumes_line=$(grep -n "^\s*volumes:" "$DOCKER_COMPOSE" | head -1 | cut -d: -f1)
    if [ -z "$volumes_line" ]; then
        echo "volumes:" >> "$DOCKER_COMPOSE"
        echo "  - ./geoip2:/usr/geoip2/" >> "$DOCKER_COMPOSE"
    else
        # 找到最后一个卷映射行并添加
        local last_volume_line=$volumes_line
        local total_lines=$(wc -l < "$DOCKER_COMPOSE")
        for ((i=volumes_line+1; i<=total_lines; i++)); do
            line=$(sed -n "${i}p" "$DOCKER_COMPOSE")
            [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]] && last_volume_line=$i
        done
        local indent=$(sed -n "${last_volume_line}p" "$DOCKER_COMPOSE" | grep -o '^[[:space:]]*')
        sed -i "${last_volume_line}a\\${indent}- ./geoip2:/usr/geoip2/" "$DOCKER_COMPOSE"
    fi
    
    log_success "GeoIP2 卷映射配置完成"
    return 0
}

# 步骤 4: 配置 Nginx Stream（无交互版，但允许自定义参数）
step_configure_nginx_stream() {
    log_banner "步骤 4/5: 配置 Nginx Stream"
    
    if [ ! -f "$NGINX_CONF" ]; then
        log_error "Nginx 配置文件不存在"
        return 1
    fi
    
    # 如果已存在 stream 块，询问是否覆盖
    if grep -q "^stream {" "$NGINX_CONF"; then
        if ! confirm_continue "已存在 stream 配置，是否覆盖？" "n"; then
            log_info "保留现有配置"
            return 0
        fi
        sed -i '/^stream {/,/^}/d' "$NGINX_CONF"
    fi
    
    local STREAM_CONFIG
    if [ "$SKIP_CONFIRM" = true ]; then
        # 一键配置使用默认参数
        STREAM_CONFIG=$(cat << 'STREAM_BLOCK'
stream {
    error_log /var/log/nginx/stream_error.log info;
    include /usr/local/openresty/nginx/conf/stream.d/*.conf;
    log_format stream_access '$remote_addr [$time_local] '
                            'SNI="$ssl_preread_server_name" '
                            'Country="$stream_geoip2_country_code" '
                            'IsPrivate="$is_private_ip" IsAllowed="$is_allowed" '
                            'TargetPort="$target_port" FinalPort="$final_backend_port" '
                            '$protocol $status $bytes_sent $bytes_received $session_time';
    geoip2 /usr/geoip2/Geoip2_Country.mmdb {
        $stream_geoip2_country_code country iso_code;
    }
    geo $is_private_ip {
        default 0;
        10.0.0.0/8        1;
        172.16.0.0/12     1;
        192.168.0.0/16    1;
        100.64.0.0/10     1;
        127.0.0.0/8       1;
        ::1/128           1;
        # TODO: 在此添加自定义白名单 IP
    }
    map $is_private_ip $real_allowed {
        1       1;
        0       $stream_geoip2_country_code;
    }
    map $real_allowed $is_allowed {
        default 0;
        1       1;
        CN      1;
    }
    map $ssl_preread_server_name $target_port {
        # TODO: 在此添加域名端口映射
        default         44444;
    }
    map $is_allowed $final_backend_port {
        1       $target_port;
        0       44444;
    }
    server {
        listen 443 reuseport;
        ssl_preread on;
        access_log /var/log/nginx/stream_access.log stream_access;
        access_log /dev/stdout stream_access;
        proxy_pass 127.0.0.1:$final_backend_port;
        proxy_connect_timeout 5s;
        proxy_timeout 30s;
    }
}
STREAM_BLOCK
)
    else
        # 交互模式允许自定义
        echo -e "\n${CYAN}自定义配置参数:${NC}"
        read -p "日志路径 [默认: /var/log/nginx/stream_access.log]: " log_path
        read -p "允许的国家代码 [默认: CN]: " allowed_country
        read -p "拒绝连接端口 [默认: 44444]: " deny_port
        log_path=${log_path:-/var/log/nginx/stream_access.log}
        allowed_country=${allowed_country:-CN}
        deny_port=${deny_port:-44444}
        
        STREAM_CONFIG=$(cat << STREAM_BLOCK_CUSTOM
stream {
    error_log /var/log/nginx/stream_error.log info;
    include /usr/local/openresty/nginx/conf/stream.d/*.conf;
    log_format stream_access '\$remote_addr [\$time_local] '
                            'SNI="\$ssl_preread_server_name" '
                            'Country="\$stream_geoip2_country_code" '
                            'IsPrivate="\$is_private_ip" IsAllowed="\$is_allowed" '
                            'TargetPort="\$target_port" FinalPort="\$final_backend_port" '
                            '\$protocol \$status \$bytes_sent \$bytes_received \$session_time';
    geoip2 /usr/geoip2/Geoip2_Country.mmdb {
        \$stream_geoip2_country_code country iso_code;
    }
    geo \$is_private_ip {
        default 0;
        10.0.0.0/8        1;
        172.16.0.0/12     1;
        192.168.0.0/16    1;
        100.64.0.0/10     1;
        127.0.0.0/8       1;
        ::1/128           1;
        # TODO: 在此添加自定义白名单 IP
    }
    map \$is_private_ip \$real_allowed {
        1       1;
        0       \$stream_geoip2_country_code;
    }
    map \$real_allowed \$is_allowed {
        default 0;
        1       1;
        ${allowed_country}      1;
    }
    map \$ssl_preread_server_name \$target_port {
        # TODO: 在此添加域名端口映射
        default         ${deny_port};
    }
    map \$is_allowed \$final_backend_port {
        1       \$target_port;
        0       ${deny_port};
    }
    server {
        listen 443 reuseport;
        ssl_preread on;
        access_log ${log_path} stream_access;
        access_log /dev/stdout stream_access;
        proxy_pass 127.0.0.1:\$final_backend_port;
        proxy_connect_timeout 5s;
        proxy_timeout 30s;
    }
}
STREAM_BLOCK_CUSTOM
)
    fi
    
    # 插入配置到 http 块之前
    local http_line=$(grep -n "^http {" "$NGINX_CONF" | head -1 | cut -d: -f1)
    if [ -n "$http_line" ]; then
        awk -v data="$STREAM_CONFIG" -v line="$http_line" 'NR==line {print data} 1' "$NGINX_CONF" > "${NGINX_CONF}.tmp"
        mv "${NGINX_CONF}.tmp" "$NGINX_CONF"
        log_success "Stream 配置已添加"
    else
        echo -e "\n$STREAM_CONFIG" >> "$NGINX_CONF"
        log_success "Stream 配置已追加到文件末尾"
    fi
    
    return 0
}

# 步骤 5: 重建服务
step_restart_openresty() {
    log_banner "步骤 5/5: 重建服务"
    
    if ! confirm_continue "是否重建 OpenResty 服务？" "y"; then
        log_info "跳过服务重启"
        return 0
    fi
    
    cd "$(dirname "$DOCKER_COMPOSE")" || return 1
    
    local compose_cmd=""
    if docker compose version &> /dev/null; then
        compose_cmd="docker compose"
    elif command -v docker-compose &> /dev/null; then
        compose_cmd="docker-compose"
    else
        log_error "未找到 docker compose 命令"
        return 1
    fi
    
    log_info "正在停止服务..."
    $compose_cmd down 2>/dev/null
    log_info "正在重建服务..."
    $compose_cmd up -d --force-recreate
    sleep 5
    
    if $compose_cmd ps | grep -q "Up"; then
        log_success "服务重建成功"
    else
        log_error "服务启动失败"
        return 1
    fi
    return 0
}

# 显示配置摘要
show_config_summary() {
    log_banner "配置完成摘要"
    echo -e "${GREEN}默认配置端口修改:${NC} 443 → ${RANDOM_PORT}"
    echo -e "${GREEN}GeoIP2 数据库:${NC} $([ -f "$GEOIP_DB_FILE" ] && echo "已下载" || echo "未下载")"
    echo -e "${GREEN}Docker Compose 卷映射:${NC} $([ -f "$DOCKER_COMPOSE" ] && grep -q "./geoip2:/usr/geoip2/" "$DOCKER_COMPOSE" && echo "已配置" || echo "未配置")"
    echo -e "${GREEN}Nginx Stream 配置:${NC} $([ -f "$NGINX_CONF" ] && grep -q "^stream {" "$NGINX_CONF" && echo "已配置" || echo "未配置")"
    echo -e "\n${YELLOW}您可以继续使用菜单中的选项进行微调。${NC}"
}

# 一键配置
one_click_config() {
    log_banner "一键配置"
    SKIP_CONFIRM=true
    init_script
    
    step_modify_default_conf
    step_deploy_geoip_database
    step_fix_docker_compose
    step_configure_nginx_stream
    step_restart_openresty
    
    SKIP_CONFIRM=false
    show_config_summary
}

# 交互式编辑 Nginx 配置
interactive_edit_nginx_conf() {
    log_banner "交互式编辑 Nginx 配置"
    
    if [ ! -f "$NGINX_CONF" ]; then
        log_error "配置文件不存在"
        return 1
    fi
    
    if ! grep -q "^stream {" "$NGINX_CONF"; then
        log_error "未找到 stream 配置，请先运行一键配置"
        return 1
    fi
    
    while true; do
        echo -e "\n${CYAN}======== Nginx 配置管理器 ========${NC}"
        echo -e "1. 添加/编辑白名单 IP"
        echo -e "2. 添加/编辑域名映射"
        echo -e "3. 查看当前配置"
        echo -e ""
        echo -e "${RED}${BOLD}0.${NC} ${YELLOW}返回上一级${NC}"
        echo -e "${CYAN}==================================${NC}"
        
        read -p "请选择操作 (0-3): " nginx_choice
        case $nginx_choice in
            1) manage_whitelist_ips ;;
            2) manage_domain_mappings ;;
            3) view_nginx_config ;;
            0) break ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
    done
}

# 管理白名单 IP
manage_whitelist_ips() {
    echo -e "\n${CYAN}当前白名单 IP 列表:${NC}"
    sed -n '/# TODO: 在此添加自定义白名单 IP/,/^[[:space:]]*}[[:space:]]*$/p' "$NGINX_CONF" | grep -E '^[[:space:]]*[0-9]'
    
    echo -e "\n${YELLOW}操作:${NC}"
    echo -e "1. 添加新 IP"
    echo -e "2. 删除 IP"
    echo -e "3. 清空白名单"
    read -p "请选择: " ip_choice
    
    case $ip_choice in
        1)
            read -p "请输入要添加的 IP 地址 (如: 192.168.1.100): " new_ip
            if [[ $new_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                local todo_line=$(grep -n "# TODO: 在此添加自定义白名单 IP" "$NGINX_CONF" | head -1 | cut -d: -f1)
                if [ -n "$todo_line" ]; then
                    sed -i "${todo_line}a\\        ${new_ip}   1;" "$NGINX_CONF"
                    log_success "已添加: ${new_ip}"
                else
                    log_error "未找到 TODO 标记"
                fi
            else
                log_error "IP 格式错误"
            fi
            ;;
        2)
            read -p "请输入要删除的 IP 地址: " del_ip
            sed -i "/${del_ip}[[:space:]]*1;/d" "$NGINX_CONF"
            log_success "已删除: ${del_ip}"
            ;;
        3)
            if confirm_continue "确定清空白名单吗？" "n"; then
                sed -i '/# TODO: 在此添加自定义白名单 IP/,/^[[:space:]]*}[[:space:]]*$/ {/^[[:space:]]*[0-9]/d}' "$NGINX_CONF"
                log_success "白名单已清空"
            fi
            ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
}

# 管理域名映射
manage_domain_mappings() {
    echo -e "\n${CYAN}当前域名映射列表:${NC}"
    sed -n '/# TODO: 在此添加域名端口映射/,/^[[:space:]]*default[[:space:]]\+[0-9]\+/p' "$NGINX_CONF" | grep -E '^[[:space:]]*[a-zA-Z]'
    
    echo -e "\n${YELLOW}操作:${NC}"
    echo -e "1. 添加域名映射"
    echo -e "2. 删除域名映射"
    echo -e "3. 清空映射"
    read -p "请选择: " domain_choice
    
    case $domain_choice in
        1)
            read -p "请输入域名: " domain
            read -p "请输入端口: " port
            if [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] && [[ "$port" =~ ^[0-9]+$ ]]; then
                local todo_line=$(grep -n "# TODO: 在此添加域名端口映射" "$NGINX_CONF" | head -1 | cut -d: -f1)
                if [ -n "$todo_line" ]; then
                    sed -i "${todo_line}a\\        ${domain} ${port};" "$NGINX_CONF"
                    log_success "已添加: ${domain} -> ${port}"
                else
                    log_error "未找到 TODO 标记"
                fi
            else
                log_error "输入无效"
            fi
            ;;
        2)
            read -p "请输入要删除的域名: " del_domain
            sed -i "/${del_domain}[[:space:]]*[0-9]*;/d" "$NGINX_CONF"
            log_success "已删除: ${del_domain}"
            ;;
        3)
            if confirm_continue "确定清空域名映射吗？" "n"; then
                sed -i '/# TODO: 在此添加域名端口映射/,/^[[:space:]]*default[[:space:]]\+[0-9]\+/ {/^[[:space:]]*[a-zA-Z]/d}' "$NGINX_CONF"
                log_success "域名映射已清空"
            fi
            ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
}

# 查看 Nginx 配置
view_nginx_config() {
    echo -e "\n${CYAN}======== 当前 Nginx 配置 ========${NC}"
    echo -e "\n${GREEN}Stream 块:${NC}"
    grep -A30 "^stream {" "$NGINX_CONF" | head -40
    echo -e "\n${GREEN}白名单 IP:${NC}"
    sed -n '/# TODO: 在此添加自定义白名单 IP/,/^[[:space:]]*}[[:space:]]*$/p' "$NGINX_CONF" | grep -E '^[[:space:]]*[0-9]' | sed 's/^[[:space:]]*//'
    echo -e "\n${GREEN}域名映射:${NC}"
    sed -n '/# TODO: 在此添加域名端口映射/,/^[[:space:]]*default[[:space:]]\+[0-9]\+/p' "$NGINX_CONF" | grep -E '^[[:space:]]*[a-zA-Z]' | sed 's/^[[:space:]]*//'
}

# 检查状态
check_status() {
    log_banner "检查配置状态"
    
    echo -e "\n${CYAN}[文件检查]${NC}"
    for file in "$DEFAULT_CONF" "$NGINX_CONF" "$DOCKER_COMPOSE"; do
        if [ -f "$file" ]; then
            echo -e "${GREEN}[✓]${NC} $file"
        else
            echo -e "${RED}[✗]${NC} $file (不存在)"
        fi
    done
    
    echo -e "\n${CYAN}[配置检查]${NC}"
    grep -q "443" "$DEFAULT_CONF" && echo -e "${YELLOW}[!]${NC} 默认配置中仍存在 443 端口" || echo -e "${GREEN}[✓]${NC} 443 端口已修改"
    
    if grep -q "^stream {" "$NGINX_CONF"; then
        echo -e "${GREEN}[✓]${NC} Stream 配置存在"
    else
        echo -e "${RED}[✗]${NC} Stream 配置缺失"
    fi
    
    if grep -q "./geoip2:/usr/geoip2/" "$DOCKER_COMPOSE"; then
        echo -e "${GREEN}[✓]${NC} GeoIP2 卷映射已配置"
    else
        echo -e "${RED}[✗]${NC} GeoIP2 卷映射缺失"
    fi
    
    if [ -f "$GEOIP_DB_FILE" ]; then
        echo -e "${GREEN}[✓]${NC} GeoIP2 数据库存在"
    else
        echo -e "${RED}[✗]${NC} GeoIP2 数据库不存在"
    fi
    
    echo -e "\n${CYAN}[容器状态]${NC}"
    cd "$(dirname "$DOCKER_COMPOSE")" 2>/dev/null
    if docker compose version &> /dev/null; then
        docker compose ps || echo -e "${YELLOW}[!]${NC} 服务未运行"
    fi
}

# 恢复备份
restore_backup() {
    log_banner "恢复备份"
    
    local backups=($(ls -d /tmp/1panel_backup_* 2>/dev/null | sort -r))
    if [ ${#backups[@]} -eq 0 ]; then
        log_error "未找到备份"
        return 1
    fi
    
    echo -e "\n${CYAN}可用的备份:${NC}"
    for i in "${!backups[@]}"; do
        echo "$((i+1)). $(basename "${backups[$i]}")"
    done
    
    read -p "请选择要恢复的备份编号 (1-${#backups[@]}，或 q 退出): " choice
    [[ "$choice" = "q" ]] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]; then
        log_error "无效选择"
        return 1
    fi
    
    local selected="${backups[$((choice-1))]}"
    if confirm_continue "确定恢复此备份吗？" "n"; then
        find "$selected" -name "*.bak" | while read backup_file; do
            local filename=$(basename "$backup_file" | sed 's/\.[^.]*$//')
            case "$filename" in
                nginx.conf) target="$NGINX_CONF" ;;
                docker-compose) target="$DOCKER_COMPOSE" ;;
                00.default.conf) target="$DEFAULT_CONF" ;;
                *) continue ;;
            esac
            cp -f "$backup_file" "$target"
            echo -e "${GREEN}[✓]${NC} 已恢复: $target"
        done
        log_success "恢复完成"
        confirm_continue "是否重启服务？" "y" && step_restart_openresty
    fi
}

# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}============================================${NC}"
    echo -e "${GREEN}      1Panel OpenResty GeoIP2 管理面板${NC}"
    echo -e "${YELLOW}           版本 5.3 - 交互式优化版${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo -e "时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log_divider
    echo -e "\n${BOLD}主菜单${NC}"
    echo -e "${CYAN}1.${NC} 一键配置 (完整流程)"
    echo -e "${CYAN}2.${NC} 配置 Nginx 文件 (交互式编辑)"
    echo -e "${CYAN}3.${NC} 检查所有修改和服务状态"
    echo -e "${CYAN}4.${NC} 恢复备份"
    echo -e ""
    echo -e "${RED}${BOLD}0.${NC} ${YELLOW}退出脚本${NC}"
    echo -e ""
    log_divider
}

# 主函数
main() {
    init_script
    
    while true; do
        show_menu
        read -p "请选择功能 (0-4): " choice
        case $choice in
            1) one_click_config ;;
            2) interactive_edit_nginx_conf ;;
            3) check_status ;;
            4) restore_backup ;;
            0) echo -e "\n${GREEN}感谢使用，再见！${NC}\n"; exit 0 ;;
            *) echo -e "\n${RED}无效选择${NC}" ;;
        esac
        echo -e ""
        confirm_continue "按 Enter 返回主菜单..." "y" && read
    done
}

# 命令行处理
case "${1:-menu}" in
    config) one_click_config ;;
    check) check_status ;;
    help|--help|-h) echo -e "用法: sudo $0 [config|check|menu|help]" ;;
    menu|*) main ;;
esac