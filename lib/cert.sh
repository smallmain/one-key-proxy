#!/usr/bin/env bash

# TLS certificate support for one-key-proxy. This file is intended to be sourced.

if ! declare -F log_info >/dev/null 2>&1; then
    log_info() { printf '[INFO] %s\n' "$*" >&2; }
fi
if ! declare -F log_warn >/dev/null 2>&1; then
    log_warn() { printf '[WARN] %s\n' "$*" >&2; }
fi
if ! declare -F log_error >/dev/null 2>&1; then
    log_error() { printf '[ERROR] %s\n' "$*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
    die() { log_error "$*"; return 1; }
fi

if [[ ${OKP_PRODUCTION_MODE:-false} == true ]]; then
    CONFIG_DIR=/etc/one-key-proxy
    CERT_DIR=/etc/one-key-proxy/certs
    OKP_SECRET_DIR=/etc/one-key-proxy/secrets
    OKP_ALIDNS_CREDENTIALS_FILE=/etc/one-key-proxy/secrets/alidns.credentials
    OKP_ACME_HOME=/etc/one-key-proxy/acme
    OKP_ACME_CONFIG_HOME=/etc/one-key-proxy/acme/config
    OKP_ACME_CERT_HOME=/etc/one-key-proxy/acme/certificates
    OKP_ACME_BIN=/etc/one-key-proxy/acme/acme.sh
    OKP_ACME_RENEW_BIN=/usr/local/bin/one-key-proxy-acme-renew
    OKP_XUI_RELOAD_HOOK=/usr/local/bin/one-key-proxy-reload-x-ui
    OKP_ACME_SYSTEMD_SERVICE=/etc/systemd/system/one-key-proxy-acme.service
    OKP_ACME_SYSTEMD_TIMER=/etc/systemd/system/one-key-proxy-acme.timer
    OKP_ACME_OPENRC_DAILY=/etc/periodic/daily/one-key-proxy-acme
    OKP_OPERATION_LOCK_FILE=/run/one-key-proxy/operation.lock
else
    CONFIG_DIR="${CONFIG_DIR:-/etc/one-key-proxy}"
    CERT_DIR="${CERT_DIR:-$CONFIG_DIR/certs}"
    OKP_SECRET_DIR="${OKP_SECRET_DIR:-$CONFIG_DIR/secrets}"
    OKP_ALIDNS_CREDENTIALS_FILE="${OKP_ALIDNS_CREDENTIALS_FILE:-$OKP_SECRET_DIR/alidns.credentials}"
    OKP_ACME_HOME="${OKP_ACME_HOME:-$CONFIG_DIR/acme}"
    OKP_ACME_CONFIG_HOME="${OKP_ACME_CONFIG_HOME:-$OKP_ACME_HOME/config}"
    OKP_ACME_CERT_HOME="${OKP_ACME_CERT_HOME:-$OKP_ACME_HOME/certificates}"
    OKP_ACME_BIN="${OKP_ACME_BIN:-$OKP_ACME_HOME/acme.sh}"
    OKP_ACME_RENEW_BIN="${OKP_ACME_RENEW_BIN:-/usr/local/bin/one-key-proxy-acme-renew}"
    OKP_XUI_RELOAD_HOOK="${OKP_XUI_RELOAD_HOOK:-/usr/local/bin/one-key-proxy-reload-x-ui}"
    OKP_ACME_SYSTEMD_SERVICE="${OKP_ACME_SYSTEMD_SERVICE:-/etc/systemd/system/one-key-proxy-acme.service}"
    OKP_ACME_SYSTEMD_TIMER="${OKP_ACME_SYSTEMD_TIMER:-/etc/systemd/system/one-key-proxy-acme.timer}"
    OKP_ACME_OPENRC_DAILY="${OKP_ACME_OPENRC_DAILY:-/etc/periodic/daily/one-key-proxy-acme}"
    OKP_OPERATION_LOCK_FILE="${OKP_OPERATION_LOCK_FILE:-/run/one-key-proxy/operation.lock}"
fi
_OKP_CERT_CLEAN_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
_OKP_CERT_CLEAN_HOME='/root'

_okp_cert_require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        die "证书配置必须以 root 身份执行"
        return 1
    fi
}

_okp_cert_require_command() {
    local command_name=$1
    if ! command -v "$command_name" >/dev/null 2>&1; then
        die "缺少必需命令: $command_name"
        return 1
    fi
}

_okp_cert_file_attribute() {
    local path=$1 linux_format=$2 bsd_format=$3
    stat -c "$linux_format" -- "$path" 2>/dev/null || \
        stat -f "$bsd_format" "$path" 2>/dev/null
}

