#!/bin/sh
# shellcheck shell=sh

# This file must stay POSIX-compatible: it is the entry point for systems that
# do not have Bash yet (notably minimal Alpine installations).
set -eu
umask 077
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

DEFAULT_REPOSITORY="smallmain/one-key-proxy"
DEFAULT_REF="main"
REPOSITORY=${ONE_KEY_PROXY_REPO:-$DEFAULT_REPOSITORY}
REF=${ONE_KEY_PROXY_REF:-$DEFAULT_REF}
TEMP_DIR=""

bootstrap_log() {
    printf '%s\n' "[one-key-proxy] $*" >&2
}

bootstrap_fail() {
    printf '%s\n' "[one-key-proxy] Error: $*" >&2
    exit 1
}

bootstrap_cleanup() {
    case ${TEMP_DIR:-} in
        /tmp/one-key-proxy.bootstrap.*)
            if [ -d "$TEMP_DIR" ]; then
                rm -rf -- "$TEMP_DIR"
            fi
            ;;
    esac
}

bootstrap_secure_temp_dir() {
    [ -d /tmp ] && [ ! -L /tmp ] || \
        bootstrap_fail "/tmp is not a real directory."
    temp_parent_owner=$(find /tmp -xdev -prune -user 0 -print 2>/dev/null) || \
        bootstrap_fail "Could not inspect /tmp ownership."
    [ "$temp_parent_owner" = /tmp ] || bootstrap_fail "/tmp is not owned by root."
    if find /tmp -xdev -prune \( -perm -020 -o -perm -002 \) \
        ! -perm -1000 -print | grep -q .; then
        bootstrap_fail "/tmp is writable by other users without the sticky bit."
    fi

    case ${TEMP_DIR:-} in
        /tmp/one-key-proxy.bootstrap.*)
            temp_suffix=${TEMP_DIR#/tmp/one-key-proxy.bootstrap.}
            case $temp_suffix in
                ''|*/*|.|..) bootstrap_fail "The bootstrap temporary directory is unsafe." ;;
            esac
            ;;
        *) bootstrap_fail "The bootstrap temporary directory is unsafe." ;;
    esac

    [ -d "$TEMP_DIR" ] && [ ! -L "$TEMP_DIR" ] || \
        bootstrap_fail "The bootstrap temporary directory is not a real directory."
    chown 0:0 "$TEMP_DIR" || \
        bootstrap_fail "Could not secure temporary directory ownership."
    chmod 0700 "$TEMP_DIR" || \
        bootstrap_fail "Could not secure temporary directory permissions."
}

bootstrap_verify_secure_tree() {
    secure_tree=$1
    [ -d "$secure_tree" ] && [ ! -L "$secure_tree" ] || \
        bootstrap_fail "The downloaded project directory is unsafe."
    find "$secure_tree" -xdev -print >/dev/null 2>&1 || \
        bootstrap_fail "Could not inspect the downloaded project tree."

    if find "$secure_tree" -xdev -type l -print | grep -q .; then
        bootstrap_fail "The downloaded project tree contains a symbolic link."
    fi
    if find "$secure_tree" -xdev \( ! -user 0 -o ! -group 0 \) -print | grep -q .; then
        bootstrap_fail "The downloaded project tree is not owned by root."
    fi
    if find "$secure_tree" -xdev \( -perm -020 -o -perm -002 \) -print | grep -q .; then
        bootstrap_fail "The downloaded project tree is writable by group or others."
    fi
}

trap bootstrap_cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

bootstrap_validate_source() {
    repository_owner=${REPOSITORY%%/*}
    repository_name=${REPOSITORY#*/}
    case $REPOSITORY in
        */*) ;;
        *) bootstrap_fail "ONE_KEY_PROXY_REPO must use the owner/repository form." ;;
    esac

    case $REPOSITORY in
        *[!A-Za-z0-9._/-]*|*//*|/*|*/|*../*|*/..)
            bootstrap_fail "ONE_KEY_PROXY_REPO contains unsupported characters."
            ;;
    esac
    case $repository_owner:$repository_name in
        :*|*:|*:*/*)
            bootstrap_fail "ONE_KEY_PROXY_REPO must contain exactly one slash."
            ;;
    esac

    case $REF in
        ''|*[!A-Za-z0-9._-]*|.*|*..*)
            bootstrap_fail "ONE_KEY_PROXY_REF contains unsupported characters."
            ;;
    esac
}

bootstrap_require_root() {
    user_id=$(id -u 2>/dev/null || printf 'unknown')
    [ "$user_id" = "0" ] || bootstrap_fail "Run this installer as root."
}

bootstrap_require_tty() {
    (: </dev/tty) 2>/dev/null || \
        bootstrap_fail "An interactive terminal (/dev/tty) is required."
    (: >/dev/tty) 2>/dev/null || \
        bootstrap_fail "An interactive terminal (/dev/tty) is required."
}

bootstrap_require_linux_arch() {
    [ "$(uname -s 2>/dev/null || true)" = "Linux" ] || \
        bootstrap_fail "Only Linux is supported."

    machine_arch=$(uname -m 2>/dev/null || true)
    case $machine_arch in
        x86_64|amd64|aarch64|arm64) ;;
        *)
            bootstrap_fail "Unsupported CPU architecture: ${machine_arch:-unknown}. Only amd64 and arm64 are supported."
            ;;
    esac
}

bootstrap_require_service_manager() {
    pid_one=""
    if [ -r /proc/1/comm ]; then
        IFS= read -r pid_one </proc/1/comm || true
    fi

    case $pid_one in
        systemd)
            [ -d /run/systemd/system ] || \
                bootstrap_fail "systemd is not running as the system service manager."
            ;;
        init|openrc|openrc-init)
            [ -d /run/openrc ] || \
                bootstrap_fail "OpenRC is not running as the system service manager."
            ;;
        *)
            bootstrap_fail "PID 1 (${pid_one:-unknown}) is not a supported systemd/OpenRC init."
            ;;
    esac
}

bootstrap_detect_family() {
    [ -r /etc/os-release ] || bootstrap_fail "/etc/os-release is missing."

    # The variables are supplied by the operating system, not by the network.
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id=$(printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')
    os_like=$(printf '%s' "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')

    case $os_id in
        debian|ubuntu) OS_FAMILY=debian ;;
        alpine) OS_FAMILY=alpine ;;
        rhel|centos|rocky|almalinux|ol|fedora|amzn) OS_FAMILY=rhel ;;
        arch|manjaro) OS_FAMILY=arch ;;
        opensuse*|sles) OS_FAMILY=suse ;;
        *)
            case " $os_like " in
                *" debian "*|*" ubuntu "*) OS_FAMILY=debian ;;
                *" rhel "*|*" fedora "*|*" centos "*) OS_FAMILY=rhel ;;
                *" arch "*) OS_FAMILY=arch ;;
                *" suse "*|*" opensuse "*) OS_FAMILY=suse ;;
                *) bootstrap_fail "Unsupported Linux distribution: ${os_id:-unknown}." ;;
            esac
            ;;
    esac
}

bootstrap_has_ca_bundle() {
    [ -s /etc/ssl/certs/ca-certificates.crt ] || \
        [ -s /etc/pki/tls/certs/ca-bundle.crt ] || \
        [ -s /etc/ssl/ca-bundle.pem ]
}

bootstrap_prerequisites_ready() {
    command -v bash >/dev/null 2>&1 || return 1
    command -v tar >/dev/null 2>&1 || return 1
    command -v gzip >/dev/null 2>&1 || return 1
    command -v curl >/dev/null 2>&1 || return 1
    bootstrap_has_ca_bundle || return 1
}

bootstrap_install_prerequisites() {
    if bootstrap_prerequisites_ready; then
        return 0
    fi

    bootstrap_log "Installing the minimal download prerequisites..."
    case $OS_FAMILY in
        alpine)
            command -v apk >/dev/null 2>&1 || bootstrap_fail "apk is unavailable."
            apk add --no-cache bash ca-certificates curl tar gzip
            ;;
        debian)
            command -v apt-get >/dev/null 2>&1 || bootstrap_fail "apt-get is unavailable."
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                bash ca-certificates curl tar gzip
            ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                rhel_installer=dnf
            elif command -v yum >/dev/null 2>&1; then
                rhel_installer=yum
            else
                bootstrap_fail "Neither dnf nor yum is available."
            fi
            "$rhel_installer" -y install bash ca-certificates curl tar gzip
            ;;
        arch)
            command -v pacman >/dev/null 2>&1 || bootstrap_fail "pacman is unavailable."
            bootstrap_log "Warning: Arch dependency installation performs a full pacman -Syu system upgrade."
            pacman -Syu --noconfirm --needed bash ca-certificates curl tar gzip
            ;;
        suse)
            command -v zypper >/dev/null 2>&1 || bootstrap_fail "zypper is unavailable."
            zypper --non-interactive install --no-recommends \
                bash ca-certificates curl tar gzip
            ;;
        *) bootstrap_fail "Internal error: unsupported package family." ;;
    esac

    bootstrap_prerequisites_ready || \
        bootstrap_fail "The required download tools could not be installed."
}

bootstrap_fetch() {
    fetch_url=$1
    fetch_destination=$2

    command -v curl >/dev/null 2>&1 || bootstrap_fail "curl is unavailable."
    env -i PATH="$PATH" HOME=/root \
        curl --disable --fail --location --silent --show-error \
        --connect-timeout 15 --retry 3 \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output "$fetch_destination" "$fetch_url"
}

bootstrap_resolve_commit() {
    commit_document=$TEMP_DIR/commit.json
    commit_url="https://api.github.com/repos/$REPOSITORY/commits/$REF"
    bootstrap_fetch "$commit_url" "$commit_document"

    resolved_commit=$(
        sed -n 's/^[[:space:]]*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f][0-9a-f]*\)".*/\1/p' \
            "$commit_document" | sed -n '1p'
    )

    case $resolved_commit in
        ''|*[!0-9a-f]*) bootstrap_fail "GitHub returned an invalid commit identifier." ;;
    esac
    [ "${#resolved_commit}" -eq 40 ] || \
        bootstrap_fail "GitHub returned an invalid commit identifier."

    RESOLVED_COMMIT=$resolved_commit
}

