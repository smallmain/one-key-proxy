#!/usr/bin/env bash

# State is stored as KEY=BASE64_VALUE. Never source STATE_FILE: even a root-owned
# file may have been restored from an older or damaged backup.

if [[ ${OKP_TEST_MODE:-false} == true && ${OKP_PRODUCTION_MODE:-false} != true ]]; then
    : "${CONFIG_DIR:=/etc/one-key-proxy}"
    : "${STATE_FILE:=${CONFIG_DIR}/state.env}"
    : "${CERT_DIR:=${CONFIG_DIR}/certs}"
    : "${LOG_FILE:=/var/log/one-key-proxy.log}"
    : "${BACKUP_DIR:=/var/backups/one-key-proxy}"
    : "${RESULT_FILE:=/root/one-key-proxy-result.txt}"
    : "${STAGE_DIR:=${CONFIG_DIR}/stages}"
    : "${STATE_LOCK_FILE:=${CONFIG_DIR}/.state-test.lock}"
else
    CONFIG_DIR=/etc/one-key-proxy
    STATE_FILE=/etc/one-key-proxy/state.env
    CERT_DIR=/etc/one-key-proxy/certs
    LOG_FILE=/var/log/one-key-proxy.log
    BACKUP_DIR=/var/backups/one-key-proxy
    RESULT_FILE=/root/one-key-proxy-result.txt
    STAGE_DIR=/etc/one-key-proxy/stages
    STATE_LOCK_FILE=/run/one-key-proxy/state.lock
fi

if ! declare -p OKP_SECRET_VALUES >/dev/null 2>&1; then
    declare -ag OKP_SECRET_VALUES=()
fi

_state_error() {
    if declare -F log_error >/dev/null 2>&1; then
        log_error "$*"
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
}

_state_info() {
    if declare -F log_info >/dev/null 2>&1; then
        log_info "$*"
    else
        printf '%s\n' "$*"
    fi
}

_state_validate_key() {
    [[ ${1-} =~ ^[A-Z][A-Z0-9_]*$ ]]
}

_state_validate_stage() {
    [[ ${1-} =~ ^[a-z0-9][a-z0-9._-]*$ ]] && [[ $1 != *..* ]]
}

_state_file_attribute() {
    local path=$1 linux_format=$2 bsd_format=$3
    stat -c "$linux_format" -- "$path" 2>/dev/null || \
        stat -f "$bsd_format" "$path" 2>/dev/null
}

_state_is_production() {
    [[ ${OKP_TEST_MODE:-false} != true || ${OKP_PRODUCTION_MODE:-false} == true ]]
}

_state_secure_regular_file() {
    local path=${1-}
    local require_root_owner=${2:-auto}
    local links owner

    [[ -n $path && -f $path && ! -L $path ]] || return 1
    links=$(_state_file_attribute "$path" '%h' '%l') || return 1
    [[ $links == 1 ]] || return 1
    if [[ $require_root_owner == true ]] || \
        { [[ $require_root_owner == auto ]] && _state_is_production; }; then
        owner=$(_state_file_attribute "$path" '%u' '%u') || return 1
        [[ $owner == 0 ]] || return 1
    fi
}

# GNU and BSD sync support -f for a single filesystem object. BusyBox may not;
# durability then remains atomic-rename level rather than making writes fail.
_state_fsync_if_supported() {
    local path=${1-}

    [[ -n $path && -e $path ]] || return 0
    if command -v sync >/dev/null 2>&1; then
        sync -f -- "$path" >/dev/null 2>&1 && return 0
        sync -f "$path" >/dev/null 2>&1 && return 0
    fi
    if command -v fsync >/dev/null 2>&1; then
        fsync "$path" >/dev/null 2>&1 && return 0
    fi
    return 0
}

_state_fsync_parent_if_supported() {
    local path=${1-}
    local parent

    parent=$(dirname -- "$path") || return 0
    _state_fsync_if_supported "$parent"
}

