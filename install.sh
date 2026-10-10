#!/usr/bin/env bash

set -Euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset OKP_TEST_MODE OKP_INTERNAL_TEST_HARNESS
OKP_PRODUCTION_MODE=true
export OKP_PRODUCTION_MODE

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_VERSION=$(tr -d '[:space:]' <"${SCRIPT_DIR}/VERSION" 2>/dev/null || printf 'development')
PROJECT_COMMIT=${ONE_KEY_PROXY_SOURCE_COMMIT:-${ONE_KEY_PROXY_COMMIT:-development}}
PROJECT_REPOSITORY=${ONE_KEY_PROXY_SOURCE_REPO:-smallmain/one-key-proxy}
readonly RUNTIME_DIR=/usr/local/lib/one-key-proxy
readonly OFFICIAL_REPO=MHSanaei/3x-ui
readonly OFFICIAL_INSTALL_URL=https://raw.githubusercontent.com/MHSanaei/3x-ui
readonly OPERATION_LOCK_FILE=/run/one-key-proxy/operation.lock

for library in common state platform config alidns cert 3xui fail2ban; do
  if [[ ! -r ${SCRIPT_DIR}/lib/${library}.sh ]]; then
    printf 'ERROR: 缺少函数库 %s。请通过 bootstrap.sh 运行完整项目。\n' "$library" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/lib/${library}.sh"
done

INSTALL_ACTION=${1-}
declare -a INSTALL_TEMP_PATHS=()
XUI_INSTALL_GUARD_ACTIVE=false
XUI_INSTALL_TRANSACTION_PRESENT=false
XUI_INSTALL_CHILD_PID=''
XUI_INSTALL_PENDING_SIGNAL=''
XUI_INSTALL_SUPERVISION_ARMED=false
XUI_INSTALL_SAVED_HUP_TRAP=''
XUI_INSTALL_SAVED_INT_TRAP=''
XUI_INSTALL_SAVED_TERM_TRAP=''
XUI_INSTALL_SAVED_EXIT_TRAP=''
XUI_INSTALL_CHILD_PID=''
XUI_INSTALL_CHILD_PGID=''
XUI_INSTALL_CHILD_MARKER=''

install_temp_register() {
  INSTALL_TEMP_PATHS+=("$1")
}

install_cleanup() {
  local path
  trap '' HUP INT TERM
  trap - EXIT
  if declare -F install_settle_xui_process_group >/dev/null 2>&1; then
    install_settle_xui_process_group
  fi
  if declare -F install_settle_partial_xui_install >/dev/null 2>&1; then
    install_settle_partial_xui_install
  fi
  for path in "${INSTALL_TEMP_PATHS[@]}"; do
    case $path in
      /tmp/*|/var/tmp/*|${TMPDIR:-/tmp}/*)
        if [[ -d $path && ! -L $path ]]; then
          rm -rf -- "$path" 2>/dev/null || true
        else
          rm -f -- "$path" 2>/dev/null || true
        fi
        ;;
    esac
  done
}

trap install_cleanup EXIT

install_handle_signal() {
  local signal=$1 status=1
  case $signal in
    HUP) status=129 ;;
    INT) status=130 ;;
    TERM) status=143 ;;
  esac
  trap '' HUP INT TERM
  if declare -F install_settle_xui_process_group >/dev/null 2>&1; then
    install_settle_xui_process_group
  fi
  if declare -F install_settle_partial_xui_install >/dev/null 2>&1; then
    install_settle_partial_xui_install
  fi
  exit "$status"
}

trap 'install_handle_signal HUP' HUP
trap 'install_handle_signal INT' INT
trap 'install_handle_signal TERM' TERM

install_xui_signal_status() {
  case $1 in
    HUP) printf '129' ;;
    INT) printf '130' ;;
    TERM) printf '143' ;;
    *) printf '1' ;;
  esac
}

install_record_xui_signal() {
  local signal=$1
  [[ -n $XUI_INSTALL_PENDING_SIGNAL ]] || XUI_INSTALL_PENDING_SIGNAL=$signal
  if [[ -n $XUI_INSTALL_CHILD_PID ]]; then
    kill -TERM -- "-${XUI_INSTALL_CHILD_PID}" 2>/dev/null || true
  fi
}

install_xui_proc_group_has_live_member() {
  local pgid=$1 stat_file line rest state pgrp
  local scanned=false matched=false
  [[ $pgid =~ ^[1-9][0-9]*$ && -d /proc ]] || return 2
  for stat_file in /proc/[0-9]*/stat; do
    [[ -r $stat_file ]] || continue
    IFS= read -r line <"$stat_file" || continue
    scanned=true
    [[ $line == *') '* ]] || continue
    rest=${line##*) }
    read -r state _ pgrp _ <<<"$rest" || continue
    [[ $pgrp == "$pgid" ]] || continue
    matched=true
    case $state in
      Z|X|x) ;;
      *) return 0 ;;
    esac
  done
  [[ $scanned == true ]] || return 2
  [[ $matched == true ]] && return 1
  return 1
}