bootstrap_download_project() {
    bootstrap_secure_temp_dir
    archive_path=$TEMP_DIR/project.tar.gz
    archive_listing=$TEMP_DIR/project.list
    archive_verbose=$TEMP_DIR/project.verbose
    archive_url="https://codeload.github.com/$REPOSITORY/tar.gz/$RESOLVED_COMMIT"
    project_name=${REPOSITORY#*/}
    PROJECT_DIR=$TEMP_DIR/$project_name-$RESOLVED_COMMIT

    bootstrap_log "Downloading $REPOSITORY at commit $RESOLVED_COMMIT..."
    bootstrap_fetch "$archive_url" "$archive_path"
    tar -tzf "$archive_path" >"$archive_listing" || \
        bootstrap_fail "The downloaded project archive is invalid."
    while IFS= read -r archive_member; do
        case $archive_member in
            "$project_name-$RESOLVED_COMMIT"|"$project_name-$RESOLVED_COMMIT"/*) ;;
            *) bootstrap_fail "The project archive contains an unsafe path." ;;
        esac
        case /$archive_member/ in
            */../*|*/./*) bootstrap_fail "The project archive contains path traversal." ;;
        esac
    done <"$archive_listing"
    tar -tvzf "$archive_path" >"$archive_verbose" || \
        bootstrap_fail "The downloaded project archive cannot be inspected."
    if awk 'substr($1, 1, 1) != "d" && substr($1, 1, 1) != "-" { bad=1 } END { exit bad ? 0 : 1 }' \
        "$archive_verbose"; then
        bootstrap_fail "The project archive contains links or special files."
    fi
    [ ! -e "$PROJECT_DIR" ] && [ ! -L "$PROJECT_DIR" ] || \
        bootstrap_fail "The project extraction directory already exists."
    tar --no-same-owner -xzf "$archive_path" -C "$TEMP_DIR"

    [ -d "$PROJECT_DIR" ] && [ ! -L "$PROJECT_DIR" ] || \
        bootstrap_fail "The downloaded project directory is unsafe."
    [ -f "$PROJECT_DIR/install.sh" ] && [ ! -L "$PROJECT_DIR/install.sh" ] || \
        bootstrap_fail "The downloaded project does not contain install.sh."
    chown -R 0:0 "$PROJECT_DIR" || bootstrap_fail "Could not secure project ownership."
    chmod -R go-w "$PROJECT_DIR" || bootstrap_fail "Could not secure project permissions."
    chmod 0755 "$PROJECT_DIR/install.sh" || bootstrap_fail "Could not make install.sh executable."
    bootstrap_verify_secure_tree "$TEMP_DIR"
}

bootstrap_run_installer() {
    case ${PROJECT_DIR:-} in
        "$TEMP_DIR"/*) ;;
        *) bootstrap_fail "The project directory is outside the secured temporary directory." ;;
    esac
    bootstrap_verify_secure_tree "$TEMP_DIR"
    bootstrap_log "Starting the interactive installer..."
    installer_term=${TERM:-dumb}
    case $installer_term in
        ''|*[!A-Za-z0-9._+-]*) installer_term=dumb ;;
    esac
    env -i PATH="$PATH" HOME=/root USER=root LOGNAME=root TERM="$installer_term" \
        ONE_KEY_PROXY_SOURCE_COMMIT="$RESOLVED_COMMIT" \
        ONE_KEY_PROXY_SOURCE_REPO="$REPOSITORY" \
        bash "$PROJECT_DIR/install.sh" </dev/tty >/dev/tty 2>&1
}

main() {
    bootstrap_validate_source
    bootstrap_require_root
    bootstrap_require_tty
    bootstrap_require_linux_arch
    bootstrap_detect_family
    bootstrap_require_service_manager
    bootstrap_install_prerequisites

    TEMP_DIR=$(mktemp -d /tmp/one-key-proxy.bootstrap.XXXXXX) || \
        bootstrap_fail "Could not create a temporary directory."
    bootstrap_secure_temp_dir
    bootstrap_resolve_commit
    bootstrap_download_project
    bootstrap_run_installer
}

main "$@"
