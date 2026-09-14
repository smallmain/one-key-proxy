#!/usr/bin/env bash

if [[ ${OKP_PRODUCTION_MODE:-false} == true ]]; then
  PANEL_PATH=/
  MIN_CLIENT_VERSION=1.0.0
  DEFAULT_REALITY_TARGET=www.cloudflare.com:443
else
  : "${PANEL_PATH:=/}"
  : "${MIN_CLIENT_VERSION:=1.0.0}"
  : "${DEFAULT_REALITY_TARGET:=www.cloudflare.com:443}"
fi

# The local SSH launcher sends only this allowlist, using the state file codec.
# Never source the file or accept controls such as PATH/OKP_TEST_MODE from it.
config_load_defaults_file() {
  local file=$1 mode line key encoded value
  local -A defaults=()
  _state_secure_regular_file "$file" || { die '安装默认配置不是安全的普通文件。'; return 1; }
  mode=$(_state_file_attribute "$file" '%a' '%Lp') || return 1
  [[ $mode == 600 ]] || { die '安装默认配置权限必须为 0600。'; return 1; }
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *=* ]] || { die '安装默认配置格式无效。'; return 1; }
    key=${line%%=*}
    encoded=${line#*=}
    case $key in
      OKP_MODE|OKP_PUBLIC_IPV4|OKP_PUBLIC_IPV6|OKP_ENABLE_IPV6|\
      OKP_PANEL_USERNAME|OKP_PANEL_PASSWORD|OKP_NODE_NAME|OKP_REALITY_TARGET|\
      OKP_FQDN|OKP_ALI_ACCESS_KEY_ID|OKP_ALI_ACCESS_KEY_SECRET|OKP_ACME_EMAIL|\
      OKP_PANEL_PORT|OKP_NODE_PORT|OKP_SUB_PORT|OKP_PANEL_MAP|OKP_NODE_MAP|OKP_SUB_MAP) ;;
      *) die '安装默认配置包含不支持的字段。'; return 1 ;;
    esac
    [[ -z ${defaults[$key]+present} ]] || { die '安装默认配置包含重复字段。'; return 1; }
    value=$(_state_decode "$encoded") || { die '安装默认配置编码无效。'; return 1; }
    ! has_control_chars "$value" || { die '安装默认配置不能包含控制字符。'; return 1; }
    [[ $(_state_encode "$value") == "$encoded" ]] || { die '安装默认配置编码无效。'; return 1; }
    defaults[$key]=$value
  done <"$file"
  for key in "${!defaults[@]}"; do
    printf -v "$key" '%s' "${defaults[$key]}"
    case $key in
      *PASSWORD|*ACCESS_KEY*) secret_register "${defaults[$key]}" ;;
    esac
  done
}

