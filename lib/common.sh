#!/usr/bin/env bash

# Shared helpers. Callers decide whether to enable errexit/pipefail.

: "${PROJECT_NAME:=one-key-proxy}"
: "${PROJECT_VERSION:=0.1.0}"
if [[ ${OKP_PRODUCTION_MODE:-false} == true ]]; then
  CONFIG_DIR=/etc/one-key-proxy
  STATE_FILE=/etc/one-key-proxy/state.env
  CERT_DIR=/etc/one-key-proxy/certs
  LOG_FILE=/var/log/one-key-proxy.log
  BACKUP_DIR=/var/backups/one-key-proxy
else
  : "${CONFIG_DIR:=/etc/one-key-proxy}"
  : "${STATE_FILE:=${CONFIG_DIR}/state.env}"
  : "${CERT_DIR:=${CONFIG_DIR}/certs}"
  : "${LOG_FILE:=/var/log/one-key-proxy.log}"
  : "${BACKUP_DIR:=/var/backups/one-key-proxy}"
fi

if [[ -t 1 ]]; then
  _OKP_RED=$'\033[0;31m'
  _OKP_GREEN=$'\033[0;32m'
  _OKP_YELLOW=$'\033[0;33m'
  _OKP_BLUE=$'\033[0;34m'
  _OKP_BOLD=$'\033[1m'
  _OKP_RESET=$'\033[0m'
else
  _OKP_RED=''
  _OKP_GREEN=''
  _OKP_YELLOW=''
  _OKP_BLUE=''
  _OKP_BOLD=''
  _OKP_RESET=''
fi

_okp_log_line() {
  local level=$1
  shift
  local message=$*
  local timestamp previous_umask
  if declare -F redact_sensitive >/dev/null 2>&1; then
    message=$(redact_sensitive "$message")
  fi
  timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
  if [[ -f $LOG_FILE && ! -L $LOG_FILE && -w $LOG_FILE ]]; then
    previous_umask=$(umask)
    umask 077
    printf '%s [%s] %s\n' "$timestamp" "$level" "$message" >>"$LOG_FILE" 2>/dev/null || true
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    umask "$previous_umask"
  fi
}

log_info() {
  printf '%s[INFO]%s %s\n' "$_OKP_BLUE" "$_OKP_RESET" "$*"
  _okp_log_line INFO "$*"
}

log_success() {
  printf '%s[ OK ]%s %s\n' "$_OKP_GREEN" "$_OKP_RESET" "$*"
  _okp_log_line OK "$*"
}

log_warn() {
  printf '%s[WARN]%s %s\n' "$_OKP_YELLOW" "$_OKP_RESET" "$*" >&2
  _okp_log_line WARN "$*"
}

log_error() {
  printf '%s[ERR ]%s %s\n' "$_OKP_RED" "$_OKP_RESET" "$*" >&2
  _okp_log_line ERROR "$*"
}

die() {
  log_error "$*"
  return 1
}

heading() {
  printf '\n%s%s%s\n' "$_OKP_BOLD" "$*" "$_OKP_RESET"
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

# Outputs populated by okp_xui_release_asset_from_json.
OKP_XUI_RELEASE_ASSET_NAME=''
OKP_XUI_RELEASE_ASSET_URL=''
OKP_XUI_RELEASE_ASSET_SHA256=''
OKP_XUI_RELEASE_ASSET_SIZE=''

# Outputs populated by okp_prepare_pinned_xui_download.
OKP_XUI_PINNED_BIN_DIR=''
OKP_XUI_PINNED_CURL=''
OKP_XUI_VERIFIED_ASSET=''
OKP_XUI_VERIFIED_RAW_DIR=''
OKP_XUI_PINNED_ASSET_URL=''

_okp_xui_validate_release_identity() {
  local repository=$1 tag=$2 commit=${3-} architecture=${4-}
  [[ $repository == MHSanaei/3x-ui ]] || return 1
  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ -z $commit || $commit =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ -z $architecture || $architecture == amd64 || $architecture == arm64 ]]
}