_okp_cert_secure_directory() {
    local path=$1 mode=${2:-0700} owner actual_mode
    if [[ -L $path || ( -e $path && ! -d $path ) ]]; then
        die "拒绝使用不安全的证书目录: $path"
        return 1
    fi
    install -d -m "$mode" -- "$path" || return 1
    [[ -d $path && ! -L $path ]] || return 1
    chmod "$mode" "$path" || return 1
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        chown 0:0 "$path" || return 1
    fi
    owner=$(_okp_cert_file_attribute "$path" '%u' '%u') || return 1
    actual_mode=$(_okp_cert_file_attribute "$path" '%a' '%Lp') || return 1
    [[ $actual_mode == "${mode#0}" ]] || return 1
    [[ ${OKP_PRODUCTION_MODE:-false} != true || $owner == 0 ]]
}

_okp_cert_sensitive_file_is_secure() {
    local path=$1 owner mode links
    [[ -f $path && ! -L $path ]] || return 1
    owner=$(_okp_cert_file_attribute "$path" '%u' '%u') || return 1
    mode=$(_okp_cert_file_attribute "$path" '%a' '%Lp') || return 1
    links=$(_okp_cert_file_attribute "$path" '%h' '%l') || return 1
    [[ $mode == 600 && $links == 1 ]] || return 1
    [[ ${OKP_PRODUCTION_MODE:-false} != true || $owner == 0 ]]
}

