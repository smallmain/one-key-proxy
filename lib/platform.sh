#!/usr/bin/env bash
# shellcheck shell=bash
# Public output variables are intentionally assigned for callers to consume.
# shellcheck disable=SC2034

# Platform abstraction for one-key-proxy. This library intentionally does not
# change the caller's shell options and never exits the process by itself.

PLATFORM_OS_ID=''
PLATFORM_OS_LIKE=''
PLATFORM_OS_NAME=''
PLATFORM_OS_VERSION=''
PLATFORM_FAMILY=''
PLATFORM_ARCH=''
PLATFORM_INIT=''
PLATFORM_PACKAGE_MANAGER=''
PLATFORM_FIREWALL=''
PLATFORM_FIREWALL_ZONE=''
PLATFORM_FIREWALL_RULE_CHANGED=0
_PLATFORM_APT_UPDATED=0

_platform_log_info() {
    if [[ $(type -t log_info 2>/dev/null || true) == function ]]; then
        log_info "$@"
    else
        printf '%s\n' "[INFO] $*" >&2
    fi
}

_platform_log_warn() {
    if [[ $(type -t log_warn 2>/dev/null || true) == function ]]; then
        log_warn "$@"
    else
        printf '%s\n' "[WARN] $*" >&2
    fi
}

_platform_log_error() {
    if [[ $(type -t log_error 2>/dev/null || true) == function ]]; then
        log_error "$@"
    else
        printf '%s\n' "[ERROR] $*" >&2
    fi
}

platform_require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        _platform_log_error "此操作必须以 root 用户运行。"
        return 1
    fi
    return 0
}

platform_detect_os() {
    if [[ $(uname -s 2>/dev/null || true) != Linux ]]; then
        _platform_log_error "仅支持 Linux 系统。"
        return 1
    fi
    if [[ ! -r /etc/os-release ]]; then
        _platform_log_error "缺少 /etc/os-release，无法安全识别发行版。"
        return 1
    fi

    local ID='' ID_LIKE='' NAME='' VERSION_ID='' PRETTY_NAME=''
    # shellcheck disable=SC1091
    source /etc/os-release

    PLATFORM_OS_ID=${ID,,}
    PLATFORM_OS_LIKE=${ID_LIKE,,}
    PLATFORM_OS_NAME=${PRETTY_NAME:-${NAME:-$PLATFORM_OS_ID}}
    PLATFORM_OS_VERSION=${VERSION_ID:-unknown}

    case $PLATFORM_OS_ID in
        debian|ubuntu)
            PLATFORM_FAMILY=debian
            ;;
        alpine)
            PLATFORM_FAMILY=alpine
            ;;
        rhel|centos|rocky|almalinux|ol|fedora|amzn)
            PLATFORM_FAMILY=rhel
            ;;
        arch|manjaro)
            PLATFORM_FAMILY=arch
            ;;
        opensuse*|sles)
            PLATFORM_FAMILY=suse
            ;;
        *)
            case " $PLATFORM_OS_LIKE " in
                *' debian '*|*' ubuntu '*) PLATFORM_FAMILY=debian ;;
                *' rhel '*|*' fedora '*|*' centos '*) PLATFORM_FAMILY=rhel ;;
                *' arch '*) PLATFORM_FAMILY=arch ;;
                *' suse '*|*' opensuse '*) PLATFORM_FAMILY=suse ;;
                *)
                    _platform_log_error "不支持的 Linux 发行版：${PLATFORM_OS_ID:-unknown}。"
                    return 1
                    ;;
            esac
            ;;
    esac

    case $PLATFORM_FAMILY in
        debian) PLATFORM_PACKAGE_MANAGER=apt-get ;;
        alpine) PLATFORM_PACKAGE_MANAGER=apk ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                PLATFORM_PACKAGE_MANAGER=dnf
            elif command -v yum >/dev/null 2>&1; then
                PLATFORM_PACKAGE_MANAGER=yum
            else
                _platform_log_error "系统缺少 dnf/yum。"
                return 1
            fi
            ;;
        arch) PLATFORM_PACKAGE_MANAGER=pacman ;;
        suse) PLATFORM_PACKAGE_MANAGER=zypper ;;
    esac

    if ! command -v "$PLATFORM_PACKAGE_MANAGER" >/dev/null 2>&1; then
        _platform_log_error "系统缺少预期的软件包管理器：$PLATFORM_PACKAGE_MANAGER。"
        return 1
    fi
    return 0
}

