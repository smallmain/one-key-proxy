#!/usr/bin/env bash
# shellcheck shell=bash

# Best-effort Fail2ban protection for the 3x-ui panel login endpoint.
#
# Source contract (3x-ui v3.6.0):
#   internal/web/controller/index.go logs failed authentication as
#     WARNING - failed login: username=%q, IP=%q, reason=%q[, blocked_until=...]
#   internal/logger/logger.go writes 3xui.log below config.GetLogFolder().
#   internal/config/config.go defaults that folder to /var/log/x-ui.
#
# This is deliberately separate from 3x-ui's "3x-ipl" client-IP-limit jail.
# The latter consumes Xray access logs and does not protect panel logins.

if [[ ${OKP_PRODUCTION_MODE:-false} == true ]]; then
    OKP_FAIL2BAN_CONFIG_DIR=/etc/fail2ban
    OKP_FAIL2BAN_SERVICE=fail2ban
    OKP_FAIL2BAN_JAIL_NAME=one-key-proxy-3xui-panel
    OKP_FAIL2BAN_FILTER_NAME=one-key-proxy
else
    : "${OKP_FAIL2BAN_CONFIG_DIR:=/etc/fail2ban}"
    : "${OKP_FAIL2BAN_SERVICE:=fail2ban}"
    : "${OKP_FAIL2BAN_JAIL_NAME:=one-key-proxy-3xui-panel}"
    : "${OKP_FAIL2BAN_FILTER_NAME:=one-key-proxy}"
fi

OKP_FAIL2BAN_STATUS=${OKP_FAIL2BAN_STATUS:-not-configured}
OKP_FAIL2BAN_DEGRADED_REASON=${OKP_FAIL2BAN_DEGRADED_REASON:-}
OKP_FAIL2BAN_LOG_PATH=${OKP_FAIL2BAN_LOG_PATH:-}
OKP_FAIL2BAN_FILTER_FILE=${OKP_FAIL2BAN_FILTER_FILE:-}
OKP_FAIL2BAN_JAIL_FILE=${OKP_FAIL2BAN_JAIL_FILE:-}

_OKP_FAIL2BAN_MARKER='# Managed by one-key-proxy; local edits will be replaced.'

_okp_f2b_info() {
    if [[ $(type -t log_info 2>/dev/null || true) == function ]]; then
        log_info "$@"
    else
        printf '[INFO] %s\n' "$*"
    fi
}

_okp_f2b_warn() {
    if [[ $(type -t log_warn 2>/dev/null || true) == function ]]; then
        log_warn "$@"
    else
        printf '[WARN] %s\n' "$*" >&2
    fi
}

