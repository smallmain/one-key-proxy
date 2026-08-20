#!/usr/bin/env bash

set -Euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

OKP_MAINTENANCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
OKP_MAINTENANCE_TEST_MODE=false
OKP_MAINTENANCE_CALLER=''
OKP_MAINTENANCE_CALLER_DIR=''

# OKP_TEST_MODE is an internal unit-test facility, not a supported runtime
# setting. Accept it only when this file is sourced by a repository test harness
# carrying the matching sentinel. Direct execution always uses production paths.
if ((${#BASH_SOURCE[@]} > 1)); then
    OKP_MAINTENANCE_CALLER=${BASH_SOURCE[1]}
fi
if [[ ${BASH_SOURCE[0]} != "$0" && \
    ${OKP_TEST_MODE:-false} == true && \
    ${OKP_INTERNAL_TEST_HARNESS:-} == one-key-proxy-tests-v1 && \
    ${OKP_MAINTENANCE_CALLER##*/} == test_*.sh ]]; then
    OKP_MAINTENANCE_CALLER_DIR=$(cd -- "$(dirname -- "$OKP_MAINTENANCE_CALLER")" 2>/dev/null && pwd -P)
    if [[ $OKP_MAINTENANCE_CALLER_DIR == "$OKP_MAINTENANCE_DIR/tests" ]]; then
        OKP_MAINTENANCE_TEST_MODE=true
    fi
fi
unset OKP_INTERNAL_TEST_HARNESS
if [[ $OKP_MAINTENANCE_TEST_MODE == true ]]; then
    OKP_PRODUCTION_MODE=false
else
    unset OKP_TEST_MODE
    OKP_PRODUCTION_MODE=true
fi
readonly OKP_MAINTENANCE_TEST_MODE

# Maintenance integration contract
# --------------------------------
# Optional integration libraries may define the hooks below. A hook that changes
# network identity or ports MUST print its proposed values and obtain final user
# confirmation before applying them.
#
#   okp_hook_show_information
#   okp_hook_diagnostics
#   okp_hook_before_backup STAGING_DIR    # quiesce DB writes or create a snapshot
#   okp_hook_backup_paths                 # absolute paths, one per output line
#   okp_hook_backup_prepare STAGING_DIR   # only inside a path from backup_paths
#   okp_hook_after_backup                 # resume services / remove snapshots
#   okp_hook_restore_preflight METADATA ROOTFS
#   okp_hook_before_restore ROOTFS_DIR
#   okp_hook_after_restore
#   okp_hook_verify_restore
#   okp_hook_reconfigure SCOPE            # SCOPE: all/address/ports/domain
#   okp_hook_renew_certificate
#   okp_hook_project_update_info
#   okp_hook_project_update
#   okp_hook_xui_update_info
#   okp_hook_xui_update
#   okp_hook_settle_pending_xui_update
#   okp_hook_rotate_panel_credentials
#   okp_hook_create_replacement_client    # MUST keep all old clients active
#   okp_hook_delete_old_client            # separate, explicitly confirmed action
#   okp_hook_rotate_api_token
#   okp_hook_uninstall_component NAME     # must support names listed below
#
# Hooks return zero only after the requested operation and their state/result-file
# updates have completed. Reconfiguration must show a diff, confirm, and invoke
# maintenance_backup_create before applying changes. Backup path hooks must not
# print log messages to stdout.

if [[ $OKP_MAINTENANCE_TEST_MODE == true ]]; then
    : "${CONFIG_DIR:=/etc/one-key-proxy}"
    : "${STATE_FILE:=${CONFIG_DIR}/state.env}"
    : "${CERT_DIR:=${CONFIG_DIR}/certs}"
    : "${LOG_FILE:=/var/log/one-key-proxy.log}"
    : "${BACKUP_DIR:=/var/backups/one-key-proxy}"
    : "${RESULT_FILE:=/root/one-key-proxy-result.txt}"
    : "${OKP_OPERATION_LOCK_FILE:=/run/one-key-proxy/operation.lock}"
else
    CONFIG_DIR=/etc/one-key-proxy
    STATE_FILE=/etc/one-key-proxy/state.env
    CERT_DIR=/etc/one-key-proxy/certs
    LOG_FILE=/var/log/one-key-proxy.log
    BACKUP_DIR=/var/backups/one-key-proxy
    RESULT_FILE=/root/one-key-proxy-result.txt
    OKP_OPERATION_LOCK_FILE=/run/one-key-proxy/operation.lock
fi

OKP_MAINTENANCE_ENTRY_COMMAND=${1-}
declare -a OKP_MAINTENANCE_TEMP_PATHS=()
declare -a OKP_RESTORE_PATHS=()
declare -a OKP_RESTORE_DESTS=()
declare -a OKP_RESTORE_OLDS=()
declare -a OKP_RESTORE_INCOMINGS=()
declare -a OKP_RESTORE_HAD_OLD=()
OKP_BACKUP_RESUME_MODE=''
OKP_RESTORE_RESUME_MODE=''
OKP_RESTORE_TRANSACTION_ACTIVE=false
OKP_RESTORE_ROOTFS=''
if [[ ${OKP_MAINTENANCE_REEXECED:-false} == true && \
    ${OKP_OPERATION_LOCK_FD:-} =~ ^[0-9]+$ && \
    -e /proc/$$/fd/${OKP_OPERATION_LOCK_FD} && \
    $(readlink "/proc/$$/fd/${OKP_OPERATION_LOCK_FD}" 2>/dev/null) == "$OKP_OPERATION_LOCK_FILE" ]]; then
    :
else
    OKP_OPERATION_LOCK_FD=''
    OKP_MAINTENANCE_REEXECED=false
fi
OKP_MAINTENANCE_FATAL=false

maintenance_temp_register() {
    local path=$1

    [[ -n $path ]] || return 1
    OKP_MAINTENANCE_TEMP_PATHS+=("$path")
}

maintenance_temp_unregister() {
    local wanted=$1
    local path
    local -a remaining=()

    for path in "${OKP_MAINTENANCE_TEMP_PATHS[@]}"; do
        [[ $path == "$wanted" ]] || remaining+=("$path")
    done
    OKP_MAINTENANCE_TEMP_PATHS=("${remaining[@]}")
}

maintenance_cleanup_temp_paths() {
    local path
    local temp_root=${TMPDIR:-/tmp}
    local restore_can_resume=true

    if [[ ${OKP_RESTORE_TRANSACTION_ACTIVE:-false} == true ]] && \
        declare -F _maintenance_restore_rollback >/dev/null 2>&1; then
        if declare -F _maintenance_restore_pause_for_rollback >/dev/null 2>&1 && \
            _maintenance_restore_pause_for_rollback; then
            if ! _maintenance_restore_rollback; then
                OKP_MAINTENANCE_FATAL=true
                restore_can_resume=false
                _maintenance_log_error '退出清理无法完整回滚恢复事务；服务保持停止，请使用保护备份人工处理。'
            fi
        else
            OKP_MAINTENANCE_FATAL=true
            restore_can_resume=false
            _maintenance_log_error '退出清理无法安全停止服务；未在运行中回滚数据库，请使用保护备份人工处理。'
        fi
    fi
    if [[ ${OKP_RESTORE_TRANSACTION_ACTIVE:-false} == true ]]; then
        restore_can_resume=false
    fi
    if [[ $restore_can_resume == true && -n ${OKP_RESTORE_RESUME_MODE-} ]] && \
        declare -F _maintenance_restore_resume >/dev/null 2>&1; then
        _maintenance_restore_resume || true
    fi
    if [[ -n ${OKP_BACKUP_RESUME_MODE-} ]] && declare -F _maintenance_backup_resume >/dev/null 2>&1; then
        _maintenance_backup_resume || true
    fi
    for path in "${OKP_MAINTENANCE_TEMP_PATHS[@]}"; do
        case "$path" in
            "${temp_root%/}"/one-key-proxy-*) rm -rf -- "$path" ;;
            *) _maintenance_log_warn "拒绝清理不符合命名约束的临时路径: ${path}" ;;
        esac
    done
    OKP_MAINTENANCE_TEMP_PATHS=()
    maintenance_operation_unlock
}

maintenance_operation_unlock() {
    if [[ -n ${OKP_OPERATION_LOCK_FD-} ]]; then
        flock -u "$OKP_OPERATION_LOCK_FD" 2>/dev/null || true
        exec {OKP_OPERATION_LOCK_FD}>&-
        OKP_OPERATION_LOCK_FD=''
    fi
}

_maintenance_lock_error() {
    if declare -F _maintenance_log_error >/dev/null 2>&1; then
        _maintenance_log_error "$*"
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
}

maintenance_operation_lock() {
    local attempt owner mode links
    local lock_file=$OKP_OPERATION_LOCK_FILE
    local lock_dir=${lock_file%/*}

    [[ -z ${OKP_OPERATION_LOCK_FD-} ]] || return 0
    command -v flock >/dev/null 2>&1 || {
        _maintenance_lock_error '缺少 flock，拒绝执行可能与备份、恢复或证书续签并发的操作。'
        return 1
    }
    if [[ -L $lock_dir || ( -e $lock_dir && ! -d $lock_dir ) ]]; then
        _maintenance_lock_error "拒绝使用不安全的操作锁目录: ${lock_dir}"
        return 1
    fi
    install -d -m 0700 -- "$lock_dir" || return 1
    chmod 0700 -- "$lock_dir" || return 1
    chown 0:0 -- "$lock_dir" || return 1
    owner=$(stat -c '%u' -- "$lock_dir" 2>/dev/null) || return 1
    mode=$(stat -c '%a' -- "$lock_dir" 2>/dev/null) || return 1
    [[ -d $lock_dir && ! -L $lock_dir && $owner == 0 && $mode == 700 ]] || return 1
    if [[ -L $lock_file || ( -e $lock_file && ! -f $lock_file ) ]]; then
        _maintenance_lock_error "拒绝使用符号链接操作锁: ${lock_file}"
        return 1
    fi
    exec {OKP_OPERATION_LOCK_FD}>"$lock_file" || return 1
    if [[ -L $lock_file || ! -f $lock_file ]] || \
        ! chmod 0600 "$lock_file" || ! chown 0:0 "$lock_file"; then
        exec {OKP_OPERATION_LOCK_FD}>&-
        OKP_OPERATION_LOCK_FD=''
        return 1
    fi
    owner=$(stat -c '%u' -- "$lock_file" 2>/dev/null) || return 1
    mode=$(stat -c '%a' -- "$lock_file" 2>/dev/null) || return 1
    links=$(stat -c '%h' -- "$lock_file" 2>/dev/null) || return 1
    [[ $owner == 0 && $mode == 600 && $links == 1 ]] || return 1
    for ((attempt = 0; attempt < 100; attempt++)); do
        if flock -n "$OKP_OPERATION_LOCK_FD"; then
            return 0
        fi
        sleep 0.1
    done
    maintenance_operation_unlock
    _maintenance_lock_error '另一个 one-key-proxy 维护或证书操作正在运行。'
    return 1
}

maintenance_command_mutates() {
    case ${1-} in
        info | status | doctor | help | -h | --help) return 1 ;;
        *) return 0 ;;
    esac
}

# Mutating commands must hold the global lock before any replaceable runtime
# library is sourced. The same FD remains open through maintenance_main.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        printf 'ERROR: 维护命令必须由 root 执行。\n' >&2
        exit 1
    fi
    umask 077
    if maintenance_command_mutates "${1-}"; then
        maintenance_operation_lock || exit 1
        if [[ ${OKP_MAINTENANCE_REEXECED:-false} != true && \
            $OKP_MAINTENANCE_DIR == /usr/local/lib/one-key-proxy ]]; then
            OKP_MAINTENANCE_REEXECED=true
            export OKP_MAINTENANCE_REEXECED OKP_OPERATION_LOCK_FD
            exec bash /usr/local/lib/one-key-proxy/maintenance.sh "$@"
        fi
    fi
fi

_maintenance_library_is_secure() {
    local path=$1 expected_type=$2 owner mode

    [[ ! -L $path ]] || return 1
    case $expected_type in
        directory) [[ -d $path ]] || return 1 ;;
        file) [[ -f $path && -r $path ]] || return 1 ;;
        *) return 1 ;;
    esac
    if [[ $OKP_MAINTENANCE_TEST_MODE == true ]]; then
        return 0
    fi
    owner=$(stat -c '%u' -- "$path" 2>/dev/null) || return 1
    mode=$(stat -c '%a' -- "$path" 2>/dev/null) || return 1
    [[ $owner == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
    (( ((8#$mode) & 0022) == 0 ))
}

_maintenance_source_libraries() {
    local library_dir="${OKP_MAINTENANCE_DIR}/lib" library
    local -a libraries=(
        common.sh
        state.sh
        platform.sh
        config.sh
        alidns.sh
        cert.sh
        3xui.sh
        fail2ban.sh
        integration.sh
    )

    _maintenance_library_is_secure "$OKP_MAINTENANCE_DIR" directory || return 1
    _maintenance_library_is_secure "$library_dir" directory || return 1
    for library in "${libraries[@]}"; do
        _maintenance_library_is_secure "${library_dir}/${library}" file || return 1
    done
    for library in "${libraries[@]}"; do
        # shellcheck disable=SC1090
        source "${library_dir}/${library}" || return 1
    done
    declare -F state_get >/dev/null 2>&1 && \
        declare -F okp_hook_show_information >/dev/null 2>&1
}

_maintenance_source_libraries || {
    printf 'ERROR: 无法加载 one-key-proxy 函数库。\n' >&2
    [[ ${BASH_SOURCE[0]} != "$0" ]] && return 1
    exit 1
}

_maintenance_log_info() {
    if declare -F safe_log_info >/dev/null 2>&1; then
        safe_log_info "$*"
    elif declare -F log_info >/dev/null 2>&1; then
        log_info "$*"
    else
        printf '%s\n' "$*"
    fi
}

_maintenance_log_warn() {
    if declare -F safe_log_warn >/dev/null 2>&1; then
        safe_log_warn "$*"
    elif declare -F log_warn >/dev/null 2>&1; then
        log_warn "$*"
    else
        printf 'WARN: %s\n' "$*" >&2
    fi
}

_maintenance_log_error() {
    if declare -F safe_log_error >/dev/null 2>&1; then
        safe_log_error "$*"
    elif declare -F log_error >/dev/null 2>&1; then
        log_error "$*"
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
}

maintenance_require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        _maintenance_log_error '维护命令必须由 root 执行。'
        return 1
    fi
}

maintenance_require_tty() {
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        _maintenance_log_error '维护菜单需要交互式终端。'
        return 1
    fi
}

maintenance_pause() {
    printf '\n按 Enter 返回菜单...' >/dev/tty
    IFS= read -r _ </dev/tty || true
}

maintenance_read() {
    local variable_name=$1
    local prompt=$2
    local default=${3-}
    local value

    if [[ -n $default ]]; then
        printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
    else
        printf '%s: ' "$prompt" >/dev/tty
    fi
    IFS= read -r value </dev/tty || return 1
    [[ -n $value ]] || value=$default
    printf -v "$variable_name" '%s' "$value"
}

maintenance_confirm() {
    local prompt=$1
    local default=${2:-n}
    local answer suffix='[y/N]'

    [[ $default == y ]] && suffix='[Y/n]'
    printf '%s %s ' "$prompt" "$suffix" >/dev/tty
    IFS= read -r answer </dev/tty || return 1
    answer=${answer:-$default}
    [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]]
}

maintenance_confirm_phrase() {
    local prompt=$1
    local phrase=$2
    local answer

    printf '%s\n请输入 %s 以继续: ' "$prompt" "$phrase" >/dev/tty
    IFS= read -r answer </dev/tty || return 1
    [[ $answer == "$phrase" ]]
}

maintenance_double_confirm() {
    local prompt=$1
    local phrase=$2

    maintenance_confirm "$prompt" n || return 1
    maintenance_confirm_phrase '该操作可能导致服务中断，第二次确认。' "$phrase"
}

maintenance_hook_exists() {
    declare -F "${1-}" >/dev/null 2>&1
}

maintenance_require_hook() {
    local hook=$1
    local feature=$2

    if ! maintenance_hook_exists "$hook"; then
        _maintenance_log_error "当前安装缺少 ${feature} 集成接口 (${hook})。"
        return 1
    fi
}

maintenance_heading() {
    if declare -F heading >/dev/null 2>&1; then
        heading "$*"
    else
        printf '\n%s\n' "$*"
    fi
}

maintenance_show_information() {
    maintenance_heading '部署信息'
    if [[ -r $RESULT_FILE ]]; then
        printf '结果文件: %s (仅 root 可读)\n\n' "$RESULT_FILE"
        cat -- "$RESULT_FILE"
    else
        _maintenance_log_warn "结果文件不存在: ${RESULT_FILE}"
        printf '\n已保存状态（敏感字段已隐藏）:\n'
        state_dump_redacted
    fi

    if maintenance_hook_exists okp_hook_show_information; then
        printf '\n集成信息:\n'
        okp_hook_show_information || return 1
    fi
}

_maintenance_show_service_status() {
    local service_name
    service_name=$(state_get XUI_SERVICE_NAME 2>/dev/null) || service_name='x-ui'

    printf '3x-ui 服务 (%s): ' "$service_name"
    if declare -F platform_service_is_active >/dev/null 2>&1; then
        if platform_service_is_active "$service_name"; then
            printf '运行中\n'
        else
            printf '未运行\n'
        fi
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl is-active "$service_name" 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$service_name" status 2>/dev/null || true
    else
        printf '无法检测\n'
    fi
}

# Returns 0 for active, 1 for known inactive, and 2 when the service probe is
# unavailable or unreliable. platform_service_is_active may expose native
# systemd/OpenRC codes (often 3 for stopped), so callers must use this wrapper.
_maintenance_service_activity() {
    local service_name=$1

    declare -F platform_service_exists >/dev/null 2>&1 || return 2
    declare -F platform_service_is_active >/dev/null 2>&1 || return 2
    platform_service_exists "$service_name" || return 2
    if platform_service_is_active "$service_name"; then
        return 0
    fi
    return 1
}

_maintenance_show_certificate_status() {
    local cert_file subject expires

    cert_file=$(state_get TLS_CERT_FILE 2>/dev/null) || cert_file=''
    [[ -n $cert_file ]] || cert_file="${CERT_DIR}/server.crt"
    printf 'TLS 证书: %s\n' "$cert_file"
    if [[ ! -r $cert_file ]]; then
        printf '  状态: 不存在或不可读\n'
        return 0
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        printf '  状态: 已存在（未安装 openssl，无法检查）\n'
        return 0
    fi
    subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null) || subject='证书解析失败'
    expires=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null) || expires='notAfter=未知'
    printf '  %s\n  %s\n' "$subject" "$expires"
    if openssl x509 -in "$cert_file" -noout -checkend 604800 >/dev/null 2>&1; then
        printf '  状态: 至少 7 天内有效\n'
    else
        printf '  状态: 已过期或将在 7 天内过期\n'
    fi
}

_maintenance_show_listeners() {
    local key port
    local -a ports=()

    while IFS= read -r key; do
        case "$key" in
            *_INTERNAL_PORT | INTERNAL_*_PORT)
                port=$(state_get "$key" 2>/dev/null) || continue
                [[ $port =~ ^[0-9]+$ ]] && ports+=("$port")
                ;;
        esac
    done < <(state_keys)

    ((${#ports[@]} > 0)) || return 0
    printf '内部监听端口:\n'
    for port in "${ports[@]}"; do
        if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | awk -v p=":${port}" '$4 ~ p "$" { found=1 } END { exit !found }'; then
            printf '  TCP %s: 正在监听\n' "$port"
        else
            printf '  TCP %s: 未检测到监听\n' "$port"
        fi
    done
}

maintenance_diagnostics() {
    local deployment_mode

    maintenance_heading '状态与诊断'
    printf '安装标识: '
    state_get INSTALLATION_ID 2>/dev/null || printf '未设置'
    printf '\n原始机器标识: '
    state_get ORIGINAL_MACHINE_ID 2>/dev/null || printf '未设置'
    printf '\n当前机器标识: %s\n' "$(state_machine_id)"
    deployment_mode=$(state_get MODE 2>/dev/null) || deployment_mode='未知'
    printf '部署模式: %s' "$deployment_mode"
    printf '\n'

    _maintenance_show_service_status
    _maintenance_show_certificate_status
    _maintenance_show_listeners

    printf '\n阶段状态:\n'
    if [[ -d ${CONFIG_DIR}/stages ]]; then
        local marker found=false
        for marker in "${CONFIG_DIR}/stages"/*.done; do
            [[ -e $marker ]] || continue
            found=true
            printf '  [完成] %s\n' "$(basename -- "$marker" .done)"
        done
        [[ $found == true ]] || printf '  尚无阶段标记\n'
    else
        printf '  阶段目录不存在\n'
    fi

}

maintenance_doctor() {
    maintenance_diagnostics || return 1
    if maintenance_hook_exists okp_hook_diagnostics; then
        printf '\n集成诊断:\n'
        okp_hook_diagnostics || return 1
    fi
}

_maintenance_sha256() {
    local file=$1
    local output digest

    if command -v sha256sum >/dev/null 2>&1; then
        output=$(sha256sum -- "$file") || return 1
        digest=${output%%[[:space:]]*}
    elif command -v shasum >/dev/null 2>&1; then
        output=$(shasum -a 256 -- "$file") || return 1
        digest=${output%%[[:space:]]*}
    elif command -v openssl >/dev/null 2>&1; then
        output=$(openssl dgst -sha256 "$file") || return 1
        digest=${output##* }
    else
        return 1
    fi
    [[ $digest =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

_maintenance_backup_seen() {
    local wanted=$1
    local existing

    for existing in "${OKP_BACKUP_PATHS[@]}"; do
        if [[ $existing == "$wanted" || $wanted == "${existing}/"* ]]; then
            return 0
        fi
    done
    return 1
}

_maintenance_path_is_safe() {
    local path=$1

    [[ $path == /* && $path != *$'\n'* && $path != *$'\r'* ]] || return 1
    case "$path" in
        / | *//* | */../* | */.. | */./* | */.) return 1 ;;
    esac
    case "$path" in
        "$CONFIG_DIR" | "${CONFIG_DIR%/}/"* | "$RESULT_FILE" | \
            /etc/x-ui | /etc/x-ui/* | \
            /usr/local/x-ui | /usr/local/x-ui/* | \
            /usr/local/lib/one-key-proxy | /usr/local/lib/one-key-proxy/* | \
            /usr/local/bin/one-key-proxy | \
            /usr/local/bin/one-key-proxy-acme-renew | \
            /usr/local/bin/one-key-proxy-reload-x-ui | \
            /etc/systemd/system/x-ui.service | \
            /etc/systemd/system/one-key-proxy-acme.service | \
            /etc/systemd/system/one-key-proxy-acme.timer | \
            /etc/init.d/x-ui | \
            /etc/periodic/daily/one-key-proxy-acme | \
            /etc/fail2ban/jail.d/one-key-proxy.local | \
            /etc/fail2ban/filter.d/one-key-proxy.conf) return 0 ;;
        *) return 1 ;;
    esac
}

_maintenance_backup_add_path() {
    local source_path=$1
    local rootfs=$2
    local destination

    _maintenance_path_is_safe "$source_path" || {
        _maintenance_log_error "备份 hook 返回了非法路径。"
        return 1
    }
    local existing
    for existing in "${OKP_BACKUP_PATHS[@]}"; do
        if [[ $existing == "${source_path%/}/"* ]]; then
            _maintenance_log_error "备份路径互相嵌套且顺序不安全: ${source_path} / ${existing}"
            return 1
        fi
    done
    [[ -e $source_path || -L $source_path ]] || return 0
    _maintenance_backup_seen "$source_path" && return 0
    OKP_BACKUP_PATHS+=("$source_path")

    destination="${rootfs}${source_path}"
    install -d -m 0700 -- "$(dirname -- "$destination")" || return 1
    cp -a -- "$source_path" "$destination"
}

_maintenance_metadata_write() {
    local file=$1
    local key=$2
    local value=$3

    _state_validate_key "$key" || return 1
    printf '%s=%s\n' "$key" "$(_state_encode "$value")" >>"$file"
}

_maintenance_validate_rootfs_coverage() {
    local rootfs=$1
    local entry absolute_path managed_path covered

    while IFS= read -r -d '' entry; do
        absolute_path=${entry#"$rootfs"}
        covered=false
        for managed_path in "${OKP_BACKUP_PATHS[@]}"; do
            if [[ $absolute_path == "$managed_path" || \
                $absolute_path == "${managed_path%/}/"* ]]; then
                covered=true
                break
            fi
        done
        if [[ $covered != true ]]; then
            _maintenance_log_error "备份 hook 写入了未登记的恢复路径: ${absolute_path}"
            return 1
        fi
    done < <(find "$rootfs" -mindepth 1 ! -type d -print0)
}

_maintenance_backup_quiesce() {
    local staging=$1
    local service_name activity_status

    OKP_BACKUP_RESUME_MODE=''
    if maintenance_hook_exists okp_hook_before_backup; then
        OKP_BACKUP_RESUME_MODE='hook'
        if ! maintenance_hook_exists okp_hook_after_backup; then
            OKP_BACKUP_RESUME_MODE=''
            _maintenance_log_error '定义了 okp_hook_before_backup，但缺少配对的 okp_hook_after_backup。'
            return 1
        fi
        if ! okp_hook_before_backup "$staging"; then
            _maintenance_backup_resume || true
            return 1
        fi
        return 0
    fi

    service_name=$(state_get XUI_SERVICE_NAME 2>/dev/null) || service_name='x-ui'
    if _maintenance_service_activity "$service_name"; then
        _maintenance_log_info '暂时停止 3x-ui，以创建一致的数据库备份。'
        OKP_BACKUP_RESUME_MODE="platform:${service_name}"
        if ! platform_service_stop "$service_name"; then
            OKP_BACKUP_RESUME_MODE=''
            return 1
        fi
    else
        activity_status=$?
        if ((activity_status != 1)); then
            _maintenance_log_error '无法可靠确定 3x-ui 服务状态，备份已取消。'
            return 1
        fi
    fi
}

_maintenance_backup_resume() {
    local mode=${OKP_BACKUP_RESUME_MODE-}
    local service_name
    local status=0

    case "$mode" in
        '') return 0 ;;
        hook)
            if maintenance_hook_exists okp_hook_after_backup; then
                okp_hook_after_backup || status=$?
            fi
            ;;
        platform:*)
            service_name=${mode#platform:}
            platform_service_start "$service_name" || status=$?
            ;;
        *)
            _maintenance_log_error "未知的备份恢复模式: ${mode}"
            return 1
            ;;
    esac
    if ((status == 0)); then
        OKP_BACKUP_RESUME_MODE=''
    fi
    return "$status"
}

maintenance_backup_prune() {
    local archive index
    local -a archives=()

    while IFS= read -r archive; do
        [[ -n $archive ]] && archives+=("$archive")
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup-*.tar.gz' -print 2>/dev/null | sort -r)

    for ((index = 5; index < ${#archives[@]}; index++)); do
        rm -f -- "${archives[index]}" "${archives[index]}.sha256" || return 1
    done
}

maintenance_backup_create() {
    local staging rootfs metadata path_list managed_paths timestamp installation_id machine_id
    local archive checksum xui_db_path xui_version system_arch status=0
    local -a default_paths=()
    OKP_BACKUP_PATHS=()
    LAST_BACKUP_PATH=''

    maintenance_require_root || return 1
    state_ensure_identity || return 1
    command -v tar >/dev/null 2>&1 || {
        _maintenance_log_error '创建备份需要 tar。'
        return 1
    }

    install -d -m 0700 -- "$BACKUP_DIR" || return 1
    staging=$(mktemp -d "${TMPDIR:-/tmp}/one-key-proxy-backup.XXXXXX") || return 1
    maintenance_temp_register "$staging" || return 1
    chmod 0700 "$staging"
    rootfs="${staging}/rootfs"
    metadata="${staging}/metadata.env"
    path_list="${staging}/hook-paths.txt"
    managed_paths="${staging}/paths.list"
    install -d -m 0700 -- "$rootfs"
    : >"$metadata"
    : >"$managed_paths"
    chmod 0600 "$metadata"
    chmod 0600 "$managed_paths"

    if ! _maintenance_backup_quiesce "$staging"; then
        rm -rf -- "$staging"
        maintenance_temp_unregister "$staging"
        _maintenance_log_error '无法冻结 3x-ui 数据写入，备份已取消。'
        return 1
    fi

    default_paths+=("$CONFIG_DIR")
    [[ -e $RESULT_FILE ]] && default_paths+=("$RESULT_FILE")
    [[ -e /etc/x-ui ]] && default_paths+=('/etc/x-ui')
    if xui_db_path=$(state_get XUI_DB_PATH 2>/dev/null) && [[ -n $xui_db_path ]]; then
        default_paths+=("$xui_db_path")
    fi

    local default_path
    for default_path in "${default_paths[@]}"; do
        _maintenance_backup_add_path "$default_path" "$rootfs" || status=$?
        ((status == 0)) || break
    done

    if ((status == 0)) && maintenance_hook_exists okp_hook_backup_paths; then
        if ! okp_hook_backup_paths >"$path_list"; then
            _maintenance_log_error '备份路径 hook 执行失败。'
            status=1
        else
            local hook_path
            while IFS= read -r hook_path || [[ -n $hook_path ]]; do
                [[ -n $hook_path ]] || continue
                _maintenance_backup_add_path "$hook_path" "$rootfs" || {
                    status=$?
                    break
                }
            done <"$path_list"
        fi
    fi

    if ((status == 0)) && maintenance_hook_exists okp_hook_backup_prepare; then
        okp_hook_backup_prepare "$staging" || status=$?
    fi
    if ((status == 0)); then
        _maintenance_validate_rootfs_coverage "$rootfs" || status=$?
    fi
    if ! _maintenance_backup_resume; then
        _maintenance_log_error '备份复制完成，但恢复服务或清理快照失败。'
        status=1
    fi

    installation_id=$(state_get INSTALLATION_ID 2>/dev/null) || status=1
    machine_id=$(state_get ORIGINAL_MACHINE_ID 2>/dev/null) || status=1
    xui_version=$(state_get XUI_VERSION 2>/dev/null) || xui_version=''
    system_arch=$(uname -m 2>/dev/null) || status=1
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || status=1
    if ((status == 0)); then
        local managed_path
        for managed_path in "${OKP_BACKUP_PATHS[@]}"; do
            printf '%s\n' "$(_state_encode "$managed_path")" >>"$managed_paths" || {
                status=1
                break
            }
        done
        _maintenance_metadata_write "$metadata" BACKUP_FORMAT '1' || status=1
        _maintenance_metadata_write "$metadata" PROJECT_NAME 'one-key-proxy' || status=1
        _maintenance_metadata_write "$metadata" INSTALLATION_ID "$installation_id" || status=1
        _maintenance_metadata_write "$metadata" ORIGINAL_MACHINE_ID "$machine_id" || status=1
        _maintenance_metadata_write "$metadata" CREATED_AT "$timestamp" || status=1
        _maintenance_metadata_write "$metadata" SYSTEM_ARCH "$system_arch" || status=1
        _maintenance_metadata_write "$metadata" XUI_VERSION "$xui_version" || status=1
    fi

    local archive_number=0
    local archive_base
    archive_base="${BACKUP_DIR}/backup-$(date -u '+%Y%m%dT%H%M%SZ')-${installation_id:0:12}"
    archive="${archive_base}.tar.gz"
    while [[ -e $archive || -e ${archive}.sha256 ]]; do
        ((archive_number += 1))
        archive="${archive_base}-${archive_number}.tar.gz"
    done
    if ((status == 0)); then
        tar -C "$staging" -czf "$archive" metadata.env paths.list rootfs || status=$?
    fi
    if ((status == 0)); then
        _maintenance_validate_archive_entries "$archive" || status=$?
    fi
    if ((status == 0)); then
        chmod 0600 "$archive" || status=$?
        checksum=$(_maintenance_sha256 "$archive") || status=$?
    fi
    if ((status == 0)); then
        printf '%s  %s\n' "$checksum" "$(basename -- "$archive")" >"${archive}.sha256" || status=$?
        chmod 0600 "${archive}.sha256" || status=$?
    fi

    rm -rf -- "$staging"
    maintenance_temp_unregister "$staging"
    if ((status != 0)); then
        rm -f -- "$archive" "${archive}.sha256"
        _maintenance_log_error '完整备份创建失败。'
        return "$status"
    fi
    maintenance_backup_prune || return 1
    LAST_BACKUP_PATH=$archive
    _maintenance_log_info "完整备份已创建: ${archive}"
}

maintenance_backup_list() {
    local archive index=0
    local -a archives=()

    while IFS= read -r archive; do
        [[ -n $archive ]] && archives+=("$archive")
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup-*.tar.gz' -print 2>/dev/null | sort -r)

    for archive in "${archives[@]}"; do
        ((index += 1))
        printf '%d. %s\n' "$index" "$(basename -- "$archive")"
    done
    ((${#archives[@]} > 0))
}

_maintenance_choose_backup() {
    local variable_name=$1
    local selection archive
    local -a archives=()

    while IFS= read -r archive; do
        [[ -n $archive ]] && archives+=("$archive")
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup-*.tar.gz' -print 2>/dev/null | sort -r)
    ((${#archives[@]} > 0)) || {
        _maintenance_log_error '没有可恢复的备份。'
        return 1
    }
    local index
    for ((index = 0; index < ${#archives[@]}; index++)); do
        printf '%d. %s\n' "$((index + 1))" "$(basename -- "${archives[index]}")"
    done
    maintenance_read selection '选择备份编号' '1' || return 1
    [[ $selection =~ ^[0-9]+$ ]] || return 1
    ((selection >= 1 && selection <= ${#archives[@]})) || return 1
    printf -v "$variable_name" '%s' "${archives[selection - 1]}"
}

_maintenance_verify_backup_checksum() {
    local archive=$1
    local expected actual

    [[ -r ${archive}.sha256 ]] || {
        _maintenance_log_error "备份校验文件缺失: ${archive}.sha256"
        return 1
    }
    IFS=' ' read -r expected _ <"${archive}.sha256" || return 1
    [[ $expected =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    actual=$(_maintenance_sha256 "$archive") || return 1
    [[ ${actual,,} == "${expected,,}" ]] || {
        _maintenance_log_error '备份 SHA-256 校验失败，拒绝恢复。'
        return 1
    }
}

# Removing a temporary listing immediately before returning from a validation
# failure is intentional; no subsequent read occurs on that file descriptor.
# shellcheck disable=SC2094
_maintenance_validate_archive_entries() {
    local archive=$1
    local listing verbose entry verbose_line entry_type

    listing=$(mktemp "${TMPDIR:-/tmp}/one-key-proxy-tar-list.XXXXXX") || return 1
    verbose=$(mktemp "${TMPDIR:-/tmp}/one-key-proxy-tar-types.XXXXXX") || {
        rm -f -- "$listing"
        return 1
    }
    if ! tar -tzf "$archive" >"$listing"; then
        rm -f -- "$listing" "$verbose"
        return 1
    fi
    if ! tar -tvzf "$archive" >"$verbose"; then
        rm -f -- "$listing" "$verbose"
        return 1
    fi
    while IFS= read -r entry || [[ -n $entry ]]; do
        case "$entry" in
            metadata.env | paths.list | rootfs | rootfs/*) ;;
            *)
                rm -f -- "$listing" "$verbose"
                _maintenance_log_error '备份包含未知顶层条目，拒绝恢复。'
                return 1
                ;;
        esac
        if [[ $entry == /* || $entry == '..' || $entry == ../* || $entry == */../* || $entry == */.. ]]; then
            rm -f -- "$listing" "$verbose"
            _maintenance_log_error '备份包含路径穿越条目，拒绝恢复。'
            return 1
        fi
    done <"$listing"
    while IFS= read -r verbose_line || [[ -n $verbose_line ]]; do
        entry_type=${verbose_line:0:1}
        case "$entry_type" in
            - | d) ;;
            *)
                rm -f -- "$listing" "$verbose"
                _maintenance_log_error '备份包含符号链接、硬链接或特殊文件，拒绝恢复。'
                return 1
                ;;
        esac
    done <"$verbose"
    rm -f -- "$listing" "$verbose"
}