platform_detect_arch() {
    local machine
    machine=$(uname -m 2>/dev/null || true)
    case $machine in
        x86_64|amd64) PLATFORM_ARCH=amd64 ;;
        aarch64|arm64) PLATFORM_ARCH=arm64 ;;
        *)
            _platform_log_error "不支持的 CPU 架构：${machine:-unknown}，仅支持 amd64 和 arm64。"
            return 1
            ;;
    esac
    return 0
}

platform_detect_init() {
    local pid1=''
    if [[ -r /proc/1/comm ]]; then
        IFS= read -r pid1 </proc/1/comm || true
    fi
    pid1=${pid1##*/}

    if [[ $pid1 == systemd ]] && command -v systemctl >/dev/null 2>&1 && \
        [[ -d /run/systemd/system ]]; then
        PLATFORM_INIT=systemd
        return 0
    fi

    if [[ $pid1 == init || $pid1 == openrc || $pid1 == openrc-init ]] && \
        command -v rc-service >/dev/null 2>&1 && \
        command -v rc-status >/dev/null 2>&1 && \
        [[ -d /run/openrc ]]; then
        PLATFORM_INIT=openrc
        return 0
    fi

    PLATFORM_INIT=unsupported
    _platform_log_error "PID 1 (${pid1:-unknown}) 不是受支持的 systemd/OpenRC init；拒绝在无服务管理器的容器环境中安装。"
    return 1
}

platform_detect() {
    platform_detect_os || return 1
    platform_detect_arch || return 1
    platform_detect_init || return 1
    return 0
}

_platform_validate_package_names() {
    local package
    for package in "$@"; do
        if [[ -z $package || $package == -* || $package =~ [^A-Za-z0-9+_.:@-] ]]; then
            _platform_log_error "非法的软件包名称：$package"
            return 1
        fi
    done
    return 0
}

platform_install_packages() {
    (($# > 0)) || return 0
    platform_require_root || return 1
    _platform_validate_package_names "$@" || return 1
    if [[ -z $PLATFORM_FAMILY || -z $PLATFORM_PACKAGE_MANAGER ]]; then
        platform_detect_os || return 1
    fi

    case $PLATFORM_FAMILY in
        debian)
            if ((_PLATFORM_APT_UPDATED == 0)); then
                apt-get update || return 1
                _PLATFORM_APT_UPDATED=1
            fi
            DEBIAN_FRONTEND=noninteractive \
                apt-get install -y --no-install-recommends "$@"
            ;;
        alpine)
            apk add --no-cache "$@"
            ;;
        rhel)
            "$PLATFORM_PACKAGE_MANAGER" -y install "$@"
            ;;
        arch)
            _platform_log_warn "Arch Linux 不支持局部升级；安装依赖将执行 pacman -Syu 完整系统升级。"
            pacman -Syu --noconfirm --needed "$@"
            ;;
        suse)
            zypper --non-interactive install --no-recommends "$@"
            ;;
        *)
            _platform_log_error "未识别的软件包管理器族：${PLATFORM_FAMILY:-unknown}。"
            return 1
            ;;
    esac
}

platform_install_dependencies() {
    [[ -n $PLATFORM_FAMILY ]] || platform_detect_os || return 1

    local -a packages=(bash ca-certificates curl tar gzip openssl jq)
    case $PLATFORM_FAMILY in
        alpine) packages+=(iproute2 flock) ;;
        rhel) packages+=(iproute util-linux) ;;
        *) packages+=(iproute2 util-linux) ;;
    esac
    _platform_log_info "正在检查并安装基础依赖。"
    platform_install_packages "${packages[@]}" || return 1

    if ! command -v flock >/dev/null 2>&1; then
        _platform_log_error "基础依赖安装完成后仍未找到 flock，无法提供可靠的状态文件锁。"
        return 1
    fi
    return 0
}

platform_install_optional_qrencode() {
    if command -v qrencode >/dev/null 2>&1; then
        return 0
    fi
    [[ -n $PLATFORM_FAMILY ]] || platform_detect_os || return 1

    local qr_package=qrencode
    [[ $PLATFORM_FAMILY == alpine ]] && qr_package=libqrencode-tools

    if platform_install_packages "$qr_package" && command -v qrencode >/dev/null 2>&1; then
        return 0
    fi

    # Alpine 3.17 and earlier shipped the executable in the main package.
    if [[ $PLATFORM_FAMILY == alpine ]] && \
        platform_install_packages libqrencode && command -v qrencode >/dev/null 2>&1; then
        return 0
    fi

    _platform_log_warn "可选的 qrencode 安装失败；核心部署将继续，但终端无法显示二维码。"
    return 0
}

