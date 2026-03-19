#!/bin/bash
# ============================================
# 脚本：1Panel OpenResty GeoIP2 管理面板
# 版本：5.5 (优化版)
# 功能：提供一键配置与交互式编辑，统一返回选项为0，增加视觉空行
#       优化代码结构，子菜单0改为保存配置并重建容器
#       卷映射自动跳过已存在的条目
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

# 通用工具函数
ensure_dir() { mkdir -p "$1"; }
ensure_file_exists() { [ -f "$1" ] || log_error "文件不存在: $1"; }

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
        return 0
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
    ensure_dir "$BACKUP_DIR"
    log_info "临时备份目录: $BACKUP_DIR"
}

# 备份重要文件到原目录（带时间戳）
backup_config_file() {
    local file="$1"
    local description="$2"
    if [ -f "$file" ]; then
        local dir=$(dirname "$file")
        local base=$(basename "$file")
        local backup_path="${dir}/${base}.bak.${BACKUP_SUFFIX}"
        cp "$file" "$backup_path"
        log_success "已备份 $description 到 $backup_path"
    fi
}

# 在指定行后插入内容
insert_line_after_pattern() {
    local file="$1"
    local pattern="$2"
    local content="$3"
    local line_num=$(grep -n "$pattern" "$file" | head -1 | cut -d: -f1)
    if [ -n "$line_num" ]; then
        sed -i "${line_num}a\\$content" "$file"
        return 0
    fi
    return 1
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

# 步骤 1: 修改默认配置文件
step_modify_default_conf() {
    log_banner "步骤 1/5: 修改默认配置"
    log_info "目标文件: ${DEFAULT_CONF}"
    
    ensure_file_exists "$DEFAULT_CONF" || return 1
    
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

# 步骤 2: 下载 GeoIP2 数据库
step_deploy_geoip_database() {
    log_banner "步骤 2/5: 部署 GeoIP2 数据库"
    ensure_dir "$GEOIP_DIR"
    
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

# 步骤 3: 配置 Docker Compose 卷映射（自动跳过已存在）
step_fix_docker_compose() {
    log_banner "步骤 3/5: 配置 Docker Compose 卷映射"
    
    ensure_file_exists "$DOCKER_COMPOSE" || return 1
    backup_config_file "$DOCKER_COMPOSE" "Docker Compose 配置"

    local MAP_ENTRY="- ./geoip2:/usr/geoip2/"
    local SEARCH_PATTERN='^[[:space:]]*-[[:space:]]*\./geoip2:/usr/geoip2/'

    # 自动检测，如果已存在则跳过
    if grep -qE "$SEARCH_PATTERN" "$DOCKER_COMPOSE"; then
        log_info "GeoIP2 卷映射已存在，跳过配置"
        return 0
    fi

    # ---------- 定位 openresty 服务块 ----------
    local target_service="openresty"
    local target_service_line=$(grep -n "^[[:space:]]*${target_service}:" "$DOCKER_COMPOSE" | head -1 | cut -d: -f1)
    if [ -z "$target_service_line" ]; then
        log_error "未找到服务 '${target_service}'，请检查 docker-compose.yml"
        return 1
    fi
    log_info "找到服务 ${target_service} (行号: ${target_service_line})"

    local service_line=$(sed -n "${target_service_line}p" "$DOCKER_COMPOSE")
    local service_indent_len=$(echo "$service_line" | grep -o '^[[:space:]]*' | wc -c)
    service_indent_len=$((service_indent_len - 1))
    log_info "服务缩进: ${service_indent_len} 空格"

    local next_service_line=$(awk "NR > $target_service_line && /^[[:space:]]{${service_indent_len}}[^[:space:]]/{print NR; exit}" "$DOCKER_COMPOSE")
    if [ -z "$next_service_line" ]; then
        next_service_line=$(wc -l < "$DOCKER_COMPOSE")
    else
        next_service_line=$((next_service_line - 1))
    fi

    local volumes_line_num=$(awk -v start="$target_service_line" -v end="$next_service_line" '
        NR > start && NR <= end && $0 ~ /^[[:space:]]*volumes:/ {print NR; exit}
    ' "$DOCKER_COMPOSE")

    if [ -z "$volumes_line_num" ]; then
        log_error "未找到 volumes: 块，无法添加映射"
        return 1
    fi
    log_info "找到 volumes: 块 (行号: ${volumes_line_num})"

    local mapping_lines=$(awk -v start="$volumes_line_num" -v end="$next_service_line" '
        NR > start && NR <= end && $0 ~ /^[[:space:]]*-/ {print NR}
    ' "$DOCKER_COMPOSE")

    local last_mapping_line=$(echo "$mapping_lines" | tail -1)
    local tmp_file="${DOCKER_COMPOSE}.tmp"

    if [ -n "$last_mapping_line" ]; then
        log_info "找到最后一个映射行 (行号: $last_mapping_line)，在其后插入"
        local last_line=$(sed -n "${last_mapping_line}p" "$DOCKER_COMPOSE")
        local indent=$(echo "$last_line" | sed -E 's/^([[:space:]]*).*/\1/')
        awk -v insert_line="$last_mapping_line" -v indent="$indent" -v entry="$MAP_ENTRY" '
        {
            print
            if (NR == insert_line) {
                print indent entry
            }
        }' "$DOCKER_COMPOSE" > "$tmp_file"
    else
        log_info "volumes 块为空，在 volumes: 行后插入"
        local volumes_line=$(sed -n "${volumes_line_num}p" "$DOCKER_COMPOSE")
        local volumes_indent=$(echo "$volumes_line" | sed -E 's/^([[:space:]]*).*/\1/')
        local indent=$(printf '%*s' $((${#volumes_indent} + 2)) '')
        awk -v insert_line="$volumes_line_num" -v indent="$indent" -v entry="$MAP_ENTRY" '
        {
            print
            if (NR == insert_line) {
                print indent entry
            }
        }' "$DOCKER_COMPOSE" > "$tmp_file"
    fi

    mv "$tmp_file" "$DOCKER_COMPOSE"
    log_success "已添加卷映射"

    log_info "正在验证 docker-compose.yml 语法..."
    cd "$(dirname "$DOCKER_COMPOSE")" || return 1
    if docker compose config > /dev/null 2>&1; then
        log_success "docker-compose.yml 语法正确"
    else
        log_error "docker-compose.yml 语法错误，正在显示错误详情..."
        docker compose config 2>&1 | head -5
        local latest_backup=$(ls -t "${DOCKER_COMPOSE}.bak."* 2>/dev/null | head -1)
        if [ -f "$latest_backup" ]; then
            cp "$latest_backup" "$DOCKER_COMPOSE"
            log_success "已恢复至备份: $latest_backup"
        else
            log_error "未找到备份，请手动检查文件"
        fi
        return 1
    fi

    log_success "GeoIP2 卷映射配置完成"
    return 0
}

# 生成 stream 配置内容（根据参数）
generate_stream_config() {
    local interactive=$1
    local log_path=""
    local allowed_country=""
    local deny_port=""
    
    if [ "$interactive" = true ] && [ "$SKIP_CONFIRM" = false ]; then
        echo -e "\n${CYAN}自定义配置参数:${NC}"
        read -p "日志路径 [默认: /var/log/nginx/stream_access.log]: " log_path
        read -p "允许的国家代码 [默认: CN]: " allowed_country
        read -p "拒绝连接端口 [默认: 44444]: " deny_port
    fi
    
    log_path=${log_path:-/var/log/nginx/stream_access.log}
    allowed_country=${allowed_country:-CN}
    deny_port=${deny_port:-44444}
    
    cat << STREAM_BLOCK
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
STREAM_BLOCK
}

# 步骤 4: 配置 Nginx Stream
step_configure_nginx_stream() {
    log_banner "步骤 4/5: 配置 Nginx Stream"
    
    ensure_file_exists "$NGINX_CONF" || return 1
    
    if grep -q "^stream {" "$NGINX_CONF"; then
        if ! confirm_continue "已存在 stream 配置，是否覆盖？" "n"; then
            log_info "保留现有配置"
            return 0
        fi
        sed -i '/^stream {/,/^}/d' "$NGINX_CONF"
    fi
    
    # 根据是否一键模式生成不同配置（交互模式允许自定义）
    local stream_config
    if [ "$SKIP_CONFIRM" = true ]; then
        stream_config=$(generate_stream_config false)
    else
        stream_config=$(generate_stream_config true)
    fi
    
    local http_line=$(grep -n "^http {" "$NGINX_CONF" | head -1 | cut -d: -f1)
    if [ -n "$http_line" ]; then
        awk -v data="$stream_config" -v line="$http_line" 'NR==line {print data} 1' "$NGINX_CONF" > "${NGINX_CONF}.tmp"
        mv "${NGINX_CONF}.tmp" "$NGINX_CONF"
        log_success "Stream 配置已添加"
    else
        echo -e "\n$stream_config" >> "$NGINX_CONF"
        log_success "Stream 配置已追加到文件末尾"
    fi
    
    return 0
}

# 验证容器内配置是否正确应用
verify_container_config() {
    log_banner "容器内配置验证"
    cd "$(dirname "$DOCKER_COMPOSE")" || return 1

    local container_name="openresty"
    local compose_cmd=""
    if docker compose version &> /dev/null; then
        compose_cmd="docker compose"
    elif command -v docker-compose &> /dev/null; then
        compose_cmd="docker-compose"
    else
        log_error "未找到 docker compose 命令"
        return 1
    fi

    local container_id=$($compose_cmd ps -q "$container_name" 2>/dev/null)
    if [ -z "$container_id" ]; then
        log_error "容器 $container_name 未运行，跳过验证"
        return 1
    fi

    log_info "正在验证容器: $container_name (${container_id:0:12})"

    # 定义检查列表
    local checks=(
        "GeoIP2 数据库:/usr/geoip2/Geoip2_Country.mmdb:test -f"
        "nginx.conf 存在:/usr/local/openresty/nginx/conf/nginx.conf:test -f"
        "stream 配置加载:/usr/local/openresty/nginx/conf/nginx.conf:grep -q '^stream {'"
    )
    
    for check in "${checks[@]}"; do
        IFS=':' read -r desc path cmd <<< "$check"
        log_step "检查 $desc"
        if docker exec "$container_id" sh -c "$cmd \"$path\"" 2>/dev/null; then
            log_success "$desc 正常"
        else
            log_error "$desc 异常"
        fi
    done

    # 检查白名单 IP
    log_step "检查白名单 IP"
    local whitelist_ips=$(sed -n '/# TODO: 在此添加自定义白名单 IP/,/^[[:space:]]*}[[:space:]]*$/p' "$NGINX_CONF" | grep -E '^[[:space:]]*[0-9]' | awk '{print $1}')
    if [ -n "$whitelist_ips" ]; then
        for ip in $whitelist_ips; do
            if docker exec "$container_id" grep -q "$ip" /usr/local/openresty/nginx/conf/nginx.conf; then
                log_success "白名单 IP $ip 存在"
            else
                log_warn "白名单 IP $ip 未找到（可能被注释或未写入）"
            fi
        done
    else
        log_info "未配置白名单 IP"
    fi

    # 检查域名映射
    log_step "检查域名映射"
    local domain_mappings=$(sed -n '/# TODO: 在此添加域名端口映射/,/^[[:space:]]*default[[:space:]]\+[0-9]\+/p' "$NGINX_CONF" | grep -E '^[[:space:]]*[a-zA-Z]' | awk '{print $1}')
    if [ -n "$domain_mappings" ]; then
        for domain in $domain_mappings; do
            if docker exec "$container_id" grep -q "$domain" /usr/local/openresty/nginx/conf/nginx.conf; then
                log_success "域名 $domain 映射存在"
            else
                log_warn "域名 $domain 映射未找到"
            fi
        done
    else
        log_info "未配置域名映射"
    fi

    log_success "容器内配置验证完成"
    echo -e "\n${YELLOW}提示: 若某项检查失败，请手动进入容器排查：${NC}"
    echo -e "  docker exec -it ${container_id} bash"
}

# 步骤 5: 重建服务
step_restart_openresty() {
    log_banner "步骤 5/5: 重建服务"
    
    if [ "$SKIP_CONFIRM" = false ]; then
        if ! confirm_continue "是否重建 OpenResty 服务？" "y"; then
            log_info "跳过服务重启"
            return 0
        fi
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
        verify_container_config
    else
        log_error "服务启动失败，最近 20 行日志如下："
        $compose_cmd logs --tail=20
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

# 通用管理函数：白名单 IP 或域名映射
manage_mappings() {
    local type="$1"  # "ip" 或 "domain"
    local todo_pattern=""
    local item_pattern=""
    local example=""
    
    if [ "$type" = "ip" ]; then
        todo_pattern="# TODO: 在此添加自定义白名单 IP"
        item_pattern='^[[:space:]]*[0-9]'
        example="192.168.1.100"
    elif [ "$type" = "domain" ]; then
        todo_pattern="# TODO: 在此添加域名端口映射"
        item_pattern='^[[:space:]]*[a-zA-Z]'
        example="example.com 443"
    else
        log_error "未知类型"
        return 1
    fi
    
    echo -e "\n${CYAN}当前列表:${NC}"
    sed -n "/$todo_pattern/,/^[[:space:]]*}[[:space:]]*$/p" "$NGINX_CONF" | grep -E "$item_pattern" | sed 's/^[[:space:]]*//'
    
    echo -e "\n${YELLOW}操作:${NC}"
    echo -e "1. 添加新条目"
    echo -e "2. 删除条目"
    echo -e "3. 清空所有"
    read -p "请选择: " choice
    
    case $choice in
        1)
            if [ "$type" = "ip" ]; then
                read -p "请输入要添加的 IP 地址 (如: $example): " new_value
                if [[ $new_value =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    insert_line_after_pattern "$NGINX_CONF" "$todo_pattern" "        ${new_value}   1;"
                    log_success "已添加: ${new_value}"
                else
                    log_error "IP 格式错误"
                fi
            else
                read -p "请输入域名: " domain
                read -p "请输入端口: " port
                if [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] && [[ "$port" =~ ^[0-9]+$ ]]; then
                    insert_line_after_pattern "$NGINX_CONF" "$todo_pattern" "        ${domain} ${port};"
                    log_success "已添加: ${domain} -> ${port}"
                else
                    log_error "输入无效"
                fi
            fi
            ;;
        2)
            if [ "$type" = "ip" ]; then
                read -p "请输入要删除的 IP 地址: " del_value
                sed -i "/${del_value}[[:space:]]*1;/d" "$NGINX_CONF"
            else
                read -p "请输入要删除的域名: " del_value
                sed -i "/${del_value}[[:space:]]*[0-9]*;/d" "$NGINX_CONF"
            fi
            log_success "已删除: ${del_value}"
            ;;
        3)
            if confirm_continue "确定清空所有吗？" "n"; then
                sed -i "/$todo_pattern/,/^[[:space:]]*}[[:space:]]*$/ {/$item_pattern/d}" "$NGINX_CONF"
                log_success "已清空"
            fi
            ;;
        *) log_error "无效选择" ;;
    esac
}

# 交互式编辑 Nginx 配置
interactive_edit_nginx_conf() {
    log_banner "交互式编辑 Nginx 配置"
    
    ensure_file_exists "$NGINX_CONF" || return 1
    
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
        echo -e "${RED}${BOLD}0.${NC} ${YELLOW}保存配置并重建容器${NC}"
        echo -e "${CYAN}==================================${NC}"
        
        read -p "请选择操作 (0-3): " nginx_choice
        case $nginx_choice in
            1) manage_mappings "ip" ;;
            2) manage_mappings "domain" ;;
            3) view_nginx_config ;;
            0) 
                echo -e "\n${YELLOW}正在保存配置并重建容器...${NC}"
                local old_skip=$SKIP_CONFIRM
                SKIP_CONFIRM=true
                if step_restart_openresty; then
                    log_success "重建成功，返回主菜单。"
                    SKIP_CONFIRM=$old_skip
                    break
                else
                    log_error "重建失败，请检查上方错误信息。"
                    SKIP_CONFIRM=$old_skip
                    echo -e "\n按 Enter 键返回子菜单..."
                    read
                fi
                ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
    done
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
    echo -e "${YELLOW}           版本 5.5 - 优化版${NC}"
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
