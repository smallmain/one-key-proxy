#!/usr/bin/env bash

# AliDNS support for one-key-proxy. This file is intended to be sourced.
# Credentials are never passed as command-line arguments or written to logs.

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
    OKP_SECRET_DIR=/etc/one-key-proxy/secrets
    OKP_STATE_DIR=/etc/one-key-proxy/state
    OKP_ALIDNS_CREDENTIALS_FILE=/etc/one-key-proxy/secrets/alidns.credentials
    OKP_ALIDNS_RECORDS_FILE=/etc/one-key-proxy/state/alidns-records.tsv
    OKP_ALIDNS_REGION=cn-hangzhou
    OKP_ALIYUN_BIN=/usr/local/bin/aliyun
else
    CONFIG_DIR="${CONFIG_DIR:-/etc/one-key-proxy}"
    OKP_SECRET_DIR="${OKP_SECRET_DIR:-$CONFIG_DIR/secrets}"
    OKP_STATE_DIR="${OKP_STATE_DIR:-$CONFIG_DIR/state}"
    OKP_ALIDNS_CREDENTIALS_FILE="${OKP_ALIDNS_CREDENTIALS_FILE:-$OKP_SECRET_DIR/alidns.credentials}"
    OKP_ALIDNS_RECORDS_FILE="${OKP_ALIDNS_RECORDS_FILE:-$OKP_STATE_DIR/alidns-records.tsv}"
    OKP_ALIDNS_REGION="${OKP_ALIDNS_REGION:-cn-hangzhou}"
    OKP_ALIYUN_BIN="${OKP_ALIYUN_BIN:-/usr/local/bin/aliyun}"
fi
_OKP_ALIDNS_CLEAN_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
_OKP_ALIDNS_CLEAN_HOME='/root'

_okp_alidns_require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        die "AliDNS 配置必须以 root 身份执行"
        return 1
    fi
}

_okp_alidns_require_command() {
    local command_name=$1
    if ! command -v "$command_name" >/dev/null 2>&1; then
        die "缺少必需命令: $command_name"
        return 1
    fi
}

_okp_alidns_file_attribute() {
    local path=$1 linux_format=$2 bsd_format=$3
    stat -c "$linux_format" -- "$path" 2>/dev/null || \
        stat -f "$bsd_format" "$path" 2>/dev/null
}

_okp_alidns_secure_directory() {
    local path=$1 mode=${2:-0700} owner actual_mode
    if [[ -L $path || ( -e $path && ! -d $path ) ]]; then
        die "拒绝使用不安全的 AliDNS 目录: $path"
        return 1
    fi
    install -d -m "$mode" -- "$path" || return 1
    [[ -d $path && ! -L $path ]] || return 1
    chmod "$mode" "$path" || return 1
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        chown 0:0 "$path" || return 1
    fi
    owner=$(_okp_alidns_file_attribute "$path" '%u' '%u') || return 1
    actual_mode=$(_okp_alidns_file_attribute "$path" '%a' '%Lp') || return 1
    [[ $actual_mode == "${mode#0}" ]] || return 1
    if [[ ${OKP_PRODUCTION_MODE:-false} == true && $owner != 0 ]]; then
        die "AliDNS 目录不属于 root: $path"
        return 1
    fi
}

_okp_alidns_secure_regular_file() {
    local path=$1 expected_mode=${2:-600} owner mode links
    [[ -f $path && ! -L $path ]] || return 1
    owner=$(_okp_alidns_file_attribute "$path" '%u' '%u') || return 1
    mode=$(_okp_alidns_file_attribute "$path" '%a' '%Lp') || return 1
    links=$(_okp_alidns_file_attribute "$path" '%h' '%l') || return 1
    [[ $mode == "$expected_mode" && $links == 1 ]] || return 1
    [[ ${OKP_PRODUCTION_MODE:-false} != true || $owner == 0 ]]
}

_okp_alidns_download() {
    local url=$1
    local destination=$2

    _okp_alidns_require_command curl || return 1
    curl --disable --noproxy '*' --fail --location --silent --show-error --retry 3 \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 15 --output "$destination" "$url"
}

_okp_alidns_sha256_file() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    else
        die "缺少 SHA-256 校验工具"
        return 1
    fi
}