platform_validate_port() {
    local port=${1:-}
    if [[ ! $port =~ ^[0-9]+$ ]] || ((${#port} > 5)) || \
        ((10#$port < 1 || 10#$port > 65535)); then
        _platform_log_error "端口必须是 1 到 65535 之间的整数：${port:-empty}。"
        return 1
    fi
    return 0
}

platform_port_is_listening() {
    local port=${1:-}
    local protocol=${2:-tcp}
    local output status
    platform_validate_port "$port" || return 2
    case $protocol in
        tcp|udp) ;;
        *)
            _platform_log_error "不支持的传输协议：$protocol。"
            return 2
            ;;
    esac

    if command -v ss >/dev/null 2>&1; then
        if [[ $protocol == tcp ]]; then
            output=$(ss -H -ltn 2>/dev/null)
        else
            output=$(ss -H -lun 2>/dev/null)
        fi
        status=$?
        if ((status != 0)); then
            _platform_log_error "ss 无法读取监听端口。"
            return 2
        fi
        awk -v wanted_port="$((10#$port))" '
            {
                local_address = $4
                if (local_address ~ (":" wanted_port "$") ) {
                    found = 1
                }
            }
            END { exit(found ? 0 : 1) }
        ' <<<"$output"
        status=$?
        ((status == 0 || status == 1)) || return 2
        return "$status"
    fi

    if command -v netstat >/dev/null 2>&1; then
        if [[ $protocol == tcp ]]; then
            output=$(netstat -ltn 2>/dev/null)
        else
            output=$(netstat -lun 2>/dev/null)
        fi
        status=$?
        if ((status != 0)); then
            _platform_log_error "netstat 无法读取监听端口。"
            return 2
        fi
        awk -v wanted_port="$((10#$port))" '
            NR > 2 {
                local_address = $4
                if (local_address ~ (":" wanted_port "$") ) {
                    found = 1
                }
            }
            END { exit(found ? 0 : 1) }
        ' <<<"$output"
        status=$?
        ((status == 0 || status == 1)) || return 2
        return "$status"
    fi

    _platform_log_error "缺少 ss/netstat，无法检测端口占用。"
    return 2
}

platform_port_is_available() {
    local status
    if platform_port_is_listening "$@"; then
        return 1
    else
        status=$?
        [[ $status -eq 1 ]] && return 0
        return "$status"
    fi
}

platform_detect_firewall() {
    local ufw_active=0
    local firewalld_active=0
    local active_zones=''
    local default_zone=''
    local zone_count=0

    if command -v ufw >/dev/null 2>&1 && \
        LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active$'; then
        ufw_active=1
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && \
        LC_ALL=C firewall-cmd --state 2>/dev/null | grep -q '^running$'; then
        firewalld_active=1
    fi

    if ((ufw_active == 1 && firewalld_active == 1)); then
        PLATFORM_FIREWALL=ambiguous
        PLATFORM_FIREWALL_ZONE=''
        _platform_log_error "UFW 和 firewalld 同时处于活动状态，拒绝自动修改防火墙。"
        return 2
    elif ((ufw_active == 1)); then
        PLATFORM_FIREWALL=ufw
        PLATFORM_FIREWALL_ZONE=''
    elif ((firewalld_active == 1)); then
        PLATFORM_FIREWALL=firewalld
        active_zones=$(LC_ALL=C firewall-cmd --get-active-zones 2>/dev/null | \
            awk '/^[^[:space:]]/ { print $1 }')
        default_zone=$(LC_ALL=C firewall-cmd --get-default-zone 2>/dev/null || true)

        if [[ -n $default_zone ]] && grep -Fxq "$default_zone" <<<"$active_zones"; then
            PLATFORM_FIREWALL_ZONE=$default_zone
        else
            zone_count=$(awk 'NF { count++ } END { print count + 0 }' <<<"$active_zones")
            if ((zone_count == 1)); then
                PLATFORM_FIREWALL_ZONE=$active_zones
            elif ((zone_count == 0)) && [[ -n $default_zone ]]; then
                PLATFORM_FIREWALL_ZONE=$default_zone
            else
                PLATFORM_FIREWALL=ambiguous
                PLATFORM_FIREWALL_ZONE=''
                _platform_log_error "firewalld 存在多个活动 zone 且默认 zone 不在其中，拒绝自动选择。"
                return 2
            fi
        fi
    else
        PLATFORM_FIREWALL=none
        PLATFORM_FIREWALL_ZONE=''
    fi
    return 0
}

platform_firewall_rule_exists() {
    local port=${1:-}
    local protocol=${2:-tcp}
    platform_validate_port "$port" || return 2
    [[ $protocol == tcp || $protocol == udp ]] || return 2
    if [[ -z $PLATFORM_FIREWALL ]] && ! platform_detect_firewall; then
        return 2
    fi

    case $PLATFORM_FIREWALL in
        ufw)
            LC_ALL=C ufw status 2>/dev/null | awk -v rule="$((10#$port))/$protocol" \
                '$1 == rule { found = 1 } END { exit(found ? 0 : 1) }'
            ;;
        firewalld)
            firewall-cmd --zone="$PLATFORM_FIREWALL_ZONE" \
                --query-port="$((10#$port))/$protocol" >/dev/null 2>&1
            ;;
        none) return 1 ;;
        *) return 2 ;;
    esac
}