_state_valid_utc_timestamp() {
    local value=${1-}
    local year month day hour minute second max_day leap=false

    [[ $value =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
    year=$((10#${value:0:4}))
    month=$((10#${value:5:2}))
    day=$((10#${value:8:2}))
    hour=$((10#${value:11:2}))
    minute=$((10#${value:14:2}))
    second=$((10#${value:17:2}))
    ((year >= 1970 && month >= 1 && month <= 12 && day >= 1 && \
        hour <= 23 && minute <= 59 && second <= 59)) || return 1

    if ((year % 400 == 0 || (year % 4 == 0 && year % 100 != 0))); then
        leap=true
    fi
    case $month in
        2) [[ $leap == true ]] && max_day=29 || max_day=28 ;;
        4 | 6 | 9 | 11) max_day=30 ;;
        *) max_day=31 ;;
    esac
    ((day <= max_day))
}

_state_encode() {
    local encoded

    encoded=$(printf '%s' "${1-}" | base64) || return 1
    encoded=${encoded//$'\r'/}
    encoded=${encoded//$'\n'/}
    printf '%s' "$encoded"
}

_state_decode() {
    local encoded=${1-}
    local decoded

    [[ $encoded =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || return 1
    if [[ -z $encoded ]]; then
        return 0
    fi
    if decoded=$(printf '%s' "$encoded" | base64 -d 2>/dev/null); then
        printf '%s' "$decoded"
        return 0
    fi
    decoded=$(printf '%s' "$encoded" | base64 -D 2>/dev/null) || return 1
    printf '%s' "$decoded"
}

state_init() {
    local previous_umask path links owner

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        _state_error "状态目录只能由 root 初始化: ${CONFIG_DIR}"
        return 1
    fi
    for path in "$CONFIG_DIR" "$CERT_DIR" "$STAGE_DIR" "$STATE_FILE" "$STATE_LOCK_FILE"; do
        if [[ -L $path ]]; then
            _state_error "拒绝使用符号链接状态路径: ${path}"
            return 1
        fi
    done
    for path in "$CONFIG_DIR" "$CERT_DIR" "$STAGE_DIR"; do
        if [[ -e $path && ! -d $path ]]; then
            _state_error "状态目录路径不是目录: ${path}"
            return 1
        fi
        if [[ -d $path ]] && _state_is_production; then
            owner=$(_state_file_attribute "$path" '%u' '%u') || return 1
            [[ $owner == 0 ]] || {
                _state_error "状态目录不是 root 所有，拒绝继续: ${path}"
                return 1
            }
        fi
    done
    if [[ -e $STATE_FILE ]]; then
        [[ -f $STATE_FILE ]] || {
            _state_error "状态文件不是普通文件: ${STATE_FILE}"
            return 1
        }
        links=$(_state_file_attribute "$STATE_FILE" '%h' '%l') || return 1
        [[ $links == 1 ]] || {
            _state_error "状态文件存在硬链接，拒绝继续: ${STATE_FILE}"
            return 1
        }
        if _state_is_production; then
            owner=$(_state_file_attribute "$STATE_FILE" '%u' '%u') || return 1
            [[ $owner == 0 ]] || {
                _state_error "状态文件不是 root 所有，拒绝继续: ${STATE_FILE}"
                return 1
            }
        fi
    fi
    if [[ -e $STATE_LOCK_FILE ]]; then
        [[ -f $STATE_LOCK_FILE ]] || {
            _state_error "状态锁不是普通文件: ${STATE_LOCK_FILE}"
            return 1
        }
        links=$(_state_file_attribute "$STATE_LOCK_FILE" '%h' '%l') || return 1
        [[ $links == 1 ]] || {
            _state_error "状态锁存在硬链接，拒绝继续: ${STATE_LOCK_FILE}"
            return 1
        }
        if _state_is_production; then
            owner=$(_state_file_attribute "$STATE_LOCK_FILE" '%u' '%u') || return 1
            [[ $owner == 0 ]] || {
                _state_error "状态锁不是 root 所有，拒绝继续: ${STATE_LOCK_FILE}"
                return 1
            }
        fi
    fi

    previous_umask=$(umask)
    umask 077
    if [[ ! -d $(dirname -- "$STATE_LOCK_FILE") ]]; then
        install -d -m 0700 -- "$(dirname -- "$STATE_LOCK_FILE")" || {
            umask "$previous_umask"
            return 1
        }
    fi
    if [[ ${OKP_TEST_MODE:-false} != true ]]; then
        [[ -d $(dirname -- "$STATE_LOCK_FILE") && ! -L $(dirname -- "$STATE_LOCK_FILE") ]] || {
            umask "$previous_umask"
            return 1
        }
        chown 0:0 -- "$(dirname -- "$STATE_LOCK_FILE")" || {
            umask "$previous_umask"
            return 1
        }
        chmod 0700 -- "$(dirname -- "$STATE_LOCK_FILE")" || {
            umask "$previous_umask"
            return 1
        }
    fi
    if ! install -d -m 0700 -- "$CONFIG_DIR" "$CERT_DIR" "$STAGE_DIR"; then
        umask "$previous_umask"
        return 1
    fi
    if [[ ! -e $STATE_FILE ]]; then
        : >"$STATE_FILE" || {
            umask "$previous_umask"
            return 1
        }
    fi
    [[ -f $STATE_FILE && ! -L $STATE_FILE ]] || {
        umask "$previous_umask"
        return 1
    }
    chmod 0700 "$CONFIG_DIR" "$CERT_DIR" "$STAGE_DIR" || {
        umask "$previous_umask"
        return 1
    }
    chmod 0600 "$STATE_FILE" || {
        umask "$previous_umask"
        return 1
    }
    chown 0:0 "$CONFIG_DIR" "$CERT_DIR" "$STAGE_DIR" "$STATE_FILE" || {
        umask "$previous_umask"
        return 1
    }
    _state_secure_regular_file "$STATE_FILE" || {
        umask "$previous_umask"
        _state_error "状态文件最终安全校验失败: ${STATE_FILE}"
        return 1
    }
    umask "$previous_umask"
}

_state_lock_acquire() {
    local lock_dir="${STATE_LOCK_FILE}.d"
    local owner_file="${lock_dir}/pid"
    local token
    local attempt

    token="${BASHPID:-$$}:${RANDOM}:$(date +%s)" || return 1

    if command -v flock >/dev/null 2>&1; then
        exec {OKP_STATE_LOCK_FD}>"$STATE_LOCK_FILE" || return 1
        chmod 0600 "$STATE_LOCK_FILE" || {
            exec {OKP_STATE_LOCK_FD}>&-
            unset OKP_STATE_LOCK_FD
            return 1
        }
        if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
            chown 0:0 "$STATE_LOCK_FILE" || {
                exec {OKP_STATE_LOCK_FD}>&-
                unset OKP_STATE_LOCK_FD
                return 1
            }
        fi
        for ((attempt = 0; attempt < 100; attempt++)); do
            # BusyBox flock supports -n but not util-linux's -w option.
            if flock -n "$OKP_STATE_LOCK_FD"; then
                OKP_STATE_LOCK_MODE=flock
                return 0
            fi
            sleep 0.1
        done
        exec {OKP_STATE_LOCK_FD}>&-
        unset OKP_STATE_LOCK_FD
        _state_error "无法获取状态文件锁: ${STATE_LOCK_FILE}"
        return 1
    fi

    # Conservative fallback for minimal systems. It deliberately never steals
    # a stale lock because doing so without flock has an unavoidable TOCTOU race.
    for ((attempt = 0; attempt < 100; attempt++)); do
        if mkdir -m 0700 -- "$lock_dir" 2>/dev/null; then
            if ! printf '%s\n' "$token" >"${owner_file}.tmp" || \
                ! mv -f -- "${owner_file}.tmp" "$owner_file"; then
                rm -f -- "${owner_file}.tmp"
                rmdir -- "$lock_dir" 2>/dev/null || true
                return 1
            fi
            OKP_STATE_LOCK_DIR=$lock_dir
            OKP_STATE_LOCK_TOKEN=$token
            OKP_STATE_LOCK_MODE='mkdir'
            return 0
        fi
        sleep 0.1
    done

    _state_error "无法获取状态文件锁: ${lock_dir}"
    return 1
}

_state_lock_release() {
    local mode=${OKP_STATE_LOCK_MODE-}
    local lock_dir=${OKP_STATE_LOCK_DIR-}
    local token=${OKP_STATE_LOCK_TOKEN-}
    local owner=''

    if [[ $mode == flock ]]; then
        if [[ -n ${OKP_STATE_LOCK_FD-} ]]; then
            flock -u "$OKP_STATE_LOCK_FD" || true
            exec {OKP_STATE_LOCK_FD}>&-
            unset OKP_STATE_LOCK_FD
        fi
        OKP_STATE_LOCK_MODE=''
        return 0
    fi
    [[ -n $lock_dir ]] || return 0
    if [[ -r ${lock_dir}/pid ]]; then
        IFS= read -r owner <"${lock_dir}/pid" || owner=''
    fi
    if [[ -n $token && $owner == "$token" ]]; then
        rm -f -- "${lock_dir}/pid"
        rmdir -- "$lock_dir" 2>/dev/null || true
    else
        _state_error '状态锁所有权已变化，拒绝释放其他进程的锁。'
    fi
    OKP_STATE_LOCK_DIR=''
    OKP_STATE_LOCK_TOKEN=''
    OKP_STATE_LOCK_MODE=''
}

state_file_get() {
    local file=${1-}
    local wanted=${2-}
    local line key encoded

    _state_validate_key "$wanted" || {
        _state_error "非法状态键: ${wanted}"
        return 2
    }
    _state_secure_regular_file "$file" || return 1
    [[ -r $file ]] || return 1

    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* ]] || continue
        key=${line%%=*}
        [[ $key == "$wanted" ]] || continue
        encoded=${line#*=}
        _state_decode "$encoded" || {
            _state_error "状态键 ${wanted} 的值不是有效 Base64"
            return 3
        }
        return 0
    done <"$file"
    return 1
}

state_get() {
    state_file_get "$STATE_FILE" "${1-}"
}

state_has() {
    state_get "${1-}" >/dev/null
}

state_set_many() {
    local key value encoded temp line line_key index
    local status=0
    local -a keys=()
    local -a encoded_values=()
    local -A replacements=()

    if (($# == 0 || $# % 2 != 0)); then
        _state_error 'state_set_many 需要一个或多个 KEY VALUE 参数对。'
        return 2
    fi
    while (($# > 0)); do
        key=$1
        value=$2
        shift 2
        _state_validate_key "$key" || {
            _state_error "非法状态键: ${key}"
            return 2
        }
        if [[ ${replacements[$key]+present} == present ]]; then
            _state_error "批量状态写入包含重复键: ${key}"
            return 2
        fi
        encoded=$(_state_encode "$value") || return 1
        keys+=("$key")
        encoded_values+=("$encoded")
        replacements["$key"]=$encoded
    done

    state_init || return 1
    _state_lock_acquire || return 1
    temp=$(mktemp "${CONFIG_DIR}/.state.XXXXXX") || status=$?
    if ((status == 0)); then
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line == *=* ]]; then
                line_key=${line%%=*}
                if _state_validate_key "$line_key" && \
                    [[ ${replacements[$line_key]+present} == present ]]; then
                    continue
                fi
            fi
            printf '%s\n' "$line" >>"$temp" || {
                status=$?
                break
            }
        done <"$STATE_FILE"
    fi
    if ((status == 0)); then
        for ((index = 0; index < ${#keys[@]}; index++)); do
            printf '%s=%s\n' "${keys[index]}" "${encoded_values[index]}" >>"$temp" || {
                status=$?
                break
            }
        done
    fi
    if ((status == 0)); then
        chmod 0600 "$temp" || status=$?
    fi
    if ((status == 0)) && [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        chown 0:0 "$temp" || status=$?
    fi
    if ((status == 0)); then
        _state_fsync_if_supported "$temp"
    fi
    if ((status == 0)); then
        mv -f -- "$temp" "$STATE_FILE" || status=$?
    fi
    if ((status == 0)); then
        _state_fsync_parent_if_supported "$STATE_FILE"
        _state_secure_regular_file "$STATE_FILE" || status=1
    fi
    [[ -z ${temp-} || ! -e $temp ]] || rm -f -- "$temp"
    _state_lock_release
    return "$status"
}

state_set() {
    state_set_many "${1-}" "${2-}"
}

state_unset_many() {
    local key temp line line_key
    local status=0
    local -A removals=()

    if (($# == 0)); then
        _state_error 'state_unset_many 需要至少一个状态键。'
        return 2
    fi
    for key in "$@"; do
        _state_validate_key "$key" || {
            _state_error "非法状态键: ${key}"
            return 2
        }
        if [[ ${removals[$key]+present} == present ]]; then
            _state_error "批量状态删除包含重复键: ${key}"
            return 2
        fi
        removals["$key"]=true
    done
    state_init || return 1
    _state_lock_acquire || return 1
    temp=$(mktemp "${CONFIG_DIR}/.state.XXXXXX") || status=$?

    if ((status == 0)); then
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line == *=* ]]; then
                line_key=${line%%=*}
                if _state_validate_key "$line_key" && \
                    [[ ${removals[$line_key]+present} == present ]]; then
                    continue
                fi
            fi
            printf '%s\n' "$line" >>"$temp" || {
                status=$?
                break
            }
        done <"$STATE_FILE"
    fi
    if ((status == 0)); then
        chmod 0600 "$temp" || status=$?
    fi
    if ((status == 0)) && [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        chown 0:0 "$temp" || status=$?
    fi
    if ((status == 0)); then
        _state_fsync_if_supported "$temp"
    fi
    if ((status == 0)); then
        mv -f -- "$temp" "$STATE_FILE" || status=$?
    fi
    if ((status == 0)); then
        _state_fsync_parent_if_supported "$STATE_FILE"
        _state_secure_regular_file "$STATE_FILE" || status=1
    fi
    [[ -z ${temp-} || ! -e $temp ]] || rm -f -- "$temp"
    _state_lock_release
    return "$status"
}

state_unset() {
    state_unset_many "${1-}"
}

state_keys() {
    local line key

    _state_secure_regular_file "$STATE_FILE" || return 0
    [[ -r $STATE_FILE ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* ]] || continue
        key=${line%%=*}
        _state_validate_key "$key" && printf '%s\n' "$key"
    done <"$STATE_FILE"
}

state_key_is_sensitive() {
    local key=${1-}

    case "$key" in
        *PASSWORD* | *PASSWD* | *SECRET* | *TOKEN* | *PRIVATE_KEY* | *ACCESS_KEY* | \
            *CLIENT_UUID* | *SUB_ID*) return 0 ;;
        *) return 1 ;;
    esac
}

state_dump_redacted() {
    local key value

    while IFS= read -r key; do
        if state_key_is_sensitive "$key"; then
            printf '%s=%s\n' "$key" '[REDACTED]'
        else
            value=$(state_get "$key") || value='[INVALID]'
            printf '%s=%s\n' "$key" "$value"
        fi
    done < <(state_keys)
}

_state_random_id() {
    local value

    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        value=$(tr -d '-' </proc/sys/kernel/random/uuid) || return 1
        [[ $value =~ ^[A-Fa-f0-9]{32}$ ]] || return 1
        printf '%s' "$value"
        return
    fi
    if command -v openssl >/dev/null 2>&1; then
        value=$(openssl rand -hex 16) || return 1
        [[ $value =~ ^[A-Fa-f0-9]{32}$ ]] || return 1
        printf '%s' "$value"
        return
    fi
    if command -v uuidgen >/dev/null 2>&1; then
        value=$(uuidgen) || return 1
        value=${value//-/}
        [[ $value =~ ^[A-Fa-f0-9]{32}$ ]] || return 1
        printf '%s' "$value"
        return
    fi
    return 1
}

state_machine_id() {
    local value=''

    if [[ -r /etc/machine-id ]]; then
        IFS= read -r value </etc/machine-id || value=''
    elif [[ -r /var/lib/dbus/machine-id ]]; then
        IFS= read -r value </var/lib/dbus/machine-id || value=''
    fi
    if [[ -n $value ]]; then
        printf 'machine-id:%s' "$value"
    else
        printf 'hostname:%s' "$(hostname 2>/dev/null || printf unknown)"
    fi
}

state_ensure_identity() {
    local installation_id original_machine_id status

    state_init || return 1
    if installation_id=$(state_get INSTALLATION_ID); then
        [[ $installation_id =~ ^[A-Fa-f0-9]{32}$ ]] || {
            _state_error 'INSTALLATION_ID 为空或格式损坏，拒绝静默替换。'
            return 1
        }
    else
        status=$?
        if ((status != 1)); then
            _state_error 'INSTALLATION_ID 无法安全读取，拒绝静默替换。'
            return 1
        fi
        installation_id=$(_state_random_id) || {
            _state_error '无法生成安装标识'
            return 1
        }
        [[ $installation_id =~ ^[A-Fa-f0-9]{32}$ ]] || return 1
        state_set INSTALLATION_ID "$installation_id" || return 1
    fi
    if original_machine_id=$(state_get ORIGINAL_MACHINE_ID); then
        [[ $original_machine_id =~ ^machine-id:[A-Fa-f0-9]{16,}$ || \
            $original_machine_id =~ ^hostname:[A-Za-z0-9._-]+$ ]] || {
            _state_error 'ORIGINAL_MACHINE_ID 为空或格式损坏，拒绝静默替换。'
            return 1
        }
    else
        status=$?
        if ((status != 1)); then
            _state_error 'ORIGINAL_MACHINE_ID 无法安全读取，拒绝静默替换。'
            return 1
        fi
        original_machine_id=$(state_machine_id) || return 1
        state_set ORIGINAL_MACHINE_ID "$original_machine_id" || return 1
    fi
}

_state_file_key_count() {
    local file=${1-}
    local wanted=${2-}
    local line key count=0

    _state_validate_key "$wanted" || return 2
    _state_secure_regular_file "$file" || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* ]] || continue
        key=${line%%=*}
        [[ $key == "$wanted" ]] && count=$((count + 1))
    done <"$file"
    printf '%s' "$count"
}

# The caller must hold the process-wide operation lock and supply a probe that
# returns 0 when an external resource exists, 1 when none exist, and >1 on an
# indeterminate/error result. Only the fixed state file itself is removed.
state_remove_abandoned_initial() {
    local resource_probe=${1-}
    local managed_by marker cert_entry probe_status status=0

    if [[ ! $resource_probe =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || \
        ! declare -F "$resource_probe" >/dev/null 2>&1; then
        _state_error '清理中断初始化状态需要一个有效的资源探针函数。'
        return 2
    fi
    [[ $STATE_FILE == "${CONFIG_DIR}/state.env" ]] || {
        _state_error "拒绝清理非固定状态文件: ${STATE_FILE}"
        return 2
    }
    [[ -e $STATE_FILE || -L $STATE_FILE ]] || return 1
    if _state_is_production && [[ ! ${OKP_OPERATION_LOCK_FD-} =~ ^[0-9]+$ ]]; then
        _state_error '清理中断初始化状态前必须持有全局操作锁。'
        return 2
    fi

    state_init || return 1
    _state_lock_acquire || return 1
    if ! _state_secure_regular_file "$STATE_FILE"; then
        _state_error '中断初始化状态文件未通过安全校验，拒绝清理。'
        status=1
    fi
    if ((status == 0)); then
        if managed_by=$(state_get MANAGED_BY); then
            [[ $managed_by == one-key-proxy ]] || {
                _state_error '状态所有者不是 one-key-proxy，拒绝清理。'
                status=1
            }
        else
            probe_status=$?
            if ((probe_status != 1)); then
                _state_error '无法安全解析中断初始化状态的所有者。'
                status=1
            fi
        fi
    fi
    if ((status == 0)); then
        if ! marker=$(find "$STAGE_DIR" -mindepth 1 -maxdepth 1 -name '*.done' -print -quit 2>/dev/null); then
            _state_error '无法检查阶段标记目录，拒绝清理。'
            status=1
        elif [[ -n $marker ]]; then
            _state_error '检测到已完成阶段标记，状态不属于可清理的初始化中断。'
            status=1
        fi
    fi
    if ((status == 0)); then
        if ! cert_entry=$(find "$CERT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null); then
            _state_error '无法检查证书目录，拒绝清理。'
            status=1
        elif [[ -n $cert_entry ]]; then
            _state_error '检测到证书资源，拒绝清理初始化状态。'
            status=1
        fi
    fi
    if ((status == 0)); then
        if "$resource_probe"; then
            _state_error '检测到外部安装资源，拒绝清理初始化状态。'
            status=1
        else
            probe_status=$?
            if ((probe_status != 1)); then
                _state_error '外部资源探针无法确定资源状态，拒绝清理。'
                status=1
            fi
        fi
    fi
    if ((status == 0)); then
        rm -f -- "$STATE_FILE" || status=$?
        if ((status == 0)); then
            _state_fsync_parent_if_supported "$STATE_FILE"
            _state_info '已清理未创建外部资源的中断初始化状态。'
        fi
    fi
    _state_lock_release
    return "$status"
}

stage_is_done() {
    local stage=${1-}
    local marker marker_stage completed_at stage_count completed_count

    _state_validate_stage "$stage" || {
        _state_error "非法阶段名: ${stage}"
        return 2
    }
    marker="${STAGE_DIR}/${stage}.done"
    _state_secure_regular_file "$marker" || return 1
    stage_count=$(_state_file_key_count "$marker" STAGE) || return 1
    completed_count=$(_state_file_key_count "$marker" COMPLETED_AT) || return 1
    [[ $stage_count == 1 && $completed_count == 1 ]] || return 1
    marker_stage=$(state_file_get "$marker" STAGE) || return 1
    completed_at=$(state_file_get "$marker" COMPLETED_AT) || return 1
    [[ $marker_stage == "$stage" ]] || return 1
    _state_valid_utc_timestamp "$completed_at"
}

stage_mark_done() {
    local stage=${1-}
    local marker temp completed_at status=0

    _state_validate_stage "$stage" || {
        _state_error "非法阶段名: ${stage}"
        return 2
    }
    state_init || return 1
    marker="${STAGE_DIR}/${stage}.done"
    _state_lock_acquire || return 1
    temp=$(mktemp "${STAGE_DIR}/.${stage}.XXXXXX") || status=$?
    if ((status == 0)); then
        completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || status=$?
    fi
    if ((status == 0)); then
        {
            printf 'STAGE=%s\n' "$(_state_encode "$stage")"
            printf 'COMPLETED_AT=%s\n' "$(_state_encode "$completed_at")"
        } >"$temp" || status=$?
    fi
    if ((status == 0)); then
        chmod 0600 "$temp" || status=$?
    fi
    if ((status == 0)) && [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        chown 0:0 "$temp" || status=$?
    fi
    if ((status == 0)); then
        _state_fsync_if_supported "$temp"
        mv -f -- "$temp" "$marker" || status=$?
    fi
    if ((status == 0)); then
        _state_fsync_parent_if_supported "$marker"
        stage_is_done "$stage" || status=1
    fi
    [[ -z ${temp-} || ! -e $temp ]] || rm -f -- "$temp"
    _state_lock_release
    return "$status"
}

stage_clear() {
    local stage=${1-}
    local status=0

    _state_validate_stage "$stage" || {
        _state_error "非法阶段名: ${stage}"
        return 2
    }
    state_init || return 1
    _state_lock_acquire || return 1
    rm -f -- "${STAGE_DIR}/${stage}.done" || status=$?
    ((status != 0)) || _state_fsync_parent_if_supported "${STAGE_DIR}/${stage}.done"
    _state_lock_release
    return "$status"
}

stage_clear_all() {
    local marker stage

    [[ -d $STAGE_DIR ]] || return 0
    for marker in "$STAGE_DIR"/*.done; do
        [[ -e $marker || -L $marker ]] || continue
        stage=${marker##*/}
        stage_clear "${stage%.done}" || return 1
    done
}

stage_next() {
    local stage

    for stage in "$@"; do
        if ! stage_is_done "$stage"; then
            printf '%s\n' "$stage"
            return 0
        fi
    done
    return 1
}

stage_run() {
    local stage=${1-}
    local action=${2-}
    local status

    shift 2 || return 2
    _state_validate_stage "$stage" || {
        _state_error "非法阶段名: ${stage}"
        return 2
    }
    declare -F "$action" >/dev/null 2>&1 || {
        _state_error "阶段 ${stage} 的执行函数不存在: ${action}"
        return 2
    }
    if stage_is_done "$stage"; then
        _state_info "阶段已完成，跳过: ${stage}"
        return 0
    fi

    _state_info "开始阶段: ${stage}"
    if "$action" "$@"; then
        status=0
    else
        status=$?
    fi
    if ((status != 0)); then
        _state_error "阶段失败，可重新运行后续跑: ${stage}"
        return "$status"
    fi
    stage_mark_done "$stage" || return 1
    _state_info "阶段完成: ${stage}"
}

# Stable aliases used by the installer orchestration layer.
stage_done() {
    stage_is_done "$@"
}

stage_mark() {
    stage_mark_done "$@"
}

run_stage() {
    stage_run "$@"
}

_result_write_header() {
    local file=$1

    {
        printf 'one-key-proxy 部署结果\n'
        printf '生成时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
        printf '%s\n' '========================================'
    } >"$file"
}

_result_atomic_update() {
    local action=$1
    local first=${2-}
    local second=${3-}
    local parent temp previous_umask
    local status=0

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        _state_error "结果文件只能由 root 写入: ${RESULT_FILE}"
        return 1
    fi
    state_init || return 1
    parent=$(dirname -- "$RESULT_FILE") || return 1
    previous_umask=$(umask)
    umask 077
    if ! install -d -m 0700 -- "$parent"; then
        umask "$previous_umask"
        return 1
    fi
    if [[ -L $RESULT_FILE || ( -e $RESULT_FILE && ! -f $RESULT_FILE ) ]]; then
        umask "$previous_umask"
        _state_error "拒绝写入非普通结果文件: ${RESULT_FILE}"
        return 1
    fi
    _state_lock_acquire || {
        umask "$previous_umask"
        return 1
    }
    if [[ -L $RESULT_FILE || ( -e $RESULT_FILE && ! -f $RESULT_FILE ) ]]; then
        status=1
    else
        temp=$(mktemp "${parent}/.one-key-proxy-result.XXXXXX") || status=$?
    fi
    if ((status == 0)); then
        case "$action" in
            reset) _result_write_header "$temp" || status=$? ;;
            add | section)
                if [[ -f $RESULT_FILE ]]; then
                    cp -- "$RESULT_FILE" "$temp" || status=$?
                else
                    _result_write_header "$temp" || status=$?
                fi
                if ((status == 0)); then
                    if [[ $action == add ]]; then
                        printf '%s: %s\n' "$first" "$second" >>"$temp" || status=$?
                    else
                        printf '\n[%s]\n' "$first" >>"$temp" || status=$?
                    fi
                fi
                ;;
            *) status=2 ;;
        esac
    fi
    if ((status == 0)); then
        chmod 0600 "$temp" || status=$?
    fi
    if ((status == 0)); then
        chown 0:0 "$parent" "$temp" || status=$?
    fi
    if ((status == 0)); then
        _state_fsync_if_supported "$temp"
    fi
    if ((status == 0)); then
        mv -f -- "$temp" "$RESULT_FILE" || status=$?
    fi
    if ((status == 0)); then
        _state_fsync_parent_if_supported "$RESULT_FILE"
    fi
    [[ -z ${temp-} || ! -e $temp ]] || rm -f -- "$temp"
    _state_lock_release
    umask "$previous_umask"
    return "$status"
}

result_reset() {
    _result_atomic_update reset
}

result_add() {
    local label=${1-}
    local value=${2-}
    local normalized_label=${label^^}

    [[ $label != *$'\n'* && $label != *$'\r'* ]] || {
        _state_error '结果字段名不能包含换行符'
        return 2
    }
    case "$normalized_label" in
        *ALI*SECRET* | *ACCESS*KEY*SECRET* | *API*TOKEN* | *REALITY*PRIVATE* | \
            *TLS*PRIVATE* | *CERTIFICATE*PRIVATE*)
            _state_error "禁止把该敏感字段写入结果文件: ${label}"
            return 2
            ;;
    esac
    _result_atomic_update add "$label" "$value"
}

result_section() {
    local title=${1-}

    [[ $title != *$'\n'* && $title != *$'\r'* ]] || return 2
    _result_atomic_update section "$title"
}

secret_register() {
    local secret=${1-}

    [[ -n $secret ]] || return 0
    OKP_SECRET_VALUES+=("$secret")
}

redact_sensitive() {
    local text=${1-}
    local secret

    for secret in "${OKP_SECRET_VALUES[@]}"; do
        ((${#secret} >= 4)) || continue
        text=${text//"$secret"/[REDACTED]}
    done

    # This second pass protects common key=value and JSON-like log fragments,
    # including secrets a caller forgot to register explicitly.
    printf '%s' "$text" | sed -E \
        -e 's/((access[_ -]?key[_ -]?secret|ali[_ -]?secret|password|passwd|token|private[_ -]?key|api[_ -]?key)[[:space:]]*[=:][[:space:]]*)[^[:space:],;]+/\1[REDACTED]/Ig' \
        -e 's/("(accessKeySecret|Ali_Secret|password|passwd|token|privateKey|apiKey)"[[:space:]]*:[[:space:]]*")[^"]*/\1[REDACTED]/Ig' \
        -e 's/((proxy-)?authorization[[:space:]]*:[[:space:]]*)(Bearer[[:space:]]+|Basic[[:space:]]+)?[^[:space:],;]+/\1[REDACTED]/Ig'
}

safe_log_info() {
    local message
    message=$(redact_sensitive "$*")
    if declare -F log_info >/dev/null 2>&1; then
        log_info "$message"
    else
        printf '%s\n' "$message"
    fi
}

safe_log_warn() {
    local message
    message=$(redact_sensitive "$*")
    if declare -F log_warn >/dev/null 2>&1; then
        log_warn "$message"
    else
        printf 'WARN: %s\n' "$message" >&2
    fi
}

safe_log_error() {
    local message
    message=$(redact_sensitive "$*")
    if declare -F log_error >/dev/null 2>&1; then
        log_error "$message"
    else
        printf 'ERROR: %s\n' "$message" >&2
    fi
}

sanitize_log_file() {
    local source_file=${1:-$LOG_FILE}
    local temp line

    [[ -f $source_file ]] || return 0
    temp="${source_file}.$$.sanitized"
    : >"$temp" || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        redact_sensitive "$line" >>"$temp" || {
            rm -f -- "$temp"
            return 1
        }
        printf '\n' >>"$temp"
    done <"$source_file"
    chmod --reference="$source_file" "$temp" 2>/dev/null || chmod 0600 "$temp"
    mv -f -- "$temp" "$source_file"
}

run_sensitive() {
    local output status

    output=$(mktemp "${TMPDIR:-/tmp}/one-key-proxy-command.XXXXXX") || return 1
    chmod 0600 "$output"
    if "$@" >"$output" 2>&1; then
        status=0
    else
        status=$?
    fi
    if ((status != 0)); then
        while IFS= read -r line || [[ -n $line ]]; do
            safe_log_error "$line"
        done <"$output"
    fi
    rm -f -- "$output"
    return "$status"
}