_okp_cert_executable_is_secure() {
    local path=$1 owner mode links
    [[ -f $path && ! -L $path && -x $path ]] || return 1
    owner=$(_okp_cert_file_attribute "$path" '%u' '%u') || return 1
    mode=$(_okp_cert_file_attribute "$path" '%a' '%Lp') || return 1
    links=$(_okp_cert_file_attribute "$path" '%h' '%l') || return 1
    [[ $mode =~ ^[0-7]{3,4}$ && $links == 1 ]] || return 1
    (( ((8#$mode) & 0022) == 0 )) || return 1
    [[ ${OKP_PRODUCTION_MODE:-false} != true || $owner == 0 ]]
}

_okp_cert_validate_ipv4() {
    local address=$1 octet
    local -a octets
    IFS=. read -r -a octets <<<"$address"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

_okp_cert_normalize_domain() {
    local domain=${1%.}
    printf '%s' "$domain" | tr '[:upper:]' '[:lower:]'
    printf '\n'
}

_okp_cert_validate_domain() {
    local domain=$1 label
    local -a labels
    if (( ${#domain} < 3 || ${#domain} > 253 )) || [[ $domain != *.* ]]; then
        return 1
    fi
    IFS=. read -r -a labels <<<"$domain"
    for label in "${labels[@]}"; do
        if (( ${#label} < 1 || ${#label} > 63 )) || \
            [[ ! $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
            return 1
        fi
    done
}

_okp_cert_set_state() {
    local mode=$1 cert_file=$2 key_file=$3 subject=$4
    if declare -F state_set_many >/dev/null 2>&1; then
        state_set_many TLS_MODE "$mode" TLS_CERT_FILE "$cert_file" \
            TLS_KEY_FILE "$key_file" TLS_SUBJECT "$subject"
    elif declare -F state_set >/dev/null 2>&1; then
        state_set TLS_MODE "$mode" && \
            state_set TLS_CERT_FILE "$cert_file" && \
            state_set TLS_KEY_FILE "$key_file" && \
            state_set TLS_SUBJECT "$subject"
    fi
}

_okp_cert_verify_ip_san() {
    local cert_file=$1 address=$2
    openssl x509 -in "$cert_file" -noout -checkend 86400 >/dev/null 2>&1 &&
        openssl x509 -in "$cert_file" -noout -text 2>/dev/null |
            grep -Fq "IP Address:$address"
}

_okp_cert_verify_dns_san() {
    local cert_file=$1 domain=$2
    openssl x509 -in "$cert_file" -noout -checkend 86400 >/dev/null 2>&1 &&
        openssl x509 -in "$cert_file" -noout -text 2>/dev/null |
            grep -Fq "DNS:$domain"
}

# Creates a ten-year RSA-2048 self-signed certificate with an IPv4 SAN.
# A temporary OpenSSL config is used instead of -addext for old OpenSSL builds.
# Usage: okp_cert_create_self_signed_ip IPV4 [CERT_FILE] [KEY_FILE]
okp_cert_create_self_signed_ip() {
    local address=$1
    local cert_file=${2:-$CERT_DIR/server.crt}
    local key_file=${3:-$CERT_DIR/server.key}
    local openssl_config temp_cert temp_key

    _okp_cert_require_root || return 1
    _okp_cert_require_command openssl || return 1
    if ! _okp_cert_validate_ipv4 "$address"; then
        die "NAT 自签名证书需要有效的公网 IPv4 地址"
        return 1
    fi

    umask 077
    _okp_cert_secure_directory "$CONFIG_DIR" 0700 || return 1
    _okp_cert_secure_directory "$CERT_DIR" 0700 || return 1
    if [[ -L $cert_file || -L $key_file || ( -e $cert_file && ! -f $cert_file ) || \
        ( -e $key_file && ! -f $key_file ) ]]; then
        die "证书目标路径不是安全的普通文件"
        return 1
    fi
    openssl_config=$(mktemp "${TMPDIR:-/tmp}/one-key-proxy-openssl.XXXXXX") || return 1
    temp_cert=$(mktemp "$CERT_DIR/.server.crt.XXXXXX") || {
        rm -f -- "$openssl_config"
        return 1
    }
    temp_key=$(mktemp "$CERT_DIR/.server.key.XXXXXX") || {
        rm -f -- "$openssl_config" "$temp_cert"
        return 1
    }

    if ! printf '%s\n' \
        '[req]' \
        'prompt = no' \
        'distinguished_name = subject' \
        'x509_extensions = extensions' \
        '[subject]' \
        "CN = $address" \
        '[extensions]' \
        'subjectAltName = @subject_alt_name' \
        'basicConstraints = critical, CA:false' \
        'keyUsage = critical, digitalSignature, keyEncipherment' \
        'extendedKeyUsage = serverAuth' \
        '[subject_alt_name]' \
        "IP.1 = $address" >"$openssl_config"; then
        rm -f -- "$openssl_config" "$temp_cert" "$temp_key"
        return 1
    fi

    log_info "正在生成 10 年有效期的 RSA-2048 IP 自签名证书"
    if ! openssl req -new -x509 -nodes -sha256 -newkey rsa:2048 \
        -days 3650 -config "$openssl_config" \
        -keyout "$temp_key" -out "$temp_cert" >/dev/null 2>&1; then
        rm -f -- "$openssl_config" "$temp_cert" "$temp_key"
        die "自签名证书生成失败"
        return 1
    fi
    rm -f -- "$openssl_config"

    if ! _okp_cert_verify_ip_san "$temp_cert" "$address"; then
        rm -f -- "$temp_cert" "$temp_key"
        die "自签名证书 SAN 自检失败"
        return 1
    fi
    chmod 0600 "$temp_key"
    chmod 0644 "$temp_cert"
    mv -f -- "$temp_key" "$key_file"
    mv -f -- "$temp_cert" "$cert_file"
    _okp_cert_set_state SELF_SIGNED "$cert_file" "$key_file" "$address"
    log_info "IP 自签名证书已生成"
}

# Installs a hook that works with the official x-ui service on systemd/OpenRC.
okp_cert_install_xui_reload_hook() {
    local temp_file
    _okp_cert_require_root || return 1
    if ! _okp_cert_validate_safe_path "$OKP_XUI_RELOAD_HOOK"; then
        die "x-ui reload hook 路径无效"
        return 1
    fi
    install -d -m 0755 "$(dirname "$OKP_XUI_RELOAD_HOOK")"
    umask 077
    temp_file=$(mktemp "${TMPDIR:-/tmp}/one-key-proxy-reload.XXXXXX") || return 1
    if ! printf '%s\n' \
        '#!/bin/sh' \
        'set -eu' \
        'if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then' \
        '    load_state=$(systemctl show -p LoadState x-ui.service 2>/dev/null | sed -n "s/^LoadState=//p" || true)' \
        '    if [ -z "$load_state" ] || [ "$load_state" = "not-found" ]; then' \
        '        [ -e /etc/systemd/system/x-ui.service ] || [ -e /usr/lib/systemd/system/x-ui.service ] || [ -e /lib/systemd/system/x-ui.service ] || [ -e /etc/init.d/x-ui ] || exit 0' \
        '    fi' \
        '    exec systemctl restart x-ui.service' \
        'fi' \
        'if command -v rc-service >/dev/null 2>&1; then' \
        '    [ -x /etc/init.d/x-ui ] || exit 0' \
        '    exec rc-service x-ui restart' \
        'fi' \
        'if command -v service >/dev/null 2>&1; then' \
        '    [ -x /etc/init.d/x-ui ] || exit 0' \
        '    exec service x-ui restart' \
        'fi' \
        'exit 0' >"$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
    chmod 0755 "$temp_file"
    mv -f -- "$temp_file" "$OKP_XUI_RELOAD_HOOK"
}

okp_cert_reload_xui() {
    if [[ ! -x $OKP_XUI_RELOAD_HOOK ]]; then
        okp_cert_install_xui_reload_hook || return 1
    fi
    "$OKP_XUI_RELOAD_HOOK"
}

_okp_cert_download() {
    local url=$1 destination=$2
    _okp_cert_require_command curl || return 1
    curl --disable --noproxy '*' --fail --location --silent --show-error --retry 3 \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 15 --output "$destination" "$url"
}

_okp_cert_resolve_latest_acme_release() {
    local output_tag_name=$1 output_commit_name=$2 temp_dir=$3
    local release_json ref_json object_json commit_json
    local resolved_tag object_type object_sha depth=0

    release_json="$temp_dir/acme-release.json"
    ref_json="$temp_dir/acme-tag-ref.json"
    object_json="$temp_dir/acme-tag-object.json"
    commit_json="$temp_dir/acme-commit.json"

    if ! _okp_cert_download \
        https://api.github.com/repos/acmesh-official/acme.sh/releases/latest \
        "$release_json"; then
        die "acme.sh Release 元数据下载失败"
        return 1
    fi
    if ! jq -e '.draft == false and .prerelease == false and
        (.tag_name | type == "string")' "$release_json" >/dev/null 2>&1; then
        die "acme.sh latest 不是可验证的稳定 Release"
        return 1
    fi
    resolved_tag=$(jq -r '.tag_name' "$release_json")
    if [[ ! $resolved_tag =~ ^v?[0-9][0-9A-Za-z._-]*$ ]]; then
        die "acme.sh Release tag 格式无效"
        return 1
    fi

    if ! _okp_cert_download \
        "https://api.github.com/repos/acmesh-official/acme.sh/git/ref/tags/$resolved_tag" \
        "$ref_json"; then
        die "无法解析 acme.sh Release tag"
        return 1
    fi
    if [[ $(jq -r '.ref // empty' "$ref_json") != "refs/tags/$resolved_tag" ]]; then
        die "acme.sh tag ref 校验失败"
        return 1
    fi
    object_type=$(jq -r '.object.type // empty' "$ref_json")
    object_sha=$(jq -r '.object.sha // empty' "$ref_json")

    while [[ $object_type == tag && $depth -lt 5 ]]; do
        if [[ ! $object_sha =~ ^[0-9A-Fa-f]{40,64}$ ]] || \
            ! _okp_cert_download \
                "https://api.github.com/repos/acmesh-official/acme.sh/git/tags/$object_sha" \
                "$object_json"; then
            die "acme.sh annotated tag 解析失败"
            return 1
        fi
        object_type=$(jq -r '.object.type // empty' "$object_json")
        object_sha=$(jq -r '.object.sha // empty' "$object_json")
        depth=$((depth + 1))
    done
    if [[ $object_type != commit || ! $object_sha =~ ^[0-9A-Fa-f]{40,64}$ ]]; then
        die "acme.sh Release tag 未解析到 commit"
        return 1
    fi
    object_sha=$(printf '%s' "$object_sha" | tr '[:upper:]' '[:lower:]')
    if ! _okp_cert_download \
        "https://api.github.com/repos/acmesh-official/acme.sh/git/commits/$object_sha" \
        "$commit_json" || \
        [[ $(jq -r '.sha // empty' "$commit_json" 2>/dev/null) != "$object_sha" ]]; then
        die "acme.sh Release commit 校验失败"
        return 1
    fi

    printf -v "$output_tag_name" '%s' "$resolved_tag"
    printf -v "$output_commit_name" '%s' "$object_sha"
}

_okp_cert_load_alidns_credentials() {
    local access_key_id access_key_secret
    if [[ ! -e $OKP_ALIDNS_CREDENTIALS_FILE && ! -L $OKP_ALIDNS_CREDENTIALS_FILE ]]; then
        die "签发证书前必须先保存 AliDNS RAM 凭据"
        return 1
    fi
    if declare -F _okp_alidns_secure_regular_file >/dev/null 2>&1; then
        _okp_alidns_secure_regular_file "$OKP_ALIDNS_CREDENTIALS_FILE" 600 || {
            die "AliDNS 凭据文件安全校验失败"
            return 1
        }
    elif ! _okp_cert_sensitive_file_is_secure "$OKP_ALIDNS_CREDENTIALS_FILE"; then
        die "AliDNS 凭据文件必须是 root 所有、0600 且无硬链接的普通文件"
        return 1
    fi
    access_key_id=$(sed -n '1p' "$OKP_ALIDNS_CREDENTIALS_FILE")
    access_key_secret=$(sed -n '2p' "$OKP_ALIDNS_CREDENTIALS_FILE")
    if [[ -z $access_key_id || -z $access_key_secret ]]; then
        die "AliDNS 凭据文件无效"
        return 1
    fi
}

_okp_cert_run_acme_with_alidns() {
    _okp_cert_load_alidns_credentials || return 1
    env -i HOME="$_OKP_CERT_CLEAN_HOME" PATH="$_OKP_CERT_CLEAN_PATH" \
        sh -c '
            IFS= read -r Ali_Key || exit 1
            IFS= read -r Ali_Secret || exit 1
            [ -n "$Ali_Key" ] && [ -n "$Ali_Secret" ] || exit 1
            export Ali_Key Ali_Secret
            unset PWD OLDPWD SHLVL _
            exec "$@"
        ' sh "$@" <"$OKP_ALIDNS_CREDENTIALS_FILE"
}

# Installs acme.sh into a project-owned home. It deliberately disables the
# installer's cron entry because okp_acme_install_scheduler owns renewal.
okp_acme_install() {
    local account_email=${1:-}
    local temp_dir archive source_dir archive_prefix archive_bad_entry unsafe_entry path link_count
    local release_tag commit_sha
    local -a install_args

    _okp_cert_require_root || return 1
    _okp_cert_require_command openssl || return 1
    _okp_cert_require_command jq || return 1
    _okp_cert_require_command tar || return 1
    if _okp_cert_executable_is_secure "$OKP_ACME_BIN"; then
        log_info "acme.sh 已安装"
        return 0
    fi
    if [[ -e $OKP_ACME_BIN || -L $OKP_ACME_BIN ]]; then
        die "现有 acme.sh 可执行文件未通过安全校验"
        return 1
    fi

    umask 077
    _okp_cert_secure_directory "$CONFIG_DIR" 0700 || return 1
    _okp_cert_secure_directory "$OKP_ACME_HOME" 0700 || return 1
    _okp_cert_secure_directory "$OKP_ACME_CONFIG_HOME" 0700 || return 1
    _okp_cert_secure_directory "$OKP_ACME_CERT_HOME" 0700 || return 1
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/one-key-proxy-acme.XXXXXX") || return 1
    archive="$temp_dir/acme.sh.tar.gz"
    if ! _okp_cert_resolve_latest_acme_release release_tag commit_sha "$temp_dir"; then
        rm -rf -- "$temp_dir"
        return 1
    fi
    log_info "正在下载 acme.sh $release_tag ($commit_sha)"
    if ! _okp_cert_download \
        "https://github.com/acmesh-official/acme.sh/archive/$commit_sha.tar.gz" \
        "$archive"; then
        rm -rf -- "$temp_dir"
        die "acme.sh 下载失败"
        return 1
    fi
    archive_prefix="acme.sh-$commit_sha"
    archive_bad_entry=$(tar -tzf "$archive" | awk -v prefix="$archive_prefix/" \
        'index($0, prefix) != 1 { print; exit }')
    if [[ -n $archive_bad_entry ]]; then
        rm -rf -- "$temp_dir"
        die "acme.sh 安装包包含意外路径"
        return 1
    fi
    archive_bad_entry=$(tar -tvzf "$archive" | awk '
        substr($1, 1, 1) != "-" && substr($1, 1, 1) != "d" { print; exit }
    ') || {
        rm -rf -- "$temp_dir"
        die "acme.sh 安装包类型清单读取失败"
        return 1
    }
    if [[ -n $archive_bad_entry ]]; then
        rm -rf -- "$temp_dir"
        die "acme.sh 安装包包含链接或特殊文件"
        return 1
    fi
    if ! tar --no-same-owner -xzf "$archive" -C "$temp_dir"; then
        rm -rf -- "$temp_dir"
        die "acme.sh 安装包解压失败"
        return 1
    fi
    source_dir="$temp_dir/$archive_prefix"
    unsafe_entry=$(find "$source_dir" \( -type l -o ! -type d ! -type f \) -print -quit 2>/dev/null) || {
        rm -rf -- "$temp_dir"
        return 1
    }
    if [[ -z $source_dir || ! -d $source_dir || -L $source_dir || \
        ! -f $source_dir/acme.sh || -L $source_dir/acme.sh || -n $unsafe_entry ]]; then
        rm -rf -- "$temp_dir"
        die "acme.sh 安装包内容无效"
        return 1
    fi
    while IFS= read -r -d '' path; do
        link_count=$(_okp_cert_file_attribute "$path" '%h' '%l') || {
            rm -rf -- "$temp_dir"
            return 1
        }
        if [[ $link_count != 1 ]]; then
            rm -rf -- "$temp_dir"
            die "acme.sh 安装包包含硬链接"
            return 1
        fi
    done < <(find "$source_dir" -type f -print0)
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        chown -R 0:0 "$source_dir" || { rm -rf -- "$temp_dir"; return 1; }
    fi
    chmod -R go-w -- "$source_dir" || { rm -rf -- "$temp_dir"; return 1; }

    install_args=(
        --install
        --home "$OKP_ACME_HOME"
        --config-home "$OKP_ACME_CONFIG_HOME"
        --cert-home "$OKP_ACME_CERT_HOME"
        --nocron
        --noprofile
    )
    log_info "正在安装独立 acme.sh 环境"
    if [[ -n $account_email ]]; then
        install_args+=(--accountemail "$account_email")
    fi
    if ! env -i \
        PATH="$_OKP_CERT_CLEAN_PATH" HOME="$_OKP_CERT_CLEAN_HOME" LANG=C \
        sh "$source_dir/acme.sh" "${install_args[@]}" >/dev/null 2>&1; then
        rm -rf -- "$temp_dir"
        die "acme.sh 安装失败"
        return 1
    fi
    rm -rf -- "$temp_dir"
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        chown -R 0:0 "$OKP_ACME_HOME" || return 1
    fi
    find "$OKP_ACME_HOME" -type d -exec chmod 0700 {} + || return 1
    find "$OKP_ACME_HOME" -type f -exec chmod go-rwx {} + || return 1
    if ! _okp_cert_executable_is_secure "$OKP_ACME_BIN"; then
        die "acme.sh 安装后自检失败"
        return 1
    fi

    if ! env -i PATH="$_OKP_CERT_CLEAN_PATH" HOME="$_OKP_CERT_CLEAN_HOME" \
        "$OKP_ACME_BIN" --set-default-ca --server letsencrypt \
        --home "$OKP_ACME_HOME" --config-home "$OKP_ACME_CONFIG_HOME" \
        >/dev/null 2>&1; then
        die "无法将 Let's Encrypt 设为默认 CA"
        return 1
    fi
    if declare -F state_set_many >/dev/null 2>&1; then
        state_set_many ACME_RELEASE_TAG "$release_tag" ACME_COMMIT_SHA "$commit_sha" || return 1
    elif declare -F state_set >/dev/null 2>&1; then
        state_set ACME_RELEASE_TAG "$release_tag" || return 1
        state_set ACME_COMMIT_SHA "$commit_sha" || return 1
    fi
    log_info "acme.sh 安装完成"
}

_okp_cert_validate_safe_path() {
    local path=$1
    [[ $path == /* && $path =~ ^/[A-Za-z0-9_./-]+$ ]]
}

_okp_acme_write_renew_wrapper() {
    local temp_file _okp_path state_file

    state_file=${CONFIG_DIR}/state.env
    for _okp_path in "$OKP_ACME_BIN" "$OKP_ACME_HOME" "$OKP_ACME_CONFIG_HOME" "$OKP_ACME_CERT_HOME" "$OKP_ACME_RENEW_BIN" "$OKP_OPERATION_LOCK_FILE" "$OKP_ALIDNS_CREDENTIALS_FILE" "$state_file"; do
        if ! _okp_cert_validate_safe_path "$_okp_path"; then
            die "ACME 路径含不安全字符: $_okp_path"
            return 1
        fi
    done

    install -d -m 0755 "$(dirname "$OKP_ACME_RENEW_BIN")"
    temp_file=$(mktemp "${TMPDIR:-/tmp}/one-key-proxy-acme-renew.XXXXXX") || return 1
    if ! printf '%s\n' \
        '#!/bin/sh' \
        'set -eu' \
        'umask 077' \
        "PATH=$_OKP_CERT_CLEAN_PATH" \
        "HOME=$_OKP_CERT_CLEAN_HOME" \
        'export PATH HOME' \
        'command -v flock >/dev/null 2>&1 || { echo "缺少 flock，拒绝无锁续签" >&2; exit 1; }' \
        "lock_dir=${OKP_OPERATION_LOCK_FILE%/*}" \
        '[ ! -L "$lock_dir" ] && { [ ! -e "$lock_dir" ] || [ -d "$lock_dir" ]; } || { echo "续签锁目录不安全" >&2; exit 1; }' \
        'install -d -m 0700 "$lock_dir"' \
        'chown 0:0 "$lock_dir"' \
        'chmod 0700 "$lock_dir"' \
        '[ "$(stat -c %u "$lock_dir")" = 0 ] && [ "$(stat -c %a "$lock_dir")" = 700 ] || { echo "续签锁目录权限无效" >&2; exit 1; }' \
        "lock_file=$OKP_OPERATION_LOCK_FILE" \
        '[ ! -L "$lock_file" ] && { [ ! -e "$lock_file" ] || [ -f "$lock_file" ]; } || { echo "续签锁文件不安全" >&2; exit 1; }' \
        'exec 9>"$lock_file"' \
        'chmod 0600 "$lock_file"' \
        'chown 0:0 "$lock_file"' \
        '[ ! -L "$lock_file" ] && [ "$(stat -c %u "$lock_file")" = 0 ] && [ "$(stat -c %a "$lock_file")" = 600 ] && [ "$(stat -c %h "$lock_file")" = 1 ] || { echo "续签锁文件权限无效" >&2; exit 1; }' \
        'flock -x 9' \
        "state_file=$state_file" \
        '[ -f "$state_file" ] && [ ! -L "$state_file" ] && [ "$(stat -c %u "$state_file")" = 0 ] && [ "$(stat -c %a "$state_file")" = 600 ] && [ "$(stat -c %h "$state_file")" = 1 ] || { echo "续签状态文件不安全" >&2; exit 1; }' \
        'pending_status=0' \
        'grep -q "^ACME_PENDING_REMOVE_DOMAIN=" "$state_file" || pending_status=$?' \
        'case "$pending_status" in' \
        '    0) echo "检测到未完成的域名切换，拒绝自动续签" >&2; exit 1 ;;' \
        '    1) ;;' \
        '    *) echo "无法检查域名切换状态，拒绝自动续签" >&2; exit 1 ;;' \
        'esac' \
        "credential_file=$OKP_ALIDNS_CREDENTIALS_FILE" \
        '[ -f "$credential_file" ] && [ ! -L "$credential_file" ] && [ "$(stat -c %u "$credential_file")" = 0 ] && [ "$(stat -c %a "$credential_file")" = 600 ] && [ "$(stat -c %h "$credential_file")" = 1 ] || { echo "AliDNS 续签凭据不安全" >&2; exit 1; }' \
        "exec env -i HOME=$_OKP_CERT_CLEAN_HOME PATH=$_OKP_CERT_CLEAN_PATH sh -c '" \
        '    IFS= read -r Ali_Key || exit 1' \
        '    IFS= read -r Ali_Secret || exit 1' \
        '    [ -n "$Ali_Key" ] && [ -n "$Ali_Secret" ] || exit 1' \
        '    export Ali_Key Ali_Secret' \
        '    unset PWD OLDPWD SHLVL _' \
        '    exec "$@"' \
        "' sh $OKP_ACME_BIN --cron --home $OKP_ACME_HOME --config-home $OKP_ACME_CONFIG_HOME --cert-home $OKP_ACME_CERT_HOME <\"\$credential_file\"" \
        >"$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
    chmod 0755 "$temp_file"
    mv -f -- "$temp_file" "$OKP_ACME_RENEW_BIN"
}

# Installs a daily renewal job using a native systemd timer or Alpine/OpenRC
# periodic job. There is intentionally no A/AAAA DDNS task.
okp_acme_install_scheduler() {
    local temp_service temp_timer

    _okp_cert_require_root || return 1
    _okp_acme_write_renew_wrapper || return 1

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        temp_service=$(mktemp "${TMPDIR:-/tmp}/one-key-proxy-acme.service.XXXXXX") || return 1
        temp_timer=$(mktemp "${TMPDIR:-/tmp}/one-key-proxy-acme.timer.XXXXXX") || {
            rm -f -- "$temp_service"
            return 1
        }
        printf '%s\n' \
            '[Unit]' \
            'Description=Renew one-key-proxy TLS certificate' \
            'After=network-online.target' \
            'Wants=network-online.target' \
            '' \
            '[Service]' \
            'Type=oneshot' \
            "ExecStart=$OKP_ACME_RENEW_BIN" >"$temp_service"
        printf '%s\n' \
            '[Unit]' \
            'Description=Daily one-key-proxy TLS certificate renewal check' \
            '' \
            '[Timer]' \
            'OnCalendar=daily' \
            'RandomizedDelaySec=2h' \
            'Persistent=true' \
            '' \
            '[Install]' \
            'WantedBy=timers.target' >"$temp_timer"
        chmod 0644 "$temp_service" "$temp_timer"
        mv -f -- "$temp_service" "$OKP_ACME_SYSTEMD_SERVICE"
        mv -f -- "$temp_timer" "$OKP_ACME_SYSTEMD_TIMER"
        systemctl daemon-reload >/dev/null
        systemctl enable --now one-key-proxy-acme.timer >/dev/null
        log_info "已安装 systemd 证书续期定时器"
        return 0
    fi

    if command -v rc-service >/dev/null 2>&1; then
        if [[ ! -d /etc/periodic/daily ]]; then
            install -d -m 0755 /etc/periodic/daily
        fi
        if ! _okp_cert_validate_safe_path "$OKP_ACME_RENEW_BIN"; then
            die "ACME 续期命令路径无效"
            return 1
        fi
        printf '%s\n' '#!/bin/sh' "exec $OKP_ACME_RENEW_BIN" >"$OKP_ACME_OPENRC_DAILY"
        chmod 0755 "$OKP_ACME_OPENRC_DAILY"
        if command -v rc-update >/dev/null 2>&1 && rc-service crond status >/dev/null 2>&1; then
            rc-update add crond default >/dev/null 2>&1 || true
        elif command -v rc-update >/dev/null 2>&1; then
            rc-update add crond default >/dev/null 2>&1 || true
            rc-service crond start >/dev/null 2>&1 || \
                log_warn "未能启动 crond，请手动确认 ACME 自动续期"
        fi
        log_info "已安装 OpenRC 每日证书续期任务"
        return 0
    fi

    log_warn "无法识别 systemd/OpenRC，未安装自动续期任务"
    return 1
}

# Usage: okp_acme_issue_alidns DOMAIN [CERT_FILE] [KEY_FILE]
okp_acme_issue_alidns() {
    local domain cert_file key_file

    domain=$(_okp_cert_normalize_domain "$1")
    cert_file=${2:-$CERT_DIR/server.crt}
    key_file=${3:-$CERT_DIR/server.key}
    _okp_cert_require_root || return 1
    if ! _okp_cert_validate_domain "$domain"; then
        die "无效的证书域名: $domain"
        return 1
    fi
    if [[ ! -x $OKP_ACME_BIN ]]; then
        die "acme.sh 尚未安装"
        return 1
    fi
    okp_cert_install_xui_reload_hook || return 1
    umask 077
    install -d -m 0700 "$CERT_DIR"

    log_info "正在通过 AliDNS DNS-01 签发 Let's Encrypt EC P-256 证书"
    if ! _okp_cert_run_acme_with_alidns \
        "$OKP_ACME_BIN" --issue --dns dns_ali --server letsencrypt \
        --keylength ec-256 -d "$domain" \
        --home "$OKP_ACME_HOME" --config-home "$OKP_ACME_CONFIG_HOME" \
        --cert-home "$OKP_ACME_CERT_HOME" >/dev/null 2>&1; then
        die "Let's Encrypt 证书签发失败（敏感响应未写入日志）"
        return 1
    fi

    if ! env -i HOME="$_OKP_CERT_CLEAN_HOME" PATH="$_OKP_CERT_CLEAN_PATH" \
        "$OKP_ACME_BIN" --install-cert -d "$domain" --ecc \
        --fullchain-file "$cert_file" --key-file "$key_file" \
        --reloadcmd "$OKP_XUI_RELOAD_HOOK" \
        --home "$OKP_ACME_HOME" --config-home "$OKP_ACME_CONFIG_HOME" \
        --cert-home "$OKP_ACME_CERT_HOME" >/dev/null 2>&1; then
        die "证书安装失败"
        return 1
    fi
    chmod 0600 "$key_file"
    chmod 0644 "$cert_file"
    chmod 0700 "$OKP_ACME_CONFIG_HOME" "$OKP_ACME_CERT_HOME"
    find "$OKP_ACME_CONFIG_HOME" "$OKP_ACME_CERT_HOME" -type f -exec chmod go-rwx {} + 2>/dev/null || true

    if ! _okp_cert_verify_dns_san "$cert_file" "$domain"; then
        die "Let's Encrypt 证书 SAN 自检失败"
        return 1
    fi
    _okp_cert_set_state ACME "$cert_file" "$key_file" "$domain"
    if declare -F state_set >/dev/null 2>&1; then
        state_set ACME_DOMAIN "$domain"
        state_set ACME_HOME "$OKP_ACME_HOME"
    fi
    log_info "Let's Encrypt 证书签发并安装完成"
}

okp_acme_renew_now() {
    local force=${1:-false}
    local -a args
    if [[ ! -x $OKP_ACME_BIN ]]; then
        die "acme.sh 尚未安装"
        return 1
    fi
    args=(--cron --home "$OKP_ACME_HOME" --config-home "$OKP_ACME_CONFIG_HOME" --cert-home "$OKP_ACME_CERT_HOME")
    if [[ $force == true ]]; then
        args+=(--force)
    fi
    _okp_cert_run_acme_with_alidns "$OKP_ACME_BIN" "${args[@]}"
}

# Remove only acme.sh's renewal configuration for a retired domain. The
# installed certificate/key paths are deliberately left untouched because they
# are shared by the active panel and subscription listeners.
okp_acme_remove_domain() {
    local domain

    domain=$(_okp_cert_normalize_domain "${1-}")
    _okp_cert_require_root || return 1
    if ! _okp_cert_validate_domain "$domain"; then
        die "无效的待清理 ACME 域名: $domain"
        return 1
    fi
    if ! _okp_cert_executable_is_secure "$OKP_ACME_BIN"; then
        die "acme.sh 可执行文件不存在或未通过安全校验"
        return 1
    fi

    if ! env -i HOME="$_OKP_CERT_CLEAN_HOME" PATH="$_OKP_CERT_CLEAN_PATH" \
        "$OKP_ACME_BIN" --remove -d "$domain" --ecc \
        --home "$OKP_ACME_HOME" --config-home "$OKP_ACME_CONFIG_HOME" \
        --cert-home "$OKP_ACME_CERT_HOME" >/dev/null 2>&1; then
        die "无法移除旧域名 $domain 的 ACME 续签配置"
        return 1
    fi
    log_info "已移除旧域名 $domain 的 ACME 续签配置"
}

okp_acme_remove_scheduler() {
    _okp_cert_require_root || return 1
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl disable --now one-key-proxy-acme.timer >/dev/null 2>&1 || true
        rm -f -- "$OKP_ACME_SYSTEMD_SERVICE" "$OKP_ACME_SYSTEMD_TIMER"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f -- "$OKP_ACME_OPENRC_DAILY" "$OKP_ACME_RENEW_BIN"
}

okp_cert_remove_managed_files() {
    local cert_file=${1:-$CERT_DIR/server.crt}
    local key_file=${2:-$CERT_DIR/server.key}
    _okp_cert_require_root || return 1
    rm -f -- "$cert_file" "$key_file"
}
