sudo bash -c '
# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
WHITE="\033[37m"
BOLD="\033[1m"
UNDERLINE="\033[4m"
RESET="\033[0m"

# 图标定义
ICON_OK="${GREEN}✓${RESET}"
ICON_WARN="${YELLOW}⚠${RESET}"
ICON_ERROR="${RED}✗${RESET}"
ICON_INFO="${BLUE}ℹ${RESET}"
ICON_CONFIG="${CYAN}⚙${RESET}"
ICON_FOLDER="${MAGENTA}📁${RESET}"

config_file="/etc/ssh/sshd_config"
backup_file="$config_file.$(date +%Y%m%d%H%M%S).bak"

# 安全配置参数
declare -a kv_pairs=(
  "PubkeyAuthentication yes"
  "PasswordAuthentication no" 
  "PermitRootLogin prohibit-password"
  "PermitEmptyPasswords no"
)

echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}${WHITE}             SSH安全配置              ${RESET}"
echo -e "${BOLD}${YELLOW}目的: 关闭密码认证,允许密钥登陆,禁用空密码${RESET}"
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"

# 创建修改标记数组
declare -A modified

# 备份原配置文件
cp "$config_file" "$backup_file" 2>/dev/null || echo -e "${ICON_WARN} 注意：无法创建备份，继续执行..."

# 检查是否需要修改
has_changes=false
for kv in "${kv_pairs[@]}"; do
  key="${kv%% *}"
  val="${kv#* }"
  current_line=$(grep -E "^[#[:space:]]*$key" "$config_file" 2>/dev/null | head -1)
  if [ -n "$current_line" ] && [ "$(echo "$current_line" | tr -d '[:space:]')" = "$(echo "$key $val" | tr -d '[:space:]')" ]; then
    # 配置已正确设置，无需修改
    modified[$key]=0
  else
    has_changes=true
  fi
done