platform_firewall_allow() {
    local port=${1:-}
    local protocol=${2:-tcp}
    platform_validate_port "$port" || return 1
    if [[ $protocol != tcp && $protocol != udp ]]; then
        _platform_log_error "不支持的防火墙协议：$protocol。"
        return 1
    fi
    platform_require_root || return 1
    platform_detect_firewall || return 1
    PLATFORM_FIREWALL_RULE_CHANGED=0

    case $PLATFORM_FIREWALL in
        none)
            _platform_log_warn "未检测到已启用的 UFW/firewalld；未修改防火墙。"
            return 0
            ;;
        ufw)
            if platform_firewall_rule_exists "$port" "$protocol"; then
                return 0
            fi
            ufw allow "$((10#$port))/$protocol" || return 1
            PLATFORM_FIREWALL_RULE_CHANGED=1
            ;;
        firewalld)
            if ! firewall-cmd --permanent --zone="$PLATFORM_FIREWALL_ZONE" \
                --query-port="$((10#$port))/$protocol" \
                >/dev/null 2>&1; then
                firewall-cmd --permanent --zone="$PLATFORM_FIREWALL_ZONE" \
                    --add-port="$((10#$port))/$protocol" || return 1
                PLATFORM_FIREWALL_RULE_CHANGED=1
            fi
            if ! firewall-cmd --zone="$PLATFORM_FIREWALL_ZONE" \
                --query-port="$((10#$port))/$protocol" >/dev/null 2>&1; then
                firewall-cmd --zone="$PLATFORM_FIREWALL_ZONE" \
                    --add-port="$((10#$port))/$protocol" || return 1
                PLATFORM_FIREWALL_RULE_CHANGED=1
            fi
            ;;
        *) return 1 ;;
    esac
    return 0
}

platform_firewall_allow_tcp() {
    platform_firewall_allow "${1:-}" tcp
}

platform_firewall_revoke_tcp() {
    platform_firewall_revoke "${1:-}" tcp
}

platform_firewall_revoke() {
    local port=${1:-}
    local protocol=${2:-tcp}
    platform_validate_port "$port" || return 1
    if [[ $protocol != tcp && $protocol != udp ]]; then
        _platform_log_error "不支持的防火墙协议：$protocol。"
        return 1
    fi
    platform_require_root || return 1
    platform_detect_firewall || return 1
    PLATFORM_FIREWALL_RULE_CHANGED=0

    case $PLATFORM_FIREWALL in
        none)
            _platform_log_warn "防火墙未启用；没有删除任何规则。"
            ;;
        ufw)
            if platform_firewall_rule_exists "$port" "$protocol"; then
                ufw --force delete allow "$((10#$port))/$protocol" || return 1
                PLATFORM_FIREWALL_RULE_CHANGED=1
            fi
            ;;
        firewalld)
            if firewall-cmd --permanent --zone="$PLATFORM_FIREWALL_ZONE" \
                --query-port="$((10#$port))/$protocol" \
                >/dev/null 2>&1; then
                firewall-cmd --permanent --zone="$PLATFORM_FIREWALL_ZONE" \
                    --remove-port="$((10#$port))/$protocol" || return 1
                PLATFORM_FIREWALL_RULE_CHANGED=1
            fi
            if firewall-cmd --zone="$PLATFORM_FIREWALL_ZONE" \
                --query-port="$((10#$port))/$protocol" >/dev/null 2>&1; then
                firewall-cmd --zone="$PLATFORM_FIREWALL_ZONE" \
                    --remove-port="$((10#$port))/$protocol" || return 1
                PLATFORM_FIREWALL_RULE_CHANGED=1
            fi
            ;;
        *) return 1 ;;
    esac
    return 0
}