detect_public_ipv4() {
  local endpoint candidate
  for endpoint in \
    'https://api.ipify.org' \
    'https://ipv4.icanhazip.com' \
    'https://ifconfig.me/ip'; do
    candidate=$(curl --disable --noproxy '*' --proto '=https' --proto-redir '=https' \
      --tlsv1.2 -4fsS --connect-timeout 4 --max-time 8 "$endpoint" 2>/dev/null || true)
    candidate=$(trim "$candidate")
    if valid_ipv4 "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

detect_public_ipv6() {
  local endpoint candidate
  for endpoint in 'https://api64.ipify.org' 'https://ipv6.icanhazip.com'; do
    candidate=$(curl --disable --noproxy '*' --proto '=https' --proto-redir '=https' \
      --tlsv1.2 -6fsS --connect-timeout 4 --max-time 8 "$endpoint" 2>/dev/null || true)
    candidate=$(trim "$candidate")
    if [[ $candidate == *:* && $candidate != fe80:* && $candidate != fc* && $candidate != fd* ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

probe_reality_target_tls() {
  local target=${1-}
  local host port

  [[ $target =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || return 2
  host=${target%%:*}
  port=${target##*:}
  valid_hostname "$host" && valid_port "$port" || return 2
  have_command curl || return 127

  # Do not use --fail: any HTTP response proves DNS, TCP, and TLS reachability.
  curl --disable --noproxy '*' --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --silent --show-error --connect-timeout 5 --max-time 10 \
    --output /dev/null "https://${target}/"
}

assert_reality_target_tls_reachable() {
  local target=${1-}
  local status

  if probe_reality_target_tls "$target"; then
    return 0
  else
    status=$?
  fi

  if ((status == 2)); then
    die 'REALITY 目标格式无效，必须使用有效的域名:端口。'
  elif ((status == 127)); then
    die '缺少 curl，无法预检 REALITY 目标。'
  else
    die "REALITY 目标 ${target} 无法通过受信任的 HTTPS 连接访问，请更换目标后重试。"
  fi
}

parse_port_map() {
  local value=$1
  local __external=$2
  local __internal=$3
  local parsed_external parsed_internal extra
  IFS=: read -r parsed_external parsed_internal extra <<<"$value"
  [[ -z ${extra:-} && -n $parsed_external && -n $parsed_internal ]] || return 1
  valid_port "$parsed_external" && valid_port "$parsed_internal" || return 1
  printf -v "$__external" '%s' "$parsed_external"
  printf -v "$__internal" '%s' "$parsed_internal"
}

prompt_port_map() {
  local __external=$1
  local __internal=$2
  local label=$3
  local value external internal
  while true; do
    read_tty value "${label}端口映射（外部:内部）" || return 1
    if parse_port_map "$value" external internal; then
      printf -v "$__external" '%s' "$external"
      printf -v "$__internal" '%s' "$internal"
      return 0
    fi
    log_warn '格式无效，请输入类似 56664:2053 的端口映射。'
  done
}

config_generate_defaults() {
  local generated
  MODE=${OKP_MODE:-}
  PUBLIC_IPV4=${OKP_PUBLIC_IPV4:-}
  PUBLIC_IPV6=${OKP_PUBLIC_IPV6:-}
  ENABLE_IPV6=${OKP_ENABLE_IPV6:-false}
  if [[ -n ${OKP_PANEL_USERNAME:-} ]]; then
    PANEL_USERNAME=$OKP_PANEL_USERNAME
  else
    generated=$(random_alnum 8) || return 1
    PANEL_USERNAME="okp_${generated}"
  fi
  if [[ -n ${OKP_PANEL_PASSWORD:-} ]]; then
    PANEL_PASSWORD=$OKP_PANEL_PASSWORD
  else
    generated=$(random_alnum 21) || return 1
    PANEL_PASSWORD="Aa1${generated}"
  fi
  NODE_NAME=${OKP_NODE_NAME:-"$(hostname -s 2>/dev/null || printf 'proxy')-reality"}
  REALITY_TARGET=${OKP_REALITY_TARGET:-$DEFAULT_REALITY_TARGET}
  REALITY_SNI=${REALITY_TARGET%%:*}
  PANEL_EXTERNAL_PORT=''
  PANEL_INTERNAL_PORT=''
  NODE_EXTERNAL_PORT=''
  NODE_INTERNAL_PORT=''
  SUB_EXTERNAL_PORT=''
  SUB_INTERNAL_PORT=''
  FQDN=${OKP_FQDN:-}
  ALI_ACCESS_KEY_ID=${OKP_ALI_ACCESS_KEY_ID:-}
  ALI_ACCESS_KEY_SECRET=${OKP_ALI_ACCESS_KEY_SECRET:-}
  ACME_EMAIL=${OKP_ACME_EMAIL:-}
  PANEL_PATH='/'
  MIN_CLIENT_VERSION='1.0.0'
}

config_choose_mode() {
  local choice
  case ${MODE,,} in
    nat|1) MODE=nat; return 0 ;;
    public|normal|2) MODE=public; return 0 ;;
  esac
  heading '选择 VPS 类型'
  printf '  1. NAT VPS（裸 IP + 自签名证书）\n'
  printf '  2. 普通 VPS（AliDNS + Let\x27s Encrypt）\n'
  while true; do
    read_tty choice '请输入选项' '1' || return 1
    case $choice in
      1) MODE=nat; return 0 ;;
      2) MODE=public; return 0 ;;
      *) log_warn '请输入 1 或 2。' ;;
    esac
  done
}

config_collect_public_ip() {
  local detected=''
  if [[ -z $PUBLIC_IPV4 ]]; then
    log_info '正在探测公网 IPv4...'
    detected=$(detect_public_ipv4 || true)
    PUBLIC_IPV4=$detected
  fi
  while ! valid_ipv4 "$PUBLIC_IPV4"; do
    read_tty PUBLIC_IPV4 '公网 IPv4（无法可靠自动探测，请输入）' || return 1
  done
  log_info "检测到公网 IPv4：${PUBLIC_IPV4}（最终确认页可修改）"
}

config_collect_nat() {
  if [[ -n ${OKP_PANEL_MAP:-} ]]; then
    parse_port_map "$OKP_PANEL_MAP" PANEL_EXTERNAL_PORT PANEL_INTERNAL_PORT || { die 'OKP_PANEL_MAP 格式无效。'; return 1; }
  else
    prompt_port_map PANEL_EXTERNAL_PORT PANEL_INTERNAL_PORT '面板' || return 1
  fi
  if [[ -n ${OKP_NODE_MAP:-} ]]; then
    parse_port_map "$OKP_NODE_MAP" NODE_EXTERNAL_PORT NODE_INTERNAL_PORT || { die 'OKP_NODE_MAP 格式无效。'; return 1; }
  else
    prompt_port_map NODE_EXTERNAL_PORT NODE_INTERNAL_PORT 'VLESS 节点' || return 1
  fi
  if [[ -n ${OKP_SUB_MAP:-} ]]; then
    parse_port_map "$OKP_SUB_MAP" SUB_EXTERNAL_PORT SUB_INTERNAL_PORT || { die 'OKP_SUB_MAP 格式无效。'; return 1; }
  else
    prompt_port_map SUB_EXTERNAL_PORT SUB_INTERNAL_PORT '订阅' || return 1
  fi
  PUBLIC_IPV6=''
  ENABLE_IPV6=false
  FQDN=''
  ALI_ACCESS_KEY_ID=''
  ALI_ACCESS_KEY_SECRET=''
  ACME_EMAIL=''
}

config_collect_public() {
  PANEL_EXTERNAL_PORT=${OKP_PANEL_PORT:-${OKP_PANEL_EXTERNAL_PORT:-2053}}
  PANEL_INTERNAL_PORT=$PANEL_EXTERNAL_PORT
  NODE_EXTERNAL_PORT=${OKP_NODE_PORT:-${OKP_NODE_EXTERNAL_PORT:-443}}
  NODE_INTERNAL_PORT=$NODE_EXTERNAL_PORT
  SUB_EXTERNAL_PORT=${OKP_SUB_PORT:-${OKP_SUB_EXTERNAL_PORT:-2096}}
  SUB_INTERNAL_PORT=$SUB_EXTERNAL_PORT

  while ! valid_hostname "$FQDN"; do
    read_tty FQDN '完整子域名（例如 hk1.example.com）' || return 1
    FQDN=${FQDN,,}
  done
  while [[ -z $ALI_ACCESS_KEY_ID ]]; do
    read_tty ALI_ACCESS_KEY_ID 'AliDNS RAM AccessKey ID' || return 1
  done
  while [[ -z $ALI_ACCESS_KEY_SECRET ]]; do
    read_secret_tty ALI_ACCESS_KEY_SECRET 'AliDNS RAM AccessKey Secret' || return 1
  done
  if [[ -z ${OKP_ACME_EMAIL+x} ]]; then
    read_tty ACME_EMAIL 'ACME 邮箱（可留空）' '' || return 1
  fi

  if [[ -z $PUBLIC_IPV6 ]]; then
    PUBLIC_IPV6=$(detect_public_ipv6 || true)
  fi
  if [[ -n $PUBLIC_IPV6 ]]; then
    if [[ -n ${OKP_ENABLE_IPV6+x} ]]; then
      ENABLE_IPV6=${OKP_ENABLE_IPV6,,}
    else
      log_info "检测到公网 IPv6：${PUBLIC_IPV6}"
      if confirm '是否同时创建 AliDNS AAAA 记录？' n; then
        ENABLE_IPV6=true
      else
        ENABLE_IPV6=false
      fi
    fi
  fi
}

config_collect() {
  config_generate_defaults || return 1
  config_choose_mode || return 1
  config_collect_public_ip || return 1
  if [[ $MODE == nat ]]; then
    config_collect_nat || return 1
  else
    config_collect_public || return 1
  fi
  config_validate
}

config_validate() {
  local ssh_port=''
  [[ $MODE == nat || $MODE == public ]] || { die 'VPS 类型无效。'; return 1; }
  valid_ipv4 "$PUBLIC_IPV4" || { die '公网 IPv4 无效。'; return 1; }
  [[ $PANEL_USERNAME =~ ^[A-Za-z0-9_.-]{3,64}$ ]] || { die '面板用户名只能包含字母、数字、点、下划线和短横线，长度 3-64。'; return 1; }
  ((${#PANEL_PASSWORD} >= 12)) || { die '面板密码至少需要 12 个字符。'; return 1; }
  ! has_control_chars "$PANEL_PASSWORD" || { die '面板密码不能包含控制字符。'; return 1; }
  [[ -n $NODE_NAME && ${#NODE_NAME} -le 80 ]] || { die '节点名称不能为空且不能超过 80 个字符。'; return 1; }
  ! has_control_chars "$NODE_NAME" || { die '节点名称不能包含控制字符。'; return 1; }
  [[ $REALITY_TARGET =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || { die 'REALITY 目标格式应为 域名:端口。'; return 1; }
  REALITY_SNI=${REALITY_TARGET%%:*}
  valid_hostname "$REALITY_SNI" || { die 'REALITY SNI 不是有效域名。'; return 1; }
  valid_port "${REALITY_TARGET##*:}" || { die 'REALITY 目标端口无效。'; return 1; }

  local port
  for port in "$PANEL_EXTERNAL_PORT" "$PANEL_INTERNAL_PORT" "$NODE_EXTERNAL_PORT" "$NODE_INTERNAL_PORT" "$SUB_EXTERNAL_PORT" "$SUB_INTERNAL_PORT"; do
    valid_port "$port" || { die "端口无效：${port}"; return 1; }
  done
  [[ $PANEL_INTERNAL_PORT != "$NODE_INTERNAL_PORT" && $PANEL_INTERNAL_PORT != "$SUB_INTERNAL_PORT" && $NODE_INTERNAL_PORT != "$SUB_INTERNAL_PORT" ]] || { die '三个内部监听端口必须互不相同。'; return 1; }
  [[ $PANEL_EXTERNAL_PORT != "$NODE_EXTERNAL_PORT" && $PANEL_EXTERNAL_PORT != "$SUB_EXTERNAL_PORT" && $NODE_EXTERNAL_PORT != "$SUB_EXTERNAL_PORT" ]] || { die '三个外部 TCP 端口必须互不相同。'; return 1; }

  if [[ -n ${SSH_CONNECTION:-} ]]; then
    ssh_port=$(awk '{print $4}' <<<"$SSH_CONNECTION")
    if [[ -n $ssh_port && ( $PANEL_INTERNAL_PORT == "$ssh_port" || $NODE_INTERNAL_PORT == "$ssh_port" || $SUB_INTERNAL_PORT == "$ssh_port" ) ]]; then
      die "内部监听端口不能占用当前 SSH 端口 ${ssh_port}。"
      return 1
    fi
  fi

  if [[ $MODE == public ]]; then
    valid_hostname "$FQDN" || { die '完整子域名无效。'; return 1; }
    [[ -n $ALI_ACCESS_KEY_ID && -n $ALI_ACCESS_KEY_SECRET ]] || { die '普通 VPS 模式需要 AliDNS RAM AccessKey。'; return 1; }
    if has_control_chars "$ALI_ACCESS_KEY_ID" || has_control_chars "$ALI_ACCESS_KEY_SECRET"; then
      die 'AliDNS AccessKey 不能包含控制字符。'
      return 1
    fi
    [[ $PANEL_EXTERNAL_PORT == "$PANEL_INTERNAL_PORT" && $NODE_EXTERNAL_PORT == "$NODE_INTERNAL_PORT" && $SUB_EXTERNAL_PORT == "$SUB_INTERNAL_PORT" ]] || { die '普通 VPS 的外部端口与内部监听端口必须保持 1:1。'; return 1; }
    [[ $ENABLE_IPV6 == true || $ENABLE_IPV6 == false ]] || { die 'IPv6 开关必须是 true 或 false。'; return 1; }
    if [[ $ENABLE_IPV6 == true ]]; then
      valid_global_ipv6 "$PUBLIC_IPV6" || { die '启用 AAAA 时必须提供有效的全局 IPv6 地址。'; return 1; }
    fi
    [[ -z $ACME_EMAIL || $ACME_EMAIL =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { die 'ACME 邮箱格式无效。'; return 1; }
  fi
}

config_summary() {
  local host panel_url sub_url
  if [[ $MODE == nat ]]; then
    host=$PUBLIC_IPV4
  else
    host=$FQDN
  fi
  panel_url="https://${host}:${PANEL_EXTERNAL_PORT}/"
  sub_url="https://${host}:${SUB_EXTERNAL_PORT}/sub/<自动生成>"

  heading '最终配置预览'
  printf '  VPS 类型          : %s\n' "$MODE"
  printf '  公网 IPv4         : %s\n' "$PUBLIC_IPV4"
  if [[ $MODE == public ]]; then
    printf '  公网 IPv6         : %s\n' "${PUBLIC_IPV6:-未启用}"
    printf '  完整子域名        : %s\n' "$FQDN"
    printf '  AliDNS AccessKey  : %s\n' "$(mask_secret "$ALI_ACCESS_KEY_ID")"
    printf '  AliDNS Secret     : %s\n' "$(mask_secret_tail "$ALI_ACCESS_KEY_SECRET")"
    printf '  ACME 邮箱         : %s\n' "${ACME_EMAIL:-未设置}"
  else
    printf '  TLS               : RSA-2048 自签名（10 年，仅 HTTPS）\n'
    printf '  自签名风险        : 客户端跳过验证时，订阅与面板不能抵御中间人替换\n'
  fi
  printf '  面板用户名        : %s\n' "$PANEL_USERNAME"
  printf '  面板密码          : %s\n' "$(mask_secret_tail "$PANEL_PASSWORD")"
  printf '  面板路径          : /\n'
  printf '  面板端口          : %s -> %s\n' "$PANEL_EXTERNAL_PORT" "$PANEL_INTERNAL_PORT"
  printf '  VLESS 端口        : %s -> %s\n' "$NODE_EXTERNAL_PORT" "$NODE_INTERNAL_PORT"
  printf '  订阅端口          : %s -> %s\n' "$SUB_EXTERNAL_PORT" "$SUB_INTERNAL_PORT"
  printf '  节点名称          : %s\n' "$NODE_NAME"
  printf '  REALITY 目标      : %s\n' "$REALITY_TARGET"
  printf '  最低 Xray 版本    : %s\n' "$MIN_CLIENT_VERSION"
  printf '  面板地址          : %s\n' "$panel_url"
  printf '  订阅地址          : %s\n' "$sub_url"
  printf '  Fail2ban          : 支持时启用\n'
  if [[ ${PLATFORM_FAMILY:-} == rhel && ${PLATFORM_OS_ID:-} != fedora ]]; then
    printf '  软件源副作用      : 默认仓库缺少 Fail2ban 时会尝试启用 EPEL\n'
  fi
  printf '  自动 DDNS         : 不启用\n'
  printf '  所需协议          : TCP only\n'
}

config_modify() {
  local choice value new_secret
  while true; do
    config_summary
    printf '\n可修改项目：\n'
    printf '  1. 公网 IPv4\n  2. 面板用户名\n  3. 面板密码\n'
    printf '  4. 面板端口映射\n  5. VLESS 端口映射\n  6. 订阅端口映射\n'
    printf '  7. 节点名称\n  8. REALITY 目标\n'
    if [[ $MODE == public ]]; then
      printf '  9. 子域名\n 10. AliDNS AccessKey\n 11. ACME 邮箱/IPv6\n'
    fi
    printf '  0. 修改完成\n'
    read_tty choice '选择' '0' || return 1
    case $choice in
      0)
        if config_validate; then
          return 0
        fi
        ;;
      1) read_tty PUBLIC_IPV4 '公网 IPv4' "$PUBLIC_IPV4" || return 1 ;;
      2) read_tty PANEL_USERNAME '面板用户名' "$PANEL_USERNAME" || return 1 ;;
      3)
        read_secret_tty new_secret '新面板密码（至少 12 位）' || return 1
        [[ -n $new_secret ]] && PANEL_PASSWORD=$new_secret
        ;;
      4)
        if [[ $MODE == public ]]; then
          read_tty value '面板 TCP 端口' "$PANEL_EXTERNAL_PORT" || return 1
          if valid_port "$value"; then PANEL_EXTERNAL_PORT=$value; PANEL_INTERNAL_PORT=$value; else log_warn '端口无效。'; fi
        else
          prompt_port_map PANEL_EXTERNAL_PORT PANEL_INTERNAL_PORT '面板' || return 1
        fi
        ;;
      5)
        if [[ $MODE == public ]]; then
          read_tty value 'VLESS TCP 端口' "$NODE_EXTERNAL_PORT" || return 1
          if valid_port "$value"; then NODE_EXTERNAL_PORT=$value; NODE_INTERNAL_PORT=$value; else log_warn '端口无效。'; fi
        else
          prompt_port_map NODE_EXTERNAL_PORT NODE_INTERNAL_PORT 'VLESS 节点' || return 1
        fi
        ;;
      6)
        if [[ $MODE == public ]]; then
          read_tty value '订阅 TCP 端口' "$SUB_EXTERNAL_PORT" || return 1
          if valid_port "$value"; then SUB_EXTERNAL_PORT=$value; SUB_INTERNAL_PORT=$value; else log_warn '端口无效。'; fi
        else
          prompt_port_map SUB_EXTERNAL_PORT SUB_INTERNAL_PORT '订阅' || return 1
        fi
        ;;
      7) read_tty NODE_NAME '节点名称' "$NODE_NAME" || return 1 ;;
      8) read_tty REALITY_TARGET 'REALITY 目标' "$REALITY_TARGET" || return 1 ;;
      9)
        [[ $MODE == public ]] || { log_warn 'NAT 模式没有域名设置。'; continue; }
        read_tty FQDN '完整子域名' "$FQDN" || return 1
        FQDN=${FQDN,,}
        ;;
      10)
        [[ $MODE == public ]] || { log_warn 'NAT 模式没有 AliDNS 设置。'; continue; }
        read_tty ALI_ACCESS_KEY_ID 'AliDNS RAM AccessKey ID' "$ALI_ACCESS_KEY_ID" || return 1
        read_secret_tty new_secret 'AliDNS RAM AccessKey Secret（留空保留）' || return 1
        [[ -n $new_secret ]] && ALI_ACCESS_KEY_SECRET=$new_secret
        ;;
      11)
        [[ $MODE == public ]] || { log_warn 'NAT 模式没有 ACME/IPv6 设置。'; continue; }
        read_tty ACME_EMAIL 'ACME 邮箱（可留空）' "$ACME_EMAIL" || return 1
        read_tty PUBLIC_IPV6 '公网 IPv6（可留空）' "$PUBLIC_IPV6" || return 1
        if [[ -n $PUBLIC_IPV6 ]]; then ENABLE_IPV6=true; else ENABLE_IPV6=false; fi
        ;;
      *) log_warn '未知选项。' ;;
    esac
  done
}