if [ "$has_changes" = true ]; then
  echo -e "${ICON_CONFIG} ${BOLD}更新SSH配置:${RESET}"
  echo -e "${BLUE}────────────────────────────────────────${RESET}"
  for kv in "${kv_pairs[@]}"; do
    key="${kv%% *}"
    val="${kv#* }"
    before=$(grep -E "^[#[:space:]]*$key" "$config_file" 2>/dev/null | head -1 | sed "s/^[[:space:]]*//")
    [ -z "$before" ] && before="${YELLOW}(未设置)${RESET}"
    
    # 检查当前配置是否与目标相同
    current_clean=$(echo "$before" | tr -d '[:space:]' | grep -o "^[^#]*" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")
    target_clean=$(echo "$key $val" | tr -d '[:space:]')
    
    if [ "$current_clean" = "$target_clean" ] || ([ -n "$current_clean" ] && [ "$current_clean" = "#$target_clean" ]); then
      # 配置已正确设置，无需修改
      modified[$key]=0
    else
      # 需要修改
      modified[$key]=1
      if grep -q "^[#[:space:]]*$key" "$config_file"; then
        sed -i "s|^[#[:space:]]*$key.*|$key $val|" "$config_file"
      else
        echo "$key $val" >> "$config_file"
      fi
    fi
    
    after=$(grep -E "^[#[:space:]]*$key" "$config_file" 2>/dev/null | head -1 | sed "s/^[[:space:]]*//")
    
    # 为每个参数添加中文说明
    case $key in
      "PubkeyAuthentication")
        cn_name="密钥认证"
        color="${GREEN}"
        ;;
      "PasswordAuthentication")
        cn_name="密码认证"
        color="${RED}"
        ;;
      "PermitRootLogin")
        cn_name="root登录"
        color="${YELLOW}"
        ;;
      "PermitEmptyPasswords")
        cn_name="空密码"
        color="${RED}"
        ;;
      *)
        cn_name="$key"
        color="${WHITE}"
        ;;
    esac
    
    # 美化前后值显示
    before_display="$before"
    if [[ "$before" =~ ^# ]] && [[ "$after" =~ ^[^#] ]]; then
      # 从注释变为非注释
      after_display="${GREEN}${after}${RESET}"
    elif [[ "$before" =~ ^[[:space:]]*$ ]] && [[ -n "$after" ]]; then
      # 从未设置到设置
      after_display="${GREEN}${after}${RESET}"
    elif [[ "$before" != "$after" ]]; then
      # 值改变
      after_display="${GREEN}${after}${RESET}"
    else
      # 无变化
      after_display="${WHITE}${after}${RESET}"
    fi
    
    # 添加修改标记
    if [ "${modified[$key]}" = "1" ]; then
      echo -e "  ${BOLD}${color}${cn_name}${RESET}: ${before_display} ${BOLD}→${RESET} ${after_display} ${ICON_OK}"
    else
      echo -e "  ${BOLD}${color}${cn_name}${RESET}: ${before_display} ${BOLD}→${RESET} ${after_display}"
    fi
  done
  echo -e "${BLUE}────────────────────────────────────────${RESET}"
else
  echo -e "${ICON_OK} ${BOLD}${GREEN}SSH配置已是最新状态，无需修改${RESET}"
  echo -e "${BLUE}────────────────────────────────────────${RESET}"
  echo -e "${BOLD}当前配置:${RESET}"
  for kv in "${kv_pairs[@]}"; do
    key="${kv%% *}"
    val="${kv#* }"
    current_line=$(grep -E "^[#[:space:]]*$key" "$config_file" 2>/dev/null | head -1 | sed "s/^[[:space:]]*//")
    [ -z "$current_line" ] && current_line="${YELLOW}(未设置)${RESET}"
    
    case $key in
      "PubkeyAuthentication")
        cn_name="密钥认证"
        color="${GREEN}"
        ;;
      "PasswordAuthentication")
        cn_name="密码认证"
        color="${RED}"
        ;;
      "PermitRootLogin")
        cn_name="root登录"
        color="${YELLOW}"
        ;;
      "PermitEmptyPasswords")
        cn_name="空密码"
        color="${RED}"
        ;;
      *)
        cn_name="$key"
        color="${WHITE}"
        ;;
    esac
    
    # 检查配置是否正确
    if [[ "$current_line" =~ ^# ]]; then
      # 注释状态
      line_color="${YELLOW}"
    elif [[ "$current_line" =~ $key[[:space:]]+$val ]]; then
      # 配置正确
      line_color="${GREEN}"
    else
      # 配置错误
      line_color="${RED}"
    fi
    
    echo -e "  ${BOLD}${color}${cn_name}${RESET}: ${line_color}${current_line}${RESET}"
  done
  echo -e "${BLUE}────────────────────────────────────────${RESET}"
fi

# 统计修改数量
modified_count=0
for key in "${!modified[@]}"; do
  if [ "${modified[$key]}" = "1" ]; then
    modified_count=$((modified_count + 1))
  fi
done

# 检查配置目录中的潜在冲突
has_conflicts=false
for conf_dir in /etc/ssh/ssh_config.d /etc/ssh/sshd_config.d; do
  if [ -d "$conf_dir" ]; then
    find "$conf_dir" -name "*.conf" -type f 2>/dev/null | while read conf; do
      for kv in "${kv_pairs[@]}"; do
        key="${kv%% *}"
        if grep -q "^[#[:space:]]*$key" "$conf" 2>/dev/null; then
          has_conflicts=true
          echo -e "${ICON_WARN} ${YELLOW}警告:${RESET} ${WHITE}$conf${RESET} 中包含 ${RED}${key}${RESET} 设置，可能与主配置冲突"
        fi
      done
    done
  fi
done

# 验证并应用配置
echo -e "\n${ICON_INFO} ${BOLD}验证配置...${RESET}"
if sshd -t 2>/dev/null; then
  if [ "$has_changes" = true ] && [ $modified_count -gt 0 ]; then
    systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null
    echo -e "\n${ICON_OK} ${BOLD}${GREEN}SSH配置已更新并重新加载${RESET}"
    echo -e "  ${GREEN}修改了 ${BOLD}${modified_count}${RESET}${GREEN} 个配置项${RESET}"
  elif [ "$has_changes" = true ]; then
    echo -e "\n${ICON_INFO} ${BOLD}配置无变化，无需重新加载${RESET}"
  fi
  
  # 列出配置目录文件内容
  echo -e "\n${ICON_FOLDER} ${BOLD}${MAGENTA}配置目录内容:${RESET}"
  for conf_dir in /etc/ssh/ssh_config.d /etc/ssh/sshd_config.d; do
    if [ -d "$conf_dir" ]; then
      echo -e "\n${BOLD}${WHITE}目录:${RESET} ${CYAN}$conf_dir${RESET}"
      if [ "$(ls -A $conf_dir/*.conf 2>/dev/null | wc -l)" -gt 0 ]; then
        for conf_file in $conf_dir/*.conf; do
          if [ -f "$conf_file" ]; then
            echo -e "\n${BOLD}文件:${RESET} ${WHITE}$conf_file${RESET}"
            echo -e "${BLUE}────────────────────────────────────────${RESET}"
            cat "$conf_file" 2>/dev/null || echo -e "${YELLOW}无法读取文件${RESET}"
          fi
        done
      else
        echo -e "  ${WHITE}(无配置文件)${RESET}"
      fi
    fi
  done
  
  # 最终提示
  echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  if [ "$has_conflicts" = true ]; then
    echo -e "${ICON_WARN} ${YELLOW}注意:${RESET} 检测到配置目录中有冲突设置，请检查！"
  fi
  if [ $modified_count -gt 0 ]; then
    echo -e "${ICON_OK} ${GREEN}配置修改摘要:${RESET}"
    for kv in "${kv_pairs[@]}"; do
      key="${kv%% *}"
      if [ "${modified[$key]}" = "1" ]; then
        case $key in
          "PubkeyAuthentication")
            cn_name="密钥认证"
            echo -e "  ${GREEN}✓${RESET} ${cn_name} 已启用"
            ;;
          "PasswordAuthentication")
            cn_name="密码认证"
            echo -e "  ${RED}✓${RESET} ${cn_name} 已禁用"
            ;;
          "PermitRootLogin")
            cn_name="root登录"
            echo -e "  ${YELLOW}✓${RESET} ${cn_name} 已限制为密钥认证"
            ;;
          "PermitEmptyPasswords")
            cn_name="空密码"
            echo -e "  ${RED}✓${RESET} ${cn_name} 已禁止"
            ;;
        esac
      fi
    done
  fi
  echo -e "${ICON_INFO} ${BOLD}重要提醒:${RESET}"
  echo -e "  ${BOLD}•${RESET} 请确保已添加SSH公钥到 ${UNDERLINE}~/.ssh/authorized_keys${RESET}"
  echo -e "  ${BOLD}•${RESET} 建议在断开当前连接前，新开终端测试SSH连接"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
else
  echo -e "\n${ICON_ERROR} ${BOLD}${RED}SSH配置测试失败，已恢复备份！${RESET}"
  cp "$backup_file" "$config_file" 2>/dev/null
  echo -e "${ICON_INFO} ${BOLD}请手动检查:${RESET} ${UNDERLINE}sudo sshd -t${RESET}"
  exit 1
fi
'