_platform_validate_service_name() {
    local service=${1:-}
    if [[ -z $service || $service == -* || $service == */* || \
        $service =~ [^A-Za-z0-9_.@:-] ]]; then
        _platform_log_error "非法的服务名称：${service:-empty}。"
        return 1
    fi
    return 0
}

_platform_openrc_service_name() {
    local service=$1
    printf '%s\n' "${service%.service}"
}

platform_service_exists() {
    local service=${1:-}
    local load_state
    _platform_validate_service_name "$service" || return 2
    [[ -n $PLATFORM_INIT ]] || platform_detect_init || return 2

    case $PLATFORM_INIT in
        systemd)
            if ! load_state=$(systemctl show --property=LoadState --value \
                "$service" 2>/dev/null); then
                return 2
            fi
            case $load_state in
                not-found) return 1 ;;
                '') return 2 ;;
                *) return 0 ;;
            esac
            ;;
        openrc)
            service=$(_platform_openrc_service_name "$service")
            [[ -d /etc/init.d && -r /etc/init.d && -x /etc/init.d ]] || return 2
            [[ -x /etc/init.d/$service ]]
            ;;
        *) return 2 ;;
    esac
}

platform_service_start() {
    local service=${1:-}
    _platform_validate_service_name "$service" || return 1
    platform_require_root || return 1
    [[ -n $PLATFORM_INIT ]] || platform_detect_init || return 1
    case $PLATFORM_INIT in
        systemd) systemctl start "$service" ;;
        openrc) rc-service "$(_platform_openrc_service_name "$service")" start ;;
        *) return 1 ;;
    esac
}

platform_service_stop() {
    local service=${1:-}
    _platform_validate_service_name "$service" || return 1
    platform_require_root || return 1
    [[ -n $PLATFORM_INIT ]] || platform_detect_init || return 1
    case $PLATFORM_INIT in
        systemd) systemctl stop "$service" ;;
        openrc) rc-service "$(_platform_openrc_service_name "$service")" stop ;;
        *) return 1 ;;
    esac
}

platform_service_restart() {
    local service=${1:-}
    _platform_validate_service_name "$service" || return 1
    platform_require_root || return 1
    [[ -n $PLATFORM_INIT ]] || platform_detect_init || return 1
    case $PLATFORM_INIT in
        systemd) systemctl restart "$service" ;;
        openrc) rc-service "$(_platform_openrc_service_name "$service")" restart ;;
        *) return 1 ;;
    esac
}

platform_service_status() {
    local service=${1:-}
    _platform_validate_service_name "$service" || return 1
    [[ -n $PLATFORM_INIT ]] || platform_detect_init || return 1
    case $PLATFORM_INIT in
        systemd) systemctl status --no-pager "$service" ;;
        openrc) rc-service "$(_platform_openrc_service_name "$service")" status ;;
        *) return 1 ;;
    esac
}

platform_service_is_active() {
    local service=${1:-}
    _platform_validate_service_name "$service" || return 2
    [[ -n $PLATFORM_INIT ]] || platform_detect_init || return 2
    case $PLATFORM_INIT in
        systemd) systemctl is-active --quiet "$service" ;;
        openrc) rc-service "$(_platform_openrc_service_name "$service")" status >/dev/null 2>&1 ;;
        *) return 2 ;;
    esac
}

# Return 0 only for the service manager's explicit "stopped" status. Active is
# 1; malformed input, missing service-manager state, and every ambiguous status
# are 2 so callers can fail closed.
platform_service_is_inactive() {
    local status
    if platform_service_is_active "$@"; then
        return 1
    else
        status=$?
    fi
    [[ $status -eq 3 ]] && return 0
    return 2
}

platform_service_enable() {
    local service=${1:-}
    _platform_validate_service_name "$service" || return 1
    platform_require_root || return 1
    [[ -n $PLATFORM_INIT ]] || platform_detect_init || return 1
    case $PLATFORM_INIT in
        systemd) systemctl enable "$service" ;;
        openrc)
            service=$(_platform_openrc_service_name "$service")
            rc-update show default 2>/dev/null | awk '{ print $1 }' | grep -Fxq "$service" || \
                rc-update add "$service" default
            ;;
        *) return 1 ;;
    esac
}

platform_service_disable() {
    local service=${1:-}
    _platform_validate_service_name "$service" || return 1
    platform_require_root || return 1
    [[ -n $PLATFORM_INIT ]] || platform_detect_init || return 1
    case $PLATFORM_INIT in
        systemd) systemctl disable "$service" ;;
        openrc)
            service=$(_platform_openrc_service_name "$service")
            if rc-update show default 2>/dev/null | awk '{ print $1 }' | grep -Fxq "$service"; then
                rc-update del "$service" default
            fi
            ;;
        *) return 1 ;;
    esac
}