# Parse the one exact Linux release asset used by the official installer. The
# caller supplies the already downloaded GitHub releases/latest JSON document.
okp_xui_release_asset_from_json() {
  local repository=$1 tag=$2 architecture=$3 document=$4
  local expected_name expected_url metadata name url digest size

  OKP_XUI_RELEASE_ASSET_NAME=''
  OKP_XUI_RELEASE_ASSET_URL=''
  OKP_XUI_RELEASE_ASSET_SHA256=''
  OKP_XUI_RELEASE_ASSET_SIZE=''

  _okp_xui_validate_release_identity "$repository" "$tag" '' "$architecture" || {
    log_error '3x-ui release 标识或架构无效。'
    return 1
  }
  have_command jq || {
    log_error '缺少 jq，无法校验 3x-ui release 资产元数据。'
    return 1
  }

  expected_name="x-ui-linux-${architecture}.tar.gz"
  expected_url="https://github.com/${repository}/releases/download/${tag}/${expected_name}"
  metadata=$(jq -er --arg tag "$tag" --arg name "$expected_name" --arg url "$expected_url" '
    select(type == "object" and .draft == false and .prerelease == false and
      .tag_name == $tag and (.assets | type) == "array") |
    [.assets[] | select(.name == $name)] as $named |
    select(($named | length) == 1) |
    $named[0] |
    select(.state == "uploaded" and
      (.size | type) == "number" and .size > 0 and (.size | floor) == .size and
      .browser_download_url == $url and
      (.digest | type) == "string" and
      (.digest | test("^sha256:[0-9A-Fa-f]{64}$"))) |
    [.name, .browser_download_url, (.digest | ascii_downcase), (.size | tostring)] |
    @tsv
  ' <<<"$document") || {
    log_error "3x-ui ${tag} 的 ${expected_name} 资产不唯一、未上传或缺少可信 SHA-256 摘要。"
    return 1
  }
  IFS=$'\t' read -r name url digest size <<<"$metadata"
  [[ $name == "$expected_name" && $url == "$expected_url" &&
    $digest =~ ^sha256:[0-9a-f]{64}$ && $size =~ ^[1-9][0-9]*$ ]] || return 1

  OKP_XUI_RELEASE_ASSET_NAME=$name
  OKP_XUI_RELEASE_ASSET_URL=$url
  OKP_XUI_RELEASE_ASSET_SHA256=${digest#sha256:}
  OKP_XUI_RELEASE_ASSET_SIZE=$size
}

_okp_xui_count_literal() {
  local document=$1 needle=$2
  awk -v needle="$needle" '
    BEGIN { count = 0 }
    {
      line = $0
      while ((position = index(line, needle)) != 0) {
        count++
        line = substr(line, position + length(needle))
      }
    }
    END { print count }
  ' <<<"$document"
}

_okp_xui_count_assignment() {
  local document=$1 variable=$2
  awk -v variable="$variable" '
    $0 ~ "^[[:space:]]*" variable "[[:space:]]*=" { count++ }
    END { print count + 0 }
  ' <<<"$document"
}

_okp_xui_count_bare_curl_with() {
  local document=$1 needle=$2
  awk -v needle="$needle" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^curl[[:space:]]/ && index(line, needle) != 0) count++
    }
    END { print count + 0 }
  ' <<<"$document"
}

