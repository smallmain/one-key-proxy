#!/usr/bin/env bash

# Integration hooks consumed by maintenance.sh. This library is sourced after
# common/state/platform/config/alidns/cert/3xui and therefore deliberately uses
# those stable interfaces instead of reading x-ui.db directly.

if [[ ${OKP_PRODUCTION_MODE:-false} == true ]]; then
    OKP_PROJECT_REPO=smallmain/one-key-proxy
    OKP_PROJECT_BRANCH=main
    OKP_XUI_REPO=MHSanaei/3x-ui
    OKP_XUI_BINARY_PATH=/usr/local/x-ui/x-ui
    OKP_XUI_INSTALL_RESULT_PATH=/etc/x-ui/install-result.env
    RUNTIME_DIR=/usr/local/lib/one-key-proxy
else
    : "${OKP_PROJECT_REPO:=smallmain/one-key-proxy}"
    : "${OKP_PROJECT_BRANCH:=main}"
    : "${OKP_XUI_REPO:=MHSanaei/3x-ui}"
    : "${OKP_XUI_BINARY_PATH:=/usr/local/x-ui/x-ui}"
    : "${OKP_XUI_INSTALL_RESULT_PATH:=/etc/x-ui/install-result.env}"
    : "${RUNTIME_DIR:=/usr/local/lib/one-key-proxy}"
fi

OKP_INTEGRATION_BACKUP_WAS_ACTIVE=false
OKP_PROJECT_TARGET_COMMIT=''
OKP_PROJECT_TARGET_VERSION=''
OKP_XUI_TARGET_TAG=''
OKP_XUI_TARGET_COMMIT=''
OKP_XUI_TARGET_ASSET_SHA256=''
OKP_XUI_UPDATE_CHILD_PID=''
OKP_XUI_UPDATE_PENDING_SIGNAL=''
OKP_XUI_UPDATE_SUPERVISION_ARMED=false
OKP_XUI_UPDATE_RECOVERY_SETTLED=false
OKP_XUI_UPDATE_SETTLEMENT_MODE=''
OKP_XUI_UPDATE_SAVED_HUP_TRAP=''
OKP_XUI_UPDATE_SAVED_INT_TRAP=''
OKP_XUI_UPDATE_SAVED_TERM_TRAP=''
OKP_XUI_UPDATE_SAVED_EXIT_TRAP=''

_okp_i_state() {
    local value
    value=$(state_get "$1" 2>/dev/null) || value=${2-}
    printf '%s' "$value"
}

_okp_i_register_state_secrets() {
    local key value
    for key in PANEL_PASSWORD ALI_ACCESS_KEY_ID ALI_ACCESS_KEY_SECRET XUI_API_TOKEN \
        CLIENT_UUID SUB_ID REALITY_SHORT_ID REALITY_PRIVATE_KEY VLESS_URI \
        SUBSCRIPTION_URL JSON_SUBSCRIPTION_URL CLASH_SUBSCRIPTION_URL; do
        value=$(_okp_i_state "$key")
        [[ -n $value ]] && secret_register "$value"
    done
}

_okp_i_load_ownership_context() {
    local installation_id expected_inbound_tag expected_host_tag
    local inbound_id host_group_id inbound_tag host_tag
    installation_id=$(_okp_i_state INSTALLATION_ID)
    [[ $installation_id =~ ^[A-Fa-f0-9]{32}$ ]] || {
        log_error '安装标识无效，拒绝解析受管资源所有权。'
        return 1
    }
    expected_inbound_tag="one-key-proxy-${installation_id:0:16}"
    expected_host_tag="one-key-proxy-host-${installation_id:0:16}"
    inbound_tag=$(_okp_i_state INBOUND_TAG)
    host_tag=$(_okp_i_state HOST_TAG)
    inbound_id=$(_okp_i_state INBOUND_ID)
    host_group_id=$(_okp_i_state HOST_GROUP_ID)
    [[ $inbound_tag == "$expected_inbound_tag" && $host_tag == "$expected_host_tag" &&
        $inbound_id =~ ^[1-9][0-9]*$ && -n $host_group_id &&
        $host_group_id =~ ^[A-Za-z0-9._:-]+$ ]] || {
        log_error '受管入站或 Host 的 ID/tag 所有权状态不完整，拒绝猜测资源。'
        return 1
    }
    declare -g OKP_INBOUND_TAG="$inbound_tag" OKP_HOST_TAG="$host_tag"
    declare -g OKP_INBOUND_ID="$inbound_id" OKP_HOST_GROUP_ID="$host_group_id"
    # Unique remarks prevent the lower-level compatibility finder from treating
    # a legacy fixed remark on an external object as project ownership.
    declare -g XUI_MANAGED_TAG="$inbound_tag" XUI_MANAGED_REMARK="$inbound_tag"
    declare -g XUI_MANAGED_HOST_TAG="$host_tag" XUI_MANAGED_HOST_REMARK="$host_tag"
}

_okp_i_find_owned_inbound() {
    local status actual_id actual_tag
    _okp_i_load_ownership_context || return 2
    if xui_find_managed_inbound; then
        status=0
    else
        status=$?
        return "$status"
    fi
    actual_id=$(jq -r '.id // empty' <<<"$XUI_MANAGED_INBOUND_JSON") || return 2
    actual_tag=$(jq -r '.tag // empty' <<<"$XUI_MANAGED_INBOUND_JSON") || return 2
    if [[ $actual_id != "$OKP_INBOUND_ID" || $actual_tag != "$OKP_INBOUND_TAG" ]]; then
        log_error '入站仅匹配名称但 ID/tag 不同时一致，拒绝将其视为受管资源。'
        return 2
    fi
    return 0
}