install_xui_group_has_live_member() {
  local pid=$XUI_INSTALL_CHILD_PID
  [[ -n $pid && $pid =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 -- "-$pid" 2>/dev/null || return 1
  if [[ -d /proc ]]; then
    install_xui_proc_group_has_live_member "$pid"
    return $?
  fi
  return 0
}

install_terminate_xui_group() {
  local attempt status=0 pid=$XUI_INSTALL_CHILD_PID
  [[ -n $pid && $pid =~ ^[1-9][0-9]*$ ]] || return 0
  kill -TERM -- "-$pid" 2>/dev/null || true
  for ((attempt = 0; attempt < 50; attempt++)); do
    if install_xui_group_has_live_member; then
      status=0
    else
      status=$?
      ((status == 1)) && break
    fi
    sleep 0.1
  done
  if ((status != 1)); then
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  for ((attempt = 0; attempt < 100; attempt++)); do
    if install_xui_group_has_live_member; then
      status=0
    else
      status=$?
      ((status == 1)) && break
    fi
    sleep 0.1
  done
  if ((status != 1)); then
    log_error "无法确认 3x-ui 安装器进程组 ${pid} 已停止；操作锁仍不得释放。"
    return 1
  fi
  XUI_INSTALL_CHILD_PID=''
}

install_settle_xui_process_group() {
  if [[ ${XUI_INSTALL_SUPERVISION_ARMED:-false} != true &&
      -z ${XUI_INSTALL_CHILD_PID:-} ]]; then
    return 0
  fi
  while ! install_terminate_xui_group; do
    log_error '3x-ui 安装器进程尚未安全收敛；继续持有操作锁并重试。'
    sleep 1 || true
  done
}

install_settle_partial_xui_install() {
  while [[ ${XUI_INSTALL_GUARD_ACTIVE:-false} == true ]]; do
    if secure_partial_xui_after_failed_install; then
      return 0
    fi
    log_error '部分安装尚未限制到回环或确认停止且禁用自启；继续持有操作锁并重试。'
    sleep 1 || true
  done
}

install_restore_saved_trap() {
  local signal=$1 saved=$2
  trap - "$signal"
  if [[ -n $saved ]]; then
    # trap -p produces shell-owned text; no network or state input reaches eval.
    # shellcheck disable=SC2294
    eval "$saved"
  fi
}

install_restore_xui_traps() {
  install_restore_saved_trap HUP "$XUI_INSTALL_SAVED_HUP_TRAP"
  install_restore_saved_trap INT "$XUI_INSTALL_SAVED_INT_TRAP"
  install_restore_saved_trap TERM "$XUI_INSTALL_SAVED_TERM_TRAP"
  install_restore_saved_trap EXIT "$XUI_INSTALL_SAVED_EXIT_TRAP"
}

install_xui_exit_guard() {
  local status=${1:-1}
  trap '' HUP INT TERM
  trap - EXIT
  install_settle_xui_process_group
  install_settle_partial_xui_install
  XUI_INSTALL_SUPERVISION_ARMED=false
  install_cleanup
  exit "$status"
}

run_supervised_xui_installer() {
  [[ $# -eq 4 ]] || return 2
  local installer=$1 tag=$2 pinned_path=$3 output=$4
  local child_status=0 signal_status monitor_was_enabled=false

  XUI_INSTALL_SAVED_HUP_TRAP=$(trap -p HUP)
  XUI_INSTALL_SAVED_INT_TRAP=$(trap -p INT)
  XUI_INSTALL_SAVED_TERM_TRAP=$(trap -p TERM)
  XUI_INSTALL_SAVED_EXIT_TRAP=$(trap -p EXIT)
  XUI_INSTALL_CHILD_PID=''
  XUI_INSTALL_PENDING_SIGNAL=''
  XUI_INSTALL_SUPERVISION_ARMED=true
  trap 'install_record_xui_signal HUP' HUP
  trap 'install_record_xui_signal INT' INT
  trap 'install_record_xui_signal TERM' TERM
  trap 'install_xui_exit_guard $?' EXIT

  [[ $- == *m* ]] && monitor_was_enabled=true
  set -m
  (
    umask 022
    exec env -i \
      PATH="$pinned_path" HOME=/root LANG=C.UTF-8 \
      XUI_NONINTERACTIVE=1 \
      XUI_USERNAME="$PANEL_USERNAME" \
      XUI_PASSWORD="$PANEL_PASSWORD" \
      XUI_PANEL_PORT="$PANEL_INTERNAL_PORT" \
      XUI_WEB_BASE_PATH='/' \
      XUI_SSL_MODE=none \
      XUI_SERVER_IP="$PUBLIC_IPV4" \
      XUI_DB_TYPE=sqlite \
      XUI_ENABLE_FAIL2BAN=false \
      bash "$installer" "$tag"
  ) </dev/null >"$output" 2>&1 &
  XUI_INSTALL_CHILD_PID=$!
  if [[ -n $XUI_INSTALL_PENDING_SIGNAL ]]; then
    kill -TERM -- "-${XUI_INSTALL_CHILD_PID}" 2>/dev/null || true
  fi
  [[ $monitor_was_enabled == true ]] || set +m

  if wait "$XUI_INSTALL_CHILD_PID"; then
    child_status=0
  else
    child_status=$?
  fi
  while ! install_terminate_xui_group; do
    log_error '3x-ui 安装器仍有可执行子进程；继续持有操作锁并重试终止。'
    sleep 1 || true
  done
  XUI_INSTALL_SUPERVISION_ARMED=false
  install_restore_xui_traps
  if [[ -n $XUI_INSTALL_PENDING_SIGNAL ]]; then
    signal_status=$(install_xui_signal_status "$XUI_INSTALL_PENDING_SIGNAL") || signal_status=1
    child_status=$signal_status
  fi
  return "$child_status"
}

secure_curl() {
  curl --disable --noproxy '*' --proto '=https' --proto-redir '=https' --tlsv1.2 "$@"
}

acquire_operation_lock() {
  local attempt lock_dir owner mode links
  if [[ -n ${OKP_OPERATION_LOCK_FD:-} ]] && flock -n "$OKP_OPERATION_LOCK_FD"; then
    return 0
  fi
  lock_dir=${OPERATION_LOCK_FILE%/*}
  if [[ -L $lock_dir || ( -e $lock_dir && ! -d $lock_dir ) ]]; then
    log_error '操作锁目录类型不安全。'
    return 1
  fi
  install -d -m 0700 -- "$lock_dir" || return 1
  chown 0:0 -- "$lock_dir" || return 1
  chmod 0700 -- "$lock_dir" || return 1
  owner=$(stat -c '%u' -- "$lock_dir" 2>/dev/null) || return 1
  mode=$(stat -c '%a' -- "$lock_dir" 2>/dev/null) || return 1
  [[ ! -L $lock_dir && -d $lock_dir && $owner == 0 && $mode == 700 ]] || return 1
  if [[ -L $OPERATION_LOCK_FILE || ( -e $OPERATION_LOCK_FILE && ! -f $OPERATION_LOCK_FILE ) ]]; then
    log_error '操作锁文件类型不安全。'
    return 1
  fi
  exec {OKP_OPERATION_LOCK_FD}>"$OPERATION_LOCK_FILE" || return 1
  [[ -f $OPERATION_LOCK_FILE && ! -L $OPERATION_LOCK_FILE ]] || return 1
  chmod 0600 -- "$OPERATION_LOCK_FILE" || return 1
  chown 0:0 -- "$OPERATION_LOCK_FILE" || return 1
  owner=$(stat -c '%u' -- "$OPERATION_LOCK_FILE" 2>/dev/null) || return 1
  mode=$(stat -c '%a' -- "$OPERATION_LOCK_FILE" 2>/dev/null) || return 1
  links=$(stat -c '%h' -- "$OPERATION_LOCK_FILE" 2>/dev/null) || return 1
  [[ $owner == 0 && $mode == 600 && $links == 1 ]] || return 1
  for ((attempt = 1; attempt <= 30; attempt++)); do
    flock -n "$OKP_OPERATION_LOCK_FD" && return 0
    sleep 1
  done
  log_error '另一个 one-key-proxy 安装或维护操作正在运行。'
  return 1
}

usage() {
  cat <<'EOF'
用法: install.sh [--resume | --defaults-file FILE]

请优先使用仓库 README 中的 bootstrap.sh 一键命令。
EOF
}

require_tty() {
  [[ -r /dev/tty && -w /dev/tty ]] || die '安装器需要可交互的 /dev/tty。'
}

foreign_xui_exists() {
  command -v x-ui >/dev/null 2>&1 ||
    [[ -e /etc/x-ui/x-ui.db || -L /etc/x-ui/x-ui.db ||
      -e /etc/x-ui/install-result.env || -L /etc/x-ui/install-result.env ||
      -e /usr/local/x-ui || -L /usr/local/x-ui ||
      -e /usr/bin/x-ui || -L /usr/bin/x-ui ||
      -e /etc/systemd/system/x-ui.service || -L /etc/systemd/system/x-ui.service ||
      -e /etc/init.d/x-ui || -L /etc/init.d/x-ui ]]
}

state_is_managed() {
  local installation_id
  [[ -r $STATE_FILE ]] || return 1
  [[ $(state_get MANAGED_BY 2>/dev/null || true) == one-key-proxy ]] || return 1
  installation_id=$(state_get INSTALLATION_ID 2>/dev/null || true)
  [[ $installation_id =~ ^[0-9a-fA-F]{32}$ ]] || return 1
  stage_is_done configured || return 1
}

register_known_secrets() {
  local key value
  for key in PANEL_PASSWORD ALI_ACCESS_KEY_SECRET XUI_API_TOKEN; do
    value=$(state_get "$key" 2>/dev/null || true)
    [[ -n $value ]] && secret_register "$value"
  done
}

generate_uuid() {
  local raw
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    IFS= read -r raw </proc/sys/kernel/random/uuid
  elif have_command uuidgen; then
    raw=$(uuidgen)
  else
    raw=$(random_hex 16)
    raw="${raw:0:8}-${raw:8:4}-${raw:12:4}-${raw:16:4}-${raw:20:12}"
  fi
  [[ $raw =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || return 1
  printf '%s' "${raw,,}"
}

install_runtime_files() {
  local temporary old_runtime path owner mode unsafe_entry link_count
  [[ $RUNTIME_DIR == /usr/local/lib/one-key-proxy ]] || {
    log_error '运行目录安全校验失败。'
    return 1
  }
  install -d -m 0755 -- /usr/local /usr/local/lib /usr/local/bin || return 1
  for path in /usr /usr/local /usr/local/lib /usr/local/bin; do
    [[ -d $path && ! -L $path ]] || {
      log_error "运行路径包含非预期目录或符号链接：${path}"
      return 1
    }
    owner=$(stat -c '%u' -- "$path" 2>/dev/null) || return 1
    mode=$(stat -c '%a' -- "$path" 2>/dev/null) || return 1
    [[ $owner == 0 && $mode =~ ^[0-7]{3,4}$ && $(((8#$mode) & 0022)) -eq 0 ]] || {
      log_error "运行路径必须由 root 所有且不得被组/其他用户写入：${path}"
      return 1
    }
  done
  if [[ -e $RUNTIME_DIR || -L $RUNTIME_DIR ]]; then
    [[ -d $RUNTIME_DIR && ! -L $RUNTIME_DIR ]] || {
      log_error '现有运行目录不是安全的常规目录。'
      return 1
    }
    owner=$(stat -c '%u' -- "$RUNTIME_DIR" 2>/dev/null) || return 1
    [[ $owner == 0 ]] || {
      log_error '现有运行目录不属于 root，拒绝覆盖。'
      return 1
    }
  fi
  if [[ -e /usr/local/bin/one-key-proxy || -L /usr/local/bin/one-key-proxy ]]; then
    [[ -f /usr/local/bin/one-key-proxy && ! -L /usr/local/bin/one-key-proxy ]] || {
      log_error '现有命令路径不是安全的常规文件。'
      return 1
    }
  fi

  temporary=$(mktemp -d "${RUNTIME_DIR}.new.XXXXXX") || return 1
  old_runtime=$(mktemp -d "${RUNTIME_DIR}.old.XXXXXX") || {
    rmdir -- "$temporary" 2>/dev/null || true
    return 1
  }
  rmdir -- "$old_runtime" || {
    rmdir -- "$temporary" 2>/dev/null || true
    return 1
  }
  if ! tar -C "$SCRIPT_DIR" \
    --exclude='.git' --exclude='.env' --exclude='.env.*' --exclude='.deploy-state' \
    --exclude='__pycache__' --exclude='work' --exclude='*.tmp' \
    -cf - . | tar -C "$temporary" --no-same-owner -xf -; then
    rm -rf -- "$temporary"
    return 1
  fi
  unsafe_entry=$(find "$temporary" \( -type l -o ! -type d ! -type f \) -print -quit) || {
    rm -rf -- "$temporary"
    return 1
  }
  if [[ -n $unsafe_entry ]]; then
    log_error "运行文件包含不允许的文件类型：${unsafe_entry}"
    rm -rf -- "$temporary"
    return 1
  fi
  unsafe_entry=''
  while IFS= read -r -d '' path; do
    link_count=$(stat -c '%h' -- "$path" 2>/dev/null) || {
      rm -rf -- "$temporary"
      return 1
    }
    if [[ $link_count != 1 ]]; then
      unsafe_entry=$path
      break
    fi
  done < <(find "$temporary" -type f -print0)
  if [[ -n $unsafe_entry ]]; then
    log_error "运行文件包含不允许的硬链接：${unsafe_entry}"
    rm -rf -- "$temporary"
    return 1
  fi
  chown -R root:root -- "$temporary" || {
    rm -rf -- "$temporary"
    return 1
  }
  find "$temporary" -type d -exec chmod 0755 {} + || return 1
  find "$temporary" -type f -exec chmod 0644 {} + || return 1
  find "$temporary" -type f -name '*.sh' -exec chmod 0755 {} + || return 1
  chmod 0755 "$temporary/one-key-proxy" "$temporary/bootstrap.sh" 2>/dev/null || true
  if [[ -d $RUNTIME_DIR ]]; then
    mv -- "$RUNTIME_DIR" "$old_runtime" || return 1
  fi
  if ! mv -- "$temporary" "$RUNTIME_DIR"; then
    [[ -d $old_runtime ]] && mv -- "$old_runtime" "$RUNTIME_DIR"
    return 1
  fi
  rm -rf -- "$old_runtime" || return 1
  install -m 0755 -- "$RUNTIME_DIR/one-key-proxy" /usr/local/bin/one-key-proxy || return 1
  state_set RUNTIME_DIR "$RUNTIME_DIR" || return 1
  state_set PROJECT_VERSION "$PROJECT_VERSION" || return 1
  state_set PROJECT_COMMIT "$PROJECT_COMMIT" || return 1
  state_set PROJECT_REPOSITORY "$PROJECT_REPOSITORY" || return 1
}

stage_dependencies() {
  platform_install_dependencies || return 1
  platform_install_optional_qrencode || true
}

resolve_latest_release() {
  local release commit_document tag commit
  release=$(secure_curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
    "https://api.github.com/repos/${OFFICIAL_REPO}/releases/latest") || return 1
  tag=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name |
    select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' <<<"$release") || return 1
  commit_document=$(secure_curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
    "https://api.github.com/repos/${OFFICIAL_REPO}/commits/${tag}") || return 1
  commit=$(jq -er '.sha | select(test("^[0-9a-f]{40}$"))' <<<"$commit_document") || return 1
  okp_xui_release_asset_from_json "$OFFICIAL_REPO" "$tag" "$PLATFORM_ARCH" "$release" || return 1
  XUI_RELEASE_TAG=$tag
  XUI_RELEASE_COMMIT=$commit
  XUI_RELEASE_ASSET_SHA256=$OKP_XUI_RELEASE_ASSET_SHA256
}

stage_compatibility() {
  local tag commit asset_sha256 spec_file url required
  resolve_latest_release || {
    log_error '无法查询 3x-ui 最新稳定版本。'
    return 1
  }
  tag=$XUI_RELEASE_TAG
  commit=$XUI_RELEASE_COMMIT
  asset_sha256=$XUI_RELEASE_ASSET_SHA256
  spec_file=$(mktemp)
  install_temp_register "$spec_file"
  chmod 600 "$spec_file"
  url="https://raw.githubusercontent.com/${OFFICIAL_REPO}/${commit}/frontend/public/openapi.json"
  if ! secure_curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 "$url" -o "$spec_file"; then
    url="https://raw.githubusercontent.com/${OFFICIAL_REPO}/${commit}/docs/public/openapi.json"
    secure_curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 "$url" -o "$spec_file" || {
      rm -f "$spec_file"
      log_error "无法读取 ${tag} 的官方 OpenAPI，拒绝盲目安装。"
      return 1
    }
  fi
  for required in \
    '/panel/api/inbounds/add' \
    '/panel/api/hosts/add' \
    '/panel/api/setting/update' \
    '/panel/api/setting/apiTokens' \
    '/panel/api/setting/apiTokens/create' \
    '/panel/api/setting/apiTokens/delete/{id}' \
    '/panel/api/server/status' \
    '/panel/api/server/getConfigJson' \
    '/panel/api/server/getNewX25519Cert' \
    '/panel/api/clients/subLinks/{subId}'; do
    if ! jq -e --arg path "$required" '.paths[$path] != null' "$spec_file" >/dev/null; then
      rm -f "$spec_file"
      log_error "最新稳定版 ${tag} 缺少必要 API：${required}。"
      return 1
    fi
  done
  jq -e '.paths["/panel/api/hosts/byInbound/{inboundId}"] != null' "$spec_file" >/dev/null || {
    rm -f "$spec_file"
    log_error "最新稳定版 ${tag} 缺少 Hosts 查询 API。"
    return 1
  }
  jq -e '(.paths["/panel/api/hosts/update/{id}"] //
          .paths["/panel/api/hosts/update/{groupId}"]) != null' "$spec_file" >/dev/null || {
    rm -f "$spec_file"
    log_error "最新稳定版 ${tag} 缺少 Hosts 更新 API。"
    return 1
  }
  rm -f "$spec_file"
  state_set_many XUI_VERSION "$tag" XUI_RELEASE_COMMIT "$commit" \
    XUI_RELEASE_ASSET_SHA256 "$asset_sha256" || return 1
  log_info "将安装 3x-ui 最新稳定版 ${tag}。"
}

assert_install_ports_available() {
  local port label
  while IFS=: read -r label port; do
    if ! platform_port_is_available "$port" tcp; then
      log_error "${label}内部端口 ${port}/tcp 已被占用。"
      return 1
    fi
  done <<EOF
面板:${PANEL_INTERNAL_PORT}
VLESS:${NODE_INTERNAL_PORT}
订阅:${SUB_INTERNAL_PORT}
EOF
}

stage_preflight() {
  assert_install_ports_available || return 1
  assert_reality_target_tls_reachable "$REALITY_TARGET" || return 1
}

read_official_install_value() {
  local key=$1 raw
  [[ $key =~ ^[A-Z0-9_]+$ && -r /etc/x-ui/install-result.env ]] || return 1
  raw=$(sed -n "s/^${key}=//p" /etc/x-ui/install-result.env | tail -n 1)
  raw=${raw#\'}
  raw=${raw%\'}
  raw=${raw#\"}
  raw=${raw%\"}
  printf '%s' "$raw"
}

install_serialized_value_matches_file() {
  local file=$1 key=$2 expected=$3 raw count canonical_c canonical_utf8=''
  [[ $key =~ ^[A-Z0-9_]+$ && -f $file && ! -L $file ]] || return 1
  count=$(awk -v prefix="${key}=" 'index($0, prefix) == 1 { count++ } END { print count + 0 }' \
    "$file") || return 1
  [[ $count == 1 ]] || return 1
  raw=$(sed -n "s/^${key}=//p" "$file") || return 1
  canonical_c=$(LC_ALL=C printf '%q' "$expected") || return 1
  canonical_utf8=$(LC_ALL=C.UTF-8 printf '%q' "$expected" 2>/dev/null || true)
  [[ $raw == "$canonical_c" || ( -n $canonical_utf8 && $raw == "$canonical_utf8" ) ]]
}

official_install_serialized_value_matches() {
  install_serialized_value_matches_file /etc/x-ui/install-result.env "$1" "$2"
}

xui_install_transition_read() {
  local marker status
  if marker=$(state_get XUI_INSTALL_RECOVERY_STATUS 2>/dev/null); then
    [[ $marker == installing ]] || {
      log_error '3x-ui 首次安装恢复事务状态无效。'
      return 2
    }
    return 0
  else
    status=$?
  fi
  ((status == 1)) && return 1
  log_error '无法安全读取 3x-ui 首次安装恢复事务。'
  return 2
}

xui_install_result_identity_matches() {
  local installed_port installed_user installed_path
  installed_port=$(read_official_install_value XUI_PANEL_PORT || true)
  installed_user=$(read_official_install_value XUI_USERNAME || true)
  installed_path=$(read_official_install_value XUI_WEB_BASE_PATH || true)
  [[ $installed_port == "$PANEL_INTERNAL_PORT" &&
    $installed_user == "$PANEL_USERNAME" && $installed_path == / ]] &&
    official_install_serialized_value_matches XUI_PASSWORD "$PANEL_PASSWORD"
}

xui_install_result_path_exists() {
  [[ -e /etc/x-ui/install-result.env || -L /etc/x-ui/install-result.env ]]
}

xui_install_result_path_is_safe() {
  [[ -f /etc/x-ui/install-result.env && ! -L /etc/x-ui/install-result.env ]]
}

xui_service_autostart_disabled() {
  local output count
  case $PLATFORM_INIT in
    systemd)
      output=$(systemctl is-enabled x-ui 2>/dev/null) || true
      case $output in
        disabled|masked|masked-runtime) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    openrc)
      output=$(rc-update show default 2>/dev/null) || return 1
      count=$(awk '$1 == "x-ui" { count++ } END { print count + 0 }' <<<"$output") || return 1
      [[ $count == 0 ]]
      ;;
    *) return 1 ;;
  esac
}

stop_owned_partial_xui_for_retry() {
  local exists_status inactive_status listener_status
  if platform_service_exists x-ui; then
    exists_status=0
  else
    exists_status=$?
  fi
  case $exists_status in
    0)
      platform_service_stop x-ui >/dev/null 2>&1 || {
        log_error '无法停止上次中断的 x-ui，拒绝重放首次安装事务。'
        return 1
      }
      if platform_service_is_inactive x-ui; then
        :
      else
        inactive_status=$?
        log_error "无法确认上次中断的 x-ui 已停止（状态 ${inactive_status}）。"
        return 1
      fi
      platform_service_disable x-ui >/dev/null 2>&1 || {
        log_error '无法禁用上次中断的 x-ui 自启，拒绝重放首次安装事务。'
        return 1
      }
      xui_service_autostart_disabled || {
        log_error '无法确认上次中断的 x-ui 自启已禁用。'
        return 1
      }
      ;;
    1) ;;
    *)
      log_error '无法判断上次中断的 x-ui 服务是否存在。'
      return 1
      ;;
  esac
  if platform_port_is_listening "$PANEL_INTERNAL_PORT" tcp; then
    listener_status=0
  else
    listener_status=$?
  fi
  case $listener_status in
    0)
      log_error '停止部分安装后面板端口仍在监听，拒绝重放首次安装事务。'
      return 1
      ;;
    1) return 0 ;;
    *)
      log_error '无法确认部分安装的面板监听已停止。'
      return 1
      ;;
  esac
}

prepare_xui_install_transaction() {
  local status
  XUI_INSTALL_TRANSACTION_PRESENT=false
  if xui_install_transition_read; then
    XUI_INSTALL_TRANSACTION_PRESENT=true
  else
    status=$?
    ((status == 1)) && return 0
    return "$status"
  fi

  if xui_install_result_path_exists; then
    xui_install_result_path_is_safe || {
      log_error '中断安装的结果路径类型不安全，拒绝接管。'
      return 1
    }
    xui_install_result_identity_matches || {
      log_error '中断安装的结果文件与本次已确认面板身份不一致，拒绝接管。'
      return 1
    }
  fi
  if foreign_xui_exists; then
    stop_owned_partial_xui_for_retry || return 1
  fi
  log_warn '检测到已登记的 3x-ui 首次安装事务，将使用同一版本和配置安全重放。'
}

write_xui_install_result() {
  local token temporary access_url
  token=$(state_get XUI_API_TOKEN) || return 1
  [[ $token =~ ^[A-Za-z0-9._-]{24,128}$ ]] || return 1
  install -d -m 0755 -- /etc/x-ui || return 1
  [[ -d /etc/x-ui && ! -L /etc/x-ui ]] || return 1
  temporary=$(mktemp /etc/x-ui/.install-result.XXXXXX) || return 1
  access_url="http://${PUBLIC_IPV4}:${PANEL_INTERNAL_PORT}/"
  if ! {
    printf 'XUI_USERNAME=%q\n' "$PANEL_USERNAME"
    printf 'XUI_PASSWORD=%q\n' "$PANEL_PASSWORD"
    printf 'XUI_PANEL_PORT=%q\n' "$PANEL_INTERNAL_PORT"
    printf 'XUI_WEB_BASE_PATH=%q\n' '/'
    printf 'XUI_ACCESS_URL=%q\n' "$access_url"
    printf 'XUI_API_TOKEN=%q\n' "$token"
    printf 'XUI_DB_TYPE=%q\n' 'sqlite'
  } >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chown root:root -- "$temporary" || { rm -f -- "$temporary"; return 1; }
  chmod 0600 -- "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" /etc/x-ui/install-result.env
}

capture_xui_api_token() {
  local token output_file
  token=$(read_official_install_value XUI_API_TOKEN || true)
  if [[ ! $token =~ ^[A-Za-z0-9._-]{24,128}$ ]]; then
    output_file=$(mktemp)
    chmod 600 "$output_file"
    if ! /usr/local/x-ui/x-ui setting -getApiToken true >"$output_file" 2>&1; then
      rm -f "$output_file"
      log_error '无法创建 3x-ui 管理 API Token。'
      return 1
    fi
    token=$(sed -nE 's/^[[:space:]]*apiToken:[[:space:]]*([A-Za-z0-9._-]+).*$/\1/p' "$output_file" | tail -n 1)
    rm -f "$output_file"
  fi
  [[ $token =~ ^[A-Za-z0-9._-]{24,128}$ ]] || {
    log_error '3x-ui API Token 格式无效。'
    return 1
  }
  state_set XUI_API_TOKEN "$token" || return 1
  secret_register "$token"
  token=''
}

xui_partial_install_matches() {
  xui_partial_install_artifacts_exist || return 1
  xui_install_result_identity_matches
}

xui_partial_binary_exists() {
  [[ -x /usr/local/x-ui/x-ui ]]
}

xui_partial_install_artifacts_exist() {
  xui_partial_binary_exists && [[ -r /etc/x-ui/install-result.env ]]
}

xui_set_panel_loopback() {
  /usr/local/x-ui/x-ui setting -webBasePath / >/dev/null 2>&1 &&
    /usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 >/dev/null 2>&1
}

secure_partial_xui_after_failed_install() {
  local exists_status inactive_status listener_status autostart_status
  if xui_partial_binary_exists && xui_set_panel_loopback; then
    if platform_service_restart x-ui >/dev/null 2>&1 &&
      wait_for_panel_loopback_http; then
      XUI_INSTALL_GUARD_ACTIVE=false
      log_warn '未完成的 3x-ui 已限制到 127.0.0.1；修复错误后可安全续跑。'
      return 0
    fi
  fi
  if platform_service_exists x-ui; then
    exists_status=0
  else
    exists_status=$?
  fi
  case $exists_status in
    0)
      platform_service_stop x-ui >/dev/null 2>&1 ||
        log_error '停止未完成的 x-ui 命令失败；正在独立核验停止状态。'
      if platform_service_is_inactive x-ui; then
        inactive_status=0
      else
        inactive_status=$?
      fi
      platform_service_disable x-ui >/dev/null 2>&1 ||
        log_error '禁用未完成的 x-ui 自启命令失败；正在独立核验自启状态。'
      if xui_service_autostart_disabled; then
        autostart_status=0
      else
        autostart_status=$?
      fi
      if ((inactive_status != 0 || autostart_status != 0)); then
        ((inactive_status == 0)) ||
          log_error '无法确认未完成的 x-ui 已停止；请立即在另一 SSH 会话中阻断面板端口。'
        ((autostart_status == 0)) ||
          log_error '无法确认未完成的 x-ui 自启已禁用；请勿重启 VPS。'
        return 1
      fi
      ;;
    1) ;;
    *)
      log_error '无法判断 x-ui 服务是否存在；保护状态保持启用，请先阻断面板端口。'
      return 1
      ;;
  esac
  if platform_port_is_listening "$PANEL_INTERNAL_PORT" tcp; then
    listener_status=0
  else
    listener_status=$?
  fi
  case $listener_status in
    0)
      if ((exists_status == 0)); then
        log_error 'x-ui 服务已报告停止，但面板端口仍在监听；无法证明已安全停止。'
      else
      log_error '未找到可管理的 x-ui 服务，但面板端口仍在监听；无法证明已安全停止。'
      fi
      return 1
      ;;
    1) ;;
    *)
      log_error '无法检测面板端口是否仍在监听；保护状态保持启用。'
      return 1
      ;;
  esac
  XUI_INSTALL_GUARD_ACTIVE=false
  log_warn '未完成的 x-ui 已停止；修复错误并续跑后才会重新启用。'
  return 0
}

secure_xui_install_result() {
  [[ -f /etc/x-ui/install-result.env && ! -L /etc/x-ui/install-result.env ]] || return 1
  chown root:root /etc/x-ui/install-result.env || return 1
  chmod 0600 /etc/x-ui/install-result.env || return 1
}

xui_service_autostart_enabled() {
  case $PLATFORM_INIT in
    systemd)
      systemctl is-enabled --quiet x-ui
      ;;
    openrc)
      rc-update show default 2>/dev/null | awk '{ print $1 }' | grep -Fxq x-ui
      ;;
    *) return 1 ;;
  esac
}

ensure_xui_service_autostart() {
  platform_service_enable x-ui >/dev/null 2>&1 || {
    log_error '无法配置 x-ui 服务随系统启动。'
    return 1
  }
  xui_service_autostart_enabled || {
    log_error 'x-ui 服务自启验证失败。'
    return 1
  }
}

wait_for_panel_loopback_http() {
  local attempt code
  for ((attempt = 1; attempt <= 15; attempt++)); do
    code=$(curl --disable --noproxy '*' -sS --connect-timeout 2 --max-time 5 \
      -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:${PANEL_INTERNAL_PORT}/" 2>/dev/null || true)
    if [[ $code =~ ^[1-5][0-9][0-9]$ ]]; then
      return 0
    fi
    sleep 1
  done
  log_error '3x-ui 面板绑定回环地址后未能通过本机 HTTP 校验。'
  return 1
}

bind_new_xui_panel_to_loopback() {
  xui_partial_binary_exists || return 1
  if ! xui_set_panel_loopback; then
    log_error '无法将初装 3x-ui 面板限制到 127.0.0.1。'
    return 1
  fi
  platform_service_restart x-ui >/dev/null 2>&1 || {
    log_error '将 3x-ui 面板限制到回环地址后重启服务失败。'
    return 1
  }
  wait_for_panel_loopback_http || return 1
  XUI_INSTALL_GUARD_ACTIVE=false
}

redact_xui_bootstrap_token_file() {
  local file=/etc/x-ui/install-result.env temporary
  [[ -f $file && ! -L $file ]] || return 0
  temporary=$(mktemp /etc/x-ui/.install-result.XXXXXX) || return 1
  if ! awk 'BEGIN { replaced=0 }
      /^XUI_API_TOKEN=/ { print "XUI_API_TOKEN=\047\047"; replaced=1; next }
      { print }
      END { if (!replaced) print "XUI_API_TOKEN=\047\047" }' "$file" >"$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chown root:root "$temporary" || { rm -f -- "$temporary"; return 1; }
  chmod 0600 "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$file"
}

install_compatible_xray() {
  local directory metadata target source architecture binary incoming detected status=0
  directory=$(mktemp -d) || return 1
  install_temp_register "$directory"
  log_info '正在选择并下载兼容的官方 Xray。'
  metadata=$(python3 -I "${SCRIPT_DIR}/lib/panel_maintenance.py" --prepare-core "$directory") || return 1
  target=$(jq -er '.version | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' <<<"$metadata") || return 1
  source=$(jq -er '.binary' <<<"$metadata") || return 1
  [[ $source == "$directory/xray" && -f $source && ! -L $source ]] || return 1
  architecture=$PLATFORM_ARCH
  case $architecture in armv6|armv7) architecture=arm32 ;; esac
  binary="/usr/local/x-ui/bin/xray-linux-${architecture}"
  [[ -f $binary && ! -L $binary ]] || return 1
  detected=$("$binary" version 2>/dev/null) || return 1
  if [[ $detected == "Xray ${target#v}" || $detected == "Xray ${target#v} "* ]]; then
    log_info "Xray 已是兼容版本 ${target}。"
    return 0
  fi
  cp -p -- "$binary" "$directory/original-core" || return 1
  incoming=$(mktemp /usr/local/x-ui/bin/.okp-core.XXXXXX) || return 1
  if install -m 0755 -- "$source" "$incoming" && platform_service_stop x-ui &&
      mv -f -- "$incoming" "$binary" && platform_service_start x-ui &&
      platform_service_is_active x-ui; then
    log_info "Xray 已配置为兼容版本 ${target}。"
  else
    status=1
    platform_service_stop x-ui || true
    install -m 0755 -- "$directory/original-core" "$incoming" && mv -f -- "$incoming" "$binary" || return 1
    platform_service_start x-ui || true
    log_error '兼容 Xray 配置失败，已还原安装器提供的内核；请继续安装流程重试。'
  fi
  rm -f -- "$incoming"
  return "$status"
}

stage_xui_install() {
  local tag commit asset_sha256 installer output_file status supply_dir pinned_path
  prepare_xui_install_transaction || return 1
  if [[ $XUI_INSTALL_TRANSACTION_PRESENT != true ]] && foreign_xui_exists; then
    if xui_partial_install_matches; then
      log_warn '检测到本项目上次启动但尚未标记完成的 3x-ui，正在核验并续接。'
      XUI_INSTALL_GUARD_ACTIVE=true
      secure_xui_install_result || return 1
      install_compatible_xray || return 1
      bind_new_xui_panel_to_loopback || return 1
      ensure_xui_service_autostart || return 1
      capture_xui_api_token || return 1
      write_xui_install_result || return 1
      secure_xui_install_result || return 1
      state_set_many PANEL_SCHEME http \
        XUI_INSTALL_RESULT_FILE /etc/x-ui/install-result.env || return 1
      return 0
    fi
    log_error '检测到无法证明与当前已确认配置一致的部分 3x-ui 安装；拒绝覆盖。'
    return 1
  fi
  assert_install_ports_available || return 1
  tag=$(state_get XUI_VERSION) || return 1
  commit=$(state_get XUI_RELEASE_COMMIT) || return 1
  asset_sha256=$(state_get XUI_RELEASE_ASSET_SHA256) || return 1
  installer=$(mktemp)
  output_file=$(mktemp)
  supply_dir=$(mktemp -d)
  install_temp_register "$installer"
  install_temp_register "$output_file"
  install_temp_register "$supply_dir"
  chmod 600 "$installer" "$output_file"
  if ! secure_curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
    "${OFFICIAL_INSTALL_URL}/${commit}/install.sh" -o "$installer"; then
    rm -f "$installer" "$output_file"
    log_error '官方 3x-ui 安装器下载失败。'
    return 1
  fi
  okp_xui_validate_pinned_installer_downloaders "$installer" "$OFFICIAL_REPO" \
    "$tag" "$PLATFORM_ARCH" || {
    rm -f "$installer" "$output_file"
    return 1
  }
  okp_prepare_pinned_xui_download "$OFFICIAL_REPO" "$tag" "$commit" \
    "$PLATFORM_ARCH" "$asset_sha256" "$supply_dir" || {
    rm -f "$installer" "$output_file"
    return 1
  }
  pinned_path="${OKP_XUI_PINNED_BIN_DIR}:${PATH}"

  log_info '正在运行官方 3x-ui 安装器。'
  state_set XUI_INSTALL_RECOVERY_STATUS installing || return 1
  XUI_INSTALL_GUARD_ACTIVE=true
  if run_supervised_xui_installer "$installer" "$tag" "$pinned_path" "$output_file"; then
    status=0
  else
    status=$?
  fi
  rm -f "$installer"
  rm -rf -- "$supply_dir"
  if ((status != 0)); then
    install_settle_partial_xui_install
    log_error "官方 3x-ui 安装失败（退出码 ${status}）。"
    redact_sensitive "$(tail -n 40 "$output_file")" >&2
    printf '\n' >&2
    rm -f "$output_file"
    return "$status"
  fi
  rm -f "$output_file"
  command -v x-ui >/dev/null 2>&1 || [[ -x /usr/local/x-ui/x-ui ]] || {
    log_error '安装器返回成功，但未找到 x-ui。'
    return 1
  }
  platform_service_is_active x-ui || {
    log_error 'x-ui 服务未运行。'
    return 1
  }
  install_compatible_xray || return 1
  capture_xui_api_token || return 1
  write_xui_install_result || return 1
  secure_xui_install_result || return 1
  bind_new_xui_panel_to_loopback || return 1
  ensure_xui_service_autostart || return 1
  state_set_many PANEL_SCHEME http \
    XUI_INSTALL_RESULT_FILE /etc/x-ui/install-result.env || return 1
  state_unset XUI_INSTALL_RECOVERY_STATUS || return 1
}

ensure_client_identity() {
  local value installation_id generated
  value=$(state_get CLIENT_UUID 2>/dev/null || true)
  if [[ -z $value ]]; then
    value=$(generate_uuid) || return 1
    state_set CLIENT_UUID "$value" || return 1
  fi
  value=$(state_get SUB_ID 2>/dev/null || true)
  if [[ -z $value ]]; then
    generated=$(random_hex 16) || return 1
    [[ $generated =~ ^[0-9a-f]{32}$ ]] || return 1
    state_set SUB_ID "$generated" || return 1
  fi
  value=$(state_get REALITY_SHORT_ID 2>/dev/null || true)
  if [[ -z $value ]]; then
    generated=$(random_hex 8) || return 1
    [[ $generated =~ ^[0-9a-f]{16}$ ]] || return 1
    state_set REALITY_SHORT_ID "$generated" || return 1
  fi
  value=$(state_get CLIENT_EMAIL 2>/dev/null || true)
  if [[ -z $value ]]; then
    installation_id=$(state_get INSTALLATION_ID 2>/dev/null || random_hex 4)
    value="okp-${installation_id:0:12}"
    state_set CLIENT_EMAIL "$value" || return 1
  fi
}

reload_existing_https_after_certificate_change() {
  local scheme host
  stage_is_done xui || return 0
  xui_partial_install_matches || return 1
  scheme=$(state_get PANEL_SCHEME 2>/dev/null || true)
  [[ $scheme == https ]] || return 0
  host=$PUBLIC_IPV4
  [[ $MODE == public ]] && host=$FQDN
  platform_service_restart x-ui >/dev/null 2>&1 || {
    log_error '证书更新后无法重启 x-ui。'
    return 1
  }
  wait_for_panel_https "$host" || {
    log_error 'x-ui 未能使用更新后的证书恢复 HTTPS。'
    return 1
  }
}

stage_certificate() {
  local zone status
  if [[ $MODE == nat ]]; then
    okp_cert_create_self_signed_ip "$PUBLIC_IPV4" "$CERT_DIR/server.crt" "$CERT_DIR/server.key" || return 1
    reload_existing_https_after_certificate_change
    return $?
  fi

  okp_alidns_install_cli || return 1
  okp_alidns_save_credentials "$ALI_ACCESS_KEY_ID" "$ALI_ACCESS_KEY_SECRET" || return 1
  secret_register "$ALI_ACCESS_KEY_SECRET"
  okp_alidns_test_credentials || return 1
  zone=$(okp_alidns_resolve_zone "$FQDN") || return 1
  state_set ALIDNS_ZONE "$zone" || return 1
  okp_alidns_ensure_record "$FQDN" A "$PUBLIC_IPV4" "$zone"
  status=$?
  if ((status == 3)); then
    log_warn '发现值完全相同但非本项目管理的 A 记录。'
    confirm '是否复用该记录（卸载时不会删除）？' n || return 1
    okp_alidns_ensure_record "$FQDN" A "$PUBLIC_IPV4" "$zone" true || return 1
  elif ((status != 0)); then
    return "$status"
  fi
  if [[ $ENABLE_IPV6 == true && -n $PUBLIC_IPV6 ]]; then
    okp_alidns_ensure_record "$FQDN" AAAA "$PUBLIC_IPV6" "$zone"
    status=$?
    if ((status == 3)); then
      log_warn '发现值完全相同但非本项目管理的 AAAA 记录。'
      confirm '是否复用该记录（卸载时不会删除）？' n || return 1
      okp_alidns_ensure_record "$FQDN" AAAA "$PUBLIC_IPV6" "$zone" true || return 1
    elif ((status != 0)); then
      return "$status"
    fi
  else
    okp_alidns_delete_managed_records_for_fqdn "$FQDN" AAAA || return 1
    okp_alidns_assert_no_record_type "$FQDN" AAAA "$zone" || {
      log_error "${FQDN} 仍存在 AAAA 记录；禁用 IPv6 时拒绝发布可能指向旧主机的域名。"
      return 1
    }
  fi
  okp_acme_install "$ACME_EMAIL" || return 1
  okp_acme_issue_alidns "$FQDN" "$CERT_DIR/server.crt" "$CERT_DIR/server.key" || return 1
  okp_acme_install_scheduler || return 1
  reload_existing_https_after_certificate_change
}

detect_live_panel_scheme() {
  local scheme code
  for scheme in https http; do
    if [[ $scheme == https ]]; then
      code=$(curl --disable --noproxy '*' -ksS --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' \
        "https://127.0.0.1:${PANEL_INTERNAL_PORT}/" 2>/dev/null || true)
    else
      code=$(curl --disable --noproxy '*' -sS --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:${PANEL_INTERNAL_PORT}/" 2>/dev/null || true)
    fi
    if [[ $code =~ ^[1-5][0-9][0-9]$ ]]; then
      state_set PANEL_SCHEME "$scheme" || return 1
      printf '%s' "$scheme"
      return 0
    fi
  done
  log_error '无法识别 3x-ui 面板当前使用的 HTTP/HTTPS 协议。'
  return 1
}

wait_for_panel_https() {
  local host=$1 attempt code url
  url=$(_xui_public_origin https "$host" "$PANEL_INTERNAL_PORT")/
  for ((attempt = 1; attempt <= 15; attempt++)); do
    code=$(curl --disable --noproxy '*' -sS --cacert "$CERT_DIR/server.crt" --connect-timeout 2 --max-time 5 \
      --resolve "${host}:${PANEL_INTERNAL_PORT}:127.0.0.1" \
      -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
    if [[ $code =~ ^[1-5][0-9][0-9]$ ]]; then
      state_set PANEL_SCHEME https || return 1
      return 0
    fi
    sleep 1
  done
  return 1
}

cleanup_bootstrap_api_token() {
  local old_id old_name
  old_id=$(state_get XUI_BOOTSTRAP_API_TOKEN_ID 2>/dev/null || true)
  old_name=$(state_get XUI_BOOTSTRAP_API_TOKEN_NAME 2>/dev/null || true)
  if [[ -n $old_id && -n $old_name ]]; then
    xui_delete_api_token_by_id "$old_id" "$old_name" || return 1
    state_unset_many XUI_BOOTSTRAP_API_TOKEN_ID XUI_BOOTSTRAP_API_TOKEN_NAME || return 1
  fi
  redact_xui_bootstrap_token_file || return 1
}

ensure_dedicated_api_token() {
  local installation_id token_name current_id current_name pending_name
  local rows_count bootstrap_id bootstrap_name
  installation_id=$(state_get INSTALLATION_ID) || return 1
  token_name="one-key-proxy-${installation_id:0:16}"
  current_id=$(state_get XUI_API_TOKEN_ID 2>/dev/null || true)
  current_name=$(state_get XUI_API_TOKEN_NAME 2>/dev/null || true)
  pending_name=$(state_get XUI_PENDING_API_TOKEN_NAME 2>/dev/null || true)
  if [[ -n $pending_name ]]; then
    xui_recover_pending_api_token || return 1
    current_id=$(state_get XUI_API_TOKEN_ID 2>/dev/null || true)
    current_name=$(state_get XUI_API_TOKEN_NAME 2>/dev/null || true)
  fi
  if [[ $current_id =~ ^[1-9][0-9]*$ && $current_name == "$token_name" ]]; then
    xui_validate_api_token "$(state_get XUI_API_TOKEN)" "$current_id" "$current_name" || return 1
    cleanup_bootstrap_api_token || return 1
    return 0
  fi

  xui_api_tokens_read || return 1
  rows_count=$(jq 'length' <<<"$XUI_API_TOKENS_JSON") || return 1
  if ((rows_count == 1)); then
    bootstrap_id=$(jq -r '.[0].id' <<<"$XUI_API_TOKENS_JSON")
    bootstrap_name=$(jq -r '.[0].name' <<<"$XUI_API_TOKENS_JSON")
    if [[ $bootstrap_name == install ]]; then
      state_set_many XUI_BOOTSTRAP_API_TOKEN_ID "$bootstrap_id" \
        XUI_BOOTSTRAP_API_TOKEN_NAME "$bootstrap_name" || return 1
    else
      log_warn '唯一的初装 Token 名称不是 install；不会自动撤销该 Token。'
    fi
  else
    log_warn '初装 API Token 无法唯一识别；将创建专用 Token，但不会自动撤销其他 Token。'
  fi
  state_set XUI_PENDING_API_TOKEN_NAME "$token_name" || return 1
  xui_create_api_token "$token_name" || return 1
  xui_switch_api_token_context "$XUI_CREATED_API_TOKEN_VALUE" \
    "$XUI_CREATED_API_TOKEN_ID" "$XUI_CREATED_API_TOKEN_NAME" || return 1
  cleanup_bootstrap_api_token || return 1
}

stage_api_configuration() {
  local public_host client_uuid client_email sub_id short_id live_scheme installation_id managed_tag host_tag
  public_host=$PUBLIC_IPV4
  [[ $MODE == public ]] && public_host=$FQDN
  installation_id=$(state_get INSTALLATION_ID) || return 1
  managed_tag="one-key-proxy-${installation_id:0:16}"
  host_tag="one-key-proxy-host-${installation_id:0:16}"
  live_scheme=$(detect_live_panel_scheme) || return 1
  log_info "检测到面板当前协议：${live_scheme}。"
  xui_check_required_endpoints || return 1
  ensure_dedicated_api_token || return 1
  xui_configure_subscription \
    "$SUB_INTERNAL_PORT" https "$public_host" "$SUB_EXTERNAL_PORT" \
    "$CERT_DIR/server.crt" "$CERT_DIR/server.key" || return 1
  xui_configure_panel_tls \
    "$PANEL_INTERNAL_PORT" "$CERT_DIR/server.crt" "$CERT_DIR/server.key" "$public_host" || return 1
  xui_restart_panel || return 1
  wait_for_panel_https "$public_host" || {
    log_error '面板切换 HTTPS 后未能通过部署证书完成本机校验。'
    return 1
  }

  ensure_client_identity || return 1
  client_uuid=$(state_get CLIENT_UUID) || return 1
  client_email=$(state_get CLIENT_EMAIL) || return 1
  sub_id=$(state_get SUB_ID) || return 1
  short_id=$(state_get REALITY_SHORT_ID) || return 1

  xui_ensure_vless_reality_inbound \
    "$NODE_INTERNAL_PORT" "$client_uuid" "$client_email" "$sub_id" \
    "$REALITY_TARGET" "$REALITY_SNI" "$short_id" "$NODE_NAME" \
    "$managed_tag" || return 1
  [[ -n ${XUI_REALITY_PRIVATE_KEY:-} ]] && secret_register "$XUI_REALITY_PRIVATE_KEY"
  xui_ensure_external_host "$XUI_MANAGED_INBOUND_ID" "$public_host" "$NODE_EXTERNAL_PORT" \
    one-key-proxy-public-endpoint "$host_tag" || return 1
  state_set_many \
    INBOUND_ID "$XUI_MANAGED_INBOUND_ID" \
    HOST_GROUP_ID "$XUI_MANAGED_HOST_GROUP_ID" \
    INBOUND_TAG "$managed_tag" \
    HOST_TAG "$host_tag" \
    CLIENT_UUID "$XUI_CLIENT_UUID" \
    CLIENT_EMAIL "$XUI_CLIENT_EMAIL" \
    SUB_ID "$XUI_SUB_ID" \
    REALITY_SHORT_ID "$XUI_REALITY_SHORT_ID" \
    REALITY_PUBLIC_KEY "$XUI_REALITY_PUBLIC_KEY" \
    TLS_CERT_FILE "$CERT_DIR/server.crt" \
    TLS_KEY_FILE "$CERT_DIR/server.key" || return 1
  platform_service_is_active x-ui || return 1
}

stage_firewall() {
  local port changed required_ports
  required_ports="${PANEL_INTERNAL_PORT},${NODE_INTERNAL_PORT},${SUB_INTERNAL_PORT}"
  if ! platform_detect_firewall; then
    log_warn '防火墙状态存在歧义，未自动修改；请手动开放三个内部 TCP 端口。'
    state_set_many \
      FIREWALL_BACKEND "${PLATFORM_FIREWALL:-ambiguous}" \
      FIREWALL_ZONE "${PLATFORM_FIREWALL_ZONE:-}" \
      FIREWALL_REQUIRED_TCP_PORTS "$required_ports" \
      FIREWALL_MANUAL_REQUIRED true || return 1
    return 0
  fi
  state_set_many \
    FIREWALL_BACKEND "$PLATFORM_FIREWALL" \
    FIREWALL_ZONE "${PLATFORM_FIREWALL_ZONE:-}" \
    FIREWALL_REQUIRED_TCP_PORTS "$required_ports" || return 1
  if [[ $PLATFORM_FIREWALL == none ]]; then
    state_set FIREWALL_MANUAL_REQUIRED true || return 1
    log_warn "未检测到已启用的 UFW/firewalld；请手动确认内部 TCP 端口 ${required_ports//,/, } 已放行。"
    return 0
  fi
  state_set FIREWALL_MANUAL_REQUIRED false || return 1
  changed=$(state_get FIREWALL_MANAGED_TCP_PORTS 2>/dev/null || true)
  for port in "$PANEL_INTERNAL_PORT" "$NODE_INTERNAL_PORT" "$SUB_INTERNAL_PORT"; do
    platform_firewall_allow_tcp "$port" || return 1
    if [[ ${PLATFORM_FIREWALL_RULE_CHANGED:-0} == 1 ]]; then
      if [[ ,$changed, != *,${port},* ]]; then
        changed=${changed:+${changed},}${port}
        state_set FIREWALL_MANAGED_TCP_PORTS "$changed" || return 1
      fi
    fi
  done
  state_set FIREWALL_MANAGED_TCP_PORTS "$changed" || return 1
}

stage_security() {
  okp_fail2ban_install "$PANEL_INTERNAL_PORT" || true
  state_has FAIL2BAN_STATUS || state_set FAIL2BAN_STATUS degraded || return 1
}

invalidate_stages() {
  local stage
  for stage in "$@"; do
    stage_clear "$stage" || return 1
  done
}

public_dns_postcondition_ok() {
  local zone
  [[ $MODE == public ]] || return 0
  zone=$(state_get ALIDNS_ZONE 2>/dev/null) || return 1
  [[ -n $zone ]] || return 1

  okp_alidns_assert_single_record_value "$FQDN" A "$PUBLIC_IPV4" "$zone" || return 1
  case $ENABLE_IPV6 in
    true)
      [[ -n $PUBLIC_IPV6 ]] || return 1
      okp_alidns_assert_single_record_value "$FQDN" AAAA "$PUBLIC_IPV6" "$zone"
      ;;
    false)
      okp_alidns_assert_no_record_type "$FQDN" AAAA "$zone"
      ;;
    *)
      return 1
      ;;
  esac
}

certificate_postcondition_ok() {
  local mode
  [[ -r $CERT_DIR/server.crt && -r $CERT_DIR/server.key && ! -L $CERT_DIR/server.key ]] || return 1
  openssl x509 -in "$CERT_DIR/server.crt" -noout -checkend 86400 >/dev/null 2>&1 || return 1
  mode=$(state_get TLS_MODE 2>/dev/null || true)
  if [[ $MODE == nat ]]; then
    [[ $mode == SELF_SIGNED ]] && _okp_cert_verify_ip_san "$CERT_DIR/server.crt" "$PUBLIC_IPV4"
  else
    [[ $mode == ACME ]] && \
      _okp_cert_verify_dns_san "$CERT_DIR/server.crt" "$FQDN" && \
      public_dns_postcondition_ok
  fi
}

firewall_postcondition_ok() {
  local backend required port
  backend=$(state_get FIREWALL_BACKEND 2>/dev/null || true)
  required=$(state_get FIREWALL_REQUIRED_TCP_PORTS 2>/dev/null || true)
  [[ -n $required ]] || return 0
  [[ $backend != none && $backend != ambiguous && -n $backend ]] || return 0
  platform_detect_firewall || return 1
  [[ $PLATFORM_FIREWALL == "$backend" ]] || return 1
  while IFS= read -r port; do
    [[ -n $port ]] || continue
    platform_firewall_rule_exists "$port" tcp || return 1
  done < <(tr ',' '\n' <<<"$required")
}

reconcile_completed_stages() {
  local live_scheme inbound_tag host_tag fail2ban_status fail2ban_log
  if stage_is_done compatibility && { ! state_has XUI_VERSION || ! state_has XUI_RELEASE_COMMIT || \
      ! state_has XUI_RELEASE_ASSET_SHA256; }; then
    invalidate_stages compatibility preflight certificate xui api firewall security verified completed || return 1
  fi
  if stage_is_done certificate && ! certificate_postcondition_ok; then
    log_warn '证书阶段后置条件不再成立，将重新执行证书与依赖配置。'
    invalidate_stages certificate api verified completed || return 1
  fi
  if stage_is_done xui; then
    if ! xui_partial_install_matches; then
      log_warn '3x-ui 安装阶段后置条件不再成立，将重新核验。'
      invalidate_stages xui api security verified completed || return 1
    else
      if ! platform_service_is_active x-ui; then
        log_warn 'x-ui 服务已停止，正在按已验证的安装元数据尝试恢复启动。'
        platform_service_start x-ui >/dev/null 2>&1 || {
          log_error 'x-ui 属于本项目，但服务无法启动；请检查服务日志后重新运行。'
          return 1
        }
      fi
      live_scheme=$(detect_live_panel_scheme) || return 1
      log_info "续跑核验：面板当前协议为 ${live_scheme}。"
    fi
  fi
  if stage_is_done api; then
    inbound_tag=$(state_get INBOUND_TAG 2>/dev/null || true)
    host_tag=$(state_get HOST_TAG 2>/dev/null || true)
    if [[ -z $inbound_tag || -z $host_tag || $inbound_tag == *[[:cntrl:]]* || \
        $host_tag == *[[:cntrl:]]* ]]; then
      log_warn 'API 阶段缺少可验证的受管身份，将重新配置。'
      invalidate_stages api verified completed || return 1
    else
      XUI_MANAGED_TAG=$inbound_tag
      XUI_MANAGED_HOST_TAG=$host_tag
    fi
  fi
  if stage_is_done api; then
    if ! xui_check_required_endpoints || ! xui_find_managed_inbound; then
      log_warn 'API/入站阶段后置条件不再成立，正在刷新引导 Token 后重做。'
      capture_xui_api_token || return 1
      state_unset XUI_API_TOKEN_ID || return 1
      state_unset XUI_API_TOKEN_NAME || return 1
      invalidate_stages api verified completed || return 1
    fi
  fi
  if stage_is_done firewall && ! firewall_postcondition_ok; then
    log_warn '受管防火墙规则缺失，将重新核验并补齐。'
    invalidate_stages firewall verified completed || return 1
  fi
  if stage_is_done security; then
    fail2ban_status=$(state_get FAIL2BAN_STATUS 2>/dev/null || true)
    fail2ban_log=$(state_get FAIL2BAN_LOG_PATH 2>/dev/null || true)
    if [[ $fail2ban_status == enabled ]] && ! okp_fail2ban_verify "$fail2ban_log"; then
      log_warn '受管 Fail2ban 规则验证失败，将重新执行安全阶段。'
      invalidate_stages security verified completed || return 1
    fi
  fi
  if stage_is_done verified && ! stage_is_done completed; then
    stage_clear verified || return 1
  fi
}

recover_abandoned_initial_state() {
  [[ -e $STATE_FILE || -L $STATE_FILE ]] || return 0
  acquire_operation_lock || return 1
  state_remove_abandoned_initial foreign_xui_exists || return 1
  log_warn '已清理由首次确认阶段中断留下、且尚未创建外部资源的状态文件。'
}

fetch_local_https_path() {
  local host=$1 port=$2 path=$3 body_file=$4
  local config_file code url
  [[ $path == /* && $path != *$'\n'* && $path != *$'\r'* && $path != *'"'* ]] || return 2
  config_file=$(mktemp)
  install_temp_register "$config_file"
  chmod 600 "$config_file"
  url=$(_xui_public_origin https "$host" "$port")${path}
  printf '%s\n' \
    'silent' \
    'show-error' \
    'connect-timeout = 3' \
    'max-time = 8' \
    "cacert = \"${CERT_DIR}/server.crt\"" \
    "resolve = \"${host}:${port}:127.0.0.1\"" \
    "output = \"${body_file}\"" \
    "url = \"${url}\"" >"$config_file" || return 1
  code=$(curl --disable --noproxy '*' --config "$config_file" -w '%{http_code}') || return 1
  [[ $code == 200 && -s $body_file ]]
}

wait_for_subscription() {
  local host=$1 sub_id=$2 attempt body_file
  body_file=$(mktemp)
  install_temp_register "$body_file"
  chmod 600 "$body_file"
  for ((attempt = 1; attempt <= 12; attempt++)); do
    if fetch_local_https_path "$host" "$SUB_INTERNAL_PORT" "/sub/${sub_id}" "$body_file"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

verify_subscription_formats() {
  local host=$1 sub_id=$2 body_file decoded_file uri found=false
  local uuid public_key short_id
  uuid=$(state_get CLIENT_UUID) || return 1
  public_key=$(state_get REALITY_PUBLIC_KEY) || return 1
  short_id=$(state_get REALITY_SHORT_ID) || return 1
  body_file=$(mktemp)
  decoded_file=$(mktemp)
  install_temp_register "$body_file"
  install_temp_register "$decoded_file"
  chmod 600 "$body_file" "$decoded_file"
  fetch_local_https_path "$host" "$SUB_INTERNAL_PORT" "/sub/${sub_id}" "$body_file" || return 1
  if ! tr -d '\r\n\t ' <"$body_file" | base64 -d >"$decoded_file" 2>/dev/null; then
    return 1
  fi
  while IFS= read -r uri || [[ -n $uri ]]; do
    uri=${uri%$'\r'}
    if [[ $uri == vless://* ]] && vless_uri_matches_deployment "$uri" "$host" "$NODE_EXTERNAL_PORT"; then
      found=true
      break
    fi
  done <"$decoded_file"
  [[ $found == true ]] || return 1
  : >"$body_file"
  fetch_local_https_path "$host" "$SUB_INTERNAL_PORT" "/json/${sub_id}" "$body_file" || return 1
  xui_json_subscription_matches "$body_file" "$host" "$NODE_EXTERNAL_PORT" \
    "$uuid" "$REALITY_SNI" "$public_key" "$short_id" || return 1
  : >"$body_file"
  fetch_local_https_path "$host" "$SUB_INTERNAL_PORT" "/clash/${sub_id}" "$body_file" || return 1
  xui_clash_subscription_matches "$body_file" "$host" "$NODE_EXTERNAL_PORT" \
    "$uuid" "$REALITY_SNI" "$public_key" "$short_id"
}

verify_managed_inbound() {
  local inbound actual expected_id expected_tag
  expected_id=$(state_get INBOUND_ID) || return 1
  expected_tag=$(state_get INBOUND_TAG) || return 1
  [[ $expected_id =~ ^[0-9]+$ && -n $expected_tag && $expected_tag != *[[:cntrl:]]* ]] || return 1
  inbound=$(xui_api_get "/panel/api/inbounds/get/${expected_id}") || return 1
  inbound=$(jq -c 'def object_value: if type == "string" then fromjson else . end;
    .settings |= object_value | .streamSettings |= object_value' <<<"$inbound") || return 1
  [[ $(jq -r '.id // empty' <<<"$inbound") == "$expected_id" ]] || return 1
  [[ $(jq -r '.tag // empty' <<<"$inbound") == "$expected_tag" ]] || return 1
  actual=$(jq -r '.port' <<<"$inbound")
  [[ $actual == "$NODE_INTERNAL_PORT" ]] || return 1
  [[ $(jq -r '.protocol' <<<"$inbound") == vless ]] || return 1
  [[ $(jq -r '.streamSettings.network' <<<"$inbound") == tcp ]] || return 1
  [[ $(jq -r '.streamSettings.security' <<<"$inbound") == reality ]] || return 1
  [[ $(jq -r '.settings.encryption' <<<"$inbound") == none ]] || return 1
  [[ $(jq -r '.settings.decryption' <<<"$inbound") == none ]] || return 1
  [[ $(jq -r '.settings.clients[0].flow' <<<"$inbound") == xtls-rprx-vision ]] || return 1
  [[ $(jq -r '.settings.clients[0].id' <<<"$inbound") == "$(state_get CLIENT_UUID)" ]] || return 1
  [[ $(jq -r '.settings.clients[0].subId' <<<"$inbound") == "$(state_get SUB_ID)" ]] || return 1
  [[ $(jq -r '.streamSettings.realitySettings.minClientVer' <<<"$inbound") == 1.0.0 ]] || return 1
  [[ $(jq -r '.streamSettings.realitySettings.target' <<<"$inbound") == "$REALITY_TARGET" ]] || return 1
  [[ $(jq -r '.streamSettings.realitySettings.serverNames[0]' <<<"$inbound") == "$REALITY_SNI" ]] || return 1
  [[ $(jq -r '.streamSettings.realitySettings.shortIds[0]' <<<"$inbound") == "$(state_get REALITY_SHORT_ID)" ]] || return 1
  [[ $(jq -r '.streamSettings.realitySettings.settings.publicKey' <<<"$inbound") == "$(state_get REALITY_PUBLIC_KEY)" ]] || return 1
}

vless_uri_matches_deployment() {
  local uri=$1 host=$2 port=$3 uuid sni public_key short_id
  uuid=$(state_get CLIENT_UUID) || return 1
  sni=$REALITY_SNI
  public_key=$(state_get REALITY_PUBLIC_KEY) || return 1
  short_id=$(state_get REALITY_SHORT_ID) || return 1
  xui_vless_uri_matches "$uri" "$host" "$port" "$uuid" "$sni" "$public_key" "$short_id"
}

select_public_vless_uri() {
  local links_json=$1 host=$2 port=$3 uri
  uri=$(jq -r --arg endpoint "@${host}:${port}" \
    '[.[] | select(startswith("vless://") and contains($endpoint))][0] // empty' \
    <<<"$links_json")
  [[ -n $uri ]] || return 1
  vless_uri_matches_deployment "$uri" "$host" "$port" || return 1
  printf '%s' "$uri"
}

write_result() {
  local public_host sub_id links_json vless_uri panel_url xui_version xray_version
  local fail2ban_status fail2ban_reason cert_fingerprint=''
  local firewall_backend firewall_manual firewall_zone firewall_description
  public_host=$PUBLIC_IPV4
  [[ $MODE == public ]] && public_host=$FQDN
  sub_id=$(state_get SUB_ID) || return 1
  xui_build_subscription_urls https "$public_host" "$SUB_EXTERNAL_PORT" "$sub_id" || return 1
  links_json=$(xui_get_sub_links "$sub_id") || return 1
  vless_uri=$(select_public_vless_uri "$links_json" "$public_host" "$NODE_EXTERNAL_PORT") || return 1
  panel_url=$(_xui_public_origin https "$public_host" "$PANEL_EXTERNAL_PORT")/
  xui_version=$(state_get XUI_VERSION 2>/dev/null || true)
  xray_version=$(state_get XUI_XRAY_VERSION 2>/dev/null || true)
  fail2ban_status=$(state_get FAIL2BAN_STATUS 2>/dev/null || printf 'unknown')
  fail2ban_reason=$(state_get FAIL2BAN_REASON 2>/dev/null || true)
  firewall_backend=$(state_get FIREWALL_BACKEND 2>/dev/null || printf 'unknown')
  firewall_manual=$(state_get FIREWALL_MANUAL_REQUIRED 2>/dev/null || printf 'true')
  firewall_zone=$(state_get FIREWALL_ZONE 2>/dev/null || true)
  case $firewall_backend in
    ufw) firewall_description='UFW 已启用，三个内部 TCP 端口已核验' ;;
    firewalld) firewall_description="firewalld 已启用，三个内部 TCP 端口已核验${firewall_zone:+（zone: ${firewall_zone}）}" ;;
    none) firewall_description='未检测到已启用的 UFW/firewalld，未修改主机防火墙' ;;
    ambiguous) firewall_description='主机防火墙状态存在歧义，未自动修改' ;;
    *) firewall_description='主机防火墙状态未知' ;;
  esac

  if [[ $MODE == nat ]]; then
    cert_fingerprint=$(openssl x509 -in "$CERT_DIR/server.crt" -outform DER | \
      openssl dgst -sha256 -r | awk '{print toupper($1)}') || return 1
    [[ $cert_fingerprint =~ ^[0-9A-F]{64}$ ]] || return 1
  fi

  state_set_many \
    PANEL_URL "$panel_url" \
    SUBSCRIPTION_URL "$XUI_SUBSCRIPTION_URL" \
    JSON_SUBSCRIPTION_URL "$XUI_JSON_SUBSCRIPTION_URL" \
    CLASH_SUBSCRIPTION_URL "$XUI_CLASH_SUBSCRIPTION_URL" \
    VLESS_URI "$vless_uri" || return 1
  if [[ -n $cert_fingerprint ]]; then
    state_set TLS_CERT_SHA256 "$cert_fingerprint" || return 1
  fi

  result_reset || return 1
  result_section '面板' || return 1
  result_add '面板地址' "$panel_url" || return 1
  result_add '面板用户名' "$PANEL_USERNAME" || return 1
  result_add '面板密码' "$PANEL_PASSWORD" || return 1
  result_add '3x-ui 版本' "$xui_version" || return 1
  result_add 'Xray Core 版本' "$xray_version" || return 1
  result_add '服务状态' 'x-ui active、自启已启用；Xray running，面板/订阅/入站本机校验通过' || return 1
  result_section '订阅' || return 1
  result_add 'Base64 订阅' "$XUI_SUBSCRIPTION_URL" || return 1
  result_add 'Xray JSON 订阅' "$XUI_JSON_SUBSCRIPTION_URL" || return 1
  result_add 'Clash/Mihomo 订阅' "$XUI_CLASH_SUBSCRIPTION_URL" || return 1
  result_section '客户端导入' || return 1
  result_add 'VLESS URI' "$vless_uri" || return 1
  result_section 'TCP 端口' || return 1
  result_add '面板 外部->内部' "${PANEL_EXTERNAL_PORT}->${PANEL_INTERNAL_PORT}" || return 1
  result_add 'VLESS 外部->内部' "${NODE_EXTERNAL_PORT}->${NODE_INTERNAL_PORT}" || return 1
  result_add '订阅 外部->内部' "${SUB_EXTERNAL_PORT}->${SUB_INTERNAL_PORT}" || return 1
  result_add '主机防火墙' "$firewall_description" || return 1
  if [[ $firewall_manual == true ]]; then
    result_add '手动放行' "确认 ${PANEL_INTERNAL_PORT}/tcp、${NODE_INTERNAL_PORT}/tcp、${SUB_INTERNAL_PORT}/tcp 已在主机防火墙放行" || return 1
  fi
  result_add '服务商入口' "确认外部 TCP 端口 ${PANEL_EXTERNAL_PORT}、${NODE_EXTERNAL_PORT}、${SUB_EXTERNAL_PORT} 已在安全组/NAT 后台开放；不需要 UDP" || return 1
  result_section '维护' || return 1
  result_add '管理命令' 'one-key-proxy' || return 1
  result_add '结果文件' "$RESULT_FILE" || return 1
  result_add '备份目录' "$BACKUP_DIR" || return 1
  result_add '公网映射状态' '仅完成 VPS 本机验证；NAT/安全组外网可达性需用户从外部确认' || return 1
  result_add 'Fail2ban 状态' "${fail2ban_status}${fail2ban_reason:+ (${fail2ban_reason})}" || return 1
  if [[ $MODE == nat ]]; then
    result_add '证书 SHA-256' "$cert_fingerprint" || return 1
    result_add '证书提示' '自签名证书；跳过验证会使面板和订阅失去服务端身份认证，请通过独立可信渠道核对上述指纹' || return 1
  else
    result_add 'DNS 提示' '未启用 DDNS；公网 IP 改变后请运行 one-key-proxy update-address' || return 1
  fi

}

display_completed_result() {
  local vless_uri mode
  [[ -r $RESULT_FILE ]] || return 1
  vless_uri=$(state_get VLESS_URI 2>/dev/null || true)
  mode=$(state_get MODE 2>/dev/null || true)
  heading '部署成功'
  cat "$RESULT_FILE" || return 1
  if [[ -n $vless_uri ]] && have_command qrencode; then
    printf '\nVLESS 二维码：\n'
    printf '%s' "$vless_uri" | qrencode -t ANSIUTF8 2>/dev/null || true
  fi
  if [[ $mode == nat ]]; then
    log_warn 'NAT 自签名订阅要求客户端开启“跳过证书验证/允许不安全证书”。'
  fi
}

stage_verify_and_result() {
  local public_host sub_id port inbound_tag
  public_host=$PUBLIC_IPV4
  [[ $MODE == public ]] && public_host=$FQDN
  if [[ $MODE == public ]] && ! public_dns_postcondition_ok; then
    log_error '公网域名的 AliDNS A/AAAA 记录未通过最终验收。'
    return 1
  fi
  sub_id=$(state_get SUB_ID) || return 1
  platform_service_is_active x-ui || {
    log_error 'x-ui 服务未运行。'
    return 1
  }
  for port in "$PANEL_INTERNAL_PORT" "$NODE_INTERNAL_PORT" "$SUB_INTERNAL_PORT"; do
    platform_port_is_listening "$port" tcp || {
      log_error "未检测到 ${port}/tcp 监听。"
      return 1
    }
  done
  wait_for_subscription "$public_host" "$sub_id" || {
    log_error '本机订阅 HTTPS 自检失败。'
    return 1
  }
  verify_subscription_formats "$public_host" "$sub_id" || {
    log_error 'JSON 或 Clash/Mihomo 订阅自检失败。'
    return 1
  }
  xui_check_required_endpoints || return 1
  verify_managed_inbound || {
    log_error 'VLESS TCP REALITY Vision 入站回读校验失败。'
    return 1
  }
  inbound_tag=$(state_get INBOUND_TAG) || return 1
  xui_verify_xray_runtime "$inbound_tag" "$NODE_INTERNAL_PORT" 15 2 || {
    log_error 'Xray Core 运行态或实际组装配置校验失败。'
    return 1
  }
  state_set XUI_XRAY_VERSION "$XUI_XRAY_VERSION" || return 1
  ensure_xui_service_autostart || return 1
  platform_service_is_active x-ui || return 1
  write_result
}

prepare_new_install() {
  config_collect || return 1
  config_confirm
  case $? in
    0) ;;
    2) log_info '已退出；安装器尚未修改系统（bootstrap 可能已补齐最小下载依赖）。'; return 2 ;;
    *) return 1 ;;
  esac

  stage_dependencies || return 1
  acquire_operation_lock || return 1
  if [[ -e $STATE_FILE || -L $STATE_FILE ]]; then
    log_error '获得操作锁后发现已有状态文件；请重新运行以按现有状态处理。'
    return 1
  fi
  safe_mkdirs || return 1
  state_init || return 1
  state_ensure_identity || return 1
  state_set MANAGED_BY one-key-proxy || return 1
  state_set CREATED_AT "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || return 1
  config_save_state || return 1
  secret_register "$PANEL_PASSWORD"
  [[ -n $ALI_ACCESS_KEY_SECRET ]] && secret_register "$ALI_ACCESS_KEY_SECRET"
  stage_mark_done configured || return 1
}

prepare_resume() {
  local choice status
  acquire_operation_lock || return 1
  state_ensure_identity || return 1
  register_known_secrets
  config_load_state || return 1
  reconcile_completed_stages || return 1
  heading '检测到未完成的 one-key-proxy 部署'
  config_summary
  while true; do
    printf '\n  C. 继续部署\n  M. 修改参数（仅限 3x-ui 尚未启动）\n  Q. 退出\n'
    read_tty choice '请选择' 'C' || return 1
    case ${choice^^} in
      C) return 0 ;;
      M)
        if stage_is_done xui || foreign_xui_exists; then
          log_warn '3x-ui 已启动；请先继续完成部署，再用 one-key-proxy 重配。'
          continue
        fi
        config_modify || return 1
        config_save_state || return 1
        for status in preflight certificate api firewall security verified completed; do
          stage_clear "$status" || return 1
        done
        config_summary
        ;;
      Q) return 2 ;;
      *) log_warn '请输入 C、M 或 Q。' ;;
    esac
  done
}

run_install_stages() {
  install_runtime_files || return 1
  run_stage compatibility stage_compatibility || return 1
  run_stage preflight stage_preflight || return 1
  run_stage certificate stage_certificate || return 1
  run_stage xui stage_xui_install || return 1
  run_stage api stage_api_configuration || return 1
  run_stage firewall stage_firewall || return 1
  run_stage security stage_security || return 1
  run_stage verified stage_verify_and_result || return 1
  stage_mark_done completed || return 1
  display_completed_result || log_warn "部署已完成，但无法显示结果文件：${RESULT_FILE}"
  sanitize_log_file || true
}

main() {
  local status
  case $INSTALL_ACTION in
    ''|--resume) ;;
    --defaults-file)
      [[ $# == 2 ]] || { usage >&2; return 2; }
      platform_require_root || return 1
      config_load_defaults_file "$2" || return 1
      ;;
    -h|--help) usage; return 0 ;;
    *) usage >&2; return 2 ;;
  esac
  require_tty || return 1
  platform_require_root || return 1
  platform_detect || return 1

  if [[ $PLATFORM_FAMILY == arch ]]; then
    log_warn 'Arch 安装依赖时会执行 pacman -Syu，可能升级整个系统。'
  fi

  if state_is_managed; then
    if stage_is_done completed; then
      [[ $INSTALL_ACTION != --defaults-file ]] || return 0
      exec bash "${RUNTIME_DIR}/maintenance.sh" "${@:2}"
    fi
    prepare_resume
    status=$?
    ((status == 0)) || { ((status == 2)) && return 0; return "$status"; }
  else
    if [[ -e $STATE_FILE || -L $STATE_FILE ]]; then
      recover_abandoned_initial_state || {
        die '检测到无法安全恢复的不完整 one-key-proxy 所有权状态；安装已停止。'
        return 1
      }
    fi
    if foreign_xui_exists; then
      die '检测到非本项目管理的 3x-ui；为避免覆盖，安装已停止。'
      return 1
    fi
    prepare_new_install
    status=$?
    ((status == 0)) || { ((status == 2)) && return 0; return "$status"; }
  fi
  run_install_stages
}

install_entrypoint() {
  local status
  main "$@"
  status=$?
  if ((status != 0)); then
    sanitize_log_file 2>/dev/null || true
    if [[ -r $STATE_FILE ]]; then
      log_error '部署未完成。修复提示的问题后，重新运行同一条一键命令即可续跑。'
    fi
    return "$status"
  fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  install_entrypoint "$@"
fi