_okp_xui_installer_has_forbidden_downloader_shape() {
  local installer=$1
  LC_ALL=C awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      gsub(/["\047]/, "", line)
      gsub(/\\/, "", line)
      lower = tolower(line)
      curl_line = lower
      sub(/^[[:space:]]+/, "", curl_line)

      if (curl_line ~ /^curl[[:space:]]/ &&
          (curl_line ~ /[[:space:]]-[a-z]*k[a-z]*([[:space:]]|$)/ ||
           curl_line ~ /[[:space:]]--(insecure|config|cacert|capath|next|proxy|proto|proto-redir|resolve|connect-to)(=|[[:space:]]|$)/ ||
           curl_line ~ /[[:space:]]-:([[:space:]]|$)/ ||
           curl_line ~ /;[[:space:]]*curl[[:space:]]/)) {
        forbidden = 1
      }

      if (line ~ /(^|[[:space:];|&(=])\/[^[:space:];|&()]+\/curl([[:space:];|&)]|$)/ ||
          lower ~ /(^|[[:space:];|&(=])([^[:space:];|&()]\/)?wget([[:space:];|&)]|$)/ ||
          lower ~ /(^|[[:space:];|&(])(function[[:space:]]+)?(curl|wget)[[:space:]]*\(\)/ ||
          lower ~ /(^|[[:space:];|&(])(alias|builtin)[[:space:]]+(curl|wget)([[:space:];|&)]|$)/ ||
          lower ~ /(^|[[:space:];|&(])command[[:space:]]+-p([[:space:]]+--)?[[:space:]]+curl([[:space:];|&)]|$)/ ||
          lower ~ /(^|[[:space:];|&(])[a-z_][a-z0-9_]*(curl|wget)[a-z0-9_]*[[:space:]]*=/ ||
          lower ~ /\$\{?[a-z_][a-z0-9_]*(curl|wget)[a-z0-9_]*\}?/ ||
          lower ~ /(^|[[:space:];|&(])(env|sudo|doas|busybox|xargs|nohup|nice|timeout|eval)[[:space:]][^;|&]*curl([[:space:];|&)]|$)/ ||
          lower ~ /(^|[[:space:];|&(])(type|command)[[:space:]][^;|&]*curl([[:space:];|&)]|$)/ ||
          line ~ /(^|[[:space:];|&(])((export|readonly)[[:space:]]+)?PATH[[:space:]]*=/ ||
          line ~ /(^|[[:space:];|&(])unset[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?PATH([[:space:];|&)]|$)/ ||
          line ~ /(^|[[:space:];|&(])printf[[:space:]]+-v[[:space:]]+PATH([[:space:];|&)]|$)/ ||
          line ~ /(^|[[:space:];|&(])read[[:space:]][^;|&]*[[:space:]]PATH([[:space:];|&<]|$)/) {
        forbidden = 1
      }
    }
    END { exit forbidden ? 0 : 1 }
  ' "$installer"
}

# Fail closed when the pinned upstream installer changes how it downloads the
# release archive or helper files. This is a compatibility check, not execution:
# the downloaded script is parsed as inert text and only later run through the
# verified curl adapter created below.
okp_xui_validate_pinned_installer_downloaders() {
  local installer=$1 repository=$2 tag=$3 architecture=$4 size code
  local asset_template asset_output direct_asset_output variable_download
  local raw_prefix raw_total expected_total count
  local xui_script_url xui_rc_url service_url
  local -a service_urls

  _okp_xui_validate_release_identity "$repository" "$tag" '' "$architecture" || {
    log_error '无法校验无效的 3x-ui 安装器 release 标识。'
    return 1
  }
  [[ -s $installer && -f $installer && ! -L $installer ]] || {
    log_error '固定的 3x-ui 安装器不是非空常规文件。'
    return 1
  }
  size=$(wc -c <"$installer") || return 1
  size=${size//[[:space:]]/}
  [[ $size =~ ^[1-9][0-9]*$ && $size -le 2097152 ]] || {
    log_error '固定的 3x-ui 安装器大小异常。'
    return 1
  }
  bash -n "$installer" >/dev/null 2>&1 || {
    log_error '固定的 3x-ui 安装器未通过 Bash 语法校验。'
    return 1
  }
  if _okp_xui_installer_has_forbidden_downloader_shape "$installer"; then
    log_error '固定的 3x-ui 安装器包含会绕过受验证 curl wrapper 的下载方式。'
    return 1
  fi

  code=$(awk '!/^[[:space:]]*#/' "$installer") || return 1
  [[ $(_okp_xui_count_bare_curl_with "$code" '') == 7 &&
    $(_okp_xui_count_bare_curl_with "$code" 'curl -s https://get.acme.sh | sh') == 2 ]] || {
    log_error '固定的 3x-ui 安装器裸 curl 命令集合已改变。'
    return 1
  }
  [[ $(_okp_xui_count_literal "$code" 'xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"') == 1 &&
    $(_okp_xui_count_assignment "$code" xui_folder) == 1 &&
    $(_okp_xui_count_literal "$code" 'tag_version=$1') == 1 &&
    $(_okp_xui_count_literal "$code" 'install_x-ui() {') == 1 &&
    $(_okp_xui_count_literal "$code" 'install_x-ui $1') == 1 &&
    $(_okp_xui_count_literal "$code" 'arch() {') == 1 ]] || {
    log_error '固定的 3x-ui 安装器目录、版本参数或架构函数形状已改变。'
    return 1
  }
  case $architecture in
    amd64)
      [[ $(_okp_xui_count_literal "$code" "x86_64 | x64 | amd64) echo 'amd64' ;;") == 1 ]] || {
        log_error '固定的 3x-ui 安装器 amd64 映射已改变。'
        return 1
      }
      ;;
    arm64)
      [[ $(_okp_xui_count_literal "$code" "armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;") == 1 ]] || {
        log_error '固定的 3x-ui 安装器 arm64 映射已改变。'
        return 1
      }
      ;;
  esac

  asset_template="https://github.com/${repository}/releases/download/\${tag_version}/x-ui-linux-\$(arch).tar.gz"
  asset_output='-o ${xui_folder}-linux-$(arch).tar.gz ${url}'
  direct_asset_output="-o \${xui_folder}-linux-\$(arch).tar.gz ${asset_template}"
  [[ $(_okp_xui_count_literal "$code" "url=\"${asset_template}\"") == 1 &&
    $(_okp_xui_count_assignment "$code" url) == 1 ]] || {
    log_error '固定的 3x-ui 安装器 release 资产 URL 构造已改变。'
    return 1
  }
  count=$(_okp_xui_count_literal "$code" "https://github.com/${repository}/releases/download/")
  [[ $count == 2 && $count == "$(_okp_xui_count_literal "$code" "$asset_template")" &&
    $(_okp_xui_count_bare_curl_with "$code" "$asset_template") == 1 &&
    $(_okp_xui_count_bare_curl_with "$code" "$direct_asset_output") == 1 ]] || {
    log_error '固定的 3x-ui 安装器包含非预期的 release 下载 URL。'
    return 1
  }
  variable_download=$(_okp_xui_count_bare_curl_with "$code" '${url}')
  [[ $variable_download == 1 && $(_okp_xui_count_literal "$code" '${url}') == 1 &&
    $(_okp_xui_count_bare_curl_with "$code" "$asset_output") == 1 ]] || {
    log_error '固定的 3x-ui 安装器 release 资产未通过 PATH curl 下载到固定输出。'
    return 1
  }

  raw_prefix="https://raw.githubusercontent.com/${repository}/"
  xui_script_url="${raw_prefix}main/x-ui.sh"
  xui_rc_url="${raw_prefix}main/x-ui.rc"
  service_urls=(
    "${raw_prefix}main/x-ui.service.debian"
    "${raw_prefix}main/x-ui.service.arch"
    "${raw_prefix}main/x-ui.service.rhel"
  )
  [[ $(_okp_xui_count_literal "$code" "$xui_script_url") == 1 &&
    $(_okp_xui_count_literal "$code" "$xui_rc_url") == 1 &&
    $(_okp_xui_count_bare_curl_with "$code" "$xui_script_url") == 1 &&
    $(_okp_xui_count_bare_curl_with "$code" "$xui_rc_url") == 1 &&
    $(_okp_xui_count_literal "$code" 'local source="$1"') == 1 &&
    $(_okp_xui_count_literal "$code" 'local source_is_url="$2"') == 1 &&
    $(_okp_xui_count_bare_curl_with "$code" 'curl -fLRo "$temp_file" "$source"') == 1 &&
    $(_okp_xui_count_literal "$code" '_install_xui_service_unit "$service_unit_url" "true"') == 1 ]] || {
    log_error '固定的 3x-ui 安装器 raw helper 下载未全部通过 PATH curl。'
    return 1
  }
  expected_total=$(_okp_xui_count_literal "$code" "$xui_script_url")
  count=$(_okp_xui_count_literal "$code" "$xui_rc_url")
  expected_total=$((expected_total + count))
  for service_url in "${service_urls[@]}"; do
    count=$(_okp_xui_count_literal "$code" "$service_url")
    [[ $count -ge 1 &&
      $(_okp_xui_count_literal "$code" "service_unit_url=\"${service_url}\"") == "$count" ]] || {
      log_error '固定的 3x-ui 安装器 service unit URL 形状已改变。'
      return 1
    }
    expected_total=$((expected_total + count))
  done
  raw_total=$(_okp_xui_count_literal "$code" "$raw_prefix")
  [[ $raw_total -eq $expected_total ]] || {
    log_error '固定的 3x-ui 安装器包含非预期的 raw.githubusercontent.com 路径。'
    return 1
  }
}

_okp_xui_sha256_file() {
  local file=$1 digest
  [[ -f $file && ! -L $file ]] || return 1
  if have_command sha256sum; then
    digest=$(sha256sum "$file" | awk '{print $1}') || return 1
  elif have_command shasum; then
    digest=$(shasum -a 256 "$file" | awk '{print $1}') || return 1
  elif have_command openssl; then
    digest=$(openssl dgst -sha256 "$file" | awk '{print $NF}') || return 1
  else
    log_error '缺少 SHA-256 校验工具。'
    return 1
  fi
  digest=$(printf '%s' "$digest" | tr '[:upper:]' '[:lower:]') || return 1
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$digest"
}

_okp_xui_write_curl_wrapper() {
  local destination=$1 real_curl=$2 asset_url=$3 verified_asset=$4
  local expected_digest=$5 raw_main_prefix=$6 raw_commit_prefix=$7 expected_output=$8
  local raw_output_test_dir=${9-} raw_xui_output_prefix raw_rc_output_prefix raw_service_output_prefix
  local temporary="${destination}.tmp" raw_cache_dir
  local raw_xui_script raw_xui_script_digest raw_xui_rc raw_xui_rc_digest
  local raw_service_debian raw_service_debian_digest raw_service_arch raw_service_arch_digest
  local raw_service_rhel raw_service_rhel_digest

  raw_cache_dir="${verified_asset%/*}/raw"
  raw_xui_script="${raw_cache_dir}/x-ui.sh"
  raw_xui_rc="${raw_cache_dir}/x-ui.rc"
  raw_service_debian="${raw_cache_dir}/x-ui.service.debian"
  raw_service_arch="${raw_cache_dir}/x-ui.service.arch"
  raw_service_rhel="${raw_cache_dir}/x-ui.service.rhel"
  if [[ -n $raw_output_test_dir ]]; then
    raw_xui_output_prefix="${raw_output_test_dir}/x-ui-temp."
    raw_rc_output_prefix="${raw_output_test_dir}/x-ui.tmp."
    raw_service_output_prefix="${raw_output_test_dir}/x-ui.service.tmp."
  else
    raw_xui_output_prefix='/usr/bin/x-ui-temp.'
    raw_rc_output_prefix='/etc/init.d/x-ui.tmp.'
    raw_service_output_prefix='/etc/systemd/system/x-ui.service.tmp.'
  fi
  raw_xui_script_digest=$(_okp_xui_sha256_file "$raw_xui_script") || return 1
  raw_xui_rc_digest=$(_okp_xui_sha256_file "$raw_xui_rc") || return 1
  raw_service_debian_digest=$(_okp_xui_sha256_file "$raw_service_debian") || return 1
  raw_service_arch_digest=$(_okp_xui_sha256_file "$raw_service_arch") || return 1
  raw_service_rhel_digest=$(_okp_xui_sha256_file "$raw_service_rhel") || return 1

  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -Euo pipefail'
    printf 'REAL_CURL=%q\n' "$real_curl"
    printf 'ASSET_URL=%q\n' "$asset_url"
    printf 'VERIFIED_ASSET=%q\n' "$verified_asset"
    printf 'EXPECTED_DIGEST=%q\n' "$expected_digest"
    printf 'RAW_MAIN_PREFIX=%q\n' "$raw_main_prefix"
    printf 'RAW_COMMIT_PREFIX=%q\n' "$raw_commit_prefix"
    printf 'RELEASE_PREFIX=%q\n' "${asset_url%%/releases/download/*}/releases/download/"
    printf 'RAW_REPOSITORY_PREFIX=%q\n' "${raw_main_prefix%main/}"
    printf 'RAW_XUI_SCRIPT=%q\n' "$raw_xui_script"
    printf 'RAW_XUI_SCRIPT_DIGEST=%q\n' "$raw_xui_script_digest"
    printf 'RAW_XUI_RC=%q\n' "$raw_xui_rc"
    printf 'RAW_XUI_RC_DIGEST=%q\n' "$raw_xui_rc_digest"
    printf 'RAW_SERVICE_DEBIAN=%q\n' "$raw_service_debian"
    printf 'RAW_SERVICE_DEBIAN_DIGEST=%q\n' "$raw_service_debian_digest"
    printf 'RAW_SERVICE_ARCH=%q\n' "$raw_service_arch"
    printf 'RAW_SERVICE_ARCH_DIGEST=%q\n' "$raw_service_arch_digest"
    printf 'RAW_SERVICE_RHEL=%q\n' "$raw_service_rhel"
    printf 'RAW_SERVICE_RHEL_DIGEST=%q\n' "$raw_service_rhel_digest"
    printf 'RAW_XUI_OUTPUT_PREFIX=%q\n' "$raw_xui_output_prefix"
    printf 'RAW_RC_OUTPUT_PREFIX=%q\n' "$raw_rc_output_prefix"
    printf 'RAW_SERVICE_OUTPUT_PREFIX=%q\n' "$raw_service_output_prefix"
    printf 'EXPECTED_OUTPUT=%q\n' "$expected_output"
    cat <<'OKP_XUI_CURL_WRAPPER'

sha256_file() {
  local file=$1 digest
  [[ -f $file && ! -L $file ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$file" | awk '{print $1}') || return 1
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$file" | awk '{print $1}') || return 1
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(openssl dgst -sha256 "$file" | awk '{print $NF}') || return 1
  else
    return 1
  fi
  digest=$(printf '%s' "$digest" | tr '[:upper:]' '[:lower:]') || return 1
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$digest"
}

copy_verified_file() {
  local source=$1 expected_digest=$2 destination=$3 actual_digest parent temporary
  actual_digest=$(sha256_file "$source") || return 65
  [[ $actual_digest == "$expected_digest" ]] || return 65
  parent=${destination%/*}
  [[ $destination == /* && -d $parent && ! -L $parent && ! -L $destination ]] || return 73
  temporary=$(mktemp "${destination}.one-key-proxy.XXXXXX") || return 73
  trap 'rm -f -- "$temporary"' EXIT
  cp -- "$source" "$temporary" || return 74
  chmod 0600 "$temporary" || return 74
  mv -f -- "$temporary" "$destination" || return 74
  trap - EXIT
}

matches_numbered_output() {
  local value=$1 prefix=$2 suffix
  [[ $value == "$prefix"* ]] || return 1
  suffix=${value#"$prefix"}
  [[ $suffix =~ ^[0-9]+$ ]]
}

declare -a rewritten=()
asset_requests=0
raw_requests=0
output=''
output_count=0
expect_output=false
raw_source=''
raw_digest=''
raw_output_prefix=''
for argument in "$@"; do
  case $argument in
    --next|-:|-k|--insecure|--insecure=*|-K|--config|--config=*|-K?*|\
    --cacert|--cacert=*|--capath|--capath=*|-x|-x?*|--proxy|--proxy=*|\
    --proto|--proto=*|--proto-redir|--proto-redir=*|--tlsv1*|\
    --resolve|--resolve=*|--connect-to|--connect-to=*)
      printf '%s\n' 'one-key-proxy curl wrapper: 拒绝可改变受控传输边界的 curl 参数' >&2
      exit 64
      ;;
  esac
  if [[ $argument =~ ^-[A-Za-z]*k[A-Za-z]*$ ]]; then
    printf '%s\n' 'one-key-proxy curl wrapper: 拒绝 curl insecure 短选项' >&2
    exit 64
  fi
  if [[ $expect_output == true ]]; then
    output=$argument
    output_count=$((output_count + 1))
    expect_output=false
  else
    case $argument in
      -o|--output) expect_output=true ;;
      --output=*) output=${argument#--output=}; output_count=$((output_count + 1)) ;;
      -o?*) output=${argument#-o}; output_count=$((output_count + 1)) ;;
      -[^-]*o) expect_output=true ;;
      -[^-]*o?*) output=${argument##*o}; output_count=$((output_count + 1)) ;;
    esac
  fi
  argument_lower=$(printf '%s' "$argument" | tr '[:upper:]' '[:lower:]') || exit 1
  release_prefix_lower=$(printf '%s' "$RELEASE_PREFIX" | tr '[:upper:]' '[:lower:]') || exit 1
  raw_repository_prefix_lower=$(printf '%s' "$RAW_REPOSITORY_PREFIX" | tr '[:upper:]' '[:lower:]') || exit 1
  if [[ $argument_lower == *"$release_prefix_lower"* ]]; then
    case $argument in
      "$ASSET_URL"|--url="$ASSET_URL") ;;
      *)
        printf '%s\n' 'one-key-proxy curl wrapper: 拒绝未验证的官方 release 资产 URL' >&2
        exit 65
        ;;
    esac
  fi
  if [[ $argument == *"$RAW_MAIN_PREFIX"* ]]; then
    argument_before=${argument%%"$RAW_MAIN_PREFIX"*}
    argument_after=${argument#*"$RAW_MAIN_PREFIX"}
    argument="${argument_before}${RAW_COMMIT_PREFIX}${argument_after}"
  fi
  case $argument in
    "$RAW_COMMIT_PREFIX"x-ui.sh|--url="$RAW_COMMIT_PREFIX"x-ui.sh)
      raw_requests=$((raw_requests + 1))
      raw_source=$RAW_XUI_SCRIPT
      raw_digest=$RAW_XUI_SCRIPT_DIGEST
      raw_output_prefix=$RAW_XUI_OUTPUT_PREFIX
      ;;
    "$RAW_COMMIT_PREFIX"x-ui.rc|--url="$RAW_COMMIT_PREFIX"x-ui.rc)
      raw_requests=$((raw_requests + 1))
      raw_source=$RAW_XUI_RC
      raw_digest=$RAW_XUI_RC_DIGEST
      raw_output_prefix=$RAW_RC_OUTPUT_PREFIX
      ;;
    "$RAW_COMMIT_PREFIX"x-ui.service.debian|--url="$RAW_COMMIT_PREFIX"x-ui.service.debian)
      raw_requests=$((raw_requests + 1))
      raw_source=$RAW_SERVICE_DEBIAN
      raw_digest=$RAW_SERVICE_DEBIAN_DIGEST
      raw_output_prefix=$RAW_SERVICE_OUTPUT_PREFIX
      ;;
    "$RAW_COMMIT_PREFIX"x-ui.service.arch|--url="$RAW_COMMIT_PREFIX"x-ui.service.arch)
      raw_requests=$((raw_requests + 1))
      raw_source=$RAW_SERVICE_ARCH
      raw_digest=$RAW_SERVICE_ARCH_DIGEST
      raw_output_prefix=$RAW_SERVICE_OUTPUT_PREFIX
      ;;
    "$RAW_COMMIT_PREFIX"x-ui.service.rhel|--url="$RAW_COMMIT_PREFIX"x-ui.service.rhel)
      raw_requests=$((raw_requests + 1))
      raw_source=$RAW_SERVICE_RHEL
      raw_digest=$RAW_SERVICE_RHEL_DIGEST
      raw_output_prefix=$RAW_SERVICE_OUTPUT_PREFIX
      ;;
    *)
      argument_lower=$(printf '%s' "$argument" | tr '[:upper:]' '[:lower:]') || exit 1
      if [[ $argument_lower == *"$raw_repository_prefix_lower"* ]]; then
        printf '%s\n' 'one-key-proxy curl wrapper: 拒绝非 allowlist 的官方 raw URL' >&2
        exit 65
      fi
      ;;
  esac
  case $argument in
    "$ASSET_URL"|--url="$ASSET_URL") asset_requests=$((asset_requests + 1)) ;;
  esac
  rewritten+=("$argument")
done
[[ $expect_output == false ]] || {
  printf '%s\n' 'one-key-proxy curl wrapper: --output 缺少目标路径' >&2
  exit 64
}

if ((asset_requests != 0)); then
  ((asset_requests == 1 && raw_requests == 0 && output_count == 1)) || {
    printf '%s\n' 'one-key-proxy curl wrapper: release 资产 URL 出现次数异常' >&2
    exit 64
  }
  [[ $output == "$EXPECTED_OUTPUT" ]] || {
    printf '%s\n' 'one-key-proxy curl wrapper: release 资产输出路径与固定目标不一致' >&2
    exit 64
  }
  copy_verified_file "$VERIFIED_ASSET" "$EXPECTED_DIGEST" "$EXPECTED_OUTPUT" || {
    copy_status=$?
    printf '%s\n' 'one-key-proxy curl wrapper: 无法复制已验证 release 资产' >&2
    exit "$copy_status"
  }
  exit 0
fi

if ((raw_requests != 0)); then
  ((raw_requests == 1 && output_count == 1)) || {
    printf '%s\n' 'one-key-proxy curl wrapper: raw helper 请求或输出次数异常' >&2
    exit 64
  }
  matches_numbered_output "$output" "$raw_output_prefix" || {
    printf '%s\n' 'one-key-proxy curl wrapper: raw helper 输出路径与 allowlist 不一致' >&2
    exit 64
  }
  copy_verified_file "$raw_source" "$raw_digest" "$output" || {
    copy_status=$?
    printf '%s\n' 'one-key-proxy curl wrapper: 无法复制固定 commit 的 raw helper' >&2
    exit "$copy_status"
  }
  exit 0
fi

if [[ $output == "$EXPECTED_OUTPUT" ]] ||
  matches_numbered_output "$output" "$RAW_XUI_OUTPUT_PREFIX" ||
  matches_numbered_output "$output" "$RAW_RC_OUTPUT_PREFIX" ||
  matches_numbered_output "$output" "$RAW_SERVICE_OUTPUT_PREFIX"; then
  printf '%s\n' 'one-key-proxy curl wrapper: 拒绝非 allowlist URL 覆盖受保护输出' >&2
  exit 65
fi

# These options are deliberately last (except --disable, which curl requires
# first) so options in the pinned upstream script cannot relax transport rules.
exec "$REAL_CURL" --disable "${rewritten[@]}" \
  --noproxy '*' --proto '=https' --proto-redir '=https' --tlsv1.2
OKP_XUI_CURL_WRAPPER
  } >"$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  chmod 0700 "$temporary" || {
    rm -f -- "$temporary"
    return 1
  }
  mv -f -- "$temporary" "$destination"
}

# Predownload the release archive and finite raw-helper set, then create a
# private curl adapter. Optional output arguments are used by isolated tests.
okp_prepare_pinned_xui_download() {
  local repository=$1 tag=$2 commit=$3 architecture=$4 expected_digest=$5 workdir=$6
  local asset_name asset_url expected_output=${7:-} raw_output_test_dir=${8-}
  local real_curl download_temp verified_asset bin_dir wrapper actual_digest previous_umask
  local raw_cache_dir raw_name raw_url raw_download

  OKP_XUI_PINNED_BIN_DIR=''
  OKP_XUI_PINNED_CURL=''
  OKP_XUI_VERIFIED_ASSET=''
  OKP_XUI_VERIFIED_RAW_DIR=''
  OKP_XUI_PINNED_ASSET_URL=''

  _okp_xui_validate_release_identity "$repository" "$tag" "$commit" "$architecture" || {
    log_error '无法为无效的 3x-ui release 标识创建固定下载环境。'
    return 1
  }
  expected_digest=${expected_digest,,}
  [[ $expected_digest =~ ^[0-9a-f]{64}$ ]] || {
    log_error '3x-ui release 资产 SHA-256 摘要无效。'
    return 1
  }
  [[ $workdir == /* && $workdir != / && -d $workdir && ! -L $workdir ]] || {
    log_error '3x-ui 固定下载工作目录不安全。'
    return 1
  }
  [[ -z $(find "$workdir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]] || {
    log_error '3x-ui 固定下载工作目录必须为空。'
    return 1
  }

  asset_name="x-ui-linux-${architecture}.tar.gz"
  asset_url="https://github.com/${repository}/releases/download/${tag}/${asset_name}"
  expected_output=${expected_output:-/usr/local/${asset_name}}
  [[ $expected_output == /* && ${expected_output##*/} == "$asset_name" &&
    -d ${expected_output%/*} && ! -L ${expected_output%/*} ]] || {
    log_error '3x-ui release 资产固定输出路径无效。'
    return 1
  }
  if [[ -n $raw_output_test_dir &&
    ( $raw_output_test_dir != /* || ! -d $raw_output_test_dir || -L $raw_output_test_dir ) ]]; then
    log_error '3x-ui raw helper 测试输出目录无效。'
    return 1
  fi
  real_curl=$(type -P curl 2>/dev/null || true)
  [[ $real_curl == /* && -x $real_curl ]] || {
    log_error '缺少可信的 curl 可执行文件。'
    return 1
  }

  previous_umask=$(umask)
  umask 077
  chmod 0700 "$workdir" || {
    umask "$previous_umask"
    return 1
  }
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    chown 0:0 "$workdir" || {
      umask "$previous_umask"
      return 1
    }
  fi
  bin_dir="${workdir}/bin"
  mkdir -- "$bin_dir" || {
    umask "$previous_umask"
    return 1
  }
  chmod 0700 "$bin_dir" || {
    umask "$previous_umask"
    return 1
  }
  verified_asset="${workdir}/${asset_name}.verified"
  download_temp="${workdir}/${asset_name}.download"
  wrapper="${bin_dir}/curl"

  if ! "$real_curl" --disable --noproxy '*' --fail --location --silent --show-error \
    --retry 3 --connect-timeout 10 --max-time 180 \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$download_temp" "$asset_url"; then
    rm -f -- "$download_temp"
    umask "$previous_umask"
    log_error '3x-ui release 资产预下载失败。'
    return 1
  fi
  [[ -s $download_temp && -f $download_temp && ! -L $download_temp ]] || {
    rm -f -- "$download_temp"
    umask "$previous_umask"
    log_error '3x-ui release 资产下载结果不是非空常规文件。'
    return 1
  }
  actual_digest=$(_okp_xui_sha256_file "$download_temp") || {
    rm -f -- "$download_temp"
    umask "$previous_umask"
    return 1
  }
  if [[ $actual_digest != "$expected_digest" ]]; then
    rm -f -- "$download_temp"
    umask "$previous_umask"
    log_error '3x-ui release 资产 SHA-256 校验失败。'
    return 1
  fi
  mv -- "$download_temp" "$verified_asset" || {
    umask "$previous_umask"
    return 1
  }
  chmod 0600 "$verified_asset" || {
    umask "$previous_umask"
    return 1
  }
  raw_cache_dir="${workdir}/raw"
  mkdir -- "$raw_cache_dir" || {
    umask "$previous_umask"
    return 1
  }
  chmod 0700 "$raw_cache_dir" || {
    umask "$previous_umask"
    return 1
  }
  for raw_name in x-ui.sh x-ui.rc x-ui.service.debian x-ui.service.arch x-ui.service.rhel; do
    raw_url="https://raw.githubusercontent.com/${repository}/${commit}/${raw_name}"
    raw_download="${raw_cache_dir}/.${raw_name}.download"
    if ! "$real_curl" --disable --noproxy '*' --fail --location --silent --show-error \
      --retry 3 --connect-timeout 10 --max-time 60 \
      --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --output "$raw_download" "$raw_url"; then
      rm -f -- "$raw_download"
      umask "$previous_umask"
      log_error "3x-ui 固定 commit 的 raw helper 下载失败：${raw_name}。"
      return 1
    fi
    [[ -s $raw_download && -f $raw_download && ! -L $raw_download ]] || {
      rm -f -- "$raw_download"
      umask "$previous_umask"
      log_error "3x-ui 固定 commit 的 raw helper 无效：${raw_name}。"
      return 1
    }
    mv -- "$raw_download" "${raw_cache_dir}/${raw_name}" || {
      umask "$previous_umask"
      return 1
    }
    chmod 0600 "${raw_cache_dir}/${raw_name}" || {
      umask "$previous_umask"
      return 1
    }
  done
  _okp_xui_write_curl_wrapper "$wrapper" "$real_curl" "$asset_url" \
    "$verified_asset" "$expected_digest" \
    "https://raw.githubusercontent.com/${repository}/main/" \
    "https://raw.githubusercontent.com/${repository}/${commit}/" \
    "$expected_output" "$raw_output_test_dir" || {
    umask "$previous_umask"
    return 1
  }
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    chown -R 0:0 "$workdir" || {
      umask "$previous_umask"
      return 1
    }
  fi
  umask "$previous_umask"

  OKP_XUI_PINNED_BIN_DIR=$bin_dir
  OKP_XUI_PINNED_CURL=$wrapper
  OKP_XUI_VERIFIED_ASSET=$verified_asset
  OKP_XUI_VERIFIED_RAW_DIR=$raw_cache_dir
  OKP_XUI_PINNED_ASSET_URL=$asset_url
}

trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

has_control_chars() {
  [[ ${1-} =~ [[:cntrl:]] ]]
}

read_tty() {
  local __var=$1
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
  printf -v "$__var" '%s' "$value"
}

read_secret_tty() {
  local __var=$1
  local prompt=$2
  local value
  printf '%s: ' "$prompt" >/dev/tty
  IFS= read -r -s value </dev/tty || return 1
  printf '\n' >/dev/tty
  printf -v "$__var" '%s' "$value"
}

confirm() {
  local prompt=$1
  local default=${2:-n}
  local suffix='[y/N]'
  local answer
  [[ $default == y ]] && suffix='[Y/n]'
  printf '%s %s ' "$prompt" "$suffix" >/dev/tty
  IFS= read -r answer </dev/tty || return 1
  answer=${answer:-$default}
  [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]]
}

confirm_phrase() {
  local prompt=$1
  local phrase=$2
  local answer
  printf '%s\n请输入 %s 以继续: ' "$prompt" "$phrase" >/dev/tty
  IFS= read -r answer </dev/tty || return 1
  [[ $answer == "$phrase" ]]
}

random_hex() {
  local bytes=${1:-16}
  local value
  [[ $bytes =~ ^[1-9][0-9]{0,2}$ ]] || return 1
  if have_command openssl; then
    value=$(openssl rand -hex "$bytes") || return 1
  else
    value=$(od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n') || return 1
  fi
  [[ $value =~ ^[0-9a-fA-F]+$ ]] && ((${#value} == bytes * 2)) || return 1
  printf '%s' "${value,,}"
}

random_alnum() {
  local length=${1:-24}
  local value
  value=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length") || true
  ((${#value} == length)) || return 1
  printf '%s' "$value"
}

valid_port() {
  [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535))
}

valid_ipv4() {
  local ip=$1
  local a b c d extra
  IFS=. read -r a b c d extra <<<"$ip"
  [[ -z ${extra:-} && $a =~ ^(0|[1-9][0-9]{0,2})$ && $b =~ ^(0|[1-9][0-9]{0,2})$ && $c =~ ^(0|[1-9][0-9]{0,2})$ && $d =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
  ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255))
}

valid_global_ipv6() {
  local address=${1,,} left right part
  local -a groups=()
  [[ -n $address && $address == *:* && $address != *[^0-9a-f:]* ]] || return 1
  case $address in
    ::|::1|fe8*|fe9*|fea*|feb*|fc*|fd*) return 1 ;;
  esac
  if [[ $address == *::* ]]; then
    left=${address%%::*}
    right=${address#*::}
    [[ $right != *::* ]] || return 1
    [[ -z $left ]] || {
      IFS=: read -r -a groups <<<"$left"
      for part in "${groups[@]}"; do [[ $part =~ ^[0-9a-f]{1,4}$ ]] || return 1; done
    }
    local left_count=${#groups[@]}
    groups=()
    [[ -z $right ]] || {
      IFS=: read -r -a groups <<<"$right"
      for part in "${groups[@]}"; do [[ $part =~ ^[0-9a-f]{1,4}$ ]] || return 1; done
    }
    ((left_count + ${#groups[@]} < 8))
    return
  fi
  IFS=: read -r -a groups <<<"$address"
  ((${#groups[@]} == 8)) || return 1
  for part in "${groups[@]}"; do [[ $part =~ ^[0-9a-f]{1,4}$ ]] || return 1; done
}

valid_hostname() {
  local host=${1%.}
  [[ ${#host} -le 253 ]] || return 1
  [[ $host =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

mask_secret() {
  local value=${1-}
  if ((${#value} <= 8)); then
    printf '********'
  else
    printf '%s****%s' "${value:0:4}" "${value: -4}"
  fi
}

mask_secret_tail() {
  local value=${1-}
  if ((${#value} <= 4)); then
    printf '********'
  else
    printf '********%s' "${value: -4}"
  fi
}

run_quiet() {
  local label=$1
  shift
  local output_file
  output_file=$(mktemp)
  if "$@" >"$output_file" 2>&1; then
    rm -f "$output_file"
    return 0
  fi
  log_error "$label"
  if declare -F redact_sensitive >/dev/null 2>&1; then
    redact_sensitive "$(<"$output_file")" >&2
    printf '\n' >&2
  else
    sed -E \
      -e 's/(password|secret|token|privateKey|Ali_Secret)(["=: ]+)[^ ,"}]+/\1\2[REDACTED]/Ig' \
      "$output_file" >&2
  fi
  rm -f "$output_file"
  return 1
}

safe_mkdirs() {
  local previous_umask path
  for path in "$CONFIG_DIR" "$CERT_DIR" "$BACKUP_DIR" "$LOG_FILE"; do
    [[ ! -L $path ]] || { log_error "拒绝使用符号链接路径：${path}"; return 1; }
  done
  previous_umask=$(umask)
  umask 077
  mkdir -p "$CONFIG_DIR" "$CERT_DIR" "$BACKUP_DIR" "${LOG_FILE%/*}" || { umask "$previous_umask"; return 1; }
  chmod 700 "$CONFIG_DIR" "$CERT_DIR" "$BACKUP_DIR" || { umask "$previous_umask"; return 1; }
  touch "$LOG_FILE" || { umask "$previous_umask"; return 1; }
  chmod 600 "$LOG_FILE" || { umask "$previous_umask"; return 1; }
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    chown root:root "$CONFIG_DIR" "$CERT_DIR" "$BACKUP_DIR" "$LOG_FILE" || { umask "$previous_umask"; return 1; }
  fi
  umask "$previous_umask"
}