_okp_i_verify_owned_host() {
    local inbound_id=$1 groups count
    _okp_i_load_ownership_context || return 2
    [[ $inbound_id == "$OKP_INBOUND_ID" ]] || return 2
    groups=$(xui_api_get "/panel/api/hosts/byInbound/${inbound_id}") || return 2
    [[ $groups == null ]] && groups='[]'
    count=$(jq -r --arg id "$OKP_HOST_GROUP_ID" --arg tag "$OKP_HOST_TAG" \
        --arg inbound "$inbound_id" '
        [.[] | select(
            ((.groupId // "") | tostring) == $id and
            (((.tags // []) | index($tag)) != null) and
            (((.inboundIds // []) | map(tostring) | index($inbound)) != null)
        )] | length
    ' <<<"$groups") || return 2
    [[ $count == 1 ]] || {
        log_error 'Host 发布组未通过保存的 ID、tag 和入站 ID 三重所有权校验。'
        return 2
    }
    declare -g XUI_MANAGED_HOST_GROUP_ID="$OKP_HOST_GROUP_ID"
}

_okp_i_update_owned_host() {
    local inbound_id=$1 public_host=$2 external_port=$3
    _okp_i_verify_owned_host "$inbound_id" || return 1
    xui_ensure_external_host "$inbound_id" "$public_host" "$external_port" \
        "$OKP_HOST_TAG" "$OKP_HOST_TAG" || return 1
    [[ $XUI_MANAGED_HOST_GROUP_ID == "$OKP_HOST_GROUP_ID" ]] || {
        log_error 'Host 发布组更新返回了非受管资源 ID。'
        return 1
    }
    _okp_i_verify_owned_host "$inbound_id"
}

_okp_i_tls_host_valid() {
    [[ $# -eq 2 ]] || return 2
    local mode=$1 host=$2
    case $mode in
        nat)
            if declare -F valid_ipv4 >/dev/null 2>&1; then
                valid_ipv4 "$host"
            else
                [[ $host =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
            fi
            ;;
        public)
            if declare -F valid_hostname >/dev/null 2>&1; then
                valid_hostname "$host"
            else
                [[ $host =~ ^[A-Za-z0-9.-]+$ && $host == *.* ]]
            fi
            ;;
        *) return 1 ;;
    esac
}

_okp_i_tls_cert_matches_host() {
    [[ $# -eq 2 ]] || return 2
    local mode=$1 host=$2 cert_file=${CERT_DIR}/server.crt
    [[ -f $cert_file && ! -L $cert_file && -r $cert_file ]] || return 1
    case $mode in
        nat) _okp_cert_verify_ip_san "$cert_file" "$host" ;;
        public) _okp_cert_verify_dns_san "$cert_file" "$host" ;;
        *) return 1 ;;
    esac
}

_okp_i_tls_saved_host() {
    [[ $# -eq 1 ]] || return 2
    case $1 in
        nat) _okp_i_state PUBLIC_IPV4 ;;
        public) _okp_i_state FQDN ;;
        *) return 1 ;;
    esac
}

_okp_i_tls_transition_read() {
    local status='' host='' status_rc=0 host_rc=0
    local status_present=false host_present=false
    if status=$(state_get XUI_TLS_TRANSITION_STATUS 2>/dev/null); then
        status_present=true
    else
        status_rc=$?
        ((status_rc == 1)) || {
            log_error '无法安全读取 TLS 身份切换状态。'
            return 2
        }
    fi
    if host=$(state_get XUI_TLS_TRANSITION_HOST 2>/dev/null); then
        host_present=true
    else
        host_rc=$?
        ((host_rc == 1)) || {
            log_error '无法安全读取 TLS 身份切换目标。'
            return 2
        }
    fi
    if [[ $status_present == false && $host_present == false ]]; then
        declare -g OKP_TLS_TRANSITION_STATUS='' OKP_TLS_TRANSITION_HOST=''
        return 1
    fi
    [[ $status_present == true && $host_present == true &&
        -n $status && -n $host && ($status == preparing || $status == active) ]] || {
        log_error 'TLS 身份切换事务状态不完整或已损坏。'
        return 2
    }
    declare -g OKP_TLS_TRANSITION_STATUS=$status OKP_TLS_TRANSITION_HOST=$host
}

_okp_i_begin_tls_transition() {
    [[ $# -eq 2 ]] || return 2
    local mode=$1 host=$2 read_status=0
    _okp_i_tls_host_valid "$mode" "$host" || {
        log_error '拒绝为无效的 TLS 主机身份创建切换事务。'
        return 1
    }
    if _okp_i_tls_transition_read; then
        [[ $OKP_TLS_TRANSITION_HOST == "$host" ]] || {
            log_error "已有未完成的 TLS 身份切换（目标 ${OKP_TLS_TRANSITION_HOST}），拒绝覆盖。"
            return 1
        }
    else
        read_status=$?
        ((read_status == 1)) || return "$read_status"
    fi
    state_set_many XUI_TLS_TRANSITION_STATUS preparing XUI_TLS_TRANSITION_HOST "$host"
}

_okp_i_wait_transition_api() {
    local attempt
    for ((attempt = 1; attempt <= 15; attempt++)); do
        if platform_service_is_active x-ui &&
            xui_api_get /panel/api/server/status >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    log_error '3x-ui 未能使用新证书身份恢复管理 API。'
    return 1
}

_okp_i_activate_tls_transition() {
    [[ $# -eq 2 ]] || return 2
    local mode=$1 host=$2
    _okp_i_tls_transition_read || return 1
    [[ $OKP_TLS_TRANSITION_STATUS == preparing && $OKP_TLS_TRANSITION_HOST == "$host" ]] || {
        log_error 'TLS 身份切换事务与待启用证书不一致。'
        return 1
    }
    _okp_i_tls_cert_matches_host "$mode" "$host" || {
        log_error '替换证书未包含预期 SAN，拒绝启用 TLS 身份切换。'
        return 1
    }
    platform_service_restart x-ui || return 1
    state_set XUI_TLS_TRANSITION_STATUS active || return 1
    _okp_i_wait_transition_api
}

_okp_i_clear_tls_transition() {
    state_unset_many XUI_TLS_TRANSITION_STATUS XUI_TLS_TRANSITION_HOST
}

# Recover a certificate replacement interrupted after its durable journal was
# written. A preparing transaction is promoted only after the replacement SAN
# is verified and x-ui has been restarted. If the old certificate is still in
# place, the unused journal is removed without changing the saved identity.
_okp_i_recover_tls_transition() {
    local read_status=0 mode target saved_host
    if _okp_i_tls_transition_read; then
        :
    else
        read_status=$?
        ((read_status == 1)) && return 0
        return "$read_status"
    fi

    if declare -F maintenance_operation_lock >/dev/null 2>&1; then
        maintenance_operation_lock || return 1
        # The writer may have completed while this process waited for its lock.
        if _okp_i_tls_transition_read; then
            :
        else
            read_status=$?
            ((read_status == 1)) && return 0
            return "$read_status"
        fi
    fi

    mode=$(_okp_i_state MODE)
    target=$OKP_TLS_TRANSITION_HOST
    _okp_i_tls_host_valid "$mode" "$target" || {
        log_error 'TLS 身份切换目标与部署模式不匹配。'
        return 1
    }
    if [[ $OKP_TLS_TRANSITION_STATUS == preparing ]]; then
        if _okp_i_tls_cert_matches_host "$mode" "$target"; then
            log_warn "检测到未完成的 TLS 证书切换，正在恢复目标 ${target}。"
            _okp_i_activate_tls_transition "$mode" "$target" || return 1
        else
            saved_host=$(_okp_i_tls_saved_host "$mode") || return 1
            if ! _okp_i_tls_host_valid "$mode" "$saved_host" ||
                ! _okp_i_tls_cert_matches_host "$mode" "$saved_host"; then
                log_error '当前证书既不匹配 TLS 切换目标，也不匹配已保存身份；拒绝猜测恢复。'
                return 1
            fi
            _okp_i_verify_subscription_delivery "$saved_host" || {
                log_error '原 TLS 身份的订阅未通过恢复验收，切换事务保持待处理。'
                return 1
            }
            _okp_i_clear_tls_transition || return 1
            log_warn '未发现已写入的新证书，已保留原 TLS 身份并清理未使用的切换事务。'
            return 0
        fi
    fi

    _okp_i_tls_cert_matches_host "$mode" "$target" || {
        log_error '已启用的 TLS 身份切换与当前证书 SAN 不一致。'
        return 1
    }
    saved_host=$(_okp_i_tls_saved_host "$mode") || return 1
    if [[ $saved_host == "$target" ]]; then
        _okp_i_wait_transition_api || return 1
        _okp_i_verify_subscription_delivery "$target" || {
            log_error '新 TLS 身份的订阅未通过恢复验收，切换事务保持待处理。'
            return 1
        }
        _okp_i_clear_tls_transition || return 1
        log_info '已完成中断的 TLS 证书切换恢复。'
    fi
}

_okp_i_complete_tls_transition() {
    [[ $# -eq 2 ]] || return 2
    local mode=$1 expected_host=$2 read_status=0
    if _okp_i_tls_transition_read; then
        :
    else
        read_status=$?
        ((read_status == 1)) && return 0
        return "$read_status"
    fi
    [[ $OKP_TLS_TRANSITION_STATUS == active &&
        $OKP_TLS_TRANSITION_HOST == "$expected_host" ]] || {
        log_error 'TLS 身份切换尚未启用或目标不一致，拒绝提交。'
        return 1
    }
    _okp_i_tls_cert_matches_host "$mode" "$expected_host" || return 1
    _okp_i_clear_tls_transition
}

_okp_i_xui_update_transition_read() {
    local marker read_status=0
    if marker=$(state_get XUI_UPDATE_RECOVERY_STATUS 2>/dev/null); then
        [[ $marker == restore-root-path ]] || {
            log_error '3x-ui 更新恢复事务状态无效。'
            return 2
        }
        return 0
    else
        read_status=$?
    fi
    ((read_status == 1)) && return 1
    log_error '无法安全读取 3x-ui 更新恢复事务。'
    return 2
}

_okp_i_xui_autostart_status() {
    local init=${PLATFORM_INIT:-} output count
    [[ -n $init ]] || {
        platform_detect_init || return 2
        init=${PLATFORM_INIT:-}
    }
    case $init in
        systemd)
            output=$(systemctl is-enabled x-ui 2>/dev/null) || true
            case $output in
                enabled) return 0 ;;
                disabled | masked | masked-runtime) return 1 ;;
                *) return 2 ;;
            esac
            ;;
        openrc)
            output=$(rc-update show default 2>/dev/null) || return 2
            count=$(awk '$1 == "x-ui" { count++ } END { print count + 0 }' <<<"$output") || return 2
            case $count in
                0) return 1 ;;
                1) return 0 ;;
                *) return 2 ;;
            esac
            ;;
        *) return 2 ;;
    esac
}

_okp_i_fail_close_xui_update() {
    local inactive_status=0 autostart_status=0 stopped=false disabled=false
    platform_service_stop x-ui >/dev/null 2>&1 || true
    if platform_service_is_inactive x-ui; then
        stopped=true
    else
        inactive_status=$?
        log_error "无法确认 x-ui 已停止（状态 ${inactive_status}）；请立即人工停止服务并从保护备份恢复。"
    fi
    # Disabling autostart is independent from proving the current process has
    # stopped. Attempt both protections so an indeterminate stop probe cannot
    # leave an avoidable reboot exposure behind.
    if ! platform_service_disable x-ui >/dev/null 2>&1; then
        log_error '无法执行 x-ui 开机自启禁用命令；正在独立核验实际状态。'
    fi
    if _okp_i_xui_autostart_status; then
        log_error '禁用 x-ui 自启后仍检测到启用状态；请立即人工禁用。'
    else
        autostart_status=$?
        if ((autostart_status == 1)); then
            disabled=true
        else
            log_error '无法确认 x-ui 开机自启已禁用；请立即人工禁用。'
        fi
    fi
    if [[ $stopped != true || $disabled != true ]]; then
        log_error '3x-ui 更新失败关闭未能同时确认“已停止且已禁用自启”。'
    fi
    OKP_MAINTENANCE_FATAL=true
    return 1
}

# The official updater treats the deliberately configured root path as an
# unsafe short path and replaces it with a random one. Repair it through the
# local CLI while x-ui is stopped, before any HTTP API call can depend on '/'.
_okp_i_restore_xui_root_path_offline() {
    local inactive_status=0 probe base_path

    if platform_service_is_inactive x-ui; then
        :
    else
        inactive_status=$?
        if ((inactive_status != 1 && inactive_status != 2)); then
            log_error '无法判定 x-ui 更新后的运行状态。'
            return 1
        fi
        platform_service_stop x-ui || {
            log_error '无法停止 x-ui，拒绝在运行中的数据库上恢复面板根路径。'
            return 1
        }
        platform_service_is_inactive x-ui || {
            log_error '停止命令返回成功，但无法确认 x-ui 已停止。'
            return 1
        }
    fi

    [[ -f $OKP_XUI_BINARY_PATH && ! -L $OKP_XUI_BINARY_PATH &&
        -x $OKP_XUI_BINARY_PATH ]] || {
        log_error '更新后的 3x-ui 本地二进制不存在、不可执行或类型不安全。'
        return 1
    }
    probe=$(mktemp "/tmp/one-key-proxy-xui-setting.XXXXXX") || return 1
    chmod 0600 "$probe" || {
        rm -f -- "$probe"
        return 1
    }
    if declare -F maintenance_temp_register >/dev/null 2>&1; then
        maintenance_temp_register "$probe" || {
            rm -f -- "$probe"
            return 1
        }
    fi

    if ! "$OKP_XUI_BINARY_PATH" setting -webBasePath / >"$probe" 2>&1 ||
        ! "$OKP_XUI_BINARY_PATH" setting -show true >"$probe" 2>&1; then
        rm -f -- "$probe"
        if declare -F maintenance_temp_unregister >/dev/null 2>&1; then
            maintenance_temp_unregister "$probe"
        fi
        log_error '无法通过 3x-ui 本地 CLI 恢复并回读面板根路径。'
        return 1
    fi
    base_path=$(sed -n 's/^webBasePath: //p' "$probe") || base_path=''
    rm -f -- "$probe"
    if declare -F maintenance_temp_unregister >/dev/null 2>&1; then
        maintenance_temp_unregister "$probe"
    fi
    [[ $base_path == / ]] || {
        log_error '3x-ui 本地 CLI 未确认 webBasePath 已恢复为 /。'
        return 1
    }
}

_okp_i_recover_xui_update_transition() {
    local read_status=0 attempt ready=false inbound_tag node_port autostart_status=0
    if _okp_i_xui_update_transition_read; then
        :
    else
        read_status=$?
        ((read_status == 1)) && return 0
        # An invalid or unreadable marker may mean the updater already changed
        # the database. Acquire the operation lock and fail closed if the
        # journal is still untrustworthy when read again under that lock.
    fi

    declare -F maintenance_operation_lock >/dev/null 2>&1 || {
        log_error '缺少维护操作锁，拒绝执行 3x-ui 更新恢复。'
        return 1
    }
    maintenance_operation_lock || return 1
    # The transaction may have completed while this process waited. Re-read
    # under the lock before performing any service or database mutation.
    if _okp_i_xui_update_transition_read; then
        :
    else
        read_status=$?
        ((read_status == 1)) && return 0
        _okp_i_fail_close_xui_update
        return "$read_status"
    fi

    log_warn '检测到 3x-ui 更新恢复事务，正在离线恢复面板根路径。'
    _okp_i_restore_xui_root_path_offline || {
        log_error '面板根路径恢复失败；x-ui 将保持停止，保护备份仍可用于恢复。'
        _okp_i_fail_close_xui_update
        return 1
    }
    platform_service_enable x-ui >/dev/null 2>&1 || {
        log_error '面板根路径已恢复，但无法启用 x-ui 开机自启。'
        _okp_i_fail_close_xui_update
        return 1
    }
    if _okp_i_xui_autostart_status; then
        :
    else
        autostart_status=$?
        log_error "启用 x-ui 后无法确认开机自启状态（状态 ${autostart_status}）。"
        _okp_i_fail_close_xui_update
        return 1
    fi
    platform_service_start x-ui || {
        log_error '面板根路径已恢复，但 x-ui 无法启动。'
        _okp_i_fail_close_xui_update
        return 1
    }
    for ((attempt = 1; attempt <= 15; attempt++)); do
        if platform_service_is_active x-ui &&
            xui_api_get /panel/api/server/status >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 2
    done
    if [[ $ready != true ]] || ! xui_check_required_endpoints; then
        log_error '恢复根路径后 3x-ui 管理 API 未通过兼容性检查。'
        _okp_i_fail_close_xui_update
        return 1
    fi
    inbound_tag=$(_okp_i_state INBOUND_TAG)
    node_port=$(_okp_i_state NODE_INTERNAL_PORT)
    if [[ -z $inbound_tag || ! $node_port =~ ^[0-9]+$ ]] ||
        ((node_port < 1 || node_port > 65535)) ||
        ! xui_verify_xray_runtime "$inbound_tag" "$node_port" 15 2; then
        log_error '恢复根路径后 Xray 运行态未通过受管入站检查。'
        _okp_i_fail_close_xui_update
        return 1
    fi
    if ! _okp_i_verify_subscription_delivery; then
        log_error '恢复根路径后三类订阅未通过验收。'
        _okp_i_fail_close_xui_update
        return 1
    fi
    state_set XUI_XRAY_VERSION "$XUI_XRAY_VERSION" || {
        _okp_i_fail_close_xui_update
        return 1
    }
    state_unset_many XUI_UPDATE_RECOVERY_STATUS || {
        _okp_i_fail_close_xui_update
        return 1
    }
    log_info '3x-ui 面板根路径恢复事务已完成。'
}

_okp_i_xui_update_fail_closed_verified() {
    local autostart_status=0
    platform_service_is_inactive x-ui || return 1
    if _okp_i_xui_autostart_status; then
        return 1
    else
        autostart_status=$?
    fi
    ((autostart_status == 1))
}

# Return 0 when a process group has an executable member, 1 when every visible
# member is a zombie, and 2 when procfs cannot prove either result. The comm
# field in /proc/PID/stat can contain spaces and parentheses, so parse from its
# final ") " delimiter rather than splitting the whole record.
_okp_i_xui_update_proc_group_status() {
    [[ $# -eq 2 ]] || return 2
    local pgid=$1 proc_root=$2 proc_stat stat_line stat_rest state pgrp
    local scanned=false matched=false
    [[ $pgid =~ ^[1-9][0-9]*$ && -d $proc_root ]] || return 2

    for proc_stat in "$proc_root"/[0-9]*/stat; do
        [[ -r $proc_stat ]] || continue
        stat_line=''
        IFS= read -r stat_line <"$proc_stat" || continue
        scanned=true
        [[ $stat_line == *') '* ]] || continue
        stat_rest=${stat_line##*) }
        state=''
        pgrp=''
        read -r state _ pgrp _ <<<"$stat_rest" || continue
        [[ $pgrp == "$pgid" ]] || continue
        matched=true
        case $state in
            Z | X | x) ;;
            *) return 0 ;;
        esac
    done
    [[ $scanned == true ]] || return 2
    [[ $matched == true ]] && return 1
    return 2
}

# Return 0 for a group that may still execute updater code, 1 only when it is
# proven gone (or zombie-only), and 2 when liveness is indeterminate.
_okp_i_xui_update_group_status() {
    local pid=$OKP_XUI_UPDATE_CHILD_PID
    [[ -n $pid && $pid =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 -- "-$pid" 2>/dev/null || return 1
    if [[ -d /proc ]]; then
        _okp_i_xui_update_proc_group_status "$pid" /proc
        return $?
    fi
    # Supported production targets are Linux. This fallback keeps non-Linux
    # development environments conservative when a group answers kill -0.
    return 0
}

_okp_i_terminate_xui_update_group() {
    local attempt pid=$OKP_XUI_UPDATE_CHILD_PID group_status=0
    [[ -n $pid && $pid =~ ^[1-9][0-9]*$ ]] || return 0

    kill -TERM -- "-$pid" 2>/dev/null || true
    for ((attempt = 0; attempt < 50; attempt++)); do
        if _okp_i_xui_update_group_status; then
            group_status=0
        else
            group_status=$?
            ((group_status == 1)) && break
        fi
        sleep 0.1
    done
    if ((group_status != 1)); then
        kill -KILL -- "-$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    for ((attempt = 0; attempt < 100; attempt++)); do
        if _okp_i_xui_update_group_status; then
            group_status=0
        else
            group_status=$?
            ((group_status == 1)) && break
        fi
        sleep 0.1
    done
    if ((group_status != 1)); then
        log_error "无法确认 3x-ui 更新器进程组 ${pid} 已停止；操作锁仍不得释放。"
        return 1
    fi
    OKP_XUI_UPDATE_CHILD_PID=''
}

_okp_i_settle_interrupted_xui_update() {
    _okp_i_terminate_xui_update_group || return 1
    if _okp_i_recover_xui_update_transition; then
        OKP_XUI_UPDATE_RECOVERY_SETTLED=true
        OKP_XUI_UPDATE_SETTLEMENT_MODE=recovered
        return 0
    fi
    if _okp_i_xui_update_fail_closed_verified; then
        OKP_XUI_UPDATE_RECOVERY_SETTLED=true
        OKP_XUI_UPDATE_SETTLEMENT_MODE=fail-closed
        return 0
    fi
    _okp_i_fail_close_xui_update || true
    if _okp_i_xui_update_fail_closed_verified; then
        OKP_XUI_UPDATE_RECOVERY_SETTLED=true
        OKP_XUI_UPDATE_SETTLEMENT_MODE=fail-closed
        return 0
    fi
    log_error '中断更新既未恢复，也无法确认 x-ui 已停止且禁用自启。'
    return 1
}

_okp_i_hold_xui_update_lock_until_settled() {
    local attempt=0
    OKP_MAINTENANCE_FATAL=true
    log_error '3x-ui 更新事务尚未安全收敛；进程将继续持有操作锁并重试，请立即人工检查。'
    while :; do
        ((attempt += 1))
        if _okp_i_settle_interrupted_xui_update; then
            return 0
        fi
        if ((attempt % 30 == 0)); then
            log_error '3x-ui 更新事务仍未安全收敛，操作锁继续保持。'
        fi
        sleep 1 || true
    done
}

_okp_i_record_xui_update_signal() {
    local signal=$1
    [[ -n $OKP_XUI_UPDATE_PENDING_SIGNAL ]] || OKP_XUI_UPDATE_PENDING_SIGNAL=$signal
    if [[ -n $OKP_XUI_UPDATE_CHILD_PID ]]; then
        kill -TERM -- "-${OKP_XUI_UPDATE_CHILD_PID}" 2>/dev/null || true
    fi
}

_okp_i_restore_saved_trap() {
    local signal=$1 saved=$2
    trap - "$signal"
    if [[ -n $saved ]]; then
        # trap -p is generated by this shell, so restoring it via eval does not
        # consume external or state-file input.
        # shellcheck disable=SC2294
        eval "$saved"
    fi
}

_okp_i_restore_xui_update_traps() {
    _okp_i_restore_saved_trap HUP "$OKP_XUI_UPDATE_SAVED_HUP_TRAP"
    _okp_i_restore_saved_trap INT "$OKP_XUI_UPDATE_SAVED_INT_TRAP"
    _okp_i_restore_saved_trap TERM "$OKP_XUI_UPDATE_SAVED_TERM_TRAP"
    _okp_i_restore_saved_trap EXIT "$OKP_XUI_UPDATE_SAVED_EXIT_TRAP"
}

_okp_i_arm_xui_update_supervision() {
    [[ $OKP_XUI_UPDATE_SUPERVISION_ARMED != true ]] || {
        log_error '3x-ui 更新监督器已启用，拒绝递归进入。'
        return 1
    }
    OKP_XUI_UPDATE_SAVED_HUP_TRAP=$(trap -p HUP)
    OKP_XUI_UPDATE_SAVED_INT_TRAP=$(trap -p INT)
    OKP_XUI_UPDATE_SAVED_TERM_TRAP=$(trap -p TERM)
    OKP_XUI_UPDATE_SAVED_EXIT_TRAP=$(trap -p EXIT)
    OKP_XUI_UPDATE_CHILD_PID=''
    OKP_XUI_UPDATE_PENDING_SIGNAL=''
    OKP_XUI_UPDATE_RECOVERY_SETTLED=false
    OKP_XUI_UPDATE_SETTLEMENT_MODE=''
    OKP_XUI_UPDATE_SUPERVISION_ARMED=true
    # Install EXIT first so a signal arriving while the per-signal traps are
    # being replaced still cannot release the operation lock before settlement.
    trap '_okp_i_xui_update_exit_guard $?' EXIT
    trap '_okp_i_record_xui_update_signal HUP' HUP
    trap '_okp_i_record_xui_update_signal INT' INT
    trap '_okp_i_record_xui_update_signal TERM' TERM
}

_okp_i_disarm_xui_update_supervision() {
    OKP_XUI_UPDATE_SUPERVISION_ARMED=false
    _okp_i_restore_xui_update_traps
}

_okp_i_xui_update_exit_guard() {
    local status=${1:-1}
    # Once EXIT begins, no ordinary termination signal may bypass settlement
    # and close the inherited flock descriptor. SIGKILL remains the explicit
    # last-resort manual escape hatch.
    trap '' HUP INT TERM
    trap - EXIT
    if [[ $OKP_XUI_UPDATE_SUPERVISION_ARMED == true &&
        $OKP_XUI_UPDATE_RECOVERY_SETTLED != true ]]; then
        if ! _okp_i_settle_interrupted_xui_update; then
            _okp_i_hold_xui_update_lock_until_settled
        fi
    fi
    OKP_XUI_UPDATE_SUPERVISION_ARMED=false
    if declare -F maintenance_cleanup_temp_paths >/dev/null 2>&1; then
        maintenance_cleanup_temp_paths
    fi
    exit "$status"
}

_okp_i_xui_update_signal_status() {
    case $1 in
        HUP) printf '129' ;;
        INT) printf '130' ;;
        TERM) printf '143' ;;
        *) printf '1' ;;
    esac
}

# Settle an update journal left by a killed or powered-off maintenance process.
# This entry point is used before every mutating maintenance command and by
# configuration loaders. It never starts the upstream updater; it only repairs
# the durable journal or verifies the stopped-and-disabled fail-closed state.
okp_hook_settle_pending_xui_update() {
    local result=0 signal_status=0 settlement_delayed=false

    declare -F maintenance_operation_lock >/dev/null 2>&1 || {
        log_error '缺少维护操作锁，拒绝处理 3x-ui 更新恢复事务。'
        return 1
    }
    _okp_i_arm_xui_update_supervision || return 1
    # Arm before taking the lock. Otherwise TERM in the narrow acquired-lock /
    # not-yet-armed window would run the generic EXIT cleanup and unlock an
    # unresolved journal without recovery or verified fail-close.
    if ! maintenance_operation_lock; then
        _okp_i_disarm_xui_update_supervision
        return 1
    fi

    if ! _okp_i_settle_interrupted_xui_update; then
        settlement_delayed=true
        _okp_i_hold_xui_update_lock_until_settled
    fi
    if [[ $OKP_XUI_UPDATE_SETTLEMENT_MODE != recovered ||
        $settlement_delayed == true ]]; then
        result=1
    fi

    _okp_i_disarm_xui_update_supervision
    if [[ -n $OKP_XUI_UPDATE_PENDING_SIGNAL ]]; then
        signal_status=$(_okp_i_xui_update_signal_status \
            "$OKP_XUI_UPDATE_PENDING_SIGNAL") || signal_status=1
        result=$signal_status
    fi
    return "$result"
}

_okp_i_run_supervised_xui_updater() {
    [[ $# -eq 4 ]] || return 2
    local installer=$1 tag=$2 pinned_path=$3 output=$4 child_status=0 signal_status=0
    local monitor_was_enabled=false settlement_delayed=false

    _okp_i_arm_xui_update_supervision || return 1

    [[ $- == *m* ]] && monitor_was_enabled=true
    set -m
    (
        umask 022
        exec env -i PATH="$pinned_path" HOME=/root LANG=C.UTF-8 XUI_NONINTERACTIVE=1 \
            bash "$installer" "$tag"
    ) </dev/null >"$output" 2>&1 &
    OKP_XUI_UPDATE_CHILD_PID=$!
    # A signal can arrive after the shell creates the background job but
    # before $! is assigned above. Its trap records the pending signal without
    # a PID; close that race immediately after publishing the process-group ID.
    if [[ -n $OKP_XUI_UPDATE_PENDING_SIGNAL ]]; then
        kill -TERM -- "-${OKP_XUI_UPDATE_CHILD_PID}" 2>/dev/null || true
    fi
    [[ $monitor_was_enabled == true ]] || set +m

    if wait "$OKP_XUI_UPDATE_CHILD_PID"; then
        child_status=0
    else
        child_status=$?
    fi

    # Keep all temporary traps and the caller's operation lock armed across
    # the post-child window. This function must not return until the journal is
    # recovered or x-ui is verifiably stopped and disabled.
    if ! _okp_i_settle_interrupted_xui_update; then
        settlement_delayed=true
        _okp_i_hold_xui_update_lock_until_settled
    fi
    if [[ $OKP_XUI_UPDATE_SETTLEMENT_MODE != recovered ||
        $settlement_delayed == true ]] && ((child_status == 0)); then
        child_status=1
    fi

    _okp_i_disarm_xui_update_supervision
    if [[ -n $OKP_XUI_UPDATE_PENDING_SIGNAL ]]; then
        signal_status=$(_okp_i_xui_update_signal_status \
            "$OKP_XUI_UPDATE_PENDING_SIGNAL") || signal_status=1
        child_status=$signal_status
    fi
    return "$child_status"
}

_okp_i_load_saved_config() {
    _okp_i_register_state_secrets
    config_load_state || {
        log_error '受管配置状态不完整，维护操作已停止。'
        return 1
    }
    RUNTIME_DIR=$(_okp_i_state RUNTIME_DIR /usr/local/lib/one-key-proxy)
    _okp_i_load_ownership_context || return 1
}

_okp_i_load_config() {
    okp_hook_settle_pending_xui_update || return 1
    _okp_i_recover_tls_transition || return 1
    _okp_i_load_saved_config
}

_okp_i_public_host() {
    if [[ ${MODE-} == public ]]; then
        printf '%s' "$FQDN"
    else
        printf '%s' "$PUBLIC_IPV4"
    fi
}

_okp_i_url_encode() {
    local value=${1-}
    [[ -n $value && $value =~ ^[A-Za-z0-9._~@+-]+$ ]] || return 1
    printf '%s' "$value"
}

_okp_i_secret_dir_create() {
    local variable_name=$1 label=${2:-secret} directory
    directory=$(mktemp -d "/tmp/one-key-proxy-${label}.XXXXXX") || return 1
    chmod 0700 "$directory" || {
        rm -rf -- "$directory"
        return 1
    }
    if declare -F maintenance_temp_register >/dev/null 2>&1; then
        maintenance_temp_register "$directory" || {
            rm -rf -- "$directory"
            return 1
        }
    fi
    printf -v "$variable_name" '%s' "$directory"
}

_okp_i_secret_dir_remove() {
    local directory=$1
    [[ $directory =~ ^/tmp/one-key-proxy-[A-Za-z0-9_-]+\.[A-Za-z0-9]+$ ]] || return 1
    rm -rf -- "$directory"
    if declare -F maintenance_temp_unregister >/dev/null 2>&1; then
        maintenance_temp_unregister "$directory"
    fi
}

_okp_i_path_is_safe_under() {
    local path=$1 root=$2 parent root_real parent_real
    root=${root%/}
    [[ $path == /* && $root == /* && $path != "$root" && $path == "$root"/* ]] || return 1
    case "$path" in
        *$'\n'* | *$'\r'* | *//* | */../* | */.. | */./* | */.) return 1 ;;
    esac
    [[ -d $root && ! -L $root ]] || return 1
    root_real=$(cd -P -- "$root" 2>/dev/null && pwd -P) || return 1
    [[ $root_real == "$root" ]] || return 1
    parent=$(dirname -- "$path") || return 1
    if [[ -d $parent ]]; then
        parent_real=$(cd -P -- "$parent" 2>/dev/null && pwd -P) || return 1
        [[ $parent_real == "$root_real" || $parent_real == "$root_real"/* ]] || return 1
    fi
}

_okp_i_generate_uuid() {
    local raw
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        IFS= read -r raw </proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        raw=$(uuidgen)
    else
        raw=$(random_hex 16) || return 1
        raw="${raw:0:8}-${raw:8:4}-${raw:12:4}-${raw:16:4}-${raw:20:12}"
    fi
    [[ $raw =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || return 1
    printf '%s' "${raw,,}"
}

_okp_i_csv_has() {
    local csv=${1-} wanted=${2-} item
    local -a _okp_i_csv_items=()
    IFS=, read -r -a _okp_i_csv_items <<<"$csv"
    for item in "${_okp_i_csv_items[@]}"; do
        [[ $item == "$wanted" ]] && return 0
    done
    return 1
}

_okp_i_csv_add() {
    local csv=${1-} value=${2-}
    if [[ -z $csv ]]; then
        printf '%s' "$value"
    elif _okp_i_csv_has "$csv" "$value"; then
        printf '%s' "$csv"
    else
        printf '%s,%s' "$csv" "$value"
    fi
}

_okp_i_csv_remove() {
    local csv=${1-} wanted=${2-} item output=''
    local -a _okp_i_csv_items=()
    IFS=, read -r -a _okp_i_csv_items <<<"$csv"
    for item in "${_okp_i_csv_items[@]}"; do
        [[ -n $item && $item != "$wanted" ]] || continue
        output=${output:+${output},}${item}
    done
    printf '%s' "$output"
}

_okp_i_select_vless_uri() {
    local links_json=$1 host=$2 port=$3 uri uuid sni public_key short_id
    uri=$(jq -r --arg endpoint "@${host}:${port}" \
        '[.[] | select(startswith("vless://") and contains($endpoint))][0] // empty' \
        <<<"$links_json") || return 1
    [[ -n $uri ]] || return 1
    uuid=$(_okp_i_state CLIENT_UUID)
    sni=$(_okp_i_state REALITY_SNI)
    public_key=$(_okp_i_state REALITY_PUBLIC_KEY)
    short_id=$(_okp_i_state REALITY_SHORT_ID)
    xui_vless_uri_matches "$uri" "$host" "$port" "$uuid" "$sni" "$public_key" "$short_id" || return 1
    printf '%s' "$uri"
}

_okp_i_verify_subscription_delivery() {
    local public_host=${1:-} sub_id=${2:-} sub_internal_port=${3:-}
    local node_external_port=${4:-} mode cert_dir
    local uuid sni public_key short_id
    if [[ -z $public_host ]]; then
        mode=$(_okp_i_state MODE "${MODE-}")
        case $mode in
            nat) public_host=$(_okp_i_state PUBLIC_IPV4 "${PUBLIC_IPV4-}") ;;
            public) public_host=$(_okp_i_state FQDN "${FQDN-}") ;;
            *) public_host='' ;;
        esac
    fi
    [[ -n $sub_id ]] || sub_id=$(_okp_i_state SUB_ID)
    [[ -n $sub_internal_port ]] ||
        sub_internal_port=$(_okp_i_state SUB_INTERNAL_PORT "${SUB_INTERNAL_PORT-}")
    [[ -n $node_external_port ]] ||
        node_external_port=$(_okp_i_state NODE_EXTERNAL_PORT "${NODE_EXTERNAL_PORT-}")
    uuid=$(_okp_i_state CLIENT_UUID)
    sni=$(_okp_i_state REALITY_SNI)
    public_key=$(_okp_i_state REALITY_PUBLIC_KEY)
    short_id=$(_okp_i_state REALITY_SHORT_ID)
    cert_dir=${CERT_DIR:-/etc/one-key-proxy/certs}
    if ! xui_verify_local_subscriptions "$public_host" "$sub_internal_port" \
        "$node_external_port" "$sub_id" "$cert_dir/server.crt" "$uuid" "$sni" \
        "$public_key" "$short_id"; then
        log_error '三类订阅未通过本机 HTTPS、公开节点地址或 REALITY 身份校验。'
        return 1
    fi
}

_okp_i_write_result() {
    local public_host sub_id links_json vless_uri panel_url xui_version xray_version
    local fail2ban_status fail2ban_reason cert_fingerprint=''
    local firewall_backend firewall_manual firewall_description
    _okp_i_load_config || return 1
    public_host=$(_okp_i_public_host)
    sub_id=$(_okp_i_state SUB_ID)
    [[ -n $sub_id ]] || return 1
    xui_build_subscription_urls https "$public_host" "$SUB_EXTERNAL_PORT" "$sub_id" || return 1
    links_json=$(xui_get_sub_links "$sub_id") || return 1
    vless_uri=$(_okp_i_select_vless_uri "$links_json" "$public_host" "$NODE_EXTERNAL_PORT") || return 1
    panel_url=$(_xui_public_origin https "$public_host" "$PANEL_EXTERNAL_PORT")/ || return 1
    _okp_i_verify_subscription_delivery "$public_host" "$sub_id" || return 1
    xui_version=$(_okp_i_state XUI_VERSION unknown)
    xray_version=$(_okp_i_state XUI_XRAY_VERSION unknown)
    fail2ban_status=$(_okp_i_state FAIL2BAN_STATUS unknown)
    fail2ban_reason=$(_okp_i_state FAIL2BAN_REASON)
    firewall_backend=$(_okp_i_state FIREWALL_BACKEND unknown)
    firewall_manual=$(_okp_i_state FIREWALL_MANUAL_REQUIRED true)
    case $firewall_backend in
        ufw) firewall_description='UFW 已启用，三个内部 TCP 端口已核验' ;;
        firewalld) firewall_description='firewalld 已启用，三个内部 TCP 端口已核验' ;;
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
    result_add '服务状态' 'x-ui active；Xray running，受管入站运行态已验证' || return 1
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
        result_add '证书提示' '自签名证书；跳过验证会失去服务端身份认证，请通过独立可信渠道核对指纹' || return 1
    else
        result_add 'DNS 提示' '未启用 DDNS；公网 IP 改变后请运行 one-key-proxy update-address' || return 1
    fi
    chmod 0600 "$RESULT_FILE" || return 1
}

_okp_i_wait_service() {
    local attempt ready=false inbound_tag
    for ((attempt = 1; attempt <= 15; attempt++)); do
        if platform_service_is_active x-ui && xui_api_get /panel/api/server/status >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 2
    done
    [[ $ready == true ]] || return 1
    inbound_tag=$(_okp_i_state INBOUND_TAG)
    [[ -n $inbound_tag ]] || return 1
    xui_verify_xray_runtime "$inbound_tag" "$NODE_INTERNAL_PORT" 15 2 || return 1
    state_set XUI_XRAY_VERSION "$XUI_XRAY_VERSION"
}

okp_hook_show_information() {
    local project_version project_commit xui_version token_name mode
    project_version=$(_okp_i_state PROJECT_VERSION unknown)
    project_commit=$(_okp_i_state PROJECT_COMMIT unknown)
    xui_version=$(_okp_i_state XUI_VERSION unknown)
    token_name=$(_okp_i_state XUI_API_TOKEN_NAME unknown)
    mode=$(_okp_i_state MODE unknown)
    project_version=$(_xui_sanitize_log_message "$project_version")
    project_commit=$(_xui_sanitize_log_message "$project_commit")
    xui_version=$(_xui_sanitize_log_message "$xui_version")
    token_name=$(_xui_sanitize_log_message "$token_name")
    mode=$(_xui_sanitize_log_message "$mode")
    printf '  项目版本: %s\n' "$project_version"
    printf '  项目 commit: %s\n' "$project_commit"
    printf '  3x-ui 版本: %s\n' "$xui_version"
    printf '  部署模式: %s\n' "$mode"
    printf '  管理 Token 名称: %s（值已隐藏）\n' "$token_name"
}

okp_hook_diagnostics() {
    local settings inbound current_email cert_file public_host failures=0
    local api_token api_token_id api_token_name fail2ban_status fail2ban_log
    _okp_i_load_config || return 1
    public_host=$(_okp_i_public_host)
    current_email=$(_okp_i_state CLIENT_EMAIL)
    cert_file=$(_okp_i_state TLS_CERT_FILE "$CERT_DIR/server.crt")

    if xui_api_get /panel/api/server/status >/dev/null; then
        printf '  [正常] 3x-ui 管理 API 可访问\n'
    else
        printf '  [失败] 3x-ui 管理 API 不可访问\n'
        failures=$((failures + 1))
    fi
    api_token=$(_okp_i_state XUI_API_TOKEN)
    api_token_id=$(_okp_i_state XUI_API_TOKEN_ID)
    api_token_name=$(_okp_i_state XUI_API_TOKEN_NAME)
    if [[ $api_token_id =~ ^[1-9][0-9]*$ && -n $api_token_name ]] &&
        xui_validate_api_token "$api_token" "$api_token_id" "$api_token_name"; then
        printf '  [正常] 项目专用管理 Token 有效且所有权一致\n'
    else
        printf '  [失败] 项目专用管理 Token 无效或所有权不一致\n'
        failures=$((failures + 1))
    fi
    if _okp_i_find_owned_inbound; then
        inbound=$XUI_MANAGED_INBOUND_JSON
        if jq -e --arg email "$current_email" --argjson port "$NODE_INTERNAL_PORT" '
            .protocol == "vless" and .port == $port and
            .streamSettings.network == "tcp" and .streamSettings.security == "reality" and
            .streamSettings.realitySettings.minClientVer == "1.0.0" and
            any(.settings.clients[]?; .email == $email and .flow == "xtls-rprx-vision" and .enable == true)
        ' >/dev/null <<<"$inbound"; then
            printf '  [正常] 受管 VLESS+TCP+REALITY+Vision 入站一致\n'
        else
            printf '  [失败] 受管入站字段或当前客户端不一致\n'
            failures=$((failures + 1))
        fi
        if _okp_i_verify_owned_host "$XUI_MANAGED_INBOUND_ID"; then
            printf '  [正常] Host 发布组 ID/tag 所有权一致\n'
        else
            printf '  [失败] Host 发布组所有权或入站绑定不一致\n'
            failures=$((failures + 1))
        fi
        if xui_verify_xray_runtime "$OKP_INBOUND_TAG" "$NODE_INTERNAL_PORT" 3 1; then
            printf '  [正常] Xray Core 正在运行且已组装受管入站\n'
        else
            printf '  [失败] Xray Core 未运行或实际组装配置缺少受管入站\n'
            failures=$((failures + 1))
        fi
    else
        printf '  [失败] 找不到唯一受管入站\n'
        failures=$((failures + 1))
    fi
    if settings=$(xui_api_post /panel/api/setting/all '{}'); then
        if jq -e --argjson panel "$PANEL_INTERNAL_PORT" --argjson sub "$SUB_INTERNAL_PORT" '
            .webBasePath == "/" and .webPort == $panel and .subPort == $sub and
            .subEnable == true and .subJsonEnable == true and .subClashEnable == true
        ' >/dev/null <<<"$settings"; then
            printf '  [正常] 面板和三类订阅设置一致\n'
        else
            printf '  [失败] 面板或订阅设置不一致\n'
            failures=$((failures + 1))
        fi
    else
        printf '  [失败] 无法回读面板设置\n'
        failures=$((failures + 1))
    fi
    if _okp_i_verify_subscription_delivery "$public_host"; then
        printf '  [正常] Base64、Xray JSON 与 Clash 订阅均发布正确的外部 REALITY 连接\n'
    else
        printf '  [失败] 三类订阅的 HTTPS 可用性或公开 REALITY 连接不一致\n'
        failures=$((failures + 1))
    fi
    if [[ -r $cert_file ]] && openssl x509 -in "$cert_file" -noout -checkend 86400 >/dev/null 2>&1; then
        if [[ $MODE == nat ]] && ! _okp_cert_verify_ip_san "$cert_file" "$public_host"; then
            printf '  [失败] 自签名证书 SAN 与公网 IPv4 不一致\n'
            failures=$((failures + 1))
        elif [[ $MODE == public ]] && ! _okp_cert_verify_dns_san "$cert_file" "$public_host"; then
            printf '  [失败] ACME 证书 SAN 与域名不一致\n'
            failures=$((failures + 1))
        else
            printf '  [正常] TLS 证书有效且身份匹配\n'
        fi
    else
        printf '  [失败] TLS 证书不存在、无效或即将过期\n'
        failures=$((failures + 1))
    fi
    fail2ban_status=$(_okp_i_state FAIL2BAN_STATUS not-configured)
    if [[ $fail2ban_status == enabled ]]; then
        fail2ban_log=$(_okp_i_state FAIL2BAN_LOG_PATH)
        if declare -F okp_fail2ban_verify >/dev/null 2>&1 &&
            okp_fail2ban_verify "$fail2ban_log"; then
            printf '  [正常] Fail2ban 项目规则和 jail 有效\n'
        else
            printf '  [失败] Fail2ban 标记为已启用，但规则或 jail 验证失败\n'
            failures=$((failures + 1))
        fi
    else
        case "$fail2ban_status" in
            degraded | removed | not-configured) ;;
            *) fail2ban_status=unknown ;;
        esac
        printf '  [提示] Fail2ban 状态: %s（不影响代理核心功能）\n' "$fail2ban_status"
    fi
    ((failures == 0))
}

okp_hook_before_backup() {
    local presence_status=0 activity_status=0
    OKP_INTEGRATION_BACKUP_WAS_ACTIVE=false
    if platform_service_exists x-ui; then
        :
    else
        presence_status=$?
        if ((presence_status == 1)); then
            log_error '找不到 x-ui 服务，无法创建一致性备份。'
        else
            log_error '无法可靠判定 x-ui 服务是否存在，备份已取消。'
        fi
        return 1
    fi
    if platform_service_is_inactive x-ui; then
        return 0
    else
        activity_status=$?
    fi
    if ((activity_status != 1)); then
        log_error '无法可靠判定 x-ui 服务是否已停止，备份已取消。'
        return 1
    fi
    platform_service_stop x-ui || return 1
    platform_service_is_inactive x-ui || {
        log_error '无法确认 x-ui 已停止，拒绝复制可能仍在写入的数据库。'
        return 1
    }
    OKP_INTEGRATION_BACKUP_WAS_ACTIVE=true
    return 0
}

okp_hook_after_backup() {
    if [[ $OKP_INTEGRATION_BACKUP_WAS_ACTIVE == true ]]; then
        platform_service_start x-ui || return 1
    fi
    OKP_INTEGRATION_BACKUP_WAS_ACTIVE=false
    return 0
}

okp_hook_backup_paths() {
    local path
    for path in \
        /usr/local/x-ui \
        /usr/local/lib/one-key-proxy \
        /usr/local/bin/one-key-proxy \
        /usr/local/bin/one-key-proxy-acme-renew \
        /usr/local/bin/one-key-proxy-reload-x-ui \
        /etc/systemd/system/x-ui.service \
        /etc/systemd/system/one-key-proxy-acme.service \
        /etc/systemd/system/one-key-proxy-acme.timer \
        /etc/init.d/x-ui \
        /etc/periodic/daily/one-key-proxy-acme \
        /etc/fail2ban/jail.d/one-key-proxy.local \
        /etc/fail2ban/filter.d/one-key-proxy.conf; do
        [[ -e $path || -L $path ]] && printf '%s\n' "$path"
    done
    return 0
}

okp_hook_backup_prepare() {
    local staging=$1 manifest
    [[ $staging == "${TMPDIR:-/tmp}"/one-key-proxy-* ]] || return 1
    manifest="${staging}/rootfs${CONFIG_DIR}/backup-runtime-manifest.txt"
    install -d -m 0700 -- "$(dirname -- "$manifest")" || return 1
    {
        printf 'created_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'project_version=%s\n' "$(_okp_i_state PROJECT_VERSION unknown)"
        printf 'project_commit=%s\n' "$(_okp_i_state PROJECT_COMMIT unknown)"
        printf 'xui_version=%s\n' "$(_okp_i_state XUI_VERSION unknown)"
        printf 'arch=%s\n' "$(uname -m)"
    } >"$manifest"
    chmod 0600 "$manifest"
}

okp_hook_restore_preflight() {
    local metadata=${1-} rootfs=${2-} backup_state project_name mode runtime database
    local cert key api_token api_token_id api_token_name port script installation_id
    local inbound_id host_group_id inbound_tag host_tag client_uuid sub_id
    local -a required_state=(
        MODE PANEL_USERNAME PANEL_PASSWORD PANEL_INTERNAL_PORT NODE_INTERNAL_PORT
        SUB_INTERNAL_PORT CLIENT_EMAIL CLIENT_UUID SUB_ID INSTALLATION_ID INBOUND_ID
        INBOUND_TAG HOST_GROUP_ID HOST_TAG
    )
    local -a port_keys=(
        PANEL_EXTERNAL_PORT PANEL_INTERNAL_PORT NODE_EXTERNAL_PORT NODE_INTERNAL_PORT
        SUB_EXTERNAL_PORT SUB_INTERNAL_PORT
    )

    [[ -f $metadata && ! -L $metadata && -d $rootfs && ! -L $rootfs ]] || return 1
    project_name=$(state_file_get "$metadata" PROJECT_NAME 2>/dev/null) || return 1
    [[ $project_name == one-key-proxy ]] || {
        log_error '备份项目标识不匹配。'
        return 1
    }
    backup_state="${rootfs}${STATE_FILE}"
    [[ -f $backup_state && ! -L $backup_state ]] || {
        log_error '备份状态文件缺失或类型不安全。'
        return 1
    }
    for script in "${required_state[@]}"; do
        state_file_get "$backup_state" "$script" >/dev/null 2>&1 || {
            log_error "备份状态缺少必要字段：${script}"
            return 1
        }
    done
    mode=$(state_file_get "$backup_state" MODE 2>/dev/null) || return 1
    [[ $mode == nat || $mode == public ]] || {
        log_error '备份部署模式无效。'
        return 1
    }
    installation_id=$(state_file_get "$backup_state" INSTALLATION_ID 2>/dev/null) || return 1
    inbound_id=$(state_file_get "$backup_state" INBOUND_ID 2>/dev/null) || return 1
    host_group_id=$(state_file_get "$backup_state" HOST_GROUP_ID 2>/dev/null) || return 1
    inbound_tag=$(state_file_get "$backup_state" INBOUND_TAG 2>/dev/null) || return 1
    host_tag=$(state_file_get "$backup_state" HOST_TAG 2>/dev/null) || return 1
    client_uuid=$(state_file_get "$backup_state" CLIENT_UUID 2>/dev/null) || return 1
    sub_id=$(state_file_get "$backup_state" SUB_ID 2>/dev/null) || return 1
    [[ $installation_id =~ ^[A-Fa-f0-9]{32}$ && $inbound_id =~ ^[1-9][0-9]*$ &&
        $host_group_id =~ ^[A-Za-z0-9._:-]+$ &&
        $inbound_tag == "one-key-proxy-${installation_id:0:16}" &&
        $host_tag == "one-key-proxy-host-${installation_id:0:16}" &&
        $client_uuid =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ &&
        $sub_id =~ ^[A-Za-z0-9_-]{16,128}$ ]] || {
        log_error '备份受管资源所有权或客户端身份字段无效。'
        return 1
    }
    for script in "${port_keys[@]}"; do
        port=$(state_file_get "$backup_state" "$script" 2>/dev/null) || return 1
        platform_validate_port "$port" || {
            log_error "备份端口字段无效：${script}"
            return 1
        }
    done

    runtime=$(state_file_get "$backup_state" RUNTIME_DIR 2>/dev/null) || runtime=/usr/local/lib/one-key-proxy
    database=$(state_file_get "$backup_state" XUI_DB_PATH 2>/dev/null) || database=/etc/x-ui/x-ui.db
    cert=$(state_file_get "$backup_state" TLS_CERT_FILE 2>/dev/null) || cert=${CONFIG_DIR}/certs/server.crt
    key=$(state_file_get "$backup_state" TLS_KEY_FILE 2>/dev/null) || key=${CONFIG_DIR}/certs/server.key
    [[ $runtime == /usr/local/lib/one-key-proxy && $database == /etc/x-ui/x-ui.db &&
        $cert == "${CONFIG_DIR}/certs/server.crt" && $key == "${CONFIG_DIR}/certs/server.key" ]] || {
        log_error '备份包含非固定运行、数据库或证书路径，拒绝恢复。'
        return 1
    }
    [[ -d ${rootfs}${runtime} && ! -L ${rootfs}${runtime} &&
        -f ${rootfs}${database} && ! -L ${rootfs}${database} &&
        -f ${rootfs}${cert} && ! -L ${rootfs}${cert} &&
        -f ${rootfs}${key} && ! -L ${rootfs}${key} ]] || {
        log_error '备份缺少安全的运行目录、数据库或证书文件。'
        return 1
    }
    openssl x509 -in "${rootfs}${cert}" -noout >/dev/null 2>&1 || {
        log_error '备份 TLS 证书无法解析。'
        return 1
    }
    openssl pkey -in "${rootfs}${key}" -noout -check >/dev/null 2>&1 || {
        log_error '备份 TLS 私钥无法解析。'
        return 1
    }
    for script in "${rootfs}${runtime}"/*.sh "${rootfs}${runtime}"/lib/*.sh \
        "${rootfs}${runtime}"/one-key-proxy; do
        [[ -f $script && ! -L $script ]] || continue
        bash -n "$script" || {
            log_error '备份运行脚本未通过语法检查。'
            return 1
        }
    done
    [[ -f ${rootfs}${runtime}/maintenance.sh && -f ${rootfs}${runtime}/one-key-proxy ]] || {
        log_error '备份运行目录不完整。'
        return 1
    }

    api_token=$(state_file_get "$backup_state" XUI_API_TOKEN 2>/dev/null) || return 1
    api_token_id=$(state_file_get "$backup_state" XUI_API_TOKEN_ID 2>/dev/null) || return 1
    api_token_name=$(state_file_get "$backup_state" XUI_API_TOKEN_NAME 2>/dev/null) || return 1
    _xui_token_value_valid "$api_token" && [[ $api_token_id =~ ^[1-9][0-9]*$ &&
        $api_token_name == one-key-proxy-* ]] || {
        log_error '备份项目专用 API Token 元数据无效。'
        return 1
    }
    api_token=''
    return 0
}

okp_hook_before_restore() {
    local presence_status=0 activity_status=0
    if platform_service_exists x-ui; then
        :
    else
        presence_status=$?
        if ((presence_status == 1)); then
            log_error '找不到 x-ui 服务，拒绝恢复。'
        else
            log_error '无法可靠判定 x-ui 服务是否存在，拒绝恢复。'
        fi
        return 1
    fi
    if platform_service_is_inactive x-ui; then
        return 0
    else
        activity_status=$?
    fi
    if ((activity_status != 1)); then
        log_error '无法可靠判定 x-ui 服务运行状态，拒绝恢复。'
        return 1
    fi
    platform_service_stop x-ui || return 1
    platform_service_is_inactive x-ui || {
        log_error '停止命令返回成功，但无法确认 x-ui 已停止，拒绝恢复。'
        return 1
    }
    return 0
}

okp_hook_after_restore() {
    _okp_i_load_saved_config || return 1
    platform_detect || return 1
    platform_service_enable x-ui || return 1
    platform_service_restart x-ui || return 1
    _okp_i_wait_service || {
        log_error '恢复文件已写入，但 3x-ui 未通过健康检查。'
        return 1
    }
}

okp_hook_verify_restore() {
    _okp_i_write_result || return 1
    okp_hook_diagnostics
}

_okp_i_show_change() {
    local label=$1 old=$2 new=$3
    [[ $old != "$new" ]] || return 1
    printf '  %-20s %s -> %s\n' "$label" "${old:-<空>}" "${new:-<空>}"
}

_okp_i_port_changed_and_busy() {
    local label=$1 old=$2 new=$3
    [[ $old != "$new" ]] || return 1
    if ! platform_port_is_available "$new" tcp; then
        log_error "${label}新内部端口 ${new}/tcp 已被占用。"
        return 0
    fi
    return 1
}

_okp_i_prompt_public_port() {
    local external_name=$1 internal_name=$2 label=$3 current value
    current=${!external_name}
    while true; do
        maintenance_read value "${label} TCP 端口" "$current" || return 1
        if valid_port "$value"; then
            printf -v "$external_name" '%s' "$value"
            printf -v "$internal_name" '%s' "$value"
            return 0
        fi
        log_warn '端口必须是 1 到 65535 之间的整数。'
    done
}

_okp_i_ensure_dns_record() {
    local fqdn=$1 type=$2 value=$3 zone=$4 status
    okp_alidns_ensure_record "$fqdn" "$type" "$value" "$zone" >/dev/null
    status=$?
    if ((status == 3)); then
        log_warn "发现值相同但不属于本项目的 ${type} 记录：${fqdn}。"
        maintenance_confirm '复用该记录（卸载时不会删除）？' n || return 1
        okp_alidns_ensure_record "$fqdn" "$type" "$value" "$zone" true >/dev/null
        return $?
    fi
    return "$status"
}

_okp_i_prepare_identity() {
    local old_fqdn=$1 zone needs_certificate=false read_status=0
    if [[ $MODE == nat ]]; then
        if _okp_i_tls_cert_matches_host nat "$PUBLIC_IPV4"; then
            return 0
        fi
        _okp_i_begin_tls_transition nat "$PUBLIC_IPV4" || return 1
        okp_cert_create_self_signed_ip "$PUBLIC_IPV4" "$CERT_DIR/server.crt" \
            "$CERT_DIR/server.key" || return 1
        _okp_i_activate_tls_transition nat "$PUBLIC_IPV4"
        return $?
    fi

    okp_alidns_install_cli || return 1
    okp_alidns_save_credentials "$ALI_ACCESS_KEY_ID" "$ALI_ACCESS_KEY_SECRET" || return 1
    okp_alidns_test_credentials || return 1
    zone=$(okp_alidns_resolve_zone "$FQDN") || return 1
    state_set ALIDNS_ZONE "$zone" || return 1
    _okp_i_ensure_dns_record "$FQDN" A "$PUBLIC_IPV4" "$zone" || return 1
    if [[ $ENABLE_IPV6 == true && -n $PUBLIC_IPV6 ]]; then
        _okp_i_ensure_dns_record "$FQDN" AAAA "$PUBLIC_IPV6" "$zone" || return 1
    else
        okp_alidns_delete_managed_records_for_fqdn "$FQDN" AAAA || return 1
        okp_alidns_assert_no_record_type "$FQDN" AAAA "$zone" || {
            log_error "${FQDN} 仍存在 AAAA 记录；禁用 IPv6 时拒绝继续发布该域名。"
            return 1
        }
    fi
    if [[ ! -r $CERT_DIR/server.crt ]] ||
        ! _okp_cert_verify_dns_san "$CERT_DIR/server.crt" "$FQDN"; then
        needs_certificate=true
    elif [[ $old_fqdn != "$FQDN" ]]; then
        # A resumed reconfiguration may already have installed and activated
        # the new-domain certificate while the normal config still names the
        # old domain. Do not reset that recoverable active transaction.
        if _okp_i_tls_transition_read; then
            [[ $OKP_TLS_TRANSITION_STATUS == active &&
                $OKP_TLS_TRANSITION_HOST == "$FQDN" ]] || needs_certificate=true
        else
            read_status=$?
            ((read_status == 1)) || return "$read_status"
            needs_certificate=true
        fi
    fi
    if [[ $needs_certificate == true ]]; then
        okp_acme_install "$ACME_EMAIL" || return 1
        _okp_i_begin_tls_transition public "$FQDN" || return 1
        okp_acme_issue_alidns "$FQDN" "$CERT_DIR/server.crt" "$CERT_DIR/server.key" || return 1
        _okp_i_activate_tls_transition public "$FQDN" || return 1
    fi
    okp_acme_install_scheduler || return 1
}

_okp_i_update_inbound_port() {
    local new_port=$1 payload
    _okp_i_find_owned_inbound || return 1
    payload=$(jq -c --argjson port "$new_port" '
        {enable, remark, listen, port: $port, protocol, expiryTime, total, settings,
         streamSettings, sniffing, tag, shareAddr, shareAddrStrategy,
         trafficReset, trafficResetDay, subSortIndex}
        | with_entries(select(.value != null))
    ' <<<"$XUI_MANAGED_INBOUND_JSON") || return 1
    xui_api_post "/panel/api/inbounds/update/${XUI_MANAGED_INBOUND_ID}" "$payload" >/dev/null || return 1
}

_okp_i_add_firewall_ports() {
    local old_managed=$1 port manual_required=false
    local new_managed=$old_managed
    platform_detect_firewall || {
        log_error '防火墙状态存在歧义，重配已在网络切换前停止。'
        return 1
    }
    [[ $PLATFORM_FIREWALL == none ]] && manual_required=true
    state_set_many \
        FIREWALL_BACKEND "$PLATFORM_FIREWALL" \
        FIREWALL_ZONE "${PLATFORM_FIREWALL_ZONE:-}" \
        FIREWALL_REQUIRED_TCP_PORTS "${PANEL_INTERNAL_PORT},${NODE_INTERNAL_PORT},${SUB_INTERNAL_PORT}" \
        FIREWALL_MANUAL_REQUIRED "$manual_required" || return 1
    for port in "$PANEL_INTERNAL_PORT" "$NODE_INTERNAL_PORT" "$SUB_INTERNAL_PORT"; do
        platform_firewall_allow_tcp "$port" || return 1
        if [[ ${PLATFORM_FIREWALL_RULE_CHANGED:-0} == 1 ]]; then
            new_managed=$(_okp_i_csv_add "$new_managed" "$port")
        fi
    done
    OKP_NEW_MANAGED_FIREWALL_PORTS=$new_managed
}

_okp_i_remove_old_firewall_ports() {
    local old_managed=$1 port keep
    local -a _okp_i_old_firewall_items=()
    IFS=, read -r -a _okp_i_old_firewall_items <<<"$old_managed"
    for port in "${_okp_i_old_firewall_items[@]}"; do
        [[ $port =~ ^[0-9]+$ ]] || continue
        keep=false
        [[ $port == "$PANEL_INTERNAL_PORT" || $port == "$NODE_INTERNAL_PORT" || $port == "$SUB_INTERNAL_PORT" ]] && keep=true
        if [[ $keep == false ]]; then
            platform_firewall_revoke_tcp "$port" || return 1
            OKP_NEW_MANAGED_FIREWALL_PORTS=$(_okp_i_csv_remove "$OKP_NEW_MANAGED_FIREWALL_PORTS" "$port")
        fi
    done
}

_okp_i_apply_reconfiguration() {
    local old_fqdn=$1 old_firewall=$2 public_host
    _okp_i_prepare_identity "$old_fqdn" || return 1
    _okp_i_add_firewall_ports "$old_firewall" || return 1
    _okp_i_update_inbound_port "$NODE_INTERNAL_PORT" || return 1
    public_host=$(_okp_i_public_host)
    _okp_i_update_owned_host "$XUI_MANAGED_INBOUND_ID" "$public_host" "$NODE_EXTERNAL_PORT" || return 1
    xui_configure_subscription "$SUB_INTERNAL_PORT" https "$public_host" "$SUB_EXTERNAL_PORT" \
        "$CERT_DIR/server.crt" "$CERT_DIR/server.key" || return 1
    xui_configure_panel_tls "$PANEL_INTERNAL_PORT" "$CERT_DIR/server.crt" \
        "$CERT_DIR/server.key" "$public_host" || return 1
    xui_restart_panel || return 1

    config_save_state || return 1
    state_set_many \
        PANEL_SCHEME https \
        INBOUND_ID "$XUI_MANAGED_INBOUND_ID" \
        HOST_GROUP_ID "$XUI_MANAGED_HOST_GROUP_ID" \
        TLS_CERT_FILE "$CERT_DIR/server.crt" \
        TLS_KEY_FILE "$CERT_DIR/server.key" \
        FIREWALL_MANAGED_TCP_PORTS "$OKP_NEW_MANAGED_FIREWALL_PORTS" || return 1
    _okp_i_wait_service || return 1
    _okp_i_verify_subscription_delivery "$public_host" || return 1
    _okp_i_complete_tls_transition "$MODE" "$public_host" || return 1
    _okp_i_remove_old_firewall_ports "$old_firewall" || return 1
    state_set FIREWALL_MANAGED_TCP_PORTS "$OKP_NEW_MANAGED_FIREWALL_PORTS" || return 1
}

_okp_i_mark_retired_acme_domain() {
    local old_fqdn=$1 pending='' status=0

    [[ $MODE == public && -n $old_fqdn && $old_fqdn != "$FQDN" ]] || return 0
    if pending=$(state_get ACME_PENDING_REMOVE_DOMAIN 2>/dev/null); then
        [[ $pending == "$old_fqdn" ]] || {
            log_error "已有旧域名 ${pending} 的 ACME 清理事务，拒绝覆盖。"
            return 1
        }
        return 0
    else
        status=$?
    fi
    ((status == 1)) || return "$status"
    state_set ACME_PENDING_REMOVE_DOMAIN "$old_fqdn"
}

_okp_i_remove_pending_acme_domain() {
    local expected_old=${1-} pending status=0

    if pending=$(state_get ACME_PENDING_REMOVE_DOMAIN 2>/dev/null); then
        :
    else
        status=$?
        ((status == 1)) && return 0
        return "$status"
    fi
    [[ -n $pending && $pending != "$FQDN" &&
        ( -z $expected_old || $pending == "$expected_old" ) ]] || {
        log_error '待清理 ACME 域名事务与当前域名状态不一致。'
        return 1
    }
    if ! okp_acme_remove_domain "$pending"; then
        log_error "新域名 ${FQDN} 已生效且当前服务保持运行，但旧域名 ${pending} 的 ACME 续签配置清理失败。"
        log_error '请勿强制续签；修复 acme.sh 状态后重新运行域名重配置以完成清理。'
        return 1
    fi
    state_unset ACME_PENDING_REMOVE_DOMAIN || return 1
}

_okp_i_resume_pending_acme_cleanup() {
    local allow_uncommitted=${1:-false} pending status=0

    [[ $MODE == public ]] || return 0
    if pending=$(state_get ACME_PENDING_REMOVE_DOMAIN 2>/dev/null); then
        :
    else
        status=$?
        ((status == 1)) && return 0
        return "$status"
    fi
    # The saved identity still names the old domain when the preceding
    # reconfiguration failed before committing its new configuration.
    if [[ $pending == "$FQDN" ]]; then
        if [[ $allow_uncommitted == true ]]; then
            return 0
        fi
        log_error '上次域名重配置尚未提交；请先重新运行域名重配置，拒绝续签全部 ACME 域名。'
        return 1
    fi
    _okp_i_tls_cert_matches_host public "$FQDN" || {
        log_error '当前证书不匹配已提交的新域名，拒绝清理旧 ACME 续签配置。'
        return 1
    }
    _okp_i_wait_service || return 1
    _okp_i_write_result || return 1
    okp_hook_diagnostics || return 1
    _okp_i_remove_pending_acme_domain "$pending"
}

_okp_i_finalize_reconfiguration() {
    local old_fqdn=$1

    _okp_i_write_result || return 1
    okp_hook_diagnostics || return 1
    if [[ $MODE == public && -n $old_fqdn && $old_fqdn != "$FQDN" ]]; then
        _okp_i_remove_pending_acme_domain "$old_fqdn" || return 1
    fi
}

okp_hook_reconfigure() {
    local scope=${1:-all} detected choice changed=0
    local old_public_ipv4 old_public_ipv6 old_enable_ipv6 old_fqdn zone
    local old_panel_external old_panel_internal old_node_external old_node_internal
    local old_sub_external old_sub_internal old_firewall

    _okp_i_load_config || return 1
    _okp_i_resume_pending_acme_cleanup true || return 1
    old_public_ipv4=$PUBLIC_IPV4
    old_public_ipv6=$PUBLIC_IPV6
    old_enable_ipv6=$ENABLE_IPV6
    old_fqdn=$FQDN
    old_panel_external=$PANEL_EXTERNAL_PORT
    old_panel_internal=$PANEL_INTERNAL_PORT
    old_node_external=$NODE_EXTERNAL_PORT
    old_node_internal=$NODE_INTERNAL_PORT
    old_sub_external=$SUB_EXTERNAL_PORT
    old_sub_internal=$SUB_INTERNAL_PORT
    old_firewall=$(_okp_i_state FIREWALL_MANAGED_TCP_PORTS)

    if [[ $scope == all || $scope == address ]]; then
        detected=$(detect_public_ipv4 || true)
        maintenance_read PUBLIC_IPV4 '新的公网 IPv4' "${detected:-$PUBLIC_IPV4}" || return 1
        if [[ $MODE == public ]]; then
            detected=$(detect_public_ipv6 || true)
            maintenance_read PUBLIC_IPV6 '新的公网 IPv6（留空禁用 AAAA）' "${detected:-$PUBLIC_IPV6}" || return 1
            [[ -n $PUBLIC_IPV6 ]] && ENABLE_IPV6=true || ENABLE_IPV6=false
        fi
    fi
    if [[ $scope == all || $scope == ports ]]; then
        if [[ $MODE == public ]]; then
            _okp_i_prompt_public_port PANEL_EXTERNAL_PORT PANEL_INTERNAL_PORT '面板' || return 1
            _okp_i_prompt_public_port NODE_EXTERNAL_PORT NODE_INTERNAL_PORT 'VLESS 节点' || return 1
            _okp_i_prompt_public_port SUB_EXTERNAL_PORT SUB_INTERNAL_PORT '订阅' || return 1
        else
            prompt_port_map PANEL_EXTERNAL_PORT PANEL_INTERNAL_PORT '面板' || return 1
            prompt_port_map NODE_EXTERNAL_PORT NODE_INTERNAL_PORT 'VLESS 节点' || return 1
            prompt_port_map SUB_EXTERNAL_PORT SUB_INTERNAL_PORT '订阅' || return 1
        fi
    fi
    if [[ $scope == all || $scope == domain ]]; then
        if [[ $MODE != public ]]; then
            [[ $scope == domain ]] && {
                log_error 'NAT 模式使用裸 IPv4，不支持域名重配。'
                return 1
            }
        else
            maintenance_read FQDN '新的完整子域名' "$FQDN" || return 1
            FQDN=${FQDN,,}
            maintenance_confirm '是否同时更换 AliDNS RAM AccessKey？' n && {
                maintenance_read ALI_ACCESS_KEY_ID '新的 AccessKey ID' "$ALI_ACCESS_KEY_ID" || return 1
                read_secret_tty choice '新的 AccessKey Secret（不能为空）' || return 1
                [[ -n $choice ]] || return 1
                ALI_ACCESS_KEY_SECRET=$choice
                secret_register "$choice"
                choice=''
            }
        fi
    fi
    config_validate || return 1

    printf '\n配置差异：\n'
    _okp_i_show_change '公网 IPv4' "$old_public_ipv4" "$PUBLIC_IPV4" && changed=$((changed + 1))
    _okp_i_show_change '公网 IPv6' "$old_public_ipv6" "$PUBLIC_IPV6" && changed=$((changed + 1))
    _okp_i_show_change 'IPv6 启用' "$old_enable_ipv6" "$ENABLE_IPV6" && changed=$((changed + 1))
    _okp_i_show_change '域名' "$old_fqdn" "$FQDN" && changed=$((changed + 1))
    _okp_i_show_change '面板外部端口' "$old_panel_external" "$PANEL_EXTERNAL_PORT" && changed=$((changed + 1))
    _okp_i_show_change '面板内部端口' "$old_panel_internal" "$PANEL_INTERNAL_PORT" && changed=$((changed + 1))
    _okp_i_show_change 'VLESS 外部端口' "$old_node_external" "$NODE_EXTERNAL_PORT" && changed=$((changed + 1))
    _okp_i_show_change 'VLESS 内部端口' "$old_node_internal" "$NODE_INTERNAL_PORT" && changed=$((changed + 1))
    _okp_i_show_change '订阅外部端口' "$old_sub_external" "$SUB_EXTERNAL_PORT" && changed=$((changed + 1))
    _okp_i_show_change '订阅内部端口' "$old_sub_internal" "$SUB_INTERNAL_PORT" && changed=$((changed + 1))
    if ((changed == 0)); then
        log_info '没有配置变化。'
        _okp_i_verify_subscription_delivery
        return $?
    fi

    _okp_i_port_changed_and_busy '面板' "$old_panel_internal" "$PANEL_INTERNAL_PORT" && return 1
    _okp_i_port_changed_and_busy 'VLESS' "$old_node_internal" "$NODE_INTERNAL_PORT" && return 1
    _okp_i_port_changed_and_busy '订阅' "$old_sub_internal" "$SUB_INTERNAL_PORT" && return 1
    [[ $MODE != nat ]] || log_warn '请确认 NAT 后台已预先开放并映射上述三个新的外部 TCP 端口。'
    maintenance_confirm '确认按以上差异重配置？' n || return 1
    maintenance_backup_create || return 1
    state_set LAST_RECONFIG_BACKUP "$LAST_BACKUP_PATH" || return 1
    _okp_i_mark_retired_acme_domain "$old_fqdn" || return 1
    if ! _okp_i_apply_reconfiguration "$old_fqdn" "$old_firewall"; then
        log_error "重配置未完整完成。保护备份：${LAST_BACKUP_PATH}"
        log_error '请先保持当前 SSH 会话并运行 one-key-proxy doctor；必要时执行原机恢复。'
        return 1
    fi
    if [[ -n $old_fqdn && $old_fqdn != "$FQDN" ]]; then
        okp_alidns_delete_managed_records_for_fqdn "$old_fqdn" ||
            log_warn "旧域名 ${old_fqdn} 的部分记录未能安全清理，所有权条目已保留供稍后重试。"
    fi
    if [[ $MODE == public && $ENABLE_IPV6 != true ]]; then
        zone=$(_okp_i_state ALIDNS_ZONE)
        okp_alidns_delete_managed_records_for_fqdn "$FQDN" AAAA || return 1
        okp_alidns_assert_no_record_type "$FQDN" AAAA "$zone" || {
            log_error "${FQDN} 仍存在 AAAA 记录；重配置尚未被标记为成功。"
            return 1
        }
        state_unset ALIDNS_AAAA_REUSED_RECORD_ID 2>/dev/null || true
    fi
    _okp_i_finalize_reconfiguration "$old_fqdn" || return 1
    log_info '网络身份与端口重配置完成；发布地址变化时请重新导入客户端。'
}

okp_hook_renew_certificate() {
    local mode public_host
    _okp_i_load_config || return 1
    _okp_i_resume_pending_acme_cleanup || return 1
    mode=$(_okp_i_state TLS_MODE)
    public_host=$(_okp_i_public_host)
    case "${MODE}:${mode}" in
        nat:SELF_SIGNED|public:ACME) ;;
        *)
            log_error '部署模式与保存的 TLS 证书类型不一致，拒绝自动续签。'
            return 1
            ;;
    esac
    maintenance_confirm '立即更新当前 TLS 证书并重启 3x-ui？' n || return 1
    maintenance_backup_create || return 1
    _okp_i_begin_tls_transition "$MODE" "$public_host" || return 1
    if [[ $MODE == nat ]]; then
        okp_cert_create_self_signed_ip "$PUBLIC_IPV4" "$CERT_DIR/server.crt" "$CERT_DIR/server.key" || return 1
    else
        okp_acme_renew_now true || return 1
    fi
    _okp_i_activate_tls_transition "$MODE" "$public_host" || return 1
    _okp_i_wait_service || return 1
    _okp_i_verify_subscription_delivery "$public_host" || return 1
    _okp_i_complete_tls_transition "$MODE" "$public_host" || return 1
    _okp_i_write_result || return 1
    okp_hook_diagnostics
}

_okp_i_download() {
    local url=$1 destination=$2
    curl --disable --noproxy '*' --fail --location --silent --show-error --retry 3 \
        --connect-timeout 15 --max-time 120 --proto '=https' \
        --proto-redir '=https' --tlsv1.2 --output "$destination" "$url"
}

_okp_i_validate_github_source() {
    local repository=$1 branch=${2-}
    [[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
    [[ -z $branch || $branch =~ ^[A-Za-z0-9._-]+$ ]] || return 1
}

_okp_i_fetch_project_target() {
    local response
    _okp_i_validate_github_source "$OKP_PROJECT_REPO" "$OKP_PROJECT_BRANCH" || return 1
    response=$(curl --disable --noproxy '*' -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        "https://api.github.com/repos/${OKP_PROJECT_REPO}/commits/${OKP_PROJECT_BRANCH}") || return 1
    OKP_PROJECT_TARGET_COMMIT=$(jq -er '.sha | select(test("^[0-9a-f]{40}$"))' <<<"$response") || return 1
    OKP_PROJECT_TARGET_VERSION=$(curl --disable --noproxy '*' -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        "https://raw.githubusercontent.com/${OKP_PROJECT_REPO}/${OKP_PROJECT_TARGET_COMMIT}/VERSION") || return 1
    OKP_PROJECT_TARGET_VERSION=$(trim "$OKP_PROJECT_TARGET_VERSION")
    [[ $OKP_PROJECT_TARGET_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || return 1
}

okp_hook_project_update_info() {
    local current_version current_commit
    current_version=$(_okp_i_state PROJECT_VERSION unknown)
    current_commit=$(_okp_i_state PROJECT_COMMIT unknown)
    _okp_i_fetch_project_target || {
        log_error '无法读取 one-key-proxy 主分支的目标 commit。'
        return 1
    }
    printf '当前项目版本: %s\n' "$current_version"
    printf '当前 commit: %s\n' "$current_commit"
    printf '目标项目版本: %s\n' "$OKP_PROJECT_TARGET_VERSION"
    printf '目标 commit: %s\n' "$OKP_PROJECT_TARGET_COMMIT"
    printf '来源: https://github.com/%s/tree/%s\n' "$OKP_PROJECT_REPO" "$OKP_PROJECT_TARGET_COMMIT"
}

_okp_i_validate_project_tree() {
    local tree=$1 script path link_count unsafe_entry
    local -a required=(bootstrap.sh install.sh maintenance.sh one-key-proxy VERSION DESIGN.md README.md)
    [[ -d $tree && ! -L $tree ]] || {
        log_error '项目归档根目录类型不安全。'
        return 1
    }
    unsafe_entry=$(find "$tree" \( -type l -o ! -type d ! -type f \) -print -quit) || return 1
    if [[ -n $unsafe_entry ]]; then
        log_error "项目归档包含不允许的文件类型：${unsafe_entry}"
        return 1
    fi
    while IFS= read -r -d '' path; do
        link_count=$(stat -c '%h' -- "$path" 2>/dev/null) || return 1
        if [[ $link_count != 1 ]]; then
            log_error "项目归档包含不允许的硬链接：${path}"
            return 1
        fi
    done < <(find "$tree" -type f -print0)
    for script in "${required[@]}"; do
        [[ -f $tree/$script ]] || {
            log_error "项目归档缺少文件：${script}"
            return 1
        }
    done
    for script in "$tree"/*.sh "$tree"/lib/*.sh "$tree"/one-key-proxy; do
        [[ -f $script ]] || continue
        bash -n "$script" || return 1
    done
    sh -n "$tree/bootstrap.sh" || return 1
}

okp_hook_project_update() {
    local temp archive tree runtime new_runtime old_runtime status=0
    local previous_version previous_commit
    [[ $OKP_PROJECT_TARGET_COMMIT =~ ^[0-9a-f]{40}$ ]] || _okp_i_fetch_project_target || return 1
    if [[ $(_okp_i_state PROJECT_COMMIT) == "$OKP_PROJECT_TARGET_COMMIT" ]]; then
        log_info 'one-key-proxy 已是目标 commit，无需更新。'
        return 0
    fi
    temp=$(mktemp -d "/tmp/one-key-proxy-project-update.XXXXXX") || return 1
    archive="$temp/project.tar.gz"
    if ! _okp_i_download \
        "https://codeload.github.com/${OKP_PROJECT_REPO}/tar.gz/${OKP_PROJECT_TARGET_COMMIT}" "$archive"; then
        rm -rf -- "$temp"
        return 1
    fi
    tar -tzf "$archive" | awk '
        /^\// || /(^|\/)\.\.($|\/)/ { bad=1 }
        END { exit bad }
    ' || {
        rm -rf -- "$temp"
        log_error '项目更新归档包含不安全路径。'
        return 1
    }
    tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$temp" || status=$?
    tree="${temp}/${OKP_PROJECT_REPO##*/}-${OKP_PROJECT_TARGET_COMMIT}"
    if ((status != 0)) || [[ -z $tree ]] || ! _okp_i_validate_project_tree "$tree"; then
        rm -rf -- "$temp"
        return 1
    fi
    [[ $(trim "$(<"$tree/VERSION")") == "$OKP_PROJECT_TARGET_VERSION" ]] || {
        rm -rf -- "$temp"
        log_error '目标 VERSION 与预检结果不一致。'
        return 1
    }

    runtime=$(_okp_i_state RUNTIME_DIR /usr/local/lib/one-key-proxy)
    [[ $runtime == /usr/local/lib/one-key-proxy && ! -L $runtime ]] || {
        rm -rf -- "$temp"
        log_error '运行目录不符合固定路径，拒绝原子替换。'
        return 1
    }
    previous_version=$(_okp_i_state PROJECT_VERSION unknown)
    previous_commit=$(_okp_i_state PROJECT_COMMIT unknown)
    new_runtime="${runtime}.new.$$"
    old_runtime="${runtime}.old.$$"
    if [[ -e $new_runtime || -L $new_runtime || -e $old_runtime || -L $old_runtime ]]; then
        rm -rf -- "$temp"
        log_error '项目更新事务路径已存在，拒绝覆盖。'
        return 1
    fi
    install -d -m 0755 -- "$new_runtime" || status=$?
    if ((status == 0)); then
        (set -o pipefail; tar -C "$tree" --exclude='.git' -cf - . | \
            tar --no-same-owner --no-same-permissions -C "$new_runtime" -xf -) || status=$?
    fi
    if ((status == 0)); then
        chown -R -h root:root "$new_runtime" || status=$?
        find "$new_runtime" -type d -exec chmod 0755 {} + || status=$?
        find "$new_runtime" -type f -name '*.sh' -exec chmod 0755 {} + || status=$?
        chmod 0755 "$new_runtime/one-key-proxy" || status=$?
    fi
    if ((status == 0)); then
        [[ ! -d $runtime ]] || mv -- "$runtime" "$old_runtime" || status=$?
    fi
    if ((status == 0)) && ! mv -- "$new_runtime" "$runtime"; then
        status=1
        [[ ! -d $old_runtime ]] || mv -- "$old_runtime" "$runtime"
    fi
    if ((status == 0)) && ! install -m 0755 -- "$runtime/one-key-proxy" /usr/local/bin/one-key-proxy; then
        status=1
    fi
    if ((status == 0)); then
        state_set_many PROJECT_VERSION "$OKP_PROJECT_TARGET_VERSION" \
            PROJECT_COMMIT "$OKP_PROJECT_TARGET_COMMIT" || status=$?
    fi
    rm -rf -- "$temp" "$new_runtime"
    if ((status != 0)); then
        if [[ -d $old_runtime ]]; then
            rm -rf -- "$runtime"
            mv -- "$old_runtime" "$runtime" || true
            install -m 0755 -- "$runtime/one-key-proxy" /usr/local/bin/one-key-proxy || true
        fi
        state_set_many PROJECT_VERSION "$previous_version" \
            PROJECT_COMMIT "$previous_commit" || true
        log_error '项目更新失败，已尽力恢复原运行目录。'
        return "$status"
    fi
    rm -rf -- "$old_runtime"
    log_info "one-key-proxy 已更新到 ${OKP_PROJECT_TARGET_VERSION} (${OKP_PROJECT_TARGET_COMMIT})。"
}

_okp_i_fetch_xui_target() {
    local response commit_document
    _okp_i_validate_github_source "$OKP_XUI_REPO" || return 1
    response=$(curl --disable --noproxy '*' -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        "https://api.github.com/repos/${OKP_XUI_REPO}/releases/latest") || return 1
    OKP_XUI_TARGET_TAG=$(jq -er '
        select(.draft == false and .prerelease == false) | .tag_name |
        select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
    ' <<<"$response") || return 1
    commit_document=$(curl --disable --noproxy '*' -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        "https://api.github.com/repos/${OKP_XUI_REPO}/commits/${OKP_XUI_TARGET_TAG}") || return 1
    OKP_XUI_TARGET_COMMIT=$(jq -er '.sha | select(test("^[0-9a-f]{40}$"))' \
        <<<"$commit_document") || return 1
    platform_detect || return 1
    okp_xui_release_asset_from_json "$OKP_XUI_REPO" "$OKP_XUI_TARGET_TAG" \
        "$PLATFORM_ARCH" "$response" || return 1
    OKP_XUI_TARGET_ASSET_SHA256=$OKP_XUI_RELEASE_ASSET_SHA256
}

_okp_i_check_xui_release_api() {
    local commit=$1 temp url path
    [[ $commit =~ ^[0-9a-f]{40}$ ]] || return 1
    temp=$(mktemp "/tmp/one-key-proxy-openapi.XXXXXX") || return 1
    url="https://raw.githubusercontent.com/${OKP_XUI_REPO}/${commit}/frontend/public/openapi.json"
    if ! _okp_i_download "$url" "$temp"; then
        url="https://raw.githubusercontent.com/${OKP_XUI_REPO}/${commit}/docs/public/openapi.json"
        _okp_i_download "$url" "$temp" || {
            rm -f -- "$temp"
            return 1
        }
    fi
    for path in \
        '/panel/api/server/status' \
        '/panel/api/server/getNewX25519Cert' \
        '/panel/api/inbounds/list' \
        '/panel/api/inbounds/update/{id}' \
        '/panel/api/inbounds/del/{id}' \
        '/panel/api/clients/add' \
        '/panel/api/clients/del/{email}' \
        '/panel/api/clients/subLinks/{subId}' \
        '/panel/api/hosts/list' \
        '/panel/api/hosts/add' \
        '/panel/api/hosts/byInbound/{inboundId}' \
        '/panel/api/setting/all' \
        '/panel/api/setting/update' \
        '/panel/api/setting/updateUser' \
        '/panel/api/setting/restartPanel' \
        '/panel/api/setting/apiTokens' \
        '/panel/api/setting/apiTokens/create' \
        '/panel/api/setting/apiTokens/delete/{id}'; do
        if ! jq -e --arg path "$path" '.paths[$path] != null' "$temp" >/dev/null; then
            rm -f -- "$temp"
            log_error "目标 3x-ui 缺少维护所需 API：${path}"
            return 1
        fi
    done
    if ! jq -e '(.paths["/panel/api/hosts/update/{id}"] //
                  .paths["/panel/api/hosts/update/{groupId}"]) != null' "$temp" >/dev/null; then
        rm -f -- "$temp"
        log_error '目标 3x-ui 缺少 Hosts 更新 API。'
        return 1
    fi
    rm -f -- "$temp"
}

okp_hook_xui_update_info() {
    local current
    current=$(_okp_i_state XUI_VERSION unknown)
    _okp_i_fetch_xui_target || {
        log_error '无法查询 3x-ui 最新稳定版。'
        return 1
    }
    _okp_i_check_xui_release_api "$OKP_XUI_TARGET_COMMIT" || return 1
    printf '当前 3x-ui 版本: %s\n' "$current"
    printf '目标 3x-ui 版本: %s\n' "$OKP_XUI_TARGET_TAG"
    printf '目标 commit: %s\n' "$OKP_XUI_TARGET_COMMIT"
    printf '目标资产 SHA-256: %s\n' "$OKP_XUI_TARGET_ASSET_SHA256"
    printf '来源: https://github.com/%s/tree/%s\n' "$OKP_XUI_REPO" "$OKP_XUI_TARGET_COMMIT"
}

_okp_i_reassert_xui_configuration() {
    local public_host
    _okp_i_load_config || return 1
    public_host=$(_okp_i_public_host)
    _okp_i_update_inbound_port "$NODE_INTERNAL_PORT" || return 1
    _okp_i_update_owned_host "$XUI_MANAGED_INBOUND_ID" "$public_host" "$NODE_EXTERNAL_PORT" || return 1
    xui_configure_subscription "$SUB_INTERNAL_PORT" https "$public_host" "$SUB_EXTERNAL_PORT" \
        "$CERT_DIR/server.crt" "$CERT_DIR/server.key" || return 1
    xui_configure_panel_tls "$PANEL_INTERNAL_PORT" "$CERT_DIR/server.crt" \
        "$CERT_DIR/server.key" "$public_host" || return 1
    xui_restart_panel || return 1
    _okp_i_wait_service || return 1
    _okp_i_verify_subscription_delivery "$public_host"
}

okp_hook_xui_update() {
    local installer output status current current_commit current_asset failure_output
    local supply_dir pinned_path
    # maintenance_main settles before the informational and backup phases. Keep
    # this defensive check so direct hook callers can never replay the upstream
    # updater over an unresolved journal.
    okp_hook_settle_pending_xui_update || return 1
    _okp_i_register_state_secrets
    if [[ ! $OKP_XUI_TARGET_TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ||
        ! $OKP_XUI_TARGET_COMMIT =~ ^[0-9a-f]{40}$ ||
        ! $OKP_XUI_TARGET_ASSET_SHA256 =~ ^[0-9a-f]{64}$ ]]; then
        _okp_i_fetch_xui_target || return 1
    fi
    current=$(_okp_i_state XUI_VERSION)
    current_commit=$(_okp_i_state XUI_RELEASE_COMMIT)
    current_asset=$(_okp_i_state XUI_RELEASE_ASSET_SHA256)
    if [[ $current == "$OKP_XUI_TARGET_TAG" && $current_commit == "$OKP_XUI_TARGET_COMMIT" &&
        $current_asset == "$OKP_XUI_TARGET_ASSET_SHA256" ]]; then
        log_info '3x-ui 已是最新稳定版；仍将执行健康检查。'
        okp_hook_diagnostics
        return $?
    fi
    _okp_i_check_xui_release_api "$OKP_XUI_TARGET_COMMIT" || return 1
    installer=$(mktemp "/tmp/one-key-proxy-xui-install.XXXXXX") || return 1
    output=$(mktemp "/tmp/one-key-proxy-xui-output.XXXXXX") || {
        rm -f -- "$installer"
        return 1
    }
    chmod 0600 "$installer" "$output"
    maintenance_temp_register "$installer" || {
        rm -f -- "$installer" "$output"
        return 1
    }
    maintenance_temp_register "$output" || {
        rm -f -- "$installer" "$output"
        return 1
    }
    supply_dir=$(mktemp -d "/tmp/one-key-proxy-xui-supply.XXXXXX") || {
        rm -f -- "$installer" "$output"
        return 1
    }
    maintenance_temp_register "$supply_dir" || {
        rm -rf -- "$supply_dir"
        rm -f -- "$installer" "$output"
        return 1
    }
    _okp_i_download \
        "https://raw.githubusercontent.com/${OKP_XUI_REPO}/${OKP_XUI_TARGET_COMMIT}/install.sh" \
        "$installer" || {
        rm -f -- "$installer" "$output"
        return 1
    }
    platform_detect || return 1
    okp_xui_validate_pinned_installer_downloaders "$installer" "$OKP_XUI_REPO" \
        "$OKP_XUI_TARGET_TAG" "$PLATFORM_ARCH" || return 1
    okp_prepare_pinned_xui_download "$OKP_XUI_REPO" "$OKP_XUI_TARGET_TAG" \
        "$OKP_XUI_TARGET_COMMIT" "$PLATFORM_ARCH" "$OKP_XUI_TARGET_ASSET_SHA256" \
        "$supply_dir" || return 1
    # Upstream's post-install hardening rewrites a root webBasePath. Persist a
    # recovery marker before it can mutate the database so an interrupted
    # maintenance run repairs the path before its next API request.
    state_set XUI_UPDATE_RECOVERY_STATUS restore-root-path || return 1
    pinned_path="${OKP_XUI_PINNED_BIN_DIR}:${PATH}"
    if _okp_i_run_supervised_xui_updater "$installer" "$OKP_XUI_TARGET_TAG" \
        "$pinned_path" "$output"; then
        status=0
    else
        status=$?
    fi
    rm -f -- "$installer"
    rm -rf -- "$supply_dir"
    if ((status != 0)); then
        log_error "3x-ui 官方更新器失败（退出码 ${status}）。"
        failure_output=$(redact_sensitive "$(tail -n 50 "$output")")
        failure_output=$(_xui_sanitize_log_message "$failure_output")
        [[ -z $failure_output ]] || log_error "$failure_output"
        rm -f -- "$output"
        if ! okp_hook_settle_pending_xui_update; then
            log_error '3x-ui 更新失败后的根路径恢复也未完成；服务已按失败关闭策略处理。'
        fi
        return "$status"
    fi
    rm -f -- "$output"
    # This stops x-ui, restores '/', verifies the CLI readback, starts x-ui,
    # and only then performs the first root-path API health call.
    okp_hook_settle_pending_xui_update || return 1
    _okp_i_reassert_xui_configuration || return 1
    state_set_many XUI_VERSION "$OKP_XUI_TARGET_TAG" \
        XUI_RELEASE_COMMIT "$OKP_XUI_TARGET_COMMIT" \
        XUI_RELEASE_ASSET_SHA256 "$OKP_XUI_TARGET_ASSET_SHA256" || return 1
    _okp_i_write_result || return 1
    okp_hook_diagnostics || return 1
    log_info "3x-ui 已更新到 ${OKP_XUI_TARGET_TAG}。"
}

okp_hook_rotate_panel_credentials() {
    local old_username old_password new_username new_password confirm_password payload secret_dir status=0
    _okp_i_load_config || return 1
    old_username=$PANEL_USERNAME
    old_password=$PANEL_PASSWORD
    maintenance_read new_username '新面板用户名' "$old_username" || return 1
    read_secret_tty new_password '新面板密码（至少 12 位）' || return 1
    read_secret_tty confirm_password '再次输入新面板密码' || return 1
    [[ $new_password == "$confirm_password" ]] || {
        log_error '两次输入的密码不一致。'
        return 1
    }
    [[ $new_username =~ ^[A-Za-z0-9_.-]{3,64}$ ]] || {
        log_error '面板用户名格式无效。'
        return 1
    }
    ((${#new_password} >= 12)) || {
        log_error '面板密码至少需要 12 个字符。'
        return 1
    }
    ! has_control_chars "$new_password" || {
        log_error '面板密码不能包含控制字符。'
        return 1
    }
    [[ $new_username != "$old_username" || $new_password != "$old_password" ]] || {
        log_info '新旧面板凭据相同，无需轮换。'
        return 0
    }
    secret_register "$old_password"
    secret_register "$new_password"
    _okp_i_secret_dir_create secret_dir panel-credentials || return 1
    printf '%s' "$old_password" >"$secret_dir/old-password"
    printf '%s' "$new_password" >"$secret_dir/new-password"
    chmod 0600 "$secret_dir/old-password" "$secret_dir/new-password"
    payload=$(jq -nc --arg oldUsername "$old_username" --arg newUsername "$new_username" \
        --rawfile oldPassword "$secret_dir/old-password" \
        --rawfile newPassword "$secret_dir/new-password" \
        '{oldUsername:$oldUsername, oldPassword:$oldPassword,
          newUsername:$newUsername, newPassword:$newPassword}') || status=$?
    _okp_i_secret_dir_remove "$secret_dir" || status=1
    ((status == 0)) || return "$status"
    xui_api_post /panel/api/setting/updateUser "$payload" >/dev/null || return 1
    xui_api_get /panel/api/server/status >/dev/null || {
        log_error '面板返回凭据更新成功，但管理 API 验证失败；状态未改写。'
        return 1
    }
    PANEL_USERNAME=$new_username
    PANEL_PASSWORD=$new_password
    state_set_many PANEL_USERNAME "$new_username" PANEL_PASSWORD "$new_password" || return 1
    _okp_i_write_result || return 1
    log_info '面板用户名和密码已轮换，旧凭据已失效。'
}

_okp_i_managed_client_csv() {
    local csv current
    csv=$(_okp_i_state MANAGED_CLIENT_EMAILS)
    current=$(_okp_i_state CLIENT_EMAIL)
    [[ -n $current ]] && csv=$(_okp_i_csv_add "$csv" "$current")
    printf '%s' "$csv"
}

_okp_i_verify_client_in_inbound() {
    local email=$1 uuid=${2-} sub_id=${3-} values actual_uuid actual_sub enabled
    _okp_i_find_owned_inbound || return 1
    values=$(jq -r --arg email "$email" '
        [.settings.clients[]? | select(.email == $email)][0] // {} |
        [.id // "", .subId // "", (.enable // false | tostring)] | @tsv
    ' <<<"$XUI_MANAGED_INBOUND_JSON") || return 1
    IFS=$'\t' read -r actual_uuid actual_sub enabled <<<"$values"
    [[ $enabled == true ]] || return 1
    [[ -z $uuid || $actual_uuid == "$uuid" ]] || return 1
    [[ -z $sub_id || $actual_sub == "$sub_id" ]]
}

okp_hook_create_replacement_client() {
    local installation_id inbound_id old_email uuid sub_id email payload managed links vless public_host
    local secret_dir status=0
    _okp_i_load_config || return 1
    _okp_i_find_owned_inbound || return 1
    inbound_id=$XUI_MANAGED_INBOUND_ID
    old_email=$(_okp_i_state CLIENT_EMAIL)
    installation_id=$(_okp_i_state INSTALLATION_ID)
    uuid=$(_okp_i_generate_uuid) || return 1
    sub_id=$(random_hex 16) || return 1
    email="okp-${installation_id:0:8}-$(date -u '+%Y%m%d%H%M%S')-$(random_hex 2)"
    _okp_i_secret_dir_create secret_dir client-credentials || return 1
    printf '%s' "$uuid" >"$secret_dir/uuid"
    printf '%s' "$sub_id" >"$secret_dir/sub-id"
    chmod 0600 "$secret_dir/uuid" "$secret_dir/sub-id"
    payload=$(jq -nc --arg email "$email" --rawfile uuid "$secret_dir/uuid" \
        --rawfile subId "$secret_dir/sub-id" --argjson inbound "$inbound_id" '
        {client:{email:$email, id:$uuid, flow:"xtls-rprx-vision", subId:$subId,
          limitIp:0, totalGB:0, expiryTime:0, enable:true, tgId:0,
          comment:"one-key-proxy replacement", reset:0}, inboundIds:[$inbound]}
    ') || status=$?
    _okp_i_secret_dir_remove "$secret_dir" || status=1
    ((status == 0)) || return "$status"
    xui_api_post /panel/api/clients/add "$payload" >/dev/null || return 1
    if ! _okp_i_verify_client_in_inbound "$email" "$uuid" "$sub_id"; then
        log_error '替代客户端创建响应成功，但入站回读验证失败。'
        return 1
    fi
    managed=$(_okp_i_managed_client_csv)
    managed=$(_okp_i_csv_add "$managed" "$email")
    state_set_many \
        MANAGED_CLIENT_EMAILS "$managed" \
        PREVIOUS_CLIENT_EMAIL "$old_email" \
        CLIENT_EMAIL "$email" \
        CLIENT_UUID "$uuid" \
        SUB_ID "$sub_id" || return 1
    _okp_i_write_result || return 1

    public_host=$(_okp_i_public_host)
    links=$(xui_get_sub_links "$sub_id") || return 1
    vless=$(_okp_i_select_vless_uri "$links" "$public_host" "$NODE_EXTERNAL_PORT") || return 1
    xui_build_subscription_urls https "$public_host" "$SUB_EXTERNAL_PORT" "$sub_id" || return 1
    printf '\n替代客户端已创建；旧客户端 %s 仍然有效。\n' "$old_email"
    printf '新客户端标识: %s\n' "$email"
    printf '新 Base64 订阅: %s\n' "$XUI_SUBSCRIPTION_URL"
    printf '新 Xray JSON 订阅: %s\n' "$XUI_JSON_SUBSCRIPTION_URL"
    printf '新 Clash/Mihomo 订阅: %s\n' "$XUI_CLASH_SUBSCRIPTION_URL"
    printf '新 VLESS URI: %s\n' "$vless"
    if command -v qrencode >/dev/null 2>&1; then
        printf '%s' "$vless" | qrencode -t ANSIUTF8 - 2>/dev/null || true
    fi
    return 0
}

okp_hook_delete_old_client() {
    local managed current inbound_clients last_online selection email encoded updated online_display
    local item index=0
    local -a candidates=()
    _okp_i_load_config || return 1
    managed=$(_okp_i_managed_client_csv)
    current=$(_okp_i_state CLIENT_EMAIL)
    _okp_i_find_owned_inbound || return 1
    inbound_clients=$(jq -c '.settings.clients // []' <<<"$XUI_MANAGED_INBOUND_JSON") || return 1
    last_online=$(xui_api_post /panel/api/clients/lastOnline '{}' 2>/dev/null || printf '{}')
    while IFS= read -r item; do
        [[ -n $item && $item != "$current" ]] || continue
        _okp_i_csv_has "$managed" "$item" || continue
        _okp_i_url_encode "$item" >/dev/null || {
            log_error '受管客户端清单包含不安全标识，拒绝继续。'
            return 1
        }
        candidates+=("$item")
    done < <(jq -r '.[].email // empty' <<<"$inbound_clients")
    ((${#candidates[@]} > 0)) || {
        log_error '没有可删除的受管旧客户端。'
        return 1
    }
    printf '可删除的旧客户端：\n'
    for email in "${candidates[@]}"; do
        index=$((index + 1))
        online_display=$(jq -r --arg email "$email" '.[$email] // "未知"' \
            <<<"$last_online" 2>/dev/null || printf '未知')
        online_display=$(_xui_sanitize_log_message "$online_display")
        printf '  %d. %s（最近在线: %s）\n' "$index" "$email" "$online_display"
    done
    maintenance_read selection '选择要删除的客户端编号' || return 1
    if [[ ! $selection =~ ^[0-9]+$ ]] || \
        ((selection < 1 || selection > ${#candidates[@]})); then
        log_error '客户端编号无效。'
        return 1
    fi
    email=${candidates[selection - 1]}
    printf '将删除旧客户端: %s\n' "$email"
    maintenance_confirm_phrase '删除后该客户端的现有设备会立即断开。' "$email" || return 1
    encoded=$(_okp_i_url_encode "$email") || return 1
    xui_api_post "/panel/api/clients/del/${encoded}" '{}' >/dev/null || return 1
    if _okp_i_verify_client_in_inbound "$email"; then
        log_error '删除 API 返回成功，但旧客户端仍存在。'
        return 1
    fi
    _okp_i_verify_client_in_inbound "$current" || {
        log_error '当前替代客户端异常；请立即从卸载前备份恢复。'
        return 1
    }
    updated=$(_okp_i_csv_remove "$managed" "$email")
    state_set MANAGED_CLIENT_EMAILS "$updated" || return 1
    log_info "旧客户端已删除：${email}；当前客户端仍有效。"
}

okp_hook_rotate_api_token() {
    local old_token old_id old_name timestamp new_name current_id
    _okp_i_register_state_secrets
    old_token=$(_okp_i_state XUI_API_TOKEN)
    old_id=$(_okp_i_state XUI_API_TOKEN_ID)
    old_name=$(_okp_i_state XUI_API_TOKEN_NAME)
    [[ -n $old_token && $old_id =~ ^[1-9][0-9]*$ && -n $old_name ]] || {
        log_error '当前 Token 缺少项目所有权 ID；为避免撤销未知 Token，拒绝轮换。'
        log_error '请先用最新版安装器完成一次受管 Token 迁移。'
        return 1
    }
    xui_validate_api_token "$old_token" "$old_id" "$old_name" || {
        log_error '当前 Token 无法通过 ID、名称和启用状态验证，拒绝轮换。'
        return 1
    }
    timestamp=$(date -u '+%Y%m%d%H%M%S')
    new_name="one-key-proxy-${timestamp}-$(random_hex 2)"
    if ! xui_rotate_api_token "$new_name" "$old_id"; then
        current_id=$(_okp_i_state XUI_API_TOKEN_ID)
        if [[ -n $current_id && $current_id != "$old_id" ]]; then
            log_error '新 Token 已写入受保护状态，但旧 Token 撤销或最终验证未完成；请运行 doctor 后重试。'
        else
            log_error 'Token 轮换失败，当前受保护状态仍指向旧 Token。'
        fi
        return 1
    fi
    xui_validate_api_token "$XUI_ROTATED_API_TOKEN_VALUE" "$XUI_ROTATED_API_TOKEN_ID" \
        "$XUI_ROTATED_API_TOKEN_NAME" || return 1
    old_token=''
    log_info "管理 API Token 已轮换为 ${new_name}，旧 Token 已撤销。"
}

_okp_i_unset_many() {
    local key
    for key in "$@"; do
        state_unset "$key" || return 1
    done
}

_okp_i_uninstall_clients() {
    local managed email encoded present=0 find_status
    local -a _okp_i_uninstall_client_items=()
    managed=$(_okp_i_managed_client_csv)
    [[ -n $managed ]] || return 0
    if _okp_i_find_owned_inbound; then
        IFS=, read -r -a _okp_i_uninstall_client_items <<<"$managed"
        for email in "${_okp_i_uninstall_client_items[@]}"; do
            [[ -n $email ]] || continue
            if jq -e --arg email "$email" 'any(.settings.clients[]?; .email == $email)' \
                >/dev/null <<<"$XUI_MANAGED_INBOUND_JSON"; then
                present=1
                encoded=$(_okp_i_url_encode "$email") || return 1
                xui_api_post "/panel/api/clients/del/${encoded}" '{}' >/dev/null || return 1
            fi
        done
        if ((present == 1)); then
            _okp_i_find_owned_inbound || return 1
            for email in "${_okp_i_uninstall_client_items[@]}"; do
                [[ -n $email ]] || continue
                if jq -e --arg email "$email" 'any(.settings.clients[]?; .email == $email)' \
                    >/dev/null <<<"$XUI_MANAGED_INBOUND_JSON"; then
                    log_error "客户端删除后仍存在：${email}"
                    return 1
                fi
            done
        fi
    else
        find_status=$?
        if ((find_status != 1)) || [[ -n $(_okp_i_state INBOUND_ID) ]]; then
            log_error '无法验证受管入站，拒绝猜测并删除全局客户端。'
            return 1
        fi
    fi
    _okp_i_unset_many MANAGED_CLIENT_EMAILS PREVIOUS_CLIENT_EMAIL CLIENT_EMAIL CLIENT_UUID SUB_ID || return 1
}

_okp_i_uninstall_inbound() {
    local stored_id find_status
    stored_id=$(_okp_i_state INBOUND_ID)
    [[ -n $stored_id ]] || return 0
    _okp_i_find_owned_inbound || {
        log_error '受管入站状态存在但无法唯一回读，拒绝删除。'
        return 1
    }
    [[ $XUI_MANAGED_INBOUND_ID == "$stored_id" ]] || {
        log_error '受管入站 ID 与状态记录不匹配，拒绝删除。'
        return 1
    }
    _okp_i_verify_owned_host "$stored_id" || {
        log_error 'Host 发布组所有权无法确认，拒绝级联删除入站。'
        return 1
    }
    xui_api_post "/panel/api/inbounds/del/${stored_id}" '{}' >/dev/null || return 1
    if _okp_i_find_owned_inbound 2>/dev/null; then
        log_error '入站删除 API 返回成功，但受管入站仍存在。'
        return 1
    else
        find_status=$?
        ((find_status == 1)) || {
            log_error '入站删除后的 API 回读失败，未清除所有权状态。'
            return 1
        }
    fi
    _okp_i_unset_many INBOUND_ID INBOUND_TAG HOST_GROUP_ID HOST_TAG \
        MANAGED_CLIENT_EMAILS PREVIOUS_CLIENT_EMAIL \
        CLIENT_EMAIL CLIENT_UUID SUB_ID REALITY_SHORT_ID REALITY_PUBLIC_KEY || return 1
}

_okp_i_uninstall_dns() {
    if [[ $(_okp_i_state MODE) != public ]]; then
        return 0
    fi
    _okp_i_path_is_safe_under "$OKP_ALIDNS_RECORDS_FILE" "$CONFIG_DIR" || {
        log_error 'AliDNS 所有权清单路径不安全，拒绝删除 DNS。'
        return 1
    }
    _okp_i_path_is_safe_under "$OKP_ALIDNS_CREDENTIALS_FILE" "$CONFIG_DIR" || {
        log_error 'AliDNS 凭据路径不安全，拒绝删除。'
        return 1
    }
    okp_alidns_delete_managed_records || return 1
    okp_alidns_remove_credentials || return 1
    _okp_i_unset_many ALIDNS_ZONE ALI_ACCESS_KEY_ID ALI_ACCESS_KEY_SECRET || return 1
}

_okp_i_uninstall_certificates() {
    local cert key
    cert=$(_okp_i_state TLS_CERT_FILE "$CERT_DIR/server.crt")
    key=$(_okp_i_state TLS_KEY_FILE "$CERT_DIR/server.key")
    if ! _okp_i_path_is_safe_under "$cert" "$CONFIG_DIR" ||
        ! _okp_i_path_is_safe_under "$key" "$CONFIG_DIR" ||
        ! _okp_i_path_is_safe_under "$OKP_ACME_HOME" "$CONFIG_DIR"; then
        log_error '证书路径不在项目配置目录中，拒绝删除。'
        return 1
    fi
    [[ $OKP_XUI_RELOAD_HOOK == /usr/local/bin/one-key-proxy-reload-x-ui &&
        $OKP_ACME_RENEW_BIN == /usr/local/bin/one-key-proxy-acme-renew &&
        $OKP_ACME_SYSTEMD_SERVICE == /etc/systemd/system/one-key-proxy-acme.service &&
        $OKP_ACME_SYSTEMD_TIMER == /etc/systemd/system/one-key-proxy-acme.timer &&
        $OKP_ACME_OPENRC_DAILY == /etc/periodic/daily/one-key-proxy-acme ]] || {
        log_error '证书调度器路径不符合项目固定路径，拒绝删除。'
        return 1
    }
    okp_acme_remove_scheduler || return 1
    okp_cert_remove_managed_files "$cert" "$key" || return 1
    rm -rf -- "$OKP_ACME_HOME"
    rm -f -- "$OKP_XUI_RELOAD_HOOK"
    _okp_i_unset_many TLS_MODE TLS_CERT_FILE TLS_KEY_FILE TLS_SUBJECT || return 1
}

_okp_i_uninstall_fail2ban() {
    declare -F okp_fail2ban_uninstall_project_rules >/dev/null 2>&1 || {
        log_error '当前运行库缺少 Fail2ban 受管卸载接口。'
        return 1
    }
    okp_fail2ban_uninstall_project_rules
}

_okp_i_uninstall_firewall() {
    local managed port
    local -a _okp_i_uninstall_firewall_items=()
    managed=$(_okp_i_state FIREWALL_MANAGED_TCP_PORTS)
    if [[ -n $managed ]]; then
        platform_detect_firewall || return 1
        IFS=, read -r -a _okp_i_uninstall_firewall_items <<<"$managed"
        for port in "${_okp_i_uninstall_firewall_items[@]}"; do
            [[ $port =~ ^[0-9]+$ ]] || {
                log_error '防火墙所有权清单无效，拒绝删除规则。'
                return 1
            }
            platform_firewall_revoke_tcp "$port" || return 1
        done
    fi
    _okp_i_unset_many FIREWALL_MANAGED_TCP_PORTS FIREWALL_REQUIRED_TCP_PORTS \
        FIREWALL_MANUAL_REQUIRED FIREWALL_BACKEND FIREWALL_ZONE || return 1
}

_okp_i_uninstall_xui() {
    local presence_status=0 activity_status=0
    if platform_service_exists x-ui; then
        if platform_service_is_inactive x-ui; then
            :
        else
            activity_status=$?
            if ((activity_status != 1)); then
                log_error '无法可靠判定 x-ui 服务运行状态，拒绝卸载。'
                return 1
            fi
            platform_service_stop x-ui || return 1
            platform_service_is_inactive x-ui || {
                log_error '无法确认 x-ui 已停止，拒绝卸载。'
                return 1
            }
        fi
        platform_service_disable x-ui || return 1
    else
        presence_status=$?
        if ((presence_status != 1)); then
            log_error '无法可靠判定 x-ui 服务是否存在，拒绝卸载。'
            return 1
        fi
    fi
    rm -f -- /etc/systemd/system/x-ui.service /etc/init.d/x-ui \
        /usr/bin/x-ui /usr/local/bin/x-ui
    rm -rf -- /usr/local/x-ui
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl daemon-reload || return 1
    fi
    _okp_i_unset_many XUI_VERSION XUI_RELEASE_COMMIT XUI_RELEASE_ASSET_SHA256 \
        XUI_SERVICE_NAME XUI_INSTALL_RESULT_FILE \
        XUI_API_TOKEN XUI_API_TOKEN_ID XUI_API_TOKEN_NAME PANEL_SCHEME || return 1
}

_okp_i_uninstall_component_selected() {
    local wanted=$1 component
    declare -p OKP_UNINSTALL_COMPONENTS >/dev/null 2>&1 || return 1
    for component in "${OKP_UNINSTALL_COMPONENTS[@]}"; do
        [[ $component == "$wanted" ]] && return 0
    done
    return 1
}

_okp_i_uninstall_database() {
    local database presence_status=0 activity_status=0
    local install_result=$OKP_XUI_INSTALL_RESULT_PATH install_result_parent owner links
    local remove_install_result=false
    database=$(_okp_i_state XUI_DB_PATH /etc/x-ui/x-ui.db)
    _okp_i_path_is_safe_under "$database" /etc/x-ui || {
        log_error '数据库路径不在 /etc/x-ui 中，拒绝删除。'
        return 1
    }
    if _okp_i_uninstall_component_selected xui &&
        _okp_i_uninstall_component_selected database &&
        [[ -e $install_result || -L $install_result ]]; then
        install_result_parent=${install_result%/*}
        if [[ ${OKP_PRODUCTION_MODE:-false} == true &&
            $install_result != /etc/x-ui/install-result.env ]] ||
            [[ ! -d $install_result_parent || -L $install_result_parent ||
                ! -f $install_result || -L $install_result ]]; then
            log_error '3x-ui 安装结果文件类型或固定路径不安全，拒绝删除数据库。'
            return 1
        fi
        owner=$(stat -c '%u' -- "$install_result" 2>/dev/null) || return 1
        links=$(stat -c '%h' -- "$install_result" 2>/dev/null) || return 1
        [[ $owner == 0 && $links == 1 ]] || {
            log_error '3x-ui 安装结果文件不是 root 所有的单硬链接文件，拒绝删除数据库。'
            return 1
        }
        remove_install_result=true
    fi
    if platform_service_exists x-ui; then
        if platform_service_is_inactive x-ui; then
            :
        else
            activity_status=$?
            if ((activity_status != 1)); then
                log_error '无法可靠判定 x-ui 服务运行状态，拒绝删除数据库。'
                return 1
            fi
            log_warn '删除数据库前将停止 x-ui；仅删除数据库时服务会保持停止。'
            platform_service_stop x-ui || return 1
            platform_service_is_inactive x-ui || {
                log_error '无法确认 x-ui 已停止，拒绝删除数据库。'
                return 1
            }
        fi
    else
        presence_status=$?
        if ((presence_status != 1)); then
            log_error '无法可靠判定 x-ui 服务是否存在，拒绝删除数据库。'
            return 1
        fi
    fi
    rm -f -- "$database" "${database}-shm" "${database}-wal" || return 1
    if [[ $remove_install_result == true ]]; then
        rm -f -- "$install_result" || return 1
    fi
    state_unset XUI_DB_PATH 2>/dev/null || true
    if [[ -d /etc/x-ui ]] && [[ -z $(find /etc/x-ui -mindepth 1 -maxdepth 1 -print -quit) ]]; then
        rmdir -- /etc/x-ui
    fi
}

_okp_i_uninstall_project_state() {
    local runtime
    runtime=$(_okp_i_state RUNTIME_DIR /usr/local/lib/one-key-proxy)
    [[ $runtime == /usr/local/lib/one-key-proxy ]] || {
        log_error '运行目录不符合固定路径，拒绝递归删除。'
        return 1
    }
    [[ $CONFIG_DIR == /etc/one-key-proxy ]] || {
        log_error '配置目录不符合固定路径，拒绝递归删除。'
        return 1
    }
    [[ $RESULT_FILE == /root/one-key-proxy-result.txt &&
        $LOG_FILE == /var/log/one-key-proxy.log ]] || {
        log_error '结果或日志路径不符合项目固定路径，拒绝删除。'
        return 1
    }
    rm -f -- /usr/local/bin/one-key-proxy "$RESULT_FILE" "$LOG_FILE"
    rm -rf -- "$runtime" "$CONFIG_DIR"
}

okp_hook_uninstall_component() {
    local component=${1-}
    case "$component" in
        inbound) _okp_i_uninstall_inbound ;;
        clients) _okp_i_uninstall_clients ;;
        dns) _okp_i_uninstall_dns ;;
        certificates) _okp_i_uninstall_certificates ;;
        fail2ban) _okp_i_uninstall_fail2ban ;;
        firewall) _okp_i_uninstall_firewall ;;
        xui) _okp_i_uninstall_xui ;;
        database) _okp_i_uninstall_database ;;
        project_state) _okp_i_uninstall_project_state ;;
        *) log_error "未知卸载组件：${component}"; return 2 ;;
    esac
}