_okp_f2b_init_paths() {
    _okp_f2b_validate_path "$OKP_FAIL2BAN_CONFIG_DIR" || return 1
    [[ $OKP_FAIL2BAN_CONFIG_DIR != / ]] || return 1
    [[ $OKP_FAIL2BAN_JAIL_NAME =~ ^[A-Za-z0-9_.-]+$ && \
        $OKP_FAIL2BAN_FILTER_NAME =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    OKP_FAIL2BAN_FILTER_FILE="${OKP_FAIL2BAN_CONFIG_DIR%/}/filter.d/${OKP_FAIL2BAN_FILTER_NAME}.conf"
    OKP_FAIL2BAN_JAIL_FILE="${OKP_FAIL2BAN_CONFIG_DIR%/}/jail.d/one-key-proxy.local"
}

_okp_f2b_state_set() {
    if [[ $(type -t state_set 2>/dev/null || true) == function ]]; then
        state_set "$1" "${2-}" >/dev/null 2>&1 || true
    fi
}

_okp_f2b_record() {
    local status=$1
    local reason=${2-}
    local managed=${3:-false}

    OKP_FAIL2BAN_STATUS=$status
    OKP_FAIL2BAN_DEGRADED_REASON=$reason
    _okp_f2b_state_set FAIL2BAN_STATUS "$status"
    _okp_f2b_state_set FAIL2BAN_REASON "$reason"
    _okp_f2b_state_set FAIL2BAN_MANAGED "$managed"
    _okp_f2b_state_set FAIL2BAN_JAIL "$OKP_FAIL2BAN_JAIL_NAME"
    _okp_f2b_state_set FAIL2BAN_FILTER_FILE "$OKP_FAIL2BAN_FILTER_FILE"
    _okp_f2b_state_set FAIL2BAN_JAIL_FILE "$OKP_FAIL2BAN_JAIL_FILE"
    [[ -z $OKP_FAIL2BAN_LOG_PATH ]] || \
        _okp_f2b_state_set FAIL2BAN_LOG_PATH "$OKP_FAIL2BAN_LOG_PATH"
}

_okp_f2b_degrade() {
    local reason=$1
    local managed=false
    _okp_f2b_init_paths || true
    if _okp_f2b_file_is_owned "$OKP_FAIL2BAN_FILTER_FILE" && \
        _okp_f2b_file_is_owned "$OKP_FAIL2BAN_JAIL_FILE"; then
        managed=true
    fi
    _okp_f2b_record degraded "$reason" "$managed"
    _okp_f2b_warn "Fail2ban 已降级：${reason}。代理与面板部署将继续。"
    return 0
}

_okp_f2b_validate_port() {
    local port=${1-}
    if [[ $(type -t platform_validate_port 2>/dev/null || true) == function ]]; then
        platform_validate_port "$port"
        return
    fi
    [[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535))
}

_okp_f2b_validate_path() {
    local path=${1-}
    [[ $path == /* && $path =~ ^/[A-Za-z0-9._+@:/-]+$ ]] || return 1
    case "/${path#/}/" in
        *'/../'*|*'/./'*) return 1 ;;
    esac
    return 0
}

_okp_f2b_read_log_folder() {
    local file line value
    for file in /etc/default/x-ui /etc/conf.d/x-ui /etc/sysconfig/x-ui; do
        [[ -r $file && -f $file && ! -L $file ]] || continue
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line#"${line%%[![:space:]]*}"}
            [[ $line == export[[:space:]]* ]] && line=${line#export}
            line=${line#"${line%%[![:space:]]*}"}
            [[ $line == XUI_LOG_FOLDER=* ]] || continue
            value=${line#*=}
            value=${value#"${value%%[![:space:]]*}"}
            value=${value%"${value##*[![:space:]]}"}
            if [[ $value == \"*\" && ${#value} -ge 2 ]]; then
                value=${value:1:${#value}-2}
            elif [[ $value == \'*\' && ${#value} -ge 2 ]]; then
                value=${value:1:${#value}-2}
            fi
            _okp_f2b_validate_path "$value" || return 1
            printf '%s\n' "${value%/}"
            return 0
        done <"$file"
    done
    printf '%s\n' /var/log/x-ui
}

okp_fail2ban_detect_log_path() {
    local requested=${1-}
    local folder

    if [[ -n $requested ]]; then
        OKP_FAIL2BAN_LOG_PATH=$requested
    elif [[ -z $OKP_FAIL2BAN_LOG_PATH ]]; then
        folder=$(_okp_f2b_read_log_folder) || return 1
        OKP_FAIL2BAN_LOG_PATH="${folder%/}/3xui.log"
    fi
    _okp_f2b_validate_path "$OKP_FAIL2BAN_LOG_PATH" || return 1
    printf '%s\n' "$OKP_FAIL2BAN_LOG_PATH"
}

_okp_f2b_require_root() {
    if [[ $(type -t platform_require_root 2>/dev/null || true) == function ]]; then
        platform_require_root
        return
    fi
    [[ ${EUID:-$(id -u)} -eq 0 ]]
}

_okp_f2b_install_package() {
    if command -v fail2ban-client >/dev/null 2>&1 && \
        command -v fail2ban-regex >/dev/null 2>&1; then
        return 0
    fi
    if [[ $(type -t platform_install_packages 2>/dev/null || true) != function ]]; then
        return 1
    fi

    _okp_f2b_info '正在尝试安装 Fail2ban。'
    if platform_install_packages fail2ban >/dev/null 2>&1 && \
        command -v fail2ban-client >/dev/null 2>&1 && \
        command -v fail2ban-regex >/dev/null 2>&1; then
        return 0
    fi

    # Most RHEL clones publish Fail2ban through EPEL. Enabling that repository
    # is still best effort; uninstall never removes it or the shared package.
    if [[ ${PLATFORM_FAMILY:-} == rhel && ${PLATFORM_OS_ID:-} != fedora ]]; then
        _okp_f2b_info '默认仓库没有 Fail2ban，正在尝试 EPEL。'
        platform_install_packages epel-release >/dev/null 2>&1 || return 1
        platform_install_packages fail2ban >/dev/null 2>&1 || return 1
    fi
    command -v fail2ban-client >/dev/null 2>&1 && \
        command -v fail2ban-regex >/dev/null 2>&1
}

_okp_f2b_file_is_owned() {
    local file=$1
    local first=''
    [[ -f $file && ! -L $file ]] || return 1
    IFS= read -r first <"$file" || true
    [[ $first == "$_OKP_FAIL2BAN_MARKER" ]]
}

_okp_f2b_target_is_writable() {
    local file=$1
    if [[ -e $file || -L $file ]]; then
        _okp_f2b_file_is_owned "$file"
        return
    fi
    return 0
}

_okp_f2b_write_filter() {
    local file=$1
    local temporary
    temporary=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if ! {
        printf '%s\n' "$_OKP_FAIL2BAN_MARKER"
        cat <<'EOF'
# 3x-ui v3.6.0 panel authentication failures from /var/log/x-ui/3xui.log.
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex = ^\s*(?:\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+)?WARNING - failed login: username="[^"]*", IP="<HOST>", reason="(?:invalid credentials|invalid 2FA code|too many failed attempts)"(?:, blocked_until=\S+)?\s*$
ignoreregex =
EOF
    } >"$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    chmod 0644 "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    mv -f -- "$temporary" "$file"
}

_okp_f2b_write_jail() {
    local file=$1
    local port=$2
    local log_path=$3
    local temporary
    temporary=$(mktemp "${file}.tmp.XXXXXX") || return 1
    if ! {
        printf '%s\n' "$_OKP_FAIL2BAN_MARKER"
        cat <<EOF
[${OKP_FAIL2BAN_JAIL_NAME}]
enabled = true
filter = ${OKP_FAIL2BAN_FILTER_NAME}
backend = polling
logpath = ${log_path}
port = ${port}
protocol = tcp
usedns = no
maxretry = 5
findtime = 600
bantime = 3600
EOF
    } >"$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    chmod 0644 "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    mv -f -- "$temporary" "$file"
}

_okp_f2b_test_filter() {
    local sample output status=0
    sample=$(mktemp "${TMPDIR:-/tmp}/one-key-proxy-f2b-sample.XXXXXX") || return 1
    output=$(mktemp "${TMPDIR:-/tmp}/one-key-proxy-f2b-output.XXXXXX") || {
        rm -f -- "$sample"
        return 1
    }
    cat >"$sample" <<'EOF'
2026/07/24 12:34:56 WARNING - failed login: username="test", IP="192.0.2.45", reason="invalid credentials"
2026/07/24 12:35:56 WARNING - failed login: username="test", IP="2001:db8::45", reason="invalid 2FA code"
2026/07/24 12:36:56 WARNING - failed login: username="test", IP="192.0.2.46", reason="too many failed attempts", blocked_until=2026-07-24T12:51:56Z
2026/07/24 12:37:56 INFO - failed login: username="test", IP="192.0.2.47", reason="invalid credentials"
EOF
    fail2ban-regex "$sample" "$OKP_FAIL2BAN_FILTER_FILE" >"$output" 2>&1 || status=$?
    if ((status == 0)) && ! grep -Eq '(^|[[:space:],])3 matched([,[:space:]]|$)' "$output"; then
        status=1
    fi
    rm -f -- "$sample" "$output"
    return "$status"
}

_okp_f2b_config_test() {
    fail2ban-client -t >/dev/null 2>&1
}

_okp_f2b_service_is_active() {
    if [[ $(type -t platform_service_is_active 2>/dev/null || true) == function ]]; then
        platform_service_is_active "$OKP_FAIL2BAN_SERVICE"
    else
        fail2ban-client ping >/dev/null 2>&1
    fi
}

_okp_f2b_activate() {
    if _okp_f2b_service_is_active; then
        fail2ban-client reload >/dev/null 2>&1 || return 1
    else
        if [[ $(type -t platform_service_enable 2>/dev/null || true) != function || \
            $(type -t platform_service_start 2>/dev/null || true) != function ]]; then
            return 1
        fi
        platform_service_enable "$OKP_FAIL2BAN_SERVICE" >/dev/null 2>&1 || return 1
        platform_service_start "$OKP_FAIL2BAN_SERVICE" >/dev/null 2>&1 || return 1
    fi
    fail2ban-client status "$OKP_FAIL2BAN_JAIL_NAME" >/dev/null 2>&1
}

_okp_f2b_restore_files() {
    local backup_dir=$1
    local had_filter=$2
    local had_jail=$3
    local temporary status=0

    if [[ $had_filter == true ]]; then
        if temporary=$(mktemp "${OKP_FAIL2BAN_FILTER_FILE}.restore.XXXXXX"); then
            cp -p -- "$backup_dir/filter.conf" "$temporary" 2>/dev/null && \
                mv -f -- "$temporary" "$OKP_FAIL2BAN_FILTER_FILE" || status=1
            [[ ! -e $temporary ]] || rm -f -- "$temporary"
        else
            status=1
        fi
    else
        rm -f -- "$OKP_FAIL2BAN_FILTER_FILE" || status=1
    fi
    if [[ $had_jail == true ]]; then
        if temporary=$(mktemp "${OKP_FAIL2BAN_JAIL_FILE}.restore.XXXXXX"); then
            cp -p -- "$backup_dir/jail.local" "$temporary" 2>/dev/null && \
                mv -f -- "$temporary" "$OKP_FAIL2BAN_JAIL_FILE" || status=1
            [[ ! -e $temporary ]] || rm -f -- "$temporary"
        else
            status=1
        fi
    else
        rm -f -- "$OKP_FAIL2BAN_JAIL_FILE" || status=1
    fi
    if ((status == 0)); then
        fail2ban-client reload >/dev/null 2>&1 || true
    fi
    return "$status"
}

_okp_f2b_remove_backup() {
    local backup_dir=$1
    rm -f -- "$backup_dir/filter.conf" "$backup_dir/jail.local"
    rmdir -- "$backup_dir" 2>/dev/null || true
}

_okp_fail2ban_apply() {
    local panel_port=$1
    local requested_log=${2-}
    local backup_dir had_filter=false had_jail=false
    local failure=''

    _okp_f2b_require_root || return 10
    _okp_f2b_validate_port "$panel_port" || return 11
    panel_port=$((10#$panel_port))
    _okp_f2b_init_paths || return 12
    okp_fail2ban_detect_log_path "$requested_log" >/dev/null || return 12
    _okp_f2b_install_package || return 13

    [[ -f $OKP_FAIL2BAN_LOG_PATH && ! -L $OKP_FAIL2BAN_LOG_PATH && \
        -r $OKP_FAIL2BAN_LOG_PATH ]] || return 14
    [[ ! -L $OKP_FAIL2BAN_CONFIG_DIR && ! -L ${OKP_FAIL2BAN_CONFIG_DIR%/}/filter.d && \
        ! -L ${OKP_FAIL2BAN_CONFIG_DIR%/}/jail.d ]] || return 15
    install -d -m 0755 -- "$OKP_FAIL2BAN_CONFIG_DIR" \
        "${OKP_FAIL2BAN_CONFIG_DIR%/}/filter.d" \
        "${OKP_FAIL2BAN_CONFIG_DIR%/}/jail.d" || return 16
    _okp_f2b_target_is_writable "$OKP_FAIL2BAN_FILTER_FILE" || return 17
    _okp_f2b_target_is_writable "$OKP_FAIL2BAN_JAIL_FILE" || return 17

    backup_dir=$(mktemp -d "${TMPDIR:-/tmp}/one-key-proxy-f2b-backup.XXXXXX") || return 18
    if [[ -e $OKP_FAIL2BAN_FILTER_FILE ]]; then
        cp -p -- "$OKP_FAIL2BAN_FILTER_FILE" "$backup_dir/filter.conf" || {
            _okp_f2b_remove_backup "$backup_dir"
            return 18
        }
        had_filter=true
    fi
    if [[ -e $OKP_FAIL2BAN_JAIL_FILE ]]; then
        cp -p -- "$OKP_FAIL2BAN_JAIL_FILE" "$backup_dir/jail.local" || {
            _okp_f2b_remove_backup "$backup_dir"
            return 18
        }
        had_jail=true
    fi

    _okp_f2b_write_filter "$OKP_FAIL2BAN_FILTER_FILE" || failure=write-filter
    if [[ -z $failure ]]; then
        _okp_f2b_write_jail "$OKP_FAIL2BAN_JAIL_FILE" "$panel_port" \
            "$OKP_FAIL2BAN_LOG_PATH" || failure=write-jail
    fi
    [[ -n $failure ]] || _okp_f2b_test_filter || failure=filter-test
    [[ -n $failure ]] || _okp_f2b_config_test || failure=config-test
    [[ -n $failure ]] || _okp_f2b_activate || failure=activate

    if [[ -n $failure ]]; then
        if ! _okp_f2b_restore_files "$backup_dir" "$had_filter" "$had_jail"; then
            failure=rollback
        fi
        _okp_f2b_remove_backup "$backup_dir"
        case $failure in
            write-filter|write-jail) return 19 ;;
            filter-test) return 20 ;;
            config-test) return 21 ;;
            activate) return 22 ;;
            rollback) return 23 ;;
        esac
    fi
    _okp_f2b_remove_backup "$backup_dir"
    return 0
}

# Best-effort public entry point. It intentionally returns success after a
# degradation so the core proxy deployment remains usable. Inspect
# OKP_FAIL2BAN_STATUS or persisted FAIL2BAN_STATUS for the actual outcome.
okp_fail2ban_install() {
    local panel_port=${1-}
    local requested_log=${2-}
    local status=0 reason='未知错误'

    _okp_fail2ban_apply "$panel_port" "$requested_log" || status=$?
    if ((status == 0)); then
        _okp_f2b_record enabled '' true
        _okp_f2b_info "Fail2ban jail ${OKP_FAIL2BAN_JAIL_NAME} 已启用。"
        return 0
    fi
    case $status in
        10) reason='需要 root 权限' ;;
        11) reason='面板内部端口无效' ;;
        12) reason='3x-ui 日志路径无效' ;;
        13) reason='软件包或命令安装失败' ;;
        14) reason="3x-ui 日志不存在或不是安全的常规文件：${OKP_FAIL2BAN_LOG_PATH:-unknown}" ;;
        15) reason='Fail2ban 配置目录包含符号链接' ;;
        16) reason='无法创建 Fail2ban 配置目录' ;;
        17) reason='同名配置不是本项目所有，拒绝覆盖' ;;
        18) reason='无法备份现有项目规则' ;;
        19) reason='无法原子写入规则文件' ;;
        20) reason='登录失败日志样例未通过 filter 匹配验证' ;;
        21) reason='Fail2ban 全量配置验证失败' ;;
        22) reason='Fail2ban 服务或 jail 启动验证失败' ;;
        23) reason='Fail2ban 新规则失败且旧规则恢复失败，需要人工检查配置文件' ;;
    esac
    _okp_f2b_degrade "$reason"
}

okp_fail2ban_verify() {
    _okp_f2b_init_paths || return 1
    okp_fail2ban_detect_log_path "${1-}" >/dev/null || return 1
    command -v fail2ban-client >/dev/null 2>&1 || return 1
    command -v fail2ban-regex >/dev/null 2>&1 || return 1
    _okp_f2b_file_is_owned "$OKP_FAIL2BAN_FILTER_FILE" || return 1
    _okp_f2b_file_is_owned "$OKP_FAIL2BAN_JAIL_FILE" || return 1
    [[ -f $OKP_FAIL2BAN_LOG_PATH && ! -L $OKP_FAIL2BAN_LOG_PATH ]] || return 1
    _okp_f2b_test_filter || return 1
    _okp_f2b_config_test || return 1
    fail2ban-client status "$OKP_FAIL2BAN_JAIL_NAME" >/dev/null 2>&1
}

# Remove only files carrying this project's ownership marker. The Fail2ban
# package and service are shared resources and are intentionally left installed.
okp_fail2ban_uninstall_project_rules() {
    local file reload_failed=false service_active=false
    _okp_f2b_require_root || return 1
    _okp_f2b_init_paths || return 1

    for file in "$OKP_FAIL2BAN_FILTER_FILE" "$OKP_FAIL2BAN_JAIL_FILE"; do
        if [[ -e $file || -L $file ]]; then
            if ! _okp_f2b_file_is_owned "$file"; then
                _okp_f2b_warn "拒绝删除不属于本项目的 Fail2ban 配置：${file}"
                return 1
            fi
        fi
    done

    if command -v fail2ban-client >/dev/null 2>&1 && \
        fail2ban-client ping >/dev/null 2>&1; then
        service_active=true
        fail2ban-client stop "$OKP_FAIL2BAN_JAIL_NAME" >/dev/null 2>&1 || true
    fi
    rm -f -- "$OKP_FAIL2BAN_FILTER_FILE" "$OKP_FAIL2BAN_JAIL_FILE" || return 1
    if [[ $service_active == true ]] && \
        ! fail2ban-client reload >/dev/null 2>&1; then
        reload_failed=true
        _okp_f2b_warn '本项目 Fail2ban 规则已删除，但服务 reload 失败。'
    fi
    _okp_f2b_record removed '' false
    [[ $reload_failed == false ]]
}