okp_alidns_install_cli() {
    local machine archive_arch temp_dir archive candidate release_json
    local release_tag release_version asset_name asset_count asset_url asset_digest
    local expected_digest actual_digest archive_member archive_members archive_type

    _okp_alidns_require_root || return 1

    machine=$(uname -m)
    case "$machine" in
        x86_64 | amd64)
            archive_arch=amd64
            ;;
        aarch64 | arm64)
            archive_arch=arm64
            ;;
        *)
            die "Aliyun CLI 仅正式支持 amd64/arm64，当前架构: $machine"
            return 1
            ;;
    esac

    _okp_alidns_require_command tar || return 1
    _okp_alidns_require_command jq || return 1
    install -d -m 0755 "$(dirname "$OKP_ALIYUN_BIN")"
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/one-key-proxy-aliyun.XXXXXX") || return 1
    archive="$temp_dir/aliyun-cli.tgz"
    release_json="$temp_dir/release.json"

    log_info "正在解析 Aliyun CLI 最新稳定 Release ($archive_arch)"
    if ! _okp_alidns_download \
        https://api.github.com/repos/aliyun/aliyun-cli/releases/latest \
        "$release_json"; then
        rm -rf -- "$temp_dir"
        die "Aliyun CLI Release 元数据下载失败"
        return 1
    fi
    if ! jq -e '.draft == false and .prerelease == false and
        (.tag_name | type == "string") and (.assets | type == "array")' \
        "$release_json" >/dev/null 2>&1; then
        rm -rf -- "$temp_dir"
        die "Aliyun CLI latest 不是可验证的稳定 Release"
        return 1
    fi
    release_tag=$(jq -r '.tag_name' "$release_json")
    if [[ ! $release_tag =~ ^v?[0-9][0-9A-Za-z._-]*$ ]]; then
        rm -rf -- "$temp_dir"
        die "Aliyun CLI Release tag 格式无效"
        return 1
    fi
    release_version=${release_tag#v}
    asset_name="aliyun-cli-linux-${release_version}-${archive_arch}.tgz"
    asset_count=$(jq --arg name "$asset_name" \
        '[.assets[] | select(.name == $name and .state == "uploaded" and (.size > 0))] | length' \
        "$release_json")
    if [[ $asset_count != 1 ]]; then
        rm -rf -- "$temp_dir"
        die "Aliyun CLI Release 中缺少唯一的 $asset_name"
        return 1
    fi
    asset_url=$(jq -r --arg name "$asset_name" \
        '.assets[] | select(.name == $name and .state == "uploaded" and (.size > 0)) |
         .browser_download_url' "$release_json")
    asset_digest=$(jq -r --arg name "$asset_name" \
        '.assets[] | select(.name == $name and .state == "uploaded" and (.size > 0)) |
         .digest // empty' "$release_json")
    if [[ $asset_url != https://github.com/aliyun/aliyun-cli/releases/download/* || \
        ! $asset_digest =~ ^sha256:[0-9A-Fa-f]{64}$ ]]; then
        rm -rf -- "$temp_dir"
        die "Aliyun CLI Release 资产缺少可信 SHA-256 digest"
        return 1
    fi
    expected_digest=$(printf '%s' "${asset_digest#sha256:}" | tr '[:upper:]' '[:lower:]')

    log_info "正在下载并校验 Aliyun CLI $release_tag"
    if ! _okp_alidns_download "$asset_url" "$archive"; then
        rm -rf -- "$temp_dir"
        die "Aliyun CLI 下载失败"
        return 1
    fi
    actual_digest=$(_okp_alidns_sha256_file "$archive") || {
        rm -rf -- "$temp_dir"
        return 1
    }
    actual_digest=$(printf '%s' "$actual_digest" | tr '[:upper:]' '[:lower:]')
    if [[ $actual_digest != "$expected_digest" ]]; then
        rm -rf -- "$temp_dir"
        die "Aliyun CLI SHA-256 校验失败"
        return 1
    fi

    archive_members=$(tar -tzf "$archive" | awk '$0 == "aliyun" || $0 == "./aliyun" { print }') || {
        rm -rf -- "$temp_dir"
        die "Aliyun CLI 安装包目录读取失败"
        return 1
    }
    if [[ $(printf '%s\n' "$archive_members" | awk 'NF { count++ } END { print count+0 }') != 1 ]]; then
        rm -rf -- "$temp_dir"
        die "Aliyun CLI 安装包未包含唯一的 aliyun 文件"
        return 1
    fi
    archive_member=$archive_members
    archive_type=$(tar -tvzf "$archive" | awk -v member="$archive_member" '
        $NF == member { print substr($1, 1, 1) }
    ') || {
        rm -rf -- "$temp_dir"
        die "Aliyun CLI 安装包类型清单读取失败"
        return 1
    }
    if [[ $archive_type != - ]]; then
        rm -rf -- "$temp_dir"
        die "Aliyun CLI 安装包中的 aliyun 不是普通文件"
        return 1
    fi
    if ! tar --no-same-owner -xzf "$archive" -C "$temp_dir" "$archive_member"; then
        rm -rf -- "$temp_dir"
        die "Aliyun CLI 可执行文件提取失败"
        return 1
    fi
    candidate="$temp_dir/${archive_member#./}"
    if [[ ! -f $candidate || -L $candidate ]]; then
        rm -rf -- "$temp_dir"
        die "Aliyun CLI 提取结果无效"
        return 1
    fi
    if ! install -m 0755 "$candidate" "$OKP_ALIYUN_BIN"; then
        rm -rf -- "$temp_dir"
        die "Aliyun CLI 安装失败"
        return 1
    fi
    rm -rf -- "$temp_dir"

    if ! "$OKP_ALIYUN_BIN" version >/dev/null 2>&1; then
        die "Aliyun CLI 安装后自检失败"
        return 1
    fi
    if declare -F state_set >/dev/null 2>&1; then
        state_set ALIYUN_CLI_VERSION "$release_tag" || return 1
    fi
    log_info "Aliyun CLI $release_tag 安装完成"
}

_okp_alidns_value_has_line_break() {
    local value=$1
    [[ $value == *$'\n'* || $value == *$'\r'* ]]
}

okp_alidns_save_credentials() {
    local access_key_id=$1
    local access_key_secret=$2
    local temp_file

    _okp_alidns_require_root || return 1
    if [[ -z $access_key_id || -z $access_key_secret ]]; then
        die "AliDNS AccessKey ID 和 AccessKey Secret 不能为空"
        return 1
    fi
    if _okp_alidns_value_has_line_break "$access_key_id" || \
        _okp_alidns_value_has_line_break "$access_key_secret"; then
        die "AliDNS 凭据不能包含换行符"
        return 1
    fi

    umask 077
    _okp_alidns_secure_directory "$CONFIG_DIR" 0700 || return 1
    _okp_alidns_secure_directory "$OKP_SECRET_DIR" 0700 || return 1
    _okp_alidns_secure_directory "$OKP_STATE_DIR" 0700 || return 1
    if [[ -e $OKP_ALIDNS_CREDENTIALS_FILE || -L $OKP_ALIDNS_CREDENTIALS_FILE ]]; then
        _okp_alidns_secure_regular_file "$OKP_ALIDNS_CREDENTIALS_FILE" 600 || {
            die "拒绝覆盖不安全的 AliDNS 凭据文件"
            return 1
        }
    fi
    temp_file=$(mktemp "$OKP_SECRET_DIR/.alidns.credentials.XXXXXX") || return 1
    if ! printf '%s\n%s\n' "$access_key_id" "$access_key_secret" >"$temp_file"; then
        rm -f -- "$temp_file"
        die "AliDNS 凭据保存失败"
        return 1
    fi
    chmod 0600 "$temp_file" || { rm -f -- "$temp_file"; return 1; }
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        chown 0:0 "$temp_file" || { rm -f -- "$temp_file"; return 1; }
    fi
    _okp_alidns_secure_regular_file "$temp_file" 600 || { rm -f -- "$temp_file"; return 1; }
    if [[ -e $OKP_ALIDNS_CREDENTIALS_FILE || -L $OKP_ALIDNS_CREDENTIALS_FILE ]]; then
        _okp_alidns_secure_regular_file "$OKP_ALIDNS_CREDENTIALS_FILE" 600 || {
            rm -f -- "$temp_file"
            die "AliDNS 凭据目标在写入期间变得不安全"
            return 1
        }
    fi
    mv -f -- "$temp_file" "$OKP_ALIDNS_CREDENTIALS_FILE" || return 1
    log_info "AliDNS RAM 凭据已保存到 root-only 配置目录"
}

_okp_alidns_load_credentials() {
    local access_key_id access_key_secret
    if [[ ! -e $OKP_ALIDNS_CREDENTIALS_FILE && ! -L $OKP_ALIDNS_CREDENTIALS_FILE ]]; then
        die "未找到 AliDNS 凭据"
        return 1
    fi
    _okp_alidns_secure_regular_file "$OKP_ALIDNS_CREDENTIALS_FILE" 600 || {
        die "AliDNS 凭据文件必须是 root 所有、0600 且无硬链接的普通文件"
        return 1
    }

    access_key_id=$(sed -n '1p' "$OKP_ALIDNS_CREDENTIALS_FILE")
    access_key_secret=$(sed -n '2p' "$OKP_ALIDNS_CREDENTIALS_FILE")
    if [[ -z $access_key_id || -z $access_key_secret ]]; then
        die "AliDNS 凭据文件无效"
        return 1
    fi
}

_okp_alidns_cli() {
    _okp_alidns_load_credentials || return 1
    env -i \
        PATH="$_OKP_ALIDNS_CLEAN_PATH" \
        HOME="$_OKP_ALIDNS_CLEAN_HOME" \
        LANG=C \
        sh -c '
            IFS= read -r ALIBABA_CLOUD_ACCESS_KEY_ID || exit 1
            IFS= read -r ALIBABA_CLOUD_ACCESS_KEY_SECRET || exit 1
            [ -n "$ALIBABA_CLOUD_ACCESS_KEY_ID" ] &&
                [ -n "$ALIBABA_CLOUD_ACCESS_KEY_SECRET" ] || exit 1
            ALIBABA_CLOUD_IGNORE_PROFILE=TRUE
            ALIBABA_CLOUD_REGION_ID=$1
            shift
            export ALIBABA_CLOUD_IGNORE_PROFILE ALIBABA_CLOUD_ACCESS_KEY_ID
            export ALIBABA_CLOUD_ACCESS_KEY_SECRET ALIBABA_CLOUD_REGION_ID
            unset PWD OLDPWD SHLVL _
            exec "$@"
        ' sh "$OKP_ALIDNS_REGION" "$OKP_ALIYUN_BIN" alidns "$@" \
        <"$OKP_ALIDNS_CREDENTIALS_FILE"
}

_okp_alidns_call() {
    local output
    if ! output=$(_okp_alidns_cli "$@" 2>/dev/null); then
        log_error "AliDNS API 调用失败: $1（详细响应已隐藏）"
        return 1
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"$output"; then
        log_error "AliDNS API 返回了无效响应"
        return 1
    fi
    printf '%s\n' "$output"
}

okp_alidns_test_credentials() {
    local response
    _okp_alidns_require_command jq || return 1
    if ! response=$(_okp_alidns_call DescribeDomains --PageNumber 1 --PageSize 1); then
        die "AliDNS 凭据验证失败，请检查 RAM 权限"
        return 1
    fi
    jq -e '.Domains.Domain // [] | type == "array"' >/dev/null <<<"$response" || {
        die "AliDNS 凭据验证响应不完整"
        return 1
    }
    log_info "AliDNS 凭据验证成功"
}

_okp_alidns_normalize_fqdn() {
    local fqdn=${1%.}
    fqdn=$(printf '%s' "$fqdn" | tr '[:upper:]' '[:lower:]')
    printf '%s\n' "$fqdn"
}

_okp_alidns_validate_fqdn() {
    local fqdn=$1 label
    local -a _okp_labels
    if (( ${#fqdn} < 3 || ${#fqdn} > 253 )) || [[ $fqdn != *.* ]]; then
        return 1
    fi
    IFS=. read -r -a _okp_labels <<<"$fqdn"
    for label in "${_okp_labels[@]}"; do
        if (( ${#label} < 1 || ${#label} > 63 )) || \
            [[ ! $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
            return 1
        fi
    done
}

_okp_alidns_validate_ipv4() {
    local address=$1 octet
    local -a octets
    IFS=. read -r -a octets <<<"$address"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

_okp_alidns_validate_ipv6() {
    local address=$1
    [[ $address == *:* && $address =~ ^[0-9a-fA-F:]+$ ]]
}

okp_alidns_resolve_zone() {
    local fqdn page response total seen candidate best=''

    _okp_alidns_require_command jq || return 1
    fqdn=$(_okp_alidns_normalize_fqdn "$1")
    if ! _okp_alidns_validate_fqdn "$fqdn"; then
        die "无效的完整域名: $fqdn"
        return 1
    fi

    page=1
    seen=0
    while :; do
        response=$(_okp_alidns_call DescribeDomains --PageNumber "$page" --PageSize 100) || return 1
        while IFS= read -r candidate; do
            candidate=${candidate%.}
            candidate=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')
            if [[ $fqdn == "$candidate" || $fqdn == *."$candidate" ]]; then
                if (( ${#candidate} > ${#best} )); then
                    best=$candidate
                fi
            fi
        done < <(jq -r '.Domains.Domain[]?.DomainName // empty' <<<"$response")

        total=$(jq -r '.TotalCount // 0' <<<"$response")
        seen=$((seen + $(jq -r '.Domains.Domain // [] | length' <<<"$response")))
        (( seen >= total )) && break
        page=$((page + 1))
    done

    if [[ -z $best ]]; then
        die "AliDNS 账户中找不到 $fqdn 对应的托管主域"
        return 1
    fi
    printf '%s\n' "$best"
}

_okp_alidns_rr_for_fqdn() {
    local fqdn=$1 zone=$2
    if [[ $fqdn == "$zone" ]]; then
        printf '@\n'
    else
        printf '%s\n' "${fqdn%."$zone"}"
    fi
}

_okp_alidns_list_address_records() {
    local zone=$1 rr=$2 page=1 response total seen=0 count

    while :; do
        response=$(_okp_alidns_call DescribeDomainRecords \
            --DomainName "$zone" --RRKeyWord "$rr" \
            --PageNumber "$page" --PageSize 500) || return 1
        jq -r --arg rr "$rr" \
            '.DomainRecords.Record[]? |
             select(.RR == $rr and (.Type == "A" or .Type == "AAAA" or .Type == "CNAME")) |
             [.RecordId, .Type, .RR, .Value] | @tsv' <<<"$response"
        count=$(jq -r '.DomainRecords.Record // [] | length' <<<"$response")
        total=$(jq -r '.TotalCount // 0' <<<"$response")
        seen=$((seen + count))
        (( seen >= total )) && break
        page=$((page + 1))
    done
}

# Usage: okp_alidns_assert_no_record_type FQDN A|AAAA [ZONE]
# Performs a read-only check and fails while any matching address record exists.
okp_alidns_assert_no_record_type() {
    local fqdn record_type zone rr records
    local record_id existing_type existing_rr existing_value matching_count=0

    fqdn=$(_okp_alidns_normalize_fqdn "$1")
    record_type=$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')
    zone=${3:-}

    _okp_alidns_require_command jq || return 1
    if ! _okp_alidns_validate_fqdn "$fqdn"; then
        die "无效的完整域名: $fqdn"
        return 1
    fi
    if [[ $record_type != A && $record_type != AAAA ]]; then
        die "DNS 断言类型只允许 A 或 AAAA"
        return 1
    fi

    if [[ -z $zone ]]; then
        zone=$(okp_alidns_resolve_zone "$fqdn") || return 1
    else
        zone=$(_okp_alidns_normalize_fqdn "$zone")
        if ! _okp_alidns_validate_fqdn "$zone"; then
            die "无效的 AliDNS 托管主域: $zone"
            return 1
        fi
    fi
    if [[ $fqdn != "$zone" && $fqdn != *."$zone" ]]; then
        die "$fqdn 不属于托管主域 $zone"
        return 1
    fi

    rr=$(_okp_alidns_rr_for_fqdn "$fqdn" "$zone")
    records=$(_okp_alidns_list_address_records "$zone" "$rr") || return 1
    while IFS=$'\t' read -r record_id existing_type existing_rr existing_value; do
        [[ -n $record_id ]] || continue
        if [[ $existing_rr != "$rr" ]]; then
            die "AliDNS 返回了意外的 RR，无法确认 $fqdn 的 DNS 状态"
            return 1
        fi
        case "$existing_type" in
            A | AAAA | CNAME)
                ;;
            *)
                die "AliDNS 返回了意外的记录类型，无法确认 $fqdn 的 DNS 状态"
                return 1
                ;;
        esac
        if [[ $existing_type == "$record_type" ]]; then
            matching_count=$((matching_count + 1))
        fi
    done <<<"$records"

    if (( matching_count != 0 )); then
        die "$fqdn 仍存在 $matching_count 条 $record_type 记录"
        return 1
    fi
}

# Usage: okp_alidns_assert_single_record_value FQDN A|AAAA EXPECTED [ZONE]
# Performs a read-only check and succeeds only when exactly one record of the
# requested type exists and its value exactly matches EXPECTED.
okp_alidns_assert_single_record_value() {
    local fqdn record_type expected zone rr records
    local record_id existing_type existing_rr existing_value actual_value=''
    local matching_count=0

    fqdn=$(_okp_alidns_normalize_fqdn "$1")
    record_type=$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')
    expected=$3
    zone=${4:-}

    _okp_alidns_require_command jq || return 1
    if ! _okp_alidns_validate_fqdn "$fqdn"; then
        die "无效的完整域名: $fqdn"
        return 1
    fi
    case "$record_type" in
        A)
            _okp_alidns_validate_ipv4 "$expected" || {
                die "无效的预期 IPv4 地址"
                return 1
            }
            ;;
        AAAA)
            _okp_alidns_validate_ipv6 "$expected" || {
                die "无效的预期 IPv6 地址"
                return 1
            }
            expected=${expected,,}
            ;;
        *)
            die "DNS 断言类型只允许 A 或 AAAA"
            return 1
            ;;
    esac

    if [[ -z $zone ]]; then
        zone=$(okp_alidns_resolve_zone "$fqdn") || return 1
    else
        zone=$(_okp_alidns_normalize_fqdn "$zone")
        if ! _okp_alidns_validate_fqdn "$zone"; then
            die "无效的 AliDNS 托管主域: $zone"
            return 1
        fi
    fi
    if [[ $fqdn != "$zone" && $fqdn != *."$zone" ]]; then
        die "$fqdn 不属于托管主域 $zone"
        return 1
    fi

    rr=$(_okp_alidns_rr_for_fqdn "$fqdn" "$zone")
    records=$(_okp_alidns_list_address_records "$zone" "$rr") || return 1
    while IFS=$'\t' read -r record_id existing_type existing_rr existing_value; do
        [[ -n $record_id ]] || continue
        if [[ $existing_rr != "$rr" ]]; then
            die "AliDNS 返回了意外的 RR，无法确认 $fqdn 的 DNS 状态"
            return 1
        fi
        case "$existing_type" in
            A | AAAA)
                ;;
            CNAME)
                die "$fqdn 同时返回 CNAME，无法确认唯一 $record_type 记录"
                return 1
                ;;
            *)
                die "AliDNS 返回了意外的记录类型，无法确认 $fqdn 的 DNS 状态"
                return 1
                ;;
        esac
        if [[ $existing_type == "$record_type" ]]; then
            matching_count=$((matching_count + 1))
            actual_value=$existing_value
        fi
    done <<<"$records"

    if (( matching_count != 1 )); then
        die "$fqdn 必须恰好存在 1 条 $record_type 记录，实际为 $matching_count 条"
        return 1
    fi
    if [[ $actual_value != "$expected" ]]; then
        die "$fqdn 的唯一 $record_type 记录与期望值不匹配"
        return 1
    fi
}

_okp_alidns_is_managed_id() {
    local record_id=$1 fqdn=$2 record_type=$3
    _okp_alidns_secure_regular_file "$OKP_ALIDNS_RECORDS_FILE" 600 || return 1
    awk -F '\t' -v id="$record_id" -v name="$fqdn" -v type="$record_type" \
        '$5 == id && $3 == name && $4 == type { found=1 } END { exit !found }' \
        "$OKP_ALIDNS_RECORDS_FILE"
}

_okp_alidns_track_record() {
    local zone=$1 rr=$2 fqdn=$3 record_type=$4 record_id=$5 value=$6
    local temp_file created_at

    umask 077
    _okp_alidns_secure_directory "$OKP_STATE_DIR" 0700 || return 1
    if [[ -e $OKP_ALIDNS_RECORDS_FILE || -L $OKP_ALIDNS_RECORDS_FILE ]]; then
        _okp_alidns_secure_regular_file "$OKP_ALIDNS_RECORDS_FILE" 600 || {
            die "AliDNS 记录所有权账本不安全"
            return 1
        }
    else
        temp_file=$(mktemp "$OKP_STATE_DIR/.alidns-records.init.XXXXXX") || return 1
        chmod 0600 "$temp_file" || { rm -f -- "$temp_file"; return 1; }
        if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
            chown 0:0 "$temp_file" || { rm -f -- "$temp_file"; return 1; }
        fi
        mv -- "$temp_file" "$OKP_ALIDNS_RECORDS_FILE" || return 1
    fi
    created_at=$(awk -F '\t' -v id="$record_id" \
        '$5 == id && $7 != "" { print $7; exit }' "$OKP_ALIDNS_RECORDS_FILE")
    [[ -n $created_at ]] || created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    temp_file=$(mktemp "$OKP_STATE_DIR/.alidns-records.XXXXXX") || return 1
    awk -F '\t' -v id="$record_id" -v name="$fqdn" -v type="$record_type" \
        '!($5 == id || ($3 == name && $4 == type))' "$OKP_ALIDNS_RECORDS_FILE" >"$temp_file"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$zone" "$rr" "$fqdn" "$record_type" "$record_id" "$value" "$created_at" >>"$temp_file"
    chmod 0600 "$temp_file" || { rm -f -- "$temp_file"; return 1; }
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        chown 0:0 "$temp_file" || { rm -f -- "$temp_file"; return 1; }
    fi
    _okp_alidns_secure_regular_file "$OKP_ALIDNS_RECORDS_FILE" 600 || {
        rm -f -- "$temp_file"
        return 1
    }
    mv -f -- "$temp_file" "$OKP_ALIDNS_RECORDS_FILE"
}

_okp_alidns_set_record_state() {
    local fqdn=$1 zone=$2 record_type=$3 record_id=$4
    if declare -F state_set >/dev/null 2>&1; then
        state_set ALIDNS_FQDN "$fqdn"
        state_set ALIDNS_ZONE "$zone"
        state_set "ALIDNS_${record_type}_RECORD_ID" "$record_id"
        if declare -F state_unset >/dev/null 2>&1; then
            state_unset "ALIDNS_${record_type}_REUSED_RECORD_ID"
        fi
    fi
}

_okp_alidns_set_reused_record_state() {
    local fqdn=$1 zone=$2 record_type=$3 record_id=$4
    if declare -F state_set >/dev/null 2>&1; then
        state_set ALIDNS_FQDN "$fqdn"
        state_set ALIDNS_ZONE "$zone"
        state_set "ALIDNS_${record_type}_REUSED_RECORD_ID" "$record_id"
    fi
}

# Usage: okp_alidns_ensure_record FQDN A|AAAA ADDRESS [ZONE] [ALLOW_REUSE]
# ALLOW_REUSE must be true only after the caller has confirmed reusing an
# identical pre-existing record. Reused records never enter the ownership file.
# Prints the effective RecordId on stdout. Return code 3 means an identical
# unowned record was found and explicit reuse confirmation is required.
okp_alidns_ensure_record() {
    local fqdn record_type value zone rr records record_id existing_type existing_rr existing_value
    local allow_reuse=${5:-false}
    local desired_id='' desired_value='' reusable_id='' response

    fqdn=$(_okp_alidns_normalize_fqdn "$1")
    record_type=$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')
    value=$3
    zone=${4:-}

    if ! _okp_alidns_validate_fqdn "$fqdn"; then
        die "无效的完整域名: $fqdn"
        return 1
    fi
    case "$record_type" in
        A)
            _okp_alidns_validate_ipv4 "$value" || {
                die "无效的 IPv4 地址"
                return 1
            }
            ;;
        AAAA)
            _okp_alidns_validate_ipv6 "$value" || {
                die "无效的 IPv6 地址"
                return 1
            }
            value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
            ;;
        *)
            die "AliDNS 仅允许本项目管理 A/AAAA 记录"
            return 1
            ;;
    esac

    if [[ -z $zone ]]; then
        zone=$(okp_alidns_resolve_zone "$fqdn") || return 1
    else
        zone=$(_okp_alidns_normalize_fqdn "$zone")
    fi
    if [[ $fqdn != "$zone" && $fqdn != *."$zone" ]]; then
        die "$fqdn 不属于托管主域 $zone"
        return 1
    fi
    rr=$(_okp_alidns_rr_for_fqdn "$fqdn" "$zone")
    records=$(_okp_alidns_list_address_records "$zone" "$rr") || return 1

    while IFS=$'\t' read -r record_id existing_type existing_rr existing_value; do
        [[ -n $record_id ]] || continue
        if [[ $existing_rr != "$rr" ]]; then
            die "AliDNS 返回了意外的 RR，拒绝继续"
            return 1
        fi
        if [[ $existing_type == CNAME ]]; then
            die "$fqdn 已存在 CNAME，拒绝覆盖"
            return 1
        fi
        if ! _okp_alidns_is_managed_id "$record_id" "$fqdn" "$existing_type"; then
            if [[ $existing_type != "$record_type" ]]; then
                continue
            fi
            if [[ $existing_value != "$value" ]]; then
                die "$fqdn 已存在值不同且非本项目管理的 $existing_type 记录，拒绝覆盖"
                return 1
            fi
            if [[ -n $reusable_id ]]; then
                die "$fqdn 已存在多条非本项目管理的 $existing_type 记录，拒绝复用"
                return 1
            fi
            reusable_id=$record_id
            continue
        fi
        if [[ $existing_type == "$record_type" ]]; then
            if [[ -n $desired_id ]]; then
                die "$fqdn 存在多条本项目记录，需人工检查后再继续"
                return 1
            fi
            desired_id=$record_id
            desired_value=$existing_value
        fi
    done <<<"$records"

    if [[ -n $reusable_id ]]; then
        if [[ -n $desired_id ]]; then
            die "$fqdn 同时存在受管和非受管 $record_type 记录，拒绝继续"
            return 1
        fi
        if [[ $allow_reuse != true ]]; then
            log_warn "$fqdn 已存在完全相同的非受管 $record_type 记录；经用户确认后可复用"
            return 3
        fi
        _okp_alidns_set_reused_record_state "$fqdn" "$zone" "$record_type" "$reusable_id"
        log_info "已复用现有 $record_type 记录（不会在卸载时删除）: $fqdn"
        printf '%s\n' "$reusable_id"
        return 0
    fi

    if [[ -n $desired_id ]]; then
        if [[ $desired_value != "$value" ]]; then
            response=$(_okp_alidns_call UpdateDomainRecord \
                --RecordId "$desired_id" --RR "$rr" --Type "$record_type" --Value "$value") || return 1
            if [[ $(jq -r '.RecordId // empty' <<<"$response") != "$desired_id" ]]; then
                die "AliDNS 更新记录后返回的 RecordId 不匹配"
                return 1
            fi
            log_info "已更新受管 $record_type 记录: $fqdn"
        else
            log_info "受管 $record_type 记录无需更新: $fqdn"
        fi
    else
        response=$(_okp_alidns_call AddDomainRecord \
            --DomainName "$zone" --RR "$rr" --Type "$record_type" --Value "$value") || return 1
        desired_id=$(jq -r '.RecordId // empty' <<<"$response")
        if [[ -z $desired_id ]]; then
            die "AliDNS 创建记录后未返回 RecordId"
            return 1
        fi
        log_info "已创建受管 $record_type 记录: $fqdn"
    fi

    _okp_alidns_track_record "$zone" "$rr" "$fqdn" "$record_type" "$desired_id" "$value" || return 1
    _okp_alidns_set_record_state "$fqdn" "$zone" "$record_type" "$desired_id"
    printf '%s\n' "$desired_id"
}

# Deletes only selected records whose current RecordId, RR, type and value still
# match the root-only ownership ledger. Empty fqdn_filter selects every entry.
_okp_alidns_delete_managed_records_filtered() {
    local fqdn_filter=${1:-}
    local type_filter=${2:-}
    local temp_file line zone rr fqdn record_type record_id expected_value
    local response actual_id actual_rr actual_type actual_value actual_domain
    local failures=0

    if [[ ! -e $OKP_ALIDNS_RECORDS_FILE && ! -L $OKP_ALIDNS_RECORDS_FILE ]]; then
        return 0
    fi
    _okp_alidns_secure_regular_file "$OKP_ALIDNS_RECORDS_FILE" 600 || {
        die "AliDNS 记录所有权账本不安全，拒绝删除 DNS 记录"
        return 1
    }
    umask 077
    temp_file=$(mktemp "$OKP_STATE_DIR/.alidns-records.keep.XXXXXX") || return 1

    while IFS= read -r line || [[ -n $line ]]; do
        IFS=$'\t' read -r zone rr fqdn record_type record_id expected_value _ <<<"$line"
        if [[ ( -n $fqdn_filter && $fqdn != "$fqdn_filter" ) || \
            ( -n $type_filter && $record_type != "$type_filter" ) ]]; then
            printf '%s\n' "$line" >>"$temp_file"
            continue
        fi
        if [[ -z $record_id ]]; then
            printf '%s\n' "$line" >>"$temp_file"
            failures=$((failures + 1))
            continue
        fi
        if ! response=$(_okp_alidns_call DescribeDomainRecordInfo --RecordId "$record_id"); then
            printf '%s\n' "$line" >>"$temp_file"
            failures=$((failures + 1))
            continue
        fi
        actual_id=$(jq -r '.RecordId // empty' <<<"$response")
        actual_rr=$(jq -r '.RR // empty' <<<"$response")
        actual_type=$(jq -r '.Type // empty' <<<"$response")
        actual_value=$(jq -r '.Value // empty' <<<"$response")
        actual_domain=$(jq -r '.DomainName // empty' <<<"$response")
        if [[ $actual_id != "$record_id" || $actual_rr != "$rr" || \
            $actual_type != "$record_type" || $actual_value != "$expected_value" || \
            ( -n $actual_domain && $actual_domain != "$zone" ) ]]; then
            log_warn "受管记录元数据不匹配，拒绝删除: $fqdn ($record_type)"
            printf '%s\n' "$line" >>"$temp_file"
            failures=$((failures + 1))
            continue
        fi
        if ! _okp_alidns_call DeleteDomainRecord --RecordId "$record_id" >/dev/null; then
            printf '%s\n' "$line" >>"$temp_file"
            failures=$((failures + 1))
            continue
        fi
        log_info "已删除受管 $record_type 记录: $fqdn"
    done <"$OKP_ALIDNS_RECORDS_FILE"

    chmod 0600 "$temp_file" || { rm -f -- "$temp_file"; return 1; }
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        chown 0:0 "$temp_file" || { rm -f -- "$temp_file"; return 1; }
    fi
    _okp_alidns_secure_regular_file "$OKP_ALIDNS_RECORDS_FILE" 600 || {
        rm -f -- "$temp_file"
        return 1
    }
    mv -f -- "$temp_file" "$OKP_ALIDNS_RECORDS_FILE" || return 1
    (( failures == 0 ))
}

# Deletes every owned A/AAAA entry in the ledger.
okp_alidns_delete_managed_records() {
    _okp_alidns_delete_managed_records_filtered '' ''
}

# Usage: okp_alidns_delete_managed_records_for_fqdn OLD_FQDN [A|AAAA]
# Deletes only owned entries matching the requested identity and optional type.
# Every other ledger line remains unchanged. Failed selected entries also remain.
okp_alidns_delete_managed_records_for_fqdn() {
    local old_fqdn record_type
    old_fqdn=$(_okp_alidns_normalize_fqdn "$1")
    if ! _okp_alidns_validate_fqdn "$old_fqdn"; then
        die "无效的旧完整域名: $old_fqdn"
        return 1
    fi
    record_type=$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]')
    if [[ -n $record_type && $record_type != A && $record_type != AAAA ]]; then
        die "DNS 删除类型只允许 A 或 AAAA"
        return 1
    fi
    _okp_alidns_delete_managed_records_filtered "$old_fqdn" "$record_type"
}

okp_alidns_remove_credentials() {
    _okp_alidns_require_root || return 1
    rm -f -- "$OKP_ALIDNS_CREDENTIALS_FILE"
    log_info "AliDNS 凭据已删除"
}