config_confirm() {
  local choice
  while true; do
    config_summary
    printf '\n  I. 开始安装\n  M. 修改参数\n  Q. 退出（不做任何修改）\n'
    read_tty choice '请选择' 'I' || return 1
    case ${choice^^} in
      I)
        if config_validate; then
          confirm '确认按以上配置执行？' y && return 0
        fi
        ;;
      M) config_modify || return 1 ;;
      Q) return 2 ;;
      *) log_warn '请输入 I、M 或 Q。' ;;
    esac
  done
}

config_save_state() {
  local key
  local -a updates=()
  for key in \
    MODE PUBLIC_IPV4 PUBLIC_IPV6 ENABLE_IPV6 PANEL_USERNAME PANEL_PASSWORD PANEL_PATH \
    PANEL_EXTERNAL_PORT PANEL_INTERNAL_PORT NODE_EXTERNAL_PORT NODE_INTERNAL_PORT \
    SUB_EXTERNAL_PORT SUB_INTERNAL_PORT NODE_NAME REALITY_TARGET REALITY_SNI \
    MIN_CLIENT_VERSION FQDN ALI_ACCESS_KEY_ID ALI_ACCESS_KEY_SECRET ACME_EMAIL; do
    updates+=("$key" "${!key-}")
  done
  state_set_many "${updates[@]}"
}

config_load_state() {
  local key
  for key in \
    MODE PUBLIC_IPV4 PUBLIC_IPV6 ENABLE_IPV6 PANEL_USERNAME PANEL_PASSWORD PANEL_PATH \
    PANEL_EXTERNAL_PORT PANEL_INTERNAL_PORT NODE_EXTERNAL_PORT NODE_INTERNAL_PORT \
    SUB_EXTERNAL_PORT SUB_INTERNAL_PORT NODE_NAME REALITY_TARGET REALITY_SNI \
    MIN_CLIENT_VERSION FQDN ALI_ACCESS_KEY_ID ALI_ACCESS_KEY_SECRET ACME_EMAIL; do
    printf -v "$key" '%s' "$(state_get "$key" 2>/dev/null || true)"
  done
  PANEL_PATH=${PANEL_PATH:-/}
  MIN_CLIENT_VERSION=${MIN_CLIENT_VERSION:-1.0.0}
  config_validate
}