_maintenance_read_restore_paths() {
    local paths_file=$1
    local rootfs=$2
    local encoded path existing

    [[ -f $paths_file && ! -L $paths_file ]] || return 1
    OKP_RESTORE_PATHS=()
    while IFS= read -r encoded || [[ -n $encoded ]]; do
        [[ -n $encoded ]] || continue
        path=$(_state_decode "$encoded") || return 1
        _maintenance_path_is_safe "$path" || {
            _maintenance_log_error "备份清单包含非法路径: ${path}"
            return 1
        }
        [[ -e ${rootfs}${path} && ! -L ${rootfs}${path} ]] || {
            _maintenance_log_error "备份清单路径缺失或为链接: ${path}"
            return 1
        }
        [[ -f ${rootfs}${path} || -d ${rootfs}${path} ]] || return 1
        for existing in "${OKP_RESTORE_PATHS[@]}"; do
            if [[ $path == "$existing" || $path == "${existing%/}/"* || \
                $existing == "${path%/}/"* ]]; then
                _maintenance_log_error "备份清单存在重复或嵌套路径: ${path} / ${existing}"
                return 1
            fi
        done
        OKP_RESTORE_PATHS+=("$path")
    done <"$paths_file"
    ((${#OKP_RESTORE_PATHS[@]} > 0))
}

_maintenance_validate_restore_coverage() {
    local rootfs=$1
    local entry absolute_path managed_path covered

    while IFS= read -r -d '' entry; do
        absolute_path=${entry#"$rootfs"}
        covered=false
        for managed_path in "${OKP_RESTORE_PATHS[@]}"; do
            if [[ $absolute_path == "$managed_path" || \
                $absolute_path == "${managed_path%/}/"* ]]; then
                covered=true
                break
            fi
            # tar contains parent directories such as rootfs/etc; those are
            # structural ancestors, not additional restore targets.
            if [[ -d $entry && $managed_path == "${absolute_path%/}/"* ]]; then
                covered=true
                break
            fi
        done
        if [[ $covered != true ]]; then
            _maintenance_log_error "备份 rootfs 包含清单外路径: ${absolute_path}"
            return 1
        fi
    done < <(find "$rootfs" -mindepth 1 -print0)
}

_maintenance_file_has_shebang() {
    local file=$1
    local prefix

    prefix=$(dd if="$file" bs=2 count=1 2>/dev/null) || return 1
    [[ $prefix == '#!' ]]
}

_maintenance_restore_file_mode() {
    local destination=$1
    local file=$2

    case "$destination" in
        "$CONFIG_DIR" | "${CONFIG_DIR%/}/"*)
            if [[ $file == *.sh ]] || _maintenance_file_has_shebang "$file"; then
                printf '0755\n'
            else
                printf '0600\n'
            fi
            ;;
        /etc/x-ui | /etc/x-ui/* | "$RESULT_FILE") printf '0600\n' ;;
        /usr/local/x-ui | /usr/local/x-ui/*)
            case "$destination" in
                /usr/local/x-ui/x-ui | /usr/local/x-ui/bin/xray*) printf '0755\n' ;;
                *)
                    if [[ $file == *.sh ]] || _maintenance_file_has_shebang "$file"; then
                        printf '0755\n'
                    else
                        printf '0644\n'
                    fi
                    ;;
            esac
            ;;
        /usr/local/lib/one-key-proxy | /usr/local/lib/one-key-proxy/*)
            if [[ $file == *.sh ]] || _maintenance_file_has_shebang "$file"; then
                printf '0755\n'
            else
                printf '0644\n'
            fi
            ;;
        /usr/local/bin/one-key-proxy | /usr/local/bin/one-key-proxy-acme-renew | \
            /usr/local/bin/one-key-proxy-reload-x-ui | /etc/init.d/x-ui | \
            /etc/periodic/daily/one-key-proxy-acme) printf '0755\n' ;;
        /etc/systemd/system/x-ui.service | \
            /etc/systemd/system/one-key-proxy-acme.service | \
            /etc/systemd/system/one-key-proxy-acme.timer | \
            /etc/fail2ban/jail.d/one-key-proxy.local | \
            /etc/fail2ban/filter.d/one-key-proxy.conf) printf '0644\n' ;;
        *) return 1 ;;
    esac
}

_maintenance_restore_normalize_path() {
    local path=$1
    local source=$2
    local item destination mode dir_mode=0755

    [[ -f $source || -d $source ]] && [[ ! -L $source ]] || return 1
    chown -R 0:0 "$source" || return 1
    case "$path" in
        "$CONFIG_DIR" | "${CONFIG_DIR%/}/"* | /etc/x-ui | /etc/x-ui/*) dir_mode=0700 ;;
    esac
    if [[ -f $source ]]; then
        mode=$(_maintenance_restore_file_mode "$path" "$source") || return 1
        chmod "$mode" "$source" || return 1
        if command -v restorecon >/dev/null 2>&1; then
            restorecon -F "$source" || return 1
        fi
        return 0
    fi

    while IFS= read -r -d '' item; do
        chmod "$dir_mode" "$item" || return 1
    done < <(find "$source" -type d -print0)
    while IFS= read -r -d '' item; do
        destination="${path}${item#"$source"}"
        mode=$(_maintenance_restore_file_mode "$destination" "$item") || return 1
        chmod "$mode" "$item" || return 1
    done < <(find "$source" -type f -print0)
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -RF "$source" || return 1
    fi
}

_maintenance_restore_normalize_paths() {
    local root_prefix=$1
    local path

    for path in "${OKP_RESTORE_PATHS[@]}"; do
        _maintenance_restore_normalize_path "$path" "${root_prefix}${path}" || {
            _maintenance_log_error "无法规范化恢复路径的所有权或权限: ${path}"
            return 1
        }
    done
}

_maintenance_restore_reset_transaction() {
    OKP_RESTORE_DESTS=()
    OKP_RESTORE_OLDS=()
    OKP_RESTORE_INCOMINGS=()
    OKP_RESTORE_HAD_OLD=()
    OKP_RESTORE_TRANSACTION_ACTIVE=false
}

_maintenance_restore_rollback() {
    local index destination old incoming had_old status=0

    for ((index = ${#OKP_RESTORE_DESTS[@]} - 1; index >= 0; index--)); do
        destination=${OKP_RESTORE_DESTS[index]}
        old=${OKP_RESTORE_OLDS[index]}
        incoming=${OKP_RESTORE_INCOMINGS[index]}
        had_old=${OKP_RESTORE_HAD_OLD[index]}

        if [[ -e $old || -L $old ]]; then
            if rm -rf -- "$destination"; then
                mv -- "$old" "$destination" || status=1
            else
                # Never let mv place the old tree *inside* a destination that
                # survived a failed removal; keep old in place for a retry.
                status=1
            fi
        elif [[ $had_old == false ]]; then
            rm -rf -- "$destination" || status=1
        fi
        rm -rf -- "$incoming" || status=1
    done
    if ((status == 0)); then
        _maintenance_restore_reset_transaction
    else
        _maintenance_log_error '事务回滚未能完整恢复所有受管路径；事务上下文已保留，服务不得启动。'
    fi
    return "$status"
}

_maintenance_restore_abort_transaction() {
    if _maintenance_restore_rollback; then
        return 0
    fi
    OKP_MAINTENANCE_FATAL=true
    _maintenance_log_error '恢复事务失败且无法完整回滚；服务保持停止，请使用保护备份人工处理。'
    return 1
}

_maintenance_restore_commit() {
    local old incoming status=0

    for old in "${OKP_RESTORE_OLDS[@]}"; do
        if [[ -e $old || -L $old ]]; then
            rm -rf -- "$old" || status=1
        fi
    done
    for incoming in "${OKP_RESTORE_INCOMINGS[@]}"; do
        if [[ -e $incoming || -L $incoming ]]; then
            rm -rf -- "$incoming" || status=1
        fi
    done
    _maintenance_restore_reset_transaction
    return "$status"
}

_maintenance_restore_transaction() {
    local rootfs=$1
    local path source destination parent base incoming old had_old index

    _maintenance_restore_reset_transaction
    OKP_RESTORE_TRANSACTION_ACTIVE=true
    for path in "${OKP_RESTORE_PATHS[@]}"; do
        source="${rootfs}${path}"
        destination=$path
        parent=$(dirname -- "$destination")
        base=$(basename -- "$destination")
        index=${#OKP_RESTORE_DESTS[@]}
        incoming="${parent}/.${base}.okp-new.$$-${index}"
        old="${parent}/.${base}.okp-old.$$-${index}"
        had_old=false
        [[ -e $destination || -L $destination ]] && had_old=true

        if [[ -e $incoming || -L $incoming || -e $old || -L $old ]]; then
            _maintenance_log_error "恢复临时路径已存在，拒绝覆盖: ${destination}"
            _maintenance_restore_abort_transaction || true
            return 1
        fi
        if [[ ! -d $parent || -L $parent ]]; then
            _maintenance_log_error "恢复目标父目录不存在或不安全: ${parent}"
            _maintenance_restore_abort_transaction || true
            return 1
        fi
        OKP_RESTORE_DESTS+=("$destination")
        OKP_RESTORE_OLDS+=("$old")
        OKP_RESTORE_INCOMINGS+=("$incoming")
        OKP_RESTORE_HAD_OLD+=("$had_old")

        if ! cp -a -- "$source" "$incoming"; then
            _maintenance_restore_abort_transaction || true
            return 1
        fi
        if [[ $had_old == true ]] && ! mv -- "$destination" "$old"; then
            _maintenance_restore_abort_transaction || true
            return 1
        fi
        if ! mv -- "$incoming" "$destination"; then
            _maintenance_restore_abort_transaction || true
            return 1
        fi
    done
}

_maintenance_restore_quiesce() {
    local rootfs=$1
    local service_name status

    OKP_RESTORE_RESUME_MODE=''
    OKP_RESTORE_ROOTFS=$rootfs
    if maintenance_hook_exists okp_hook_before_restore; then
        maintenance_hook_exists okp_hook_after_restore || {
            _maintenance_log_error '定义了 okp_hook_before_restore，但缺少配对的 okp_hook_after_restore。'
            return 1
        }
        OKP_RESTORE_RESUME_MODE='hook'
        if ! okp_hook_before_restore "$rootfs"; then
            _maintenance_restore_resume || true
            return 1
        fi
        return 0
    fi

    service_name=$(state_get XUI_SERVICE_NAME 2>/dev/null) || service_name='x-ui'
    if _maintenance_service_activity "$service_name"; then
        OKP_RESTORE_RESUME_MODE="platform:${service_name}"
        if ! platform_service_stop "$service_name"; then
            OKP_RESTORE_RESUME_MODE=''
            _maintenance_log_error '无法停止 3x-ui，恢复已取消。'
            return 1
        fi
    else
        status=$?
        if ((status != 1)); then
            _maintenance_log_error '无法确定 3x-ui 服务状态，恢复已取消。'
            return 1
        fi
        # A successful restore must be validated against a running service,
        # even if it was stopped when the operator entered the menu.
        OKP_RESTORE_RESUME_MODE="platform:${service_name}"
    fi
}

_maintenance_restore_verify() {
    local service_name port key attempt ready
    local -a port_keys=(PANEL_INTERNAL_PORT NODE_INTERNAL_PORT SUB_INTERNAL_PORT)

    service_name=$(state_get XUI_SERVICE_NAME 2>/dev/null) || service_name='x-ui'
    for key in "${port_keys[@]}"; do
        port=$(state_get "$key" 2>/dev/null) || {
            _maintenance_log_error "恢复后缺少端口状态: ${key}"
            return 1
        }
    done

    for ((attempt = 1; attempt <= 20; attempt++)); do
        ready=true
        _maintenance_service_activity "$service_name" || ready=false
        if [[ $ready == true ]] && declare -F platform_port_is_listening >/dev/null 2>&1; then
            for key in "${port_keys[@]}"; do
                port=$(state_get "$key" 2>/dev/null) || {
                    ready=false
                    break
                }
                if ! platform_port_is_listening "$port" tcp; then
                    ready=false
                    break
                fi
            done
        fi
        if [[ $ready == true ]] && declare -F xui_api_get >/dev/null 2>&1 && \
            ! XUI_API_CONNECT_TIMEOUT=2 XUI_API_MAX_TIME=3 \
                xui_api_get /panel/api/server/status >/dev/null 2>&1; then
            ready=false
        fi
        if [[ $ready == true ]]; then
            if maintenance_hook_exists okp_hook_verify_restore; then
                okp_hook_verify_restore || return 1
            fi
            return 0
        fi
        sleep 1
    done
    _maintenance_log_error '恢复后服务、监听端口或管理 API 未在 20 秒内通过验收。'
    return 1
}

_maintenance_restore_resume() {
    local mode=${OKP_RESTORE_RESUME_MODE-}
    local service_name status=0

    case "$mode" in
        '') return 0 ;;
        hook) okp_hook_after_restore || status=$? ;;
        platform:*)
            service_name=${mode#platform:}
            platform_service_start "$service_name" || status=$?
            ;;
        *) return 1 ;;
    esac
    if ((status == 0)); then
        _maintenance_restore_verify || status=$?
    fi
    if ((status == 0)) && [[ $OKP_RESTORE_TRANSACTION_ACTIVE != true ]]; then
        OKP_RESTORE_RESUME_MODE=''
    fi
    return "$status"
}

_maintenance_restore_pause_for_rollback() {
    local mode=${OKP_RESTORE_RESUME_MODE-}
    local service_name activity_status

    case "$mode" in
        hook) okp_hook_before_restore "$OKP_RESTORE_ROOTFS" || return 1 ;;
        platform:*)
            service_name=${mode#platform:}
            if _maintenance_service_activity "$service_name"; then
                platform_service_stop "$service_name" || return 1
            else
                activity_status=$?
                ((activity_status == 1)) || return 1
            fi
            ;;
        '') ;;
        *) return 1 ;;
    esac
}

_maintenance_restore_network_check() {
    local rootfs=$1
    local backup_state="${rootfs}${STATE_FILE}"
    local key current_value backup_value changed=false
    local -a keys=(
        MODE PUBLIC_IPV4 PUBLIC_IPV6 FQDN PANEL_EXTERNAL_PORT PANEL_INTERNAL_PORT
        NODE_EXTERNAL_PORT NODE_INTERNAL_PORT SUB_EXTERNAL_PORT SUB_INTERNAL_PORT
    )

    [[ -f $backup_state && ! -L $backup_state ]] || {
        _maintenance_log_error '备份中缺少安全可读的项目状态文件。'
        return 1
    }
    for key in "${keys[@]}"; do
        current_value=$(state_get "$key" 2>/dev/null) || current_value=''
        backup_value=$(state_file_get "$backup_state" "$key" 2>/dev/null) || backup_value=''
        if [[ $current_value != "$backup_value" ]]; then
            changed=true
            printf '  %s: 当前=%s, 备份=%s\n' "$key" "${current_value:-<空>}" "${backup_value:-<空>}"
        fi
    done
    if [[ $changed == true ]]; then
        printf '恢复将改变以上网络参数，可能导致面板、订阅或客户端失联。\n'
        maintenance_confirm_phrase '确认恢复备份中的网络参数？' NETWORK || return 1
    fi
}

_maintenance_restore_preflight() {
    local metadata=$1
    local rootfs=$2
    local backup_arch current_arch backup_xui current_xui

    backup_arch=$(state_file_get "$metadata" SYSTEM_ARCH 2>/dev/null) || backup_arch=''
    current_arch=$(uname -m 2>/dev/null) || return 1
    [[ -n $backup_arch && $backup_arch == "$current_arch" ]] || {
        _maintenance_log_error "备份架构 (${backup_arch:-未知}) 与当前架构 (${current_arch}) 不兼容。"
        return 1
    }
    backup_xui=$(state_file_get "$metadata" XUI_VERSION 2>/dev/null) || backup_xui=''
    current_xui=$(state_get XUI_VERSION 2>/dev/null) || current_xui=''
    if [[ -n $backup_xui && $backup_xui != "$current_xui" ]]; then
        _maintenance_log_error "备份的 3x-ui 版本 (${backup_xui}) 与当前版本 (${current_xui:-未知}) 不一致。"
        return 1
    fi
    _maintenance_restore_network_check "$rootfs" || return 1
    if maintenance_hook_exists okp_hook_restore_preflight; then
        okp_hook_restore_preflight "$metadata" "$rootfs" || return 1
    fi
}

maintenance_restore() {
    local archive extract metadata backup_installation current_installation
    local backup_machine current_machine format rootfs paths_file

    _maintenance_choose_backup archive || return 1
    _maintenance_verify_backup_checksum "$archive" || return 1
    _maintenance_validate_archive_entries "$archive" || return 1

    extract=$(mktemp -d "${TMPDIR:-/tmp}/one-key-proxy-restore.XXXXXX") || return 1
    maintenance_temp_register "$extract" || return 1
    chmod 0700 "$extract"
    if ! tar --no-same-owner -C "$extract" -xzf "$archive"; then
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        return 1
    fi
    metadata="${extract}/metadata.env"
    paths_file="${extract}/paths.list"
    rootfs="${extract}/rootfs"
    if [[ ! -f $metadata || -L $metadata || ! -f $paths_file || -L $paths_file || \
        ! -d $rootfs || -L $rootfs ]]; then
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        _maintenance_log_error '备份解包后的结构或文件类型不安全。'
        return 1
    fi
    if ! _maintenance_read_restore_paths "$paths_file" "$rootfs"; then
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        _maintenance_log_error '备份受管路径清单无效。'
        return 1
    fi
    if ! _maintenance_validate_restore_coverage "$rootfs"; then
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        return 1
    fi
    format=$(state_file_get "$metadata" BACKUP_FORMAT 2>/dev/null) || format=''
    backup_installation=$(state_file_get "$metadata" INSTALLATION_ID 2>/dev/null) || backup_installation=''
    backup_machine=$(state_file_get "$metadata" ORIGINAL_MACHINE_ID 2>/dev/null) || backup_machine=''
    current_installation=$(state_get INSTALLATION_ID 2>/dev/null) || current_installation=''
    current_machine=$(state_machine_id)

    if [[ $format != 1 || -z $backup_installation || -z $backup_machine ]]; then
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        _maintenance_log_error '备份元数据不完整。'
        return 1
    fi
    if [[ -n $current_installation && $current_installation != "$backup_installation" ]]; then
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        _maintenance_log_error '备份属于另一套 one-key-proxy 安装，拒绝恢复。'
        return 1
    fi
    if [[ $current_machine != "$backup_machine" ]]; then
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        _maintenance_log_error '备份不属于当前原始服务器，拒绝恢复。'
        return 1
    fi

    if ! _maintenance_restore_preflight "$metadata" "$rootfs"; then
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        return 1
    fi

    printf '将恢复: %s\n' "$archive"
    printf '恢复会覆盖当前受管配置、证书、凭据和 3x-ui 数据库。\n'
    if ! maintenance_double_confirm '确认开始原机恢复？' RESTORE; then
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        return 1
    fi

    _maintenance_log_info '恢复前创建当前状态的强制备份。'
    if ! maintenance_backup_create; then
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        return 1
    fi
    if ! _maintenance_restore_quiesce "$rootfs"; then
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        _maintenance_log_error "恢复前无法安全停止服务；保护备份为 ${LAST_BACKUP_PATH}。"
        return 1
    fi

    if ! _maintenance_restore_transaction "$rootfs"; then
        if [[ $OKP_RESTORE_TRANSACTION_ACTIVE == true ]]; then
            OKP_MAINTENANCE_FATAL=true
            _maintenance_log_error '恢复失败且回滚未完成；为避免混合状态，未启动 3x-ui。'
        else
            _maintenance_restore_resume || true
        fi
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        _maintenance_log_error "事务式恢复失败且已尝试回滚；保护备份为 ${LAST_BACKUP_PATH}。"
        return 1
    fi
    if ! _maintenance_restore_normalize_paths ''; then
        _maintenance_log_error '恢复文件权限或所有权规范化失败，正在回滚。'
        if ! _maintenance_restore_rollback; then
            OKP_MAINTENANCE_FATAL=true
            _maintenance_log_error '恢复权限修复失败且回滚未完成；为避免混合状态，未启动 3x-ui。'
            return 1
        fi
        _maintenance_restore_resume || true
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        _maintenance_log_error "恢复失败；保护备份为 ${LAST_BACKUP_PATH}。"
        return 1
    fi
    if ! _maintenance_restore_resume; then
        _maintenance_log_error '恢复后的服务重启或验收失败，正在回滚。'
        if ! _maintenance_restore_pause_for_rollback; then
            OKP_MAINTENANCE_FATAL=true
            _maintenance_log_error '回滚前无法再次停止服务；为避免损坏运行中的数据库，未执行回滚。'
            _maintenance_log_error "请停止 x-ui 后使用保护备份人工恢复: ${LAST_BACKUP_PATH}"
            return 1
        fi
        if ! _maintenance_restore_rollback; then
            OKP_MAINTENANCE_FATAL=true
            _maintenance_log_error '恢复失败且回滚未完成；为避免混合状态，未启动 3x-ui。'
            return 1
        fi
        _maintenance_restore_resume || true
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        _maintenance_log_error "恢复失败；保护备份为 ${LAST_BACKUP_PATH}。"
        return 1
    fi
    if ! _maintenance_restore_commit; then
        OKP_RESTORE_RESUME_MODE=''
        rm -rf -- "$extract"
        maintenance_temp_unregister "$extract"
        _maintenance_log_error '恢复成功，但旧事务文件清理失败。'
        return 1
    fi
    OKP_RESTORE_RESUME_MODE=''
    OKP_RESTORE_ROOTFS=''
    chmod 0700 "$CONFIG_DIR" "$CERT_DIR" 2>/dev/null || true
    chmod 0600 "$STATE_FILE" 2>/dev/null || true

    rm -rf -- "$extract"
    maintenance_temp_unregister "$extract"
    _maintenance_log_info '原机恢复完成。'
}

maintenance_reconfigure() {
    local scope=${1:-all}

    case "$scope" in
        all | address | ports | domain) ;;
        *)
            _maintenance_log_error "未知重配范围: ${scope}"
            return 2
            ;;
    esac
    maintenance_require_hook okp_hook_reconfigure '地址/端口/域名重配' || return 1
    printf '重配 hook 必须先展示最终差异并再次确认；公网地址变化可能要求重新导入客户端。\n'
    okp_hook_reconfigure "$scope"
}

maintenance_renew_certificate() {
    if maintenance_hook_exists okp_hook_renew_certificate; then
        okp_hook_renew_certificate
    elif declare -F okp_acme_renew_now >/dev/null 2>&1 && [[ $(state_get TLS_MODE 2>/dev/null) == ACME ]]; then
        maintenance_confirm '立即强制续签证书？' n || return 1
        okp_acme_renew_now true
    else
        _maintenance_log_error '当前安装缺少适用的证书续签接口。'
        return 1
    fi
}

_maintenance_update_with_backup() {
    local component=$1
    local info_hook=$2
    local update_hook=$3

    maintenance_require_hook "$update_hook" "${component} 更新" || return 1
    if maintenance_hook_exists "$info_hook"; then
        "$info_hook" || return 1
    fi
    maintenance_confirm "确认手动更新 ${component}？" n || return 1
    maintenance_backup_create || return 1
    "$update_hook"
}

maintenance_update_project() {
    _maintenance_update_with_backup 'one-key-proxy' okp_hook_project_update_info okp_hook_project_update || return 1
    if [[ -z $OKP_MAINTENANCE_ENTRY_COMMAND && \
        $OKP_MAINTENANCE_DIR == /usr/local/lib/one-key-proxy ]]; then
        OKP_MAINTENANCE_REEXECED=true
        export OKP_MAINTENANCE_REEXECED OKP_OPERATION_LOCK_FD
        exec bash /usr/local/lib/one-key-proxy/maintenance.sh
    fi
}

maintenance_update_xui() {
    _maintenance_update_with_backup '3x-ui' okp_hook_xui_update_info okp_hook_xui_update
}

maintenance_update_menu() {
    local choice

    while true; do
        maintenance_heading '手动更新'
        printf '1. 更新 one-key-proxy 项目\n'
        printf '2. 更新 3x-ui 到最新稳定版\n'
        printf '0. 返回\n'
        maintenance_read choice '请选择' || return 1
        case "$choice" in
            1) maintenance_update_project ;;
            2) maintenance_update_xui ;;
            0) return 0 ;;
            *) _maintenance_log_warn '无效选项。' ;;
        esac
        maintenance_pause
    done
}

maintenance_rotate_panel() {
    maintenance_require_hook okp_hook_rotate_panel_credentials '面板凭据轮换' && \
        maintenance_double_confirm '轮换后旧面板凭据将立即失效，继续？' ROTATE && \
        maintenance_backup_create && \
        okp_hook_rotate_panel_credentials
}

maintenance_rotate_client() {
    maintenance_require_hook okp_hook_create_replacement_client '客户端轮换' && \
        maintenance_confirm '创建新客户端并保持所有旧客户端有效？' n && \
        okp_hook_create_replacement_client
}

maintenance_remove_old_client() {
    maintenance_require_hook okp_hook_delete_old_client '旧客户端删除' && \
        maintenance_double_confirm '仅在所有设备迁移后删除旧客户端，继续？' DELETE && \
        maintenance_backup_create && \
        okp_hook_delete_old_client
}

maintenance_rotate_api_token() {
    maintenance_require_hook okp_hook_rotate_api_token '管理 API Token 轮换' && \
        maintenance_double_confirm '旧管理 API Token 将立即失效，继续？' ROTATE && \
        maintenance_backup_create && \
        okp_hook_rotate_api_token
}

maintenance_credentials_menu() {
    local choice

    while true; do
        maintenance_heading '凭据轮换'
        printf '1. 轮换面板用户名/密码\n'
        printf '2. 创建替代客户端（保留全部旧客户端）\n'
        printf '3. 删除已迁移完成的旧客户端\n'
        printf '4. 轮换项目专用管理 API Token\n'
        printf '0. 返回\n'
        maintenance_read choice '请选择' || return 1
        case "$choice" in
            1) maintenance_rotate_panel ;;
            2) maintenance_rotate_client ;;
            3) maintenance_remove_old_client ;;
            4) maintenance_rotate_api_token ;;
            0) return 0 ;;
            *) _maintenance_log_warn '无效选项。' ;;
        esac
        maintenance_pause
    done
}

_maintenance_parse_components() {
    local input=$1
    local item
    local -a requested=()
    local -a all=(clients inbound dns certificates fail2ban firewall xui database project_state)
    local -A selected=()

    if [[ -z $input || $input == all ]]; then
        OKP_UNINSTALL_COMPONENTS=("${all[@]}")
        return 0
    fi
    input=${input//,/ }
    read -r -a requested <<<"$input"
    OKP_UNINSTALL_COMPONENTS=()
    for item in "${requested[@]}"; do
        case "$item" in
            inbound | clients | dns | certificates | fail2ban | firewall | xui | database | project_state)
                selected["$item"]=true
                ;;
            *)
                _maintenance_log_error "未知卸载组件: ${item}"
                return 1
                ;;
        esac
    done
    for item in "${all[@]}"; do
        [[ ${selected[$item]-} == true ]] && OKP_UNINSTALL_COMPONENTS+=("$item")
    done
    ((${#OKP_UNINSTALL_COMPONENTS[@]} > 0))
}

maintenance_uninstall() {
    local selection component

    maintenance_require_hook okp_hook_uninstall_component '逐项卸载' || return 1
    maintenance_heading '逐项卸载'
    printf '%s\n' '组件: inbound clients dns certificates fail2ban firewall xui database project_state'
    printf '%s\n' '用空格或逗号分隔；直接回车默认完整卸载。'
    maintenance_read selection '要卸载的组件' 'all' || return 1
    _maintenance_parse_components "$selection" || return 1

    printf '将卸载:\n'
    for component in "${OKP_UNINSTALL_COMPONENTS[@]}"; do
        printf '  - %s\n' "$component"
    done
    maintenance_double_confirm '确认执行上述卸载？' UNINSTALL || return 1

    # A full backup is mandatory before any component removal. This is stronger
    # than only protecting explicit database deletion and avoids x-ui uninstallers
    # removing their database as an implementation detail.
    _maintenance_log_info '卸载前创建强制完整备份。'
    maintenance_backup_create || {
        _maintenance_log_error '备份失败，卸载已取消。'
        return 1
    }

    for component in "${OKP_UNINSTALL_COMPONENTS[@]}"; do
        _maintenance_log_info "卸载组件: ${component}"
        if ! okp_hook_uninstall_component "$component"; then
            _maintenance_log_error "组件卸载失败，已停止: ${component}"
            _maintenance_log_error "卸载前备份: ${LAST_BACKUP_PATH}"
            return 1
        fi
    done
    _maintenance_log_info "所选组件卸载完成。卸载前备份保留在: ${LAST_BACKUP_PATH}"
}

maintenance_main_menu() {
    local choice

    while true; do
        maintenance_heading 'one-key-proxy 维护菜单'
        printf '1. 查看部署信息\n'
        printf '2. 状态与诊断\n'
        printf '3. 创建完整备份（保留最近 5 份）\n'
        printf '4. 原机恢复\n'
        printf '5. 重配公网地址 / 端口 / 域名\n'
        printf '6. 立即续签证书\n'
        printf '7. 手动更新\n'
        printf '8. 凭据轮换\n'
        printf '9. 逐项卸载（默认全选）\n'
        printf '0. 退出\n'
        maintenance_read choice '请选择' || return 1
        case "$choice" in
            1) maintenance_show_information ;;
            2) maintenance_doctor ;;
            3) maintenance_backup_create ;;
            4) maintenance_restore ;;
            5) maintenance_reconfigure all ;;
            6) maintenance_renew_certificate ;;
            7) maintenance_update_menu ;;
            8) maintenance_credentials_menu ;;
            9) maintenance_uninstall ;;
            0) return 0 ;;
            *) _maintenance_log_warn '无效选项。' ;;
        esac
        [[ $OKP_MAINTENANCE_FATAL != true ]] || return 1
        [[ $choice == 7 || $choice == 8 ]] || maintenance_pause
    done
}

maintenance_usage() {
    cat <<'EOF'
用法:
  one-key-proxy                         打开交互式维护菜单
  one-key-proxy info                    查看部署信息
  one-key-proxy status                  快速检查服务、端口与证书
  one-key-proxy doctor                  执行深度诊断
  one-key-proxy backup                  创建完整敏感备份
  one-key-proxy restore                 在原服务器恢复备份
  one-key-proxy update-3xui             备份后更新 3x-ui
  one-key-proxy self-update             备份后更新本项目
  one-key-proxy update-address          手动更新公网地址
  one-key-proxy reconfigure-ports       重配监听与发布端口
  one-key-proxy reconfigure-domain      重配普通 VPS 域名
  one-key-proxy reconfigure [范围]      范围: all/address/ports/domain
  one-key-proxy renew-cert              手动续签证书
  one-key-proxy rotate-panel            轮换面板凭据
  one-key-proxy rotate-token            轮换项目管理 API Token
  one-key-proxy rotate-client           新建客户端并保留旧客户端
  one-key-proxy remove-client           删除迁移完成的旧客户端
  one-key-proxy rotate [类型]            类型: panel/token/client/remove-client
  one-key-proxy uninstall               逐项卸载（默认全选）

兼容别名: update-project, update-xui, renew
EOF
}

maintenance_validate_arguments() {
    local command_name=${1-}

    case "$command_name" in
        reconfigure | rotate)
            if (($# > 2)); then
                maintenance_usage >&2
                return 2
            fi
            ;;
        '')
            if (($# != 0)); then
                maintenance_usage >&2
                return 2
            fi
            ;;
        *)
            if (($# != 1)); then
                maintenance_usage >&2
                return 2
            fi
            ;;
    esac

    case "$command_name" in
        '' | info | status | doctor | backup | restore | update-3xui | update-xui | \
            self-update | update-project | update-address | reconfigure-ports | \
            reconfigure-domain | reconfigure | renew-cert | renew | rotate-panel | \
            rotate-token | rotate-client | remove-client | rotate | uninstall | \
            help | -h | --help) return 0 ;;
        *)
            maintenance_usage >&2
            return 2
            ;;
    esac
}

maintenance_dispatch() {
    local command_name=${1-}
    local subcommand=${2-}

    case "$command_name" in
        '') maintenance_require_tty && maintenance_main_menu ;;
        info) maintenance_show_information ;;
        status) maintenance_diagnostics ;;
        doctor) maintenance_doctor ;;
        backup) maintenance_backup_create ;;
        restore) maintenance_require_tty && maintenance_restore ;;
        update-3xui | update-xui) maintenance_require_tty && maintenance_update_xui ;;
        self-update | update-project) maintenance_require_tty && maintenance_update_project ;;
        update-address) maintenance_require_tty && maintenance_reconfigure address ;;
        reconfigure-ports) maintenance_require_tty && maintenance_reconfigure ports ;;
        reconfigure-domain) maintenance_require_tty && maintenance_reconfigure domain ;;
        reconfigure)
            maintenance_require_tty && maintenance_reconfigure "${subcommand:-all}"
            ;;
        renew-cert | renew) maintenance_require_tty && maintenance_renew_certificate ;;
        rotate-panel) maintenance_require_tty && maintenance_rotate_panel ;;
        rotate-token) maintenance_require_tty && maintenance_rotate_api_token ;;
        rotate-client) maintenance_require_tty && maintenance_rotate_client ;;
        remove-client) maintenance_require_tty && maintenance_remove_old_client ;;
        rotate)
            maintenance_require_tty || return 1
            case "$subcommand" in
                '') maintenance_credentials_menu ;;
                panel) maintenance_rotate_panel ;;
                token) maintenance_rotate_api_token ;;
                client) maintenance_rotate_client ;;
                remove-client) maintenance_remove_old_client ;;
                *)
                    maintenance_usage >&2
                    return 2
                    ;;
            esac
            ;;
        uninstall) maintenance_require_tty && maintenance_uninstall ;;
        help | -h | --help) maintenance_usage ;;
        *)
            maintenance_usage >&2
            return 2
            ;;
    esac
}

maintenance_main() {
    local mutates=false
    if (($# == 1)); then
        case ${1-} in
            help | -h | --help)
                maintenance_usage
                return 0
                ;;
        esac
    fi
    maintenance_validate_arguments "$@" || return $?
    maintenance_require_root || return 1
    trap maintenance_cleanup_temp_paths EXIT
    state_init || return 1
    if maintenance_command_mutates "${1-}"; then
        mutates=true
    fi
    if [[ $mutates == true ]]; then
        maintenance_require_hook okp_hook_settle_pending_xui_update \
            '3x-ui 更新事务恢复' || return 1
        # The hook arms update settlement before it acquires (or reuses) the
        # operation lock. This must precede every command-specific info,
        # confirmation, backup, or hook. In particular, never back up or replay
        # the upstream updater over an unresolved update journal.
        okp_hook_settle_pending_xui_update || return 1
    fi
    state_ensure_identity || return 1
    maintenance_dispatch "$@"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    maintenance_main "$@"
fi
