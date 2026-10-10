#!/usr/bin/env bash
# Public output variables are intentionally assigned for installer callers.
# shellcheck disable=SC2034

# 3x-ui v3.x Admin API helpers. This library deliberately never reads or
# writes x-ui.db; every operation goes through the documented Bearer API.

if [[ ${OKP_PRODUCTION_MODE:-false} == true ]]; then
    XUI_INSTALL_RESULT_FILE=/etc/x-ui/install-result.env
    XUI_MANAGED_REMARK=one-key-proxy-vless-reality
    XUI_MANAGED_TAG=one-key-proxy-vless-reality
    XUI_MANAGED_HOST_REMARK=one-key-proxy-public-endpoint
    XUI_MANAGED_HOST_TAG=one-key-proxy
else
    XUI_INSTALL_RESULT_FILE=${XUI_INSTALL_RESULT_FILE:-/etc/x-ui/install-result.env}
    XUI_MANAGED_REMARK=${XUI_MANAGED_REMARK:-one-key-proxy-vless-reality}
    XUI_MANAGED_TAG=${XUI_MANAGED_TAG:-one-key-proxy-vless-reality}
    XUI_MANAGED_HOST_REMARK=${XUI_MANAGED_HOST_REMARK:-one-key-proxy-public-endpoint}
    XUI_MANAGED_HOST_TAG=${XUI_MANAGED_HOST_TAG:-one-key-proxy}
fi

_xui_sanitize_log_message() {
    local input=${1-} output='' char next
    local i=0 length=${#input}

    # Strip terminal escape sequences before removing standalone controls, so
    # an attacker cannot leave visible fragments such as "[31m" in the log.
    while ((i < length)); do
        char=${input:i:1}
        if [[ $char == $'\033' ]]; then
            ((i += 1))
            ((i < length)) || break
            next=${input:i:1}
            if [[ $next == '[' ]]; then
                # ECMA-48 CSI: consume through its final byte (0x40-0x7e).
                ((i += 1))
                while ((i < length)); do
                    char=${input:i:1}
                    ((i += 1))
                    [[ $char == [@-~] ]] && break
                done
                continue
            fi
            if [[ $next == ']' ]]; then
                # OSC: consume through BEL or the ESC + backslash terminator.
                ((i += 1))
                while ((i < length)); do
                    char=${input:i:1}
                    if [[ $char == $'\a' ]]; then
                        ((i += 1))
                        break
                    fi
                    if [[ $char == $'\033' && ${input:i+1:1} == '\' ]]; then
                        ((i += 2))
                        break
                    fi
                    ((i += 1))
                done
                continue
            fi
            # Other two-byte ESC sequences are removed as a unit.
            ((i += 1))
            continue
        fi
        case $char in
            $'\n'|$'\r'|$'\t') output+=' ' ;;
            [[:cntrl:]]) ;;
            *) output+=$char ;;
        esac
        ((i += 1))
    done
    printf '%s' "$output"
}

_xui_error() {
    local message
    message=$(_xui_sanitize_log_message "$*")
    if declare -F safe_log_error > /dev/null 2>&1; then
        safe_log_error "$message"
        return
    fi
    if declare -F redact_sensitive > /dev/null 2>&1; then
        message=$(redact_sensitive "$message")
    fi
    if declare -F log_error > /dev/null 2>&1; then
        log_error "$message"
    else
        printf 'ERROR: %s\n' "$message" >&2
    fi
}

_xui_state_get() {
    local value
    [[ $# -eq 1 ]] || return 2
    if ! declare -F state_get > /dev/null 2>&1; then
        return 1
    fi
    if ! value=$(state_get "$1" 2> /dev/null); then
        return 1
    fi
    [[ -n "$value" ]] || return 1
    printf '%s' "$value"
}

_xui_token_value_valid() {
    [[ $# -eq 1 && -n $1 ]] || return 1
    case $1 in
        *[[:cntrl:]]*|*'"'*|*'\'*) return 1 ;;
    esac
}

_xui_percent_encoding_valid() {
    [[ $# -eq 1 ]] || return 1
    local value=$1 suffix hex

    while [[ $value == *%* ]]; do
        suffix=${value#*%}
        ((${#suffix} >= 2)) || return 1
        hex=${suffix:0:2}
        [[ $hex =~ ^[A-Fa-f0-9]{2}$ ]] || return 1
        hex=${hex^^}
        case $hex in
            0[0-9A-F]|1[0-9A-F]|7F) return 1 ;;
        esac
        value=${suffix:2}
    done
}

_xui_api_path_valid() {
    [[ $# -eq 1 ]] || return 1
    local value=$1 route query='' pair key component remainder upper_route

    if [[ $value == *'?'* ]]; then
        route=${value%%\?*}
        query=${value#*\?}
        [[ -n $query && $query != *'?'* ]] || return 1
    else
        route=$value
    fi
    [[ $route =~ ^/panel/api/[A-Za-z0-9._~:/@+%-]+$ ]] || return 1
    _xui_percent_encoding_valid "$route" || return 1
    upper_route=${route^^}
    case $route in
        *'//'*|*'/./'*|*'/../'*|*/.|*/..) return 1 ;;
    esac
    # Encoded delimiters or dots could be normalized into another route by a
    # proxy/router. API path segments must use their literal safe form instead.
    case $upper_route in
        *%2F*|*%5C*|*%2E*|*%3F*|*%23*) return 1 ;;
    esac
    [[ -n $query ]] || return 0

    remainder=$query
    while :; do
        if [[ $remainder == *'&'* ]]; then
            pair=${remainder%%&*}
            remainder=${remainder#*&}
            [[ -n $remainder ]] || return 1
        else
            pair=$remainder
            remainder=''
        fi
        [[ -n $pair && $pair == *=* ]] || return 1
        key=${pair%%=*}
        component=${pair#*=}
        [[ $key =~ ^[A-Za-z0-9._~%-]+$ ]] || return 1
        [[ $component =~ ^[A-Za-z0-9._~%-]*$ ]] || return 1
        _xui_percent_encoding_valid "$key" || return 1
        _xui_percent_encoding_valid "$component" || return 1
        [[ -n $remainder ]] || break
    done
}

_xui_urlencode_query_component() (
    [[ $# -eq 1 ]] || exit 2
    local LC_ALL=C input=$1 output='' char encoded i
    [[ $input != *[[:cntrl:]]* ]] || exit 2
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        case $char in
            [A-Za-z0-9._~-]) output+=$char ;;
            *)
                printf -v encoded '%02X' "'$char"
                output+="%$encoded"
                ;;
        esac
    done
    printf '%s' "$output"
)

_xui_build_api_query_path() {
    (($# >= 3 && $# % 2 == 1)) || return 2
    local path=$1 query='' key value encoded_key encoded_value
    shift
    # The base route itself may contain encoded path segments, but callers may
    # not smuggle an already assembled query around the component encoder.
    [[ $path != *'?'* ]] || return 2
    while (($#)); do
        key=$1
        value=$2
        shift 2
        [[ -n $key ]] || return 2
        encoded_key=$(_xui_urlencode_query_component "$key") || return 2
        encoded_value=$(_xui_urlencode_query_component "$value") || return 2
        [[ -z $query ]] || query+='&'
        query+="${encoded_key}=${encoded_value}"
    done
    _xui_api_path_valid "${path}?${query}" || return 2
    printf '%s' "${path}?${query}"
}

_xui_install_result_api_token() {
    local raw
    [[ $# -eq 0 && -r $XUI_INSTALL_RESULT_FILE ]] || return 1
    raw=$(sed -n 's/^XUI_API_TOKEN=//p' "$XUI_INSTALL_RESULT_FILE" | tail -n 1)
    raw=${raw#\'}
    raw=${raw%\'}
    raw=${raw#\"}
    raw=${raw%\"}
    [[ $raw =~ ^[A-Za-z0-9._-]{24,128}$ ]] || return 1
    printf '%s' "$raw"
}

# Resolve the certificate identity used for verified loopback HTTPS. During a
# certificate replacement, the normal MODE identity remains authoritative
# until the service has been restarted with the replacement certificate and
# the transition journal has been promoted to "active".
_xui_api_tls_identity_host() {
    [[ $# -eq 1 ]] || return 2
    local deployment_mode=$1 public_host='' transition_status='' transition_host=''

    case $deployment_mode in
        nat) public_host=$(_xui_state_get PUBLIC_IPV4) || return 1 ;;
        public) public_host=$(_xui_state_get FQDN) || return 1 ;;
        *)
            _xui_error 'Deployment mode is invalid for verified HTTPS API access'
            return 1
            ;;
    esac
    transition_status=$(_xui_state_get XUI_TLS_TRANSITION_STATUS) || transition_status=''
    transition_host=$(_xui_state_get XUI_TLS_TRANSITION_HOST) || transition_host=''
    if [[ -n $transition_status || -n $transition_host ]]; then
        [[ -n $transition_status && -n $transition_host ]] || {
            _xui_error 'TLS identity transition state is incomplete'
            return 1
        }
        case $transition_status in
            preparing) ;;
            active) public_host=$transition_host ;;
            *)
                _xui_error 'TLS identity transition state is invalid'
                return 1
                ;;
        esac
    fi
    printf '%s' "$public_host"
}

# Load the full-admin API token and build a loopback panel URL. State written
# by one-key-proxy wins; install-result.env is the authoritative fallback.
xui_load_api_context() {
    local token='' port='' scheme='' state_value='' raw='' file_token=''
    local deployment_mode='' public_host='' cert_file=''
    local inherited_port=''
    local inherited_token inherited_base

    if [[ ${OKP_PRODUCTION_MODE:-false} == true ]]; then
        inherited_token=${XUI_API_TOKEN_MEMORY:-}
        inherited_base=''
    else
        inherited_token=${XUI_API_TOKEN_MEMORY:-${XUI_API_TOKEN:-}}
        inherited_base=${XUI_API_BASE_URL:-}
    fi

    if state_value=$(_xui_state_get XUI_API_TOKEN); then
        token=$state_value
    elif [[ -n "$inherited_token" ]]; then
        token=$inherited_token
    fi
    if state_value=$(_xui_state_get PANEL_INTERNAL_PORT); then
        port=$state_value
    fi
    if state_value=$(_xui_state_get PANEL_SCHEME); then
        scheme=$state_value
    fi

    if [[ -r "$XUI_INSTALL_RESULT_FILE" ]]; then
        # Only accept the simple character sets these three official values use.
        # Never source a restored or damaged result file as shell code.
        if [[ -z $token ]] && file_token=$(_xui_install_result_api_token); then
            token=$file_token
        fi
        raw=$(sed -n 's/^XUI_PANEL_PORT=//p' "$XUI_INSTALL_RESULT_FILE" | tail -n 1)
        raw=${raw#\'}
        raw=${raw%\'}
        raw=${raw#\"}
        raw=${raw%\"}
        if [[ -z "$port" && $raw =~ ^[0-9]{1,5}$ ]]; then
            port=$raw
        fi
        if [[ -z "$scheme" ]]; then
            raw=$(sed -n 's/^XUI_ACCESS_URL=//p' "$XUI_INSTALL_RESULT_FILE" | tail -n 1)
            raw=${raw#\'}
            raw=${raw%\'}
            raw=${raw#\"}
            raw=${raw%\"}
            case $raw in
                https://*) scheme=https ;;
                http://*) scheme=http ;;
            esac
        fi
    fi

    if [[ -n "$inherited_base" ]]; then
        if [[ $inherited_base =~ ^https?://127\.0\.0\.1:([0-9]{1,5})/?$ ]]; then
            inherited_port=${BASH_REMATCH[1]}
        elif [[ $inherited_base =~ ^https?://\[::1\]:([0-9]{1,5})/?$ ]]; then
            inherited_port=${BASH_REMATCH[1]}
        else
            _xui_error 'XUI_API_BASE_URL must be an exact 127.0.0.1 or [::1] loopback URL with a port'
            return 1
        fi
        ((10#$inherited_port >= 1 && 10#$inherited_port <= 65535)) || {
            _xui_error 'XUI_API_BASE_URL contains an invalid port'
            return 1
        }
        inherited_base=${inherited_base%/}
    else
        if [[ ! $port =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
            _xui_error 'Unable to determine the internal 3x-ui panel port'
            return 1
        fi
        case $scheme in
            http|https) ;;
            '') scheme=http ;;
            *) _xui_error "Unsupported panel scheme: $scheme"; return 1 ;;
        esac
        inherited_base="${scheme}://127.0.0.1:${port}"
    fi

    [[ -n "$token" ]] || {
        _xui_error "3x-ui API token is missing from state and $XUI_INSTALL_RESULT_FILE"
        return 1
    }
    _xui_token_value_valid "$token" || {
        _xui_error '3x-ui API token contains unsupported characters'
        return 1
    }

    declare -g XUI_API_TOKEN_VALUE="$token"
    declare -g XUI_API_BASE_URL_VALUE="$inherited_base"
    declare -g XUI_API_TLS_HOST_VALUE=''
    declare -g XUI_API_TLS_CERT_VALUE=''
    declare -g XUI_API_TLS_PORT_VALUE=''
    if [[ ${OKP_PRODUCTION_MODE:-false} == true && $inherited_base == https://* ]]; then
        deployment_mode=$(_xui_state_get MODE) || {
            _xui_error 'Unable to determine deployment mode for verified HTTPS API access'
            return 1
        }
        public_host=$(_xui_api_tls_identity_host "$deployment_mode") || return 1
        if declare -F valid_ipv4 > /dev/null 2>&1 && [[ $deployment_mode == nat ]]; then
            valid_ipv4 "$public_host" || {
                _xui_error 'Public IPv4 is invalid for verified HTTPS API access'
                return 1
            }
        elif declare -F valid_hostname > /dev/null 2>&1 && [[ $deployment_mode == public ]]; then
            valid_hostname "$public_host" || {
                _xui_error 'Public hostname is invalid for verified HTTPS API access'
                return 1
            }
        else
            [[ $public_host =~ ^[A-Za-z0-9.-]+$ ]] || return 1
        fi
        cert_file=/etc/one-key-proxy/certs/server.crt
        [[ -f $cert_file && ! -L $cert_file && -r $cert_file ]] || {
            _xui_error 'Managed TLS certificate is unavailable for verified HTTPS API access'
            return 1
        }
        XUI_API_BASE_URL_VALUE="https://${public_host}:${port}"
        XUI_API_TLS_HOST_VALUE=$public_host
        XUI_API_TLS_CERT_VALUE=$cert_file
        XUI_API_TLS_PORT_VALUE=$port
    fi
}

_xui_api_request() (
    local method=$1 path=$2 body=${3-} token_override=${4-} encoding=${5:-json}
    local temp_dir config_file response_file body_file http_code response msg request_url
    local -a curl_args

    case $method in
        GET|POST) ;;
        *) _xui_error 'Unsupported 3x-ui API request method'; exit 2 ;;
    esac
    xui_load_api_context || exit 1
    if [[ -n $token_override ]]; then
        _xui_token_value_valid "$token_override" || {
            _xui_error 'Candidate 3x-ui API token contains unsupported characters'
            exit 1
        }
        XUI_API_TOKEN_VALUE=$token_override
    fi
    _xui_api_path_valid "$path" || {
        _xui_error 'Refusing an invalid or non-panel API path'
        exit 1
    }
    command -v curl > /dev/null 2>&1 || { _xui_error 'curl is required'; exit 1; }
    command -v jq > /dev/null 2>&1 || { _xui_error 'jq is required'; exit 1; }

    umask 077
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/one-key-proxy-api.XXXXXX") || exit 1
    config_file=$temp_dir/request.conf
    response_file=$temp_dir/response.json
    body_file=$temp_dir/request.json
    trap 'rm -f -- "$config_file" "$response_file" "$body_file"; rmdir -- "$temp_dir" 2> /dev/null || true' EXIT
    trap 'exit 1' HUP INT TERM

    request_url=${XUI_API_BASE_URL_VALUE}${path}
    # Both values have already been restricted to characters that cannot end a
    # curl quoted config value. Keeping the URL here also protects Sub IDs from
    # /proc/<pid>/cmdline disclosure.
    {
        printf 'header = "Authorization: Bearer %s"\n' "$XUI_API_TOKEN_VALUE"
        printf 'url = "%s"\n' "$request_url"
    } > "$config_file"
    curl_args=(
        --disable
        --silent --show-error
        --noproxy '*'
        --connect-timeout "${XUI_API_CONNECT_TIMEOUT:-5}"
        --max-time "${XUI_API_MAX_TIME:-30}"
        --config "$config_file"
        --header 'Accept: application/json'
        --request "$method"
        --output "$response_file"
        --write-out '%{http_code}'
    )
    if [[ $XUI_API_BASE_URL_VALUE == https://* ]]; then
        if [[ -n ${XUI_API_TLS_HOST_VALUE:-} && -n ${XUI_API_TLS_CERT_VALUE:-} ]]; then
            curl_args+=(
                --cacert "$XUI_API_TLS_CERT_VALUE"
                --resolve "${XUI_API_TLS_HOST_VALUE}:${XUI_API_TLS_PORT_VALUE}:127.0.0.1"
            )
        else
            # Injectable test contexts use an ephemeral loopback TLS endpoint.
            curl_args+=(--insecure)
        fi
    fi
    if [[ $method == POST ]]; then
        case $encoding in
            json)
                jq -e . > /dev/null 2>&1 <<< "$body" || {
                    _xui_error 'Refusing to send invalid JSON to 3x-ui'
                    exit 1
                }
                curl_args+=(--header 'Content-Type: application/json')
                ;;
            form)
                [[ $body != *[[:cntrl:]]* ]] || exit 1
                curl_args+=(--header 'Content-Type: application/x-www-form-urlencoded')
                ;;
            *) _xui_error 'Unsupported 3x-ui request encoding'; exit 1 ;;
        esac
        printf '%s' "$body" > "$body_file"
        curl_args+=(--data-binary "@$body_file")
    fi

    if ! http_code=$(curl "${curl_args[@]}"); then
        _xui_error "3x-ui API transport failed for a $method request"
        exit 1
    fi
    if [[ ! $http_code =~ ^2[0-9][0-9]$ ]]; then
        _xui_error "3x-ui API returned HTTP $http_code for a $method request"
        exit 1
    fi
    if ! jq -e 'type == "object" and (.success | type == "boolean")' "$response_file" > /dev/null 2>&1; then
        _xui_error "3x-ui returned an invalid API envelope for a $method request"
        exit 1
    fi
    if ! jq -e '.success == true' "$response_file" > /dev/null 2>&1; then
        msg=$(jq -r '.msg // "unknown API error"' "$response_file" | tr '\r\n' ' ' | cut -c 1-400)
        _xui_error "3x-ui rejected a $method request: $msg"
        exit 1
    fi
    response=$(jq -c '.obj // null' "$response_file") || exit 1
    printf '%s\n' "$response"
)

xui_api_get() {
    [[ $# -eq 1 ]] || { _xui_error 'Usage: xui_api_get /panel/api/path'; return 2; }
    _xui_api_request GET "$1"
}

xui_api_post() {
    local body='{}'
    [[ $# -ge 1 && $# -le 2 ]] || {
        _xui_error 'Usage: xui_api_post /panel/api/path [json]'
        return 2
    }
    if [[ $# -eq 2 ]]; then
        body=$2
    fi
    _xui_api_request POST "$1" "$body"
}

# Query values are encoded component-by-component and the resulting URL remains
# in the protected curl config. Args are: path key value [key value ...].
xui_api_get_with_query() {
    local target
    (($# >= 3 && $# % 2 == 1)) || return 2
    target=$(_xui_build_api_query_path "$@") || return 2
    _xui_api_request GET "$target"
}

# Args are: path json-body key value [key value ...].
xui_api_post_with_query() {
    local path body target
    (($# >= 4 && $# % 2 == 0)) || return 2
    path=$1
    body=$2
    shift 2
    target=$(_xui_build_api_query_path "$path" "$@") || return 2
    _xui_api_request POST "$target" "$body"
}

# Compatibility names requested by the project design.
api_get() { xui_api_get "$@"; }
api_post() { xui_api_post "$@"; }

_xui_normalize_token_name() {
    local value=${1-}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}

# API token metadata is safe to retain: v3.6 never includes plaintext in the
# list response. del(.token) is an extra guard for an unexpected older build.
xui_api_tokens_read() {
    local rows
    [[ $# -eq 0 ]] || return 2
    rows=$(xui_api_get /panel/api/setting/apiTokens) || return 1
    jq -e 'type == "array" and all(.[];
        (.id | type == "number") and (.name | type == "string") and
        (.enabled | type == "boolean"))' > /dev/null 2>&1 <<< "$rows" || {
        _xui_error '3x-ui API token list has an incompatible shape'
        return 1
    }
    rows=$(jq -c 'map(del(.token))' <<< "$rows") || return 1
    declare -g XUI_API_TOKENS_JSON="$rows"
}

# Returns 1 when absent and sets only non-secret metadata when found.
xui_find_api_token_by_name() {
    local name matches count
    [[ $# -eq 1 ]] || return 2
    name=$(_xui_normalize_token_name "$1")
    [[ -n $name ]] || return 2
    xui_api_tokens_read || return 2
    matches=$(jq -c --arg name "$name" '[.[] | select(.name == $name)]' \
        <<< "$XUI_API_TOKENS_JSON") || return 2
    count=$(jq 'length' <<< "$matches") || return 2
    ((count > 0)) || return 1
    if ((count != 1)); then
        _xui_error "Multiple API tokens have the same name: $name"
        return 2
    fi
    declare -g XUI_FOUND_API_TOKEN_ID XUI_FOUND_API_TOKEN_NAME XUI_FOUND_API_TOKEN_ENABLED
    XUI_FOUND_API_TOKEN_ID=$(jq -r '.[0].id' <<< "$matches")
    XUI_FOUND_API_TOKEN_NAME=$(jq -r '.[0].name' <<< "$matches")
    XUI_FOUND_API_TOKEN_ENABLED=$(jq -r '.[0].enabled' <<< "$matches")
}

# Authenticate with a candidate token without changing persistent state. When
# an expected ID/name is provided, also require that row to be enabled.
xui_validate_api_token() {
    [[ $# -ge 1 && $# -le 3 ]] || return 2
    local candidate=$1 expected_id=${2-} expected_name=${3-} rows matched
    _xui_token_value_valid "$candidate" || return 2
    if [[ -n $expected_id && ! $expected_id =~ ^[1-9][0-9]*$ ]]; then
        return 2
    fi
    rows=$(_xui_api_request GET /panel/api/setting/apiTokens '' "$candidate") || return 1
    jq -e 'type == "array"' > /dev/null 2>&1 <<< "$rows" || return 1
    if [[ -n $expected_id ]]; then
        if [[ -n $expected_name ]]; then
            matched=$(jq -r --argjson id "$expected_id" --arg name "$expected_name" '
                any(.[]; .id == $id and .name == $name and .enabled == true)
            ' <<< "$rows") || return 1
        else
            matched=$(jq -r --argjson id "$expected_id" '
                any(.[]; .id == $id and .enabled == true)
            ' <<< "$rows") || return 1
        fi
        [[ $matched == true ]] || {
            _xui_error 'Candidate API token authenticated, but its expected enabled row was not found'
            return 1
        }
    fi
    declare -g XUI_VALIDATED_API_TOKEN_ID="$expected_id"
    declare -g XUI_VALIDATED_API_TOKEN_NAME="$expected_name"
}

# Create a dedicated admin token; v3.7 adds scopes while v3.6 ignores the field.
# Plaintext is returned once and retained only in the secret global.
xui_create_api_token() {
    local name payload created id returned_name token enabled LC_ALL=C
    [[ $# -eq 1 ]] || return 2
    name=$(_xui_normalize_token_name "$1")
    [[ -n $name && ${#name} -le 64 && $name != *$'\n'* && $name != *$'\r'* ]] || {
        _xui_error 'API token name must contain 1-64 characters on one line'
        return 2
    }
    payload=$(jq -nc --arg name "$name" '{name: $name, scope: "admin"}') || return 1
    created=$(xui_api_post /panel/api/setting/apiTokens/create "$payload") || return 1
    id=$(jq -r '.id // empty' <<< "$created")
    returned_name=$(jq -r '.name // empty' <<< "$created")
    token=$(jq -r '.token // empty' <<< "$created")
    enabled=$(jq -r '.enabled // false' <<< "$created")
    [[ $id =~ ^[1-9][0-9]*$ && $returned_name == "$name" && $enabled == true ]] || {
        _xui_error '3x-ui returned incompatible API token metadata'
        return 1
    }
    _xui_token_value_valid "$token" || {
        _xui_error '3x-ui did not return a usable one-time API token value'
        return 1
    }

    declare -g XUI_CREATED_API_TOKEN_ID="$id"
    declare -g XUI_CREATED_API_TOKEN_NAME="$returned_name"
    declare -g XUI_CREATED_API_TOKEN_VALUE="$token"
    if declare -F secret_register > /dev/null 2>&1; then
        secret_register "$token"
    fi
    if ! xui_validate_api_token "$token" "$id" "$returned_name"; then
        # The installer token is still active here, so roll back the unusable
        # row and leave the current authentication context untouched.
        if ! xui_api_post "/panel/api/setting/apiTokens/delete/$id" '{"expectedScope":"admin"}' > /dev/null; then
            if declare -F log_warn > /dev/null 2>&1; then
                log_warn "无法清理验证失败的 API Token 行 ID=$id"
            fi
        fi
        XUI_CREATED_API_TOKEN_VALUE=''
        return 1
    fi
}

_xui_clear_pending_api_token_state() {
    [[ $# -eq 0 ]] || return 2
    if declare -F state_unset_many > /dev/null 2>&1; then
        state_unset_many \
            XUI_PENDING_API_TOKEN_NAME \
            XUI_PENDING_API_TOKEN_OLD_ID \
            XUI_PENDING_API_TOKEN_OLD_NAME
    elif declare -F state_unset > /dev/null 2>&1; then
        _xui_error 'state_unset_many is required for atomic API token recovery cleanup'
        return 1
    fi
}

# Validate, persist, then activate a candidate token. Keeping persistence ahead
# of old-token deletion makes interruption fail open with two valid tokens.
xui_switch_api_token_context() {
    [[ $# -eq 3 ]] || return 2
    local candidate=$1 id=$2 name=$3
    local persisted_token persisted_id persisted_name pending_name='' pending_old_id=''
    [[ $id =~ ^[1-9][0-9]*$ ]] || return 2
    xui_validate_api_token "$candidate" "$id" "$name" || return 1
    if declare -F state_set_many > /dev/null 2>&1; then
        # One lock, one replacement file and one rename: a crash can expose
        # either the previous complete credential tuple or this complete tuple,
        # never a token paired with stale/absent ownership metadata.
        state_set_many \
            XUI_API_TOKEN "$candidate" \
            XUI_API_TOKEN_ID "$id" \
            XUI_API_TOKEN_NAME "$name" || return 1
        persisted_token=$(_xui_state_get XUI_API_TOKEN) || return 1
        persisted_id=$(_xui_state_get XUI_API_TOKEN_ID) || return 1
        persisted_name=$(_xui_state_get XUI_API_TOKEN_NAME) || return 1
        [[ $persisted_token == "$candidate" && $persisted_id == "$id" &&
            $persisted_name == "$name" ]] || {
            _xui_error 'Atomic API token state readback did not match the validated credential'
            return 1
        }
        if pending_name=$(_xui_state_get XUI_PENDING_API_TOKEN_NAME) &&
            [[ $pending_name == "$name" ]] &&
            ! pending_old_id=$(_xui_state_get XUI_PENDING_API_TOKEN_OLD_ID); then
            # Initial installation has no previous managed token to revoke.
            # Clearing this journal after the atomic tuple write is idempotent;
            # a crash before here is finalized by the recovery helper.
            _xui_clear_pending_api_token_state || return 1
        fi
    elif declare -F state_set > /dev/null 2>&1; then
        _xui_error 'state_set_many is required for atomic API token persistence'
        return 1
    fi
    declare -g XUI_API_TOKEN_MEMORY="$candidate"
    declare -g XUI_API_TOKEN_VALUE="$candidate"
    declare -g XUI_CURRENT_API_TOKEN_ID="$id"
    declare -g XUI_CURRENT_API_TOKEN_NAME="$name"
    if declare -F secret_register > /dev/null 2>&1; then
        secret_register "$candidate"
    fi
    # Re-read through the normal state/global resolution path before allowing
    # callers to revoke the previous credential.
    xui_api_tokens_read || return 1
}

# Permanently delete an explicitly identified old token. Refuse deletion until
# the currently active token ID is known, and never delete that current ID.
# Optional expected-name binds the deletion to both immutable row properties.
xui_delete_api_token_by_id() {
    [[ $# -ge 1 && $# -le 2 ]] || return 2
    local id=$1 expected_name=${2-} current_id='' rows target count name remaining
    [[ $id =~ ^[1-9][0-9]*$ ]] || return 2
    if [[ -n $expected_name ]]; then
        [[ ${#expected_name} -le 64 && $expected_name != *$'\n'* && $expected_name != *$'\r'* ]] || return 2
    fi
    if current_id=$(_xui_state_get XUI_API_TOKEN_ID); then
        :
    elif [[ -n ${XUI_CURRENT_API_TOKEN_ID:-} ]]; then
        current_id=$XUI_CURRENT_API_TOKEN_ID
    fi
    [[ $current_id =~ ^[1-9][0-9]*$ ]] || {
        _xui_error 'Current API token ID is unknown; switch context before deleting any token'
        return 1
    }
    [[ $id != "$current_id" ]] || {
        _xui_error 'Refusing to delete the currently active API token'
        return 1
    }

    xui_api_tokens_read || return 1
    rows=$XUI_API_TOKENS_JSON
    target=$(jq -c --argjson id "$id" '[.[] | select(.id == $id)]' <<< "$rows") || return 1
    count=$(jq 'length' <<< "$target") || return 1
    if ((count == 0)); then
        declare -g XUI_DELETED_API_TOKEN_ID="$id"
        declare -g XUI_DELETED_API_TOKEN_NAME="$expected_name"
        return 0
    fi
    if ((count != 1)); then
        _xui_error "API token ID=$id did not resolve to exactly one row"
        return 1
    fi
    name=$(jq -r '.[0].name' <<< "$target")
    if [[ -n $expected_name && $name != "$expected_name" ]]; then
        _xui_error "API token ID=$id does not match the expected name"
        return 1
    fi
    xui_api_post "/panel/api/setting/apiTokens/delete/$id" '{"expectedScope":"admin"}' > /dev/null || return 1
    xui_api_tokens_read || return 1
    remaining=$(jq -r --argjson id "$id" 'any(.[]; .id == $id)' <<< "$XUI_API_TOKENS_JSON") || return 1
    [[ $remaining == false ]] || {
        _xui_error "3x-ui reported success but API token ID=$id still exists"
        return 1
    }
    declare -g XUI_DELETED_API_TOKEN_ID="$id"
    declare -g XUI_DELETED_API_TOKEN_NAME="$name"
}

xui_delete_api_token() {
    xui_delete_api_token_by_id "$@"
}

# Recover either side of an interrupted create/switch/delete sequence. The only
# selector is the exact managed name already persisted before token creation.
xui_recover_pending_api_token() {
    [[ $# -eq 0 ]] || return 2
    local pending_name='' old_id='' old_name=''
    local current_token='' current_id='' current_name=''
    local installer_token selected_token matches count candidate_id remaining

    if ! pending_name=$(_xui_state_get XUI_PENDING_API_TOKEN_NAME); then
        declare -g XUI_RECOVERED_API_TOKEN_ACTION=none
        return 0
    fi
    [[ $pending_name == one-key-proxy-* && $pending_name != one-key-proxy- &&
        ${#pending_name} -le 64 && $pending_name != *[[:cntrl:]]* ]] || {
        _xui_error 'Pending API token name is outside the managed one-key-proxy namespace'
        return 1
    }
    old_id=$(_xui_state_get XUI_PENDING_API_TOKEN_OLD_ID) || old_id=''
    old_name=$(_xui_state_get XUI_PENDING_API_TOKEN_OLD_NAME) || old_name=''
    if [[ -n $old_id || -n $old_name ]]; then
        [[ $old_id =~ ^[1-9][0-9]*$ && -n $old_name && $old_name != *[[:cntrl:]]* ]] || {
            _xui_error 'Pending API token rotation metadata is incomplete or invalid'
            return 1
        }
    fi

    current_token=$(_xui_state_get XUI_API_TOKEN) || current_token=''
    current_id=$(_xui_state_get XUI_API_TOKEN_ID) || current_id=''
    current_name=$(_xui_state_get XUI_API_TOKEN_NAME) || current_name=''
    if [[ -n $current_id || -n $current_name ]]; then
        [[ -n $current_token && $current_id =~ ^[1-9][0-9]*$ &&
            -n $current_name && $current_name != *[[:cntrl:]]* ]] || {
            _xui_error 'Current API token state is a partial credential tuple'
            return 1
        }
        xui_validate_api_token "$current_token" "$current_id" "$current_name" || return 1

        if [[ $current_name == "$pending_name" ]]; then
            if [[ -n $old_id ]]; then
                [[ $old_id != "$current_id" ]] || {
                    _xui_error 'Pending rotation identifies the current API token as its predecessor'
                    return 1
                }
                xui_delete_api_token_by_id "$old_id" "$old_name" || return 1
                declare -g XUI_RECOVERED_API_TOKEN_ACTION=completed-rotation
            else
                declare -g XUI_RECOVERED_API_TOKEN_ACTION=finalized-switch
            fi
            _xui_clear_pending_api_token_state || return 1
            return 0
        fi
        if [[ -n $old_id && ($current_id != "$old_id" || $current_name != "$old_name") ]]; then
            _xui_error 'Pending rotation predecessor does not match the current API token tuple'
            return 1
        fi

        xui_api_tokens_read || return 1
        matches=$(jq -c --arg name "$pending_name" '[.[] | select(.name == $name)]' \
            <<< "$XUI_API_TOKENS_JSON") || return 1
        count=$(jq 'length' <<< "$matches") || return 1
        if ((count > 1)); then
            _xui_error 'Pending API token name resolves to multiple rows'
            return 1
        fi
        if ((count == 1)); then
            candidate_id=$(jq -r '.[0].id // empty' <<< "$matches")
            [[ $candidate_id =~ ^[1-9][0-9]*$ && $candidate_id != "$current_id" ]] || {
                _xui_error 'Pending API token row aliases the currently active credential'
                return 1
            }
            xui_delete_api_token_by_id "$candidate_id" "$pending_name" || return 1
            declare -g XUI_CLEANED_ORPHAN_API_TOKEN_ID="$candidate_id"
            declare -g XUI_CLEANED_ORPHAN_API_TOKEN_NAME="$pending_name"
            declare -g XUI_RECOVERED_API_TOKEN_ACTION=deleted-orphan
        else
            declare -g XUI_RECOVERED_API_TOKEN_ACTION=cleared-stale-journal
        fi
        _xui_clear_pending_api_token_state || return 1
        return 0
    fi

    [[ -z $old_id && -z $old_name ]] || {
        _xui_error 'Pending rotation has predecessor metadata but no current credential tuple'
        return 1
    }
    installer_token=$(_xui_install_result_api_token) || {
        _xui_error 'Official installer token is unavailable; refusing first-install recovery'
        return 1
    }
    xui_load_api_context || return 1
    selected_token=$XUI_API_TOKEN_VALUE
    [[ $selected_token == "$installer_token" ]] || {
        _xui_error 'Current bearer is not the installer token; refusing possible self-deletion'
        return 1
    }
    xui_api_tokens_read || return 1
    matches=$(jq -c --arg name "$pending_name" '[.[] | select(.name == $name)]' \
        <<< "$XUI_API_TOKENS_JSON") || return 1
    count=$(jq 'length' <<< "$matches") || return 1
    if ((count > 1)); then
        _xui_error 'Pending API token name resolves to multiple orphan rows'
        return 1
    fi
    if ((count == 1)); then
        candidate_id=$(jq -r '.[0].id // empty' <<< "$matches")
        [[ $candidate_id =~ ^[1-9][0-9]*$ ]] || return 1
        xui_api_post "/panel/api/setting/apiTokens/delete/$candidate_id" '{"expectedScope":"admin"}' > /dev/null || return 1
        xui_api_tokens_read || return 1
        remaining=$(jq -r --argjson id "$candidate_id" --arg name "$pending_name" '
            any(.[]; .id == $id or .name == $name)
        ' <<< "$XUI_API_TOKENS_JSON") || return 1
        [[ $remaining == false ]] || {
            _xui_error '3x-ui reported success but the pending orphan still exists'
            return 1
        }
        declare -g XUI_CLEANED_ORPHAN_API_TOKEN_ID="$candidate_id"
        declare -g XUI_CLEANED_ORPHAN_API_TOKEN_NAME="$pending_name"
        declare -g XUI_RECOVERED_API_TOKEN_ACTION=deleted-first-install-orphan
    else
        declare -g XUI_RECOVERED_API_TOKEN_ACTION=cleared-stale-journal
    fi
    _xui_clear_pending_api_token_state || return 1
}

xui_cleanup_pending_api_token_orphan() {
    xui_recover_pending_api_token "$@"
}

xui_recover_api_token_rotation() {
    xui_recover_pending_api_token "$@"
}

# Recoverable maintenance primitive: journal -> create -> atomic switch ->
# delete predecessor -> clear journal. Omitting old-id intentionally keeps the
# previous credential valid, while still protecting the new create/switch.
xui_rotate_api_token() {
    [[ $# -ge 1 && $# -le 2 ]] || return 2
    local new_name=$1 old_id=${2-} recorded_old_id='' old_name='' current_token=''
    [[ $new_name == one-key-proxy-* && $new_name != one-key-proxy- &&
        ${#new_name} -le 64 && $new_name != *[[:cntrl:]]* ]] || return 2
    xui_recover_pending_api_token || return 1
    declare -F state_set_many > /dev/null 2>&1 || {
        _xui_error 'state_set_many is required for recoverable API token rotation'
        return 1
    }
    if [[ -n $old_id && ! $old_id =~ ^[1-9][0-9]*$ ]]; then
        return 2
    fi
    if [[ -n $old_id ]]; then
        recorded_old_id=$(_xui_state_get XUI_API_TOKEN_ID) || {
            _xui_error 'Cannot rotate an old token whose current state ID is unknown'
            return 1
        }
        old_name=$(_xui_state_get XUI_API_TOKEN_NAME) || {
            _xui_error 'Cannot rotate an old token whose current state name is unknown'
            return 1
        }
        [[ $recorded_old_id == "$old_id" && -n $old_name ]] || {
            _xui_error 'Requested old token ID does not match the active token state'
            return 1
        }
        current_token=$(_xui_state_get XUI_API_TOKEN) || return 1
        xui_validate_api_token "$current_token" "$old_id" "$old_name" || return 1
        state_set_many \
            XUI_PENDING_API_TOKEN_NAME "$new_name" \
            XUI_PENDING_API_TOKEN_OLD_ID "$old_id" \
            XUI_PENDING_API_TOKEN_OLD_NAME "$old_name" || return 1
    else
        state_set_many XUI_PENDING_API_TOKEN_NAME "$new_name" || return 1
    fi
    xui_create_api_token "$new_name" || return 1
    xui_switch_api_token_context "$XUI_CREATED_API_TOKEN_VALUE" \
        "$XUI_CREATED_API_TOKEN_ID" "$XUI_CREATED_API_TOKEN_NAME" || return 1
    if [[ -n $old_id ]]; then
        [[ $old_id != "$XUI_CREATED_API_TOKEN_ID" ]] || return 2
        xui_delete_api_token_by_id "$old_id" "$old_name" || return 1
    fi
    _xui_clear_pending_api_token_state || return 1
    declare -g XUI_ROTATED_API_TOKEN_ID="$XUI_CREATED_API_TOKEN_ID"
    declare -g XUI_ROTATED_API_TOKEN_NAME="$XUI_CREATED_API_TOKEN_NAME"
    declare -g XUI_ROTATED_API_TOKEN_VALUE="$XUI_CREATED_API_TOKEN_VALUE"
}

xui_check_required_endpoints() {
    local obj private_key public_key
    xui_api_post /panel/api/setting/all '{}' > /dev/null || return 1
    xui_api_get /panel/api/setting/apiTokens > /dev/null || return 1
    xui_api_get /panel/api/inbounds/list > /dev/null || return 1
    xui_api_get /panel/api/hosts/list > /dev/null || return 1
    obj=$(xui_api_get /panel/api/server/getNewX25519Cert) || return 1
    private_key=$(jq -r '.privateKey // empty' <<< "$obj")
    public_key=$(jq -r '.publicKey // empty' <<< "$obj")
    [[ -n "$private_key" && -n "$public_key" ]] || {
        _xui_error 'The X25519 endpoint returned an incompatible response'
        return 1
    }
    private_key=''
    public_key=''
    obj=''
    # subLinks is validated against the release OpenAPI before installation.
    # Calling it with a synthetic Sub ID is not a valid runtime health probe.
}

# Require two consecutive healthy snapshots, then confirm that the managed
# inbound is present in the Xray configuration assembled by 3x-ui. Arguments:
# managed-tag internal-port [attempts] [delay-seconds]
xui_verify_xray_runtime() {
    [[ $# -ge 2 && $# -le 4 ]] || return 2
    local managed_tag=$1 internal_port=$2 attempts=${3:-15} delay_seconds=${4:-2}
    local attempt consecutive=0 status config version

    [[ -n $managed_tag && $managed_tag != *[[:cntrl:]]* ]] || return 2
    [[ $internal_port =~ ^[0-9]+$ ]] && \
        ((internal_port >= 1 && internal_port <= 65535)) || return 2
    [[ $attempts =~ ^[1-9][0-9]*$ && $delay_seconds =~ ^[0-9]+$ ]] || return 2

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        status=$(xui_api_get /panel/api/server/status 2>/dev/null || true)
        if jq -e '
            type == "object" and
            .xray.state == "running" and
            (.xray.errorMsg // "") == "" and
            (.xray.version | type == "string" and length > 0)
        ' >/dev/null 2>&1 <<< "$status"; then
            consecutive=$((consecutive + 1))
        else
            consecutive=0
        fi
        if ((consecutive >= 2)); then
            version=$(jq -r '.xray.version' <<< "$status") || return 1
            config=$(xui_api_get /panel/api/server/getConfigJson) || return 1
            config=$(jq -c 'if type == "string" then fromjson else . end' <<< "$config") || return 1
            if ! jq -e --arg tag "$managed_tag" --argjson port "$internal_port" '
                type == "object" and (.inbounds | type == "array") and
                any(.inbounds[]; .tag == $tag and .port == $port)
            ' >/dev/null 2>&1 <<< "$config"; then
                _xui_error 'Xray is running, but the managed inbound is absent from its assembled configuration'
                return 1
            fi
            declare -g XUI_XRAY_VERSION="$version"
            return 0
        fi
        ((attempt == attempts)) || sleep "$delay_seconds"
    done
    _xui_error 'Xray did not reach two consecutive healthy running snapshots'
    return 1
}

xui_settings_read() {
    local settings
    settings=$(xui_api_post /panel/api/setting/all '{}') || return 1
    jq -e 'type == "object"' > /dev/null 2>&1 <<< "$settings" || {
        _xui_error '3x-ui settings response is not an object'
        return 1
    }
    declare -g XUI_SETTINGS_JSON="$settings"
}

_xui_merge_settings_json() (
    [[ $# -eq 2 ]] || exit 2
    local current=$1 patch=$2 temp_dir current_file patch_file

    umask 077
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/one-key-proxy-settings.XXXXXX") || exit 1
    current_file=$temp_dir/current.json
    patch_file=$temp_dir/patch.json
    trap 'rm -f -- "$current_file" "$patch_file"; rmdir -- "$temp_dir" 2> /dev/null || true' EXIT
    trap 'exit 1' HUP INT TERM
    printf '%s' "$current" > "$current_file"
    printf '%s' "$patch" > "$patch_file"
    jq -c --slurpfile patch "$patch_file" '
        with_entries(select(.key | startswith("has") | not)) + $patch[0]
    ' "$current_file"
)

# Merge a flat JSON patch into the complete current settings object, then send
# the complete object back. Browser-only has* flags are intentionally removed.
xui_settings_merge_update() {
    [[ $# -eq 1 ]] || return 2
    local patch=$1 merged
    jq -e 'type == "object"' > /dev/null 2>&1 <<< "$patch" || {
        _xui_error 'Settings patch must be a JSON object'
        return 2
    }
    xui_settings_read || return 1
    merged=$(_xui_merge_settings_json "$XUI_SETTINGS_JSON" "$patch") || return 1
    xui_api_post /panel/api/setting/update "$merged" > /dev/null || return 1
    declare -g XUI_SETTINGS_JSON=$merged
}

_xui_url_host() {
    [[ $# -eq 1 ]] || return 2
    local host=$1
    host=${host#\[}
    host=${host%\]}
    if [[ $host == *:* ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

_xui_public_origin() {
    [[ $# -eq 3 ]] || return 2
    local scheme=$1 host=$2 port=$3 url_host
    url_host=$(_xui_url_host "$host") || return 1
    if [[ ($scheme == https && $port == 443) || ($scheme == http && $port == 80) ]]; then
        printf '%s://%s' "$scheme" "$url_host"
    else
        printf '%s://%s:%s' "$scheme" "$url_host" "$port"
    fi
}

_xui_uri_query_has_pair() {
    [[ $# -eq 3 ]] || return 2
    local query=$1 wanted_key=$2 wanted_value=$3 item key value count=0
    while IFS= read -r item; do
        [[ $item == *=* ]] || continue
        key=${item%%=*}
        value=${item#*=}
        [[ $key == "$wanted_key" ]] || continue
        ((count += 1))
        [[ $value == "$wanted_value" ]] || return 1
    done < <(tr '&' '\n' <<< "$query")
    [[ $count == 1 ]]
}

# Validate the public endpoint and the security-critical fields emitted in a
# VLESS REALITY URI. Arguments: URI host port UUID SNI public-key short-ID.
xui_vless_uri_matches() {
    [[ $# -eq 7 ]] || return 2
    local uri=$1 host=$2 port=$3 uuid=$4 sni=$5 public_key=$6 short_id=$7
    local without_fragment authority query key expected

    [[ $uri == vless://* && $uri == *\?* ]] || return 1
    [[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || return 2
    [[ -n $host && -n $uuid && -n $sni && -n $public_key && -n $short_id ]] || return 2
    without_fragment=${uri%%#*}
    authority=${without_fragment%%\?*}
    query=${without_fragment#*\?}
    [[ $authority == "vless://${uuid}@${host}:${port}" ]] || return 1

    while IFS=' ' read -r key expected; do
        _xui_uri_query_has_pair "$query" "$key" "$expected" || return 1
    done <<EOF
type tcp
security reality
flow xtls-rprx-vision
sni ${sni}
pbk ${public_key}
sid ${short_id}
EOF
}

_xui_subscription_expectations_valid() {
    [[ $# -eq 6 ]] || return 2
    local host=$1 port=$2 uuid=$3 sni=$4 public_key=$5 short_id=$6
    host=${host#\[}
    host=${host%\]}
    [[ -n $host && $host =~ ^[A-Za-z0-9._:-]+$ ]] || return 2
    [[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || return 2
    [[ $uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || return 2
    [[ -n $sni && $sni =~ ^[A-Za-z0-9.-]+$ ]] || return 2
    [[ -n $public_key && $public_key =~ ^[A-Za-z0-9_-]+$ ]] || return 2
    [[ $short_id =~ ^[[:xdigit:]]{2,16}$ && $((${#short_id} % 2)) -eq 0 ]] || return 2
}

# Validate an official 3x-ui Xray JSON subscription. Both the single-config
# object and always-array forms are accepted, as are current flat VLESS
# settings and the older vnext representation. Exactly one security-relevant
# candidate may identify the expected UUID or public endpoint.
# Args: JSON-file host port UUID SNI public-key short-ID.
xui_json_subscription_matches() (
    [[ $# -eq 7 ]] || exit 2
    local document_file=$1 host=$2 port=$3 uuid=$4 sni=$5 public_key=$6 short_id=$7
    local temp_dir expected_file

    host=${host#\[}
    host=${host%\]}
    _xui_subscription_expectations_valid \
        "$host" "$port" "$uuid" "$sni" "$public_key" "$short_id" || exit 2
    [[ -f $document_file && -r $document_file && -s $document_file ]] || exit 2
    command -v jq > /dev/null 2>&1 || exit 2

    umask 077
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/one-key-proxy-sub-json.XXXXXX") || exit 1
    expected_file=$temp_dir/expected
    trap 'rm -f -- "$expected_file"; rmdir -- "$temp_dir" 2> /dev/null || true' EXIT
    trap 'exit 1' HUP INT TERM
    printf '%s\n' "$host" "$port" "$uuid" "$sni" "$public_key" "$short_id" > "$expected_file" || exit 1

    jq -e --rawfile expected "$expected_file" '
        ($expected | rtrimstr("\n") | split("\n")) as $e
        | ($e[0]) as $host
        | ($e[1] | tonumber) as $port
        | ($e[2]) as $uuid
        | ($e[3]) as $sni
        | ($e[4]) as $publicKey
        | ($e[5]) as $shortId
        | def valid_document:
            if type == "object" then (.outbounds | type == "array")
            elif type == "array" then
                length > 0 and all(.[]; type == "object" and (.outbounds | type == "array"))
            else false
            end;
          def documents:
            if type == "object" then . else .[] end;
          def record($out; $address; $recordPort; $user): {
            protocol: $out.protocol,
            address: $address,
            port: $recordPort,
            id: $user.id,
            encryption: $user.encryption,
            flow: $user.flow,
            stream: $out.streamSettings
          };
          def subscription_records:
            documents
            | .outbounds[]
            | select(type == "object") as $out
            | select($out.settings | type == "object")
            | if ($out.settings.vnext | type) == "array" then
                $out.settings.vnext[]
                | select(type == "object" and (.users | type) == "array") as $server
                | $server.users[]
                | select(type == "object")
                | record($out; $server.address; $server.port; .)
              elif ($out.settings.servers | type) == "array" then
                $out.settings.servers[]
                | select(type == "object")
                | record($out; .address; .port; .)
              else
                record($out; $out.settings.address; $out.settings.port; $out.settings)
              end;
          def is_expected:
            .protocol == "vless"
            and .address == $host
            and .port == $port
            and .id == $uuid
            and .encryption == "none"
            and .flow == "xtls-rprx-vision"
            and (.stream | type == "object")
            and .stream.network == "tcp"
            and .stream.security == "reality"
            and ((.stream.tcpSettings.header.type // "none") == "none")
            and .stream.realitySettings.serverName == $sni
            and .stream.realitySettings.publicKey == $publicKey
            and .stream.realitySettings.shortId == $shortId
            and .stream.realitySettings.fingerprint == "chrome";
          select(valid_document)
          | [subscription_records
              | select(.id == $uuid or (.address == $host and .port == $port))] as $candidates
          | ($candidates | length) == 1
          and ($candidates[0] | is_expected)
    ' "$document_file" > /dev/null 2>&1
)

# Validate the block-style YAML emitted by the official 3x-ui Clash service
# without adding a yq dependency. Only plain, single-quoted and double-quoted
# scalar forms are accepted for security fields; aliases, tags, flow maps and
# multiline scalars fail closed. Duplicate security fields also fail closed.
# Args: Clash-YAML-file host port UUID SNI public-key short-ID.
xui_clash_subscription_matches() (
    [[ $# -eq 7 ]] || exit 2
    local document_file=$1 host=$2 port=$3 uuid=$4 sni=$5 public_key=$6 short_id=$7
    local temp_dir expected_file

    host=${host#\[}
    host=${host%\]}
    _xui_subscription_expectations_valid \
        "$host" "$port" "$uuid" "$sni" "$public_key" "$short_id" || exit 2
    [[ -f $document_file && -r $document_file && -s $document_file ]] || exit 2
    command -v awk > /dev/null 2>&1 || exit 2

    umask 077
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/one-key-proxy-sub-clash.XXXXXX") || exit 1
    expected_file=$temp_dir/expected
    trap 'rm -f -- "$expected_file"; rmdir -- "$temp_dir" 2> /dev/null || true' EXIT
    trap 'exit 1' HUP INT TERM
    printf '%s\n' "$host" "$port" "$uuid" "$sni" "$public_key" "$short_id" > "$expected_file" || exit 1

    awk '
        NR == FNR { expected[FNR] = $0; next }

        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }

        function scalar(value, first, last) {
            scalar_valid = 1
            value = trim(value)
            if (value == "") {
                scalar_valid = 0
                return ""
            }
            first = substr(value, 1, 1)
            last = substr(value, length(value), 1)
            if (first == "\047") {
                if (last != "\047" || length(value) < 2) {
                    scalar_valid = 0
                    return ""
                }
                value = substr(value, 2, length(value) - 2)
                gsub(/\047\047/, "\047", value)
                return value
            }
            if (first == "\"") {
                if (last != "\"" || length(value) < 2) {
                    scalar_valid = 0
                    return ""
                }
                value = substr(value, 2, length(value) - 2)
                if (index(value, "\\") != 0) {
                    scalar_valid = 0
                    return ""
                }
                return value
            }
            sub(/[[:space:]]+#.*$/, "", value)
            value = trim(value)
            if (value == "" || value ~ /^[>|*&!]/) scalar_valid = 0
            return value
        }

        function reset_record() {
            record_active = 1
            record_invalid = 0
            nested = ""
            type = server = port = uuid = network = tls = flow = servername = fingerprint = encryption = ""
            public_key = short_id = ""
            have_type = have_server = have_port = have_uuid = have_network = have_tls = 0
            have_flow = have_servername = have_fingerprint = have_encryption = 0
            have_public_key = have_short_id = have_reality_opts = 0
        }

        function set_field(key, raw, value) {
            value = scalar(raw)
            if (!scalar_valid) record_invalid = 1
            if (key == "type") {
                if (++have_type > 1) record_invalid = 1
                type = value
            } else if (key == "server") {
                if (++have_server > 1) record_invalid = 1
                server = value
            } else if (key == "port") {
                if (++have_port > 1) record_invalid = 1
                port = value
            } else if (key == "uuid") {
                if (++have_uuid > 1) record_invalid = 1
                uuid = value
            } else if (key == "network") {
                if (++have_network > 1) record_invalid = 1
                network = value
            } else if (key == "tls") {
                if (++have_tls > 1) record_invalid = 1
                tls = value
            } else if (key == "flow") {
                if (++have_flow > 1) record_invalid = 1
                flow = value
            } else if (key == "servername") {
                if (++have_servername > 1) record_invalid = 1
                servername = value
            } else if (key == "client-fingerprint") {
                if (++have_fingerprint > 1) record_invalid = 1
                fingerprint = value
            } else if (key == "encryption") {
                if (++have_encryption > 1) record_invalid = 1
                encryption = value
            }
        }

        function set_reality_field(key, raw, value) {
            if (key == "public-key") {
                value = scalar(raw)
                if (!scalar_valid) record_invalid = 1
                if (++have_public_key > 1) record_invalid = 1
                public_key = value
            } else if (key == "short-id") {
                value = scalar(raw)
                if (!scalar_valid) record_invalid = 1
                if (++have_short_id > 1) record_invalid = 1
                short_id = value
            }
        }

        function is_security_field(key) {
            return key == "type" || key == "server" || key == "port" || key == "uuid" ||
                key == "network" || key == "tls" || key == "flow" || key == "servername" ||
                key == "client-fingerprint" || key == "encryption"
        }

        function mapping(text, level, top_level, colon, key, raw) {
            colon = index(text, ":")
            if (colon < 2) {
                record_invalid = 1
                return
            }
            key = trim(substr(text, 1, colon - 1))
            raw = substr(text, colon + 1)
            if (key !~ /^[A-Za-z0-9_-]+$/) {
                record_invalid = 1
                return
            }
            if (top_level) {
                if (key == "reality-opts") {
                    if (++have_reality_opts > 1 || trim(raw) != "") record_invalid = 1
                    nested = "reality-opts"
                    return
                }
                nested = ""
                if (is_security_field(key)) {
                    set_field(key, raw)
                } else if (trim(raw) == "") {
                    nested = key
                }
            } else if (nested == "reality-opts") {
                set_reality_field(key, raw)
            }
        }

        function finish_record(candidate) {
            if (!record_active) return
            if (record_invalid) invalid_document = 1
            candidate = (uuid == expected[3] || (server == expected[1] && port == expected[2]))
            if (candidate) {
                candidate_count++
                if (!record_invalid &&
                    type == "vless" &&
                    server == expected[1] &&
                    port == expected[2] &&
                    uuid == expected[3] &&
                    network == "tcp" &&
                    tls == "true" &&
                    flow == "xtls-rprx-vision" &&
                    servername == expected[4] &&
                    public_key == expected[5] &&
                    short_id == expected[6] &&
                    fingerprint == "chrome" &&
                    (encryption == "" || encryption == "none")) match_count++
            }
            record_active = 0
        }

        {
            line = $0
            sub(/\r$/, "", line)
            if (index(line, "\t") != 0) {
                invalid_document = 1
                next
            }
            if (line ~ /^[ ]*$/ || line ~ /^[ ]*#/) next
            match(line, /^[ ]*/)
            indent = RLENGTH
            content = substr(line, indent + 1)

            if (indent == 0 && content ~ /^proxies[ ]*:/) {
                finish_record()
                if (seen_proxies++) invalid_document = 1
                after = substr(content, index(content, ":") + 1)
                sub(/[[:space:]]+#.*$/, "", after)
                if (trim(after) != "") invalid_document = 1
                in_proxies = 1
                item_indent = -1
                next
            }
            if (!in_proxies) next

            if (content ~ /^-[ ]+/ && (item_indent < 0 || indent == item_indent)) {
                finish_record()
                if (item_indent < 0) item_indent = indent
                field_indent = item_indent + 2
                reset_record()
                mapping(substr(content, 3), field_indent, 1)
                next
            }
            if (indent == 0) {
                finish_record()
                in_proxies = 0
                next
            }
            if (!record_active) {
                invalid_document = 1
                next
            }
            if (indent == field_indent) {
                mapping(content, indent, 1)
            } else if (indent > field_indent && nested == "reality-opts") {
                mapping(content, indent, 0)
            } else if (indent < field_indent) {
                record_invalid = 1
            }
        }

        END {
            finish_record()
            if (!seen_proxies || invalid_document || candidate_count != 1 || match_count != 1) exit 1
        }
    ' "$expected_file" "$document_file" > /dev/null 2>&1
)

# Validate a Base64 subscription without accepting an ambiguous second VLESS
# candidate for the same UUID or public endpoint. Arguments:
# Base64-file host port UUID SNI public-key short-ID.
xui_base64_subscription_matches() (
    [[ $# -eq 7 ]] || exit 2
    local document_file=$1 host=$2 port=$3 uuid=$4 sni=$5 public_key=$6 short_id=$7
    local temp_dir encoded_file decoded_file uri authority
    local expected_authority candidate_count=0 match_count=0 encoded_size

    _xui_subscription_expectations_valid \
        "$host" "$port" "$uuid" "$sni" "$public_key" "$short_id" || exit 2
    [[ -f $document_file && ! -L $document_file && -r $document_file && -s $document_file ]] || exit 2
    command -v base64 > /dev/null 2>&1 || exit 2

    umask 077
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/one-key-proxy-sub-base64.XXXXXX") || exit 1
    encoded_file=$temp_dir/encoded
    decoded_file=$temp_dir/decoded
    trap 'rm -f -- "$encoded_file" "$decoded_file"; rmdir -- "$temp_dir" 2> /dev/null || true' EXIT
    trap 'exit 1' HUP INT TERM

    tr -d '\r\n\t ' <"$document_file" >"$encoded_file" || exit 1
    [[ -s $encoded_file ]] || exit 1
    LC_ALL=C grep -Eq '^[A-Za-z0-9+/]+={0,2}$' "$encoded_file" || exit 1
    encoded_size=$(wc -c <"$encoded_file") || exit 1
    encoded_size=${encoded_size//[[:space:]]/}
    [[ $encoded_size =~ ^[0-9]+$ ]] && ((encoded_size % 4 == 0)) || exit 1
    if ! base64 -d <"$encoded_file" >"$decoded_file" 2>/dev/null; then
        base64 -D <"$encoded_file" >"$decoded_file" 2>/dev/null || exit 1
    fi
    [[ -s $decoded_file ]] || exit 1

    expected_authority="vless://${uuid}@${host}:${port}"
    while IFS= read -r uri || [[ -n $uri ]]; do
        uri=${uri%$'\r'}
        [[ $uri == vless://* ]] || continue
        authority=${uri%%\?*}
        authority=${authority%%#*}
        if [[ $authority == "vless://${uuid}@"* ||
            $authority == *"@${host}:${port}" ]]; then
            ((candidate_count += 1))
            if [[ $authority == "$expected_authority" ]] &&
                xui_vless_uri_matches "$uri" "$host" "$port" "$uuid" "$sni" \
                    "$public_key" "$short_id"; then
                ((match_count += 1))
            fi
        fi
    done <"$decoded_file"
    ((candidate_count == 1 && match_count == 1))
)

# Fetch a subscription through the deployed HTTPS identity while forcing the
# connection to the loopback listener. This verifies certificate trust, SNI,
# Host routing and the internal listener without depending on NAT hairpinning.
# Arguments: public-host internal-port certificate path output-file.
xui_fetch_local_https_path() (
    [[ $# -eq 5 ]] || exit 2
    local host=$1 internal_port=$2 cert_file=$3 path=$4 output_file=$5
    local url http_code

    host=${host#\[}
    host=${host%\]}
    [[ -n $host && $host != -* && $host != *:* && $host =~ ^[A-Za-z0-9.-]+$ ]] || exit 2
    [[ $internal_port =~ ^[0-9]+$ ]] &&
        ((internal_port >= 1 && internal_port <= 65535)) || exit 2
    [[ $path == /* && $path != *$'\n'* && $path != *$'\r'* ]] || exit 2
    [[ -f $cert_file && ! -L $cert_file && -r $cert_file ]] || exit 2
    [[ -f $output_file && ! -L $output_file ]] || exit 2
    command -v curl > /dev/null 2>&1 || exit 2

    url=$(_xui_public_origin https "$host" "$internal_port")${path} || exit 1
    : >"$output_file" || exit 1
    http_code=$(curl --disable --noproxy '*' --silent --show-error \
        --connect-timeout 3 --max-time 8 --max-filesize 8388608 \
        --proto '=https' --tlsv1.2 --cacert "$cert_file" \
        --resolve "${host}:${internal_port}:127.0.0.1" \
        --output "$output_file" --write-out '%{http_code}' --url "$url") || exit 1
    [[ $http_code == 200 && -s $output_file ]]
)

# Fetch and strictly validate all three official subscription formats. The
# listener port and advertised VLESS port are separate by design for NAT VPSes.
# Arguments: public-host subscription-internal-port VLESS-external-port Sub-ID
# certificate UUID SNI public-key short-ID [attempts [delay-seconds]].
xui_verify_local_subscriptions() (
    [[ $# -ge 9 && $# -le 11 ]] || exit 2
    local host=$1 sub_internal_port=$2 node_external_port=$3 sub_id=$4 cert_file=$5
    local uuid=$6 sni=$7 public_key=$8 short_id=$9 attempts=${10:-6} delay=${11:-2}
    local temp_dir body_file attempt

    host=${host#\[}
    host=${host%\]}
    _xui_subscription_expectations_valid \
        "$host" "$node_external_port" "$uuid" "$sni" "$public_key" "$short_id" || exit 2
    [[ $sub_internal_port =~ ^[0-9]+$ ]] &&
        ((sub_internal_port >= 1 && sub_internal_port <= 65535)) || exit 2
    [[ $sub_id =~ ^[A-Za-z0-9_-]+$ ]] || exit 2
    [[ -f $cert_file && ! -L $cert_file && -r $cert_file ]] || exit 2
    [[ $attempts =~ ^[1-9][0-9]*$ && $delay =~ ^[0-9]+$ ]] || exit 2

    umask 077
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/one-key-proxy-sub-verify.XXXXXX") || exit 1
    body_file=$temp_dir/body
    trap 'rm -f -- "$body_file"; rmdir -- "$temp_dir" 2> /dev/null || true' EXIT
    trap 'exit 1' HUP INT TERM
    : >"$body_file" || exit 1

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if xui_fetch_local_https_path "$host" "$sub_internal_port" "$cert_file" \
                "/sub/${sub_id}" "$body_file" &&
            xui_base64_subscription_matches "$body_file" "$host" "$node_external_port" \
                "$uuid" "$sni" "$public_key" "$short_id" &&
            xui_fetch_local_https_path "$host" "$sub_internal_port" "$cert_file" \
                "/json/${sub_id}" "$body_file" &&
            xui_json_subscription_matches "$body_file" "$host" "$node_external_port" \
                "$uuid" "$sni" "$public_key" "$short_id" &&
            xui_fetch_local_https_path "$host" "$sub_internal_port" "$cert_file" \
                "/clash/${sub_id}" "$body_file" &&
            xui_clash_subscription_matches "$body_file" "$host" "$node_external_port" \
                "$uuid" "$sni" "$public_key" "$short_id"; then
            exit 0
        fi
        ((attempt == attempts)) || sleep "$delay"
    done
    exit 1
)

# Configure Base64, Xray JSON and Clash/Mihomo subscriptions. Arguments:
# internal-port scheme public-host external-port cert-file key-file
xui_configure_subscription() {
    [[ $# -eq 6 ]] || return 2
    local internal_port=$1 scheme=$2 public_host=$3 external_port=$4
    local cert_file=$5 key_file=$6 origin patch
    [[ $internal_port =~ ^[0-9]+$ ]] && ((internal_port >= 1 && internal_port <= 65535)) || return 2
    [[ $external_port =~ ^[0-9]+$ ]] && ((external_port >= 1 && external_port <= 65535)) || return 2
    [[ $scheme == http || $scheme == https ]] || return 2
    [[ -n "$public_host" && $public_host != */* ]] || return 2
    if [[ $scheme == https && (-z $cert_file || -z $key_file) ]]; then
        _xui_error 'HTTPS subscription requires certificate and key paths'
        return 2
    fi
    origin=$(_xui_public_origin "$scheme" "$public_host" "$external_port") || return 1
    patch=$(jq -nc \
        --argjson port "$internal_port" \
        --arg domain "${public_host#\[}" \
        --arg cert "$cert_file" --arg key "$key_file" \
        --arg sub "$origin/sub/" --arg json "$origin/json/" --arg clash "$origin/clash/" '
        {
            subEnable: true, subListen: "", subPort: $port,
            subPath: "/sub/", subDomain: ($domain | rtrimstr("]")),
            subCertFile: $cert, subKeyFile: $key, subEncrypt: true,
            subURI: $sub,
            subJsonEnable: true, subJsonPath: "/json/", subJsonURI: $json,
            subClashEnable: true, subClashPath: "/clash/", subClashURI: $clash
        }
    ') || return 1
    xui_settings_merge_update "$patch"
}

xui_configure_panel_tls() {
    [[ $# -ge 3 && $# -le 4 ]] || return 2
    local internal_port=$1 cert_file=$2 key_file=$3 public_host=${4:-}
    local patch
    [[ $internal_port =~ ^[0-9]+$ ]] && ((internal_port >= 1 && internal_port <= 65535)) || return 2
    [[ -n $cert_file && -n $key_file ]] || return 2
    patch=$(jq -nc --argjson port "$internal_port" --arg cert "$cert_file" \
        --arg key "$key_file" --arg domain "$public_host" '
        {webPort: $port, webListen: "", webBasePath: "/", webCertFile: $cert,
         webKeyFile: $key, webDomain: $domain}
    ') || return 1
    xui_settings_merge_update "$patch"
}

xui_restart_panel() {
    xui_api_post /panel/api/setting/restartPanel '{}' > /dev/null
}

xui_generate_x25519() {
    local pair private_key public_key
    pair=$(xui_api_get /panel/api/server/getNewX25519Cert) || return 1
    private_key=$(jq -r '.privateKey // empty' <<< "$pair")
    public_key=$(jq -r '.publicKey // empty' <<< "$pair")
    [[ -n $private_key && -n $public_key ]] || {
        _xui_error 'Could not generate a REALITY X25519 keypair'
        return 1
    }
    declare -g XUI_REALITY_PRIVATE_KEY="$private_key"
    declare -g XUI_REALITY_PUBLIC_KEY="$public_key"
    if declare -F secret_register > /dev/null 2>&1; then
        secret_register "$private_key"
    fi
    pair=''
    private_key=''
    public_key=''
}

_xui_normalize_inbounds() {
    jq -c '
        def object_value:
            if type == "string" then (try fromjson catch null) else . end;
        map(.settings |= object_value | .streamSettings |= object_value | .sniffing |= object_value)
    '
}

# Set XUI_MANAGED_INBOUND_JSON/ID without printing the inbound (which contains
# the REALITY private key). Returns 1 when absent and 2 when identity is not
# unique.
xui_find_managed_inbound() {
    local list matches count matched_id stored_id=''
    [[ -n $XUI_MANAGED_TAG && $XUI_MANAGED_TAG != *[[:cntrl:]]* ]] || {
        _xui_error 'Managed inbound tag must be a non-empty single-line value'
        return 2
    }
    if ! stored_id=$(_xui_state_get INBOUND_ID); then
        stored_id=''
    fi
    list=$(xui_api_get /panel/api/inbounds/list) || return 2
    list=$(printf '%s' "$list" | _xui_normalize_inbounds) || return 2
    matches=$(jq -c --arg tag "$XUI_MANAGED_TAG" '
        [.[] | select(.tag == $tag)]
    ' <<< "$list") || return 2
    count=$(jq 'length' <<< "$matches") || return 2
    if ((count == 0)); then
        if [[ -n $stored_id ]]; then
            _xui_error 'Stored inbound ID exists, but no inbound has the exact managed tag'
            return 2
        fi
        return 1
    fi
    if ((count != 1)); then
        _xui_error 'Multiple inbounds match the one-key-proxy identity; refusing to guess'
        return 2
    fi
    matched_id=$(jq -r '.[0].id // empty' <<< "$matches")
    [[ $matched_id =~ ^[0-9]+$ ]] || {
        _xui_error 'Managed inbound has an invalid ID'
        return 2
    }
    if [[ -n $stored_id && $matched_id != "$stored_id" ]]; then
        _xui_error 'Managed inbound tag resolves to an ID different from project state'
        return 2
    fi
    declare -g XUI_MANAGED_INBOUND_JSON
    XUI_MANAGED_INBOUND_JSON=$(jq -c '.[0]' <<< "$matches")
    declare -g XUI_MANAGED_INBOUND_ID
    XUI_MANAGED_INBOUND_ID=$matched_id
}

_xui_existing_inbound_values() {
    declare -g XUI_CLIENT_UUID XUI_CLIENT_EMAIL XUI_SUB_ID
    declare -g XUI_REALITY_PRIVATE_KEY XUI_REALITY_PUBLIC_KEY XUI_REALITY_SHORT_ID
    XUI_CLIENT_UUID=$(jq -r '.settings.clients[0].id // empty' <<< "$XUI_MANAGED_INBOUND_JSON")
    XUI_CLIENT_EMAIL=$(jq -r '.settings.clients[0].email // empty' <<< "$XUI_MANAGED_INBOUND_JSON")
    XUI_SUB_ID=$(jq -r '.settings.clients[0].subId // empty' <<< "$XUI_MANAGED_INBOUND_JSON")
    XUI_REALITY_PRIVATE_KEY=$(jq -r '.streamSettings.realitySettings.privateKey // empty' <<< "$XUI_MANAGED_INBOUND_JSON")
    XUI_REALITY_PUBLIC_KEY=$(jq -r '.streamSettings.realitySettings.settings.publicKey // empty' <<< "$XUI_MANAGED_INBOUND_JSON")
    XUI_REALITY_SHORT_ID=$(jq -r '.streamSettings.realitySettings.shortIds[0] // empty' <<< "$XUI_MANAGED_INBOUND_JSON")
    if declare -F secret_register > /dev/null 2>&1; then
        secret_register "$XUI_CLIENT_UUID"
        secret_register "$XUI_SUB_ID"
        secret_register "$XUI_REALITY_PRIVATE_KEY"
        secret_register "$XUI_REALITY_SHORT_ID"
    fi
}

_xui_enforce_min_client_version() {
    local current payload id
    current=$(jq -r '.streamSettings.realitySettings.minClientVer // empty' <<< "$XUI_MANAGED_INBOUND_JSON")
    [[ $current == 1.0.0 ]] && return 0
    id=$XUI_MANAGED_INBOUND_ID
    payload=$(jq -c '
        {enable, remark, listen, port, protocol, expiryTime, total, settings,
         streamSettings, sniffing, tag, shareAddr, shareAddrStrategy,
         trafficReset, trafficResetDay, subSortIndex}
        | .streamSettings.realitySettings.minClientVer = "1.0.0"
        | with_entries(select(.value != null))
    ' <<< "$XUI_MANAGED_INBOUND_JSON") || return 1
    xui_api_post "/panel/api/inbounds/update/$id" "$payload" > /dev/null || return 1
    XUI_MANAGED_INBOUND_JSON=$(jq -c '.streamSettings.realitySettings.minClientVer = "1.0.0"' \
        <<< "$XUI_MANAGED_INBOUND_JSON")
}

_xui_build_reality_inbound_payload() (
    [[ $# -eq 11 ]] || exit 2
    local port=$1 uuid=$2 email=$3 sub_id=$4 target=$5 sni=$6 short_id=$7
    local private_key=$8 public_key=$9 remark=${10} tag=${11}
    local temp_dir uuid_file email_file sub_id_file target_file sni_file
    local short_id_file private_key_file public_key_file remark_file tag_file

    umask 077
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/one-key-proxy-reality.XXXXXX") || exit 1
    uuid_file=$temp_dir/uuid
    email_file=$temp_dir/email
    sub_id_file=$temp_dir/sub-id
    target_file=$temp_dir/target
    sni_file=$temp_dir/sni
    short_id_file=$temp_dir/short-id
    private_key_file=$temp_dir/private-key
    public_key_file=$temp_dir/public-key
    remark_file=$temp_dir/remark
    tag_file=$temp_dir/tag
    trap 'rm -f -- "$uuid_file" "$email_file" "$sub_id_file" "$target_file" "$sni_file" "$short_id_file" "$private_key_file" "$public_key_file" "$remark_file" "$tag_file"; rmdir -- "$temp_dir" 2> /dev/null || true' EXIT
    trap 'exit 1' HUP INT TERM

    # printf is a Bash builtin. Each value is therefore written without ever
    # becoming an external command argument, and --rawfile preserves it exactly.
    printf '%s' "$uuid" > "$uuid_file"
    printf '%s' "$email" > "$email_file"
    printf '%s' "$sub_id" > "$sub_id_file"
    printf '%s' "$target" > "$target_file"
    printf '%s' "$sni" > "$sni_file"
    printf '%s' "$short_id" > "$short_id_file"
    printf '%s' "$private_key" > "$private_key_file"
    printf '%s' "$public_key" > "$public_key_file"
    printf '%s' "$remark" > "$remark_file"
    printf '%s' "$tag" > "$tag_file"

    jq -nc \
        --argjson port "$port" \
        --rawfile uuid "$uuid_file" --rawfile email "$email_file" \
        --rawfile subId "$sub_id_file" --rawfile target "$target_file" \
        --rawfile sni "$sni_file" --rawfile sid "$short_id_file" \
        --rawfile privateKey "$private_key_file" --rawfile publicKey "$public_key_file" \
        --rawfile remark "$remark_file" --rawfile tag "$tag_file" '
        {
            enable: true, remark: $remark, listen: "", port: $port,
            protocol: "vless", expiryTime: 0, total: 0, tag: $tag,
            shareAddr: "", shareAddrStrategy: "node",
            settings: {
                clients: [{id: $uuid, email: $email, flow: "xtls-rprx-vision",
                    limitIp: 0, totalGB: 0, expiryTime: 0, enable: true,
                    tgId: 0, subId: $subId, comment: "", reset: 0}],
                decryption: "none", encryption: "none", fallbacks: []
            },
            streamSettings: {
                network: "tcp", security: "reality",
                tcpSettings: {acceptProxyProtocol: false, header: {type: "none"}},
                realitySettings: {
                    show: false, xver: 0, target: $target, serverNames: [$sni],
                    privateKey: $privateKey, minClientVer: "1.0.0",
                    maxClientVer: "", maxTimediff: 0, shortIds: [$sid],
                    mldsa65Seed: "",
                    settings: {publicKey: $publicKey, fingerprint: "chrome",
                        serverName: "", spiderX: "/", mldsa65Verify: ""}
                }
            },
            sniffing: {enabled: true, destOverride: ["http", "tls", "quic", "fakedns"],
                metadataOnly: false, routeOnly: false, ipsExcluded: [], domainsExcluded: []}
        }
    '
)

# Ensure exactly one managed VLESS+TCP+REALITY+Vision inbound. Existing managed
# credentials are preserved; only minClientVer is repaired on a resumed run.
# Args: port uuid email sub-id target sni short-id [remark] [tag]
xui_ensure_vless_reality_inbound() {
    [[ $# -ge 7 && $# -le 9 ]] || return 2
    local port=$1 uuid=$2 email=$3 sub_id=$4 target=$5 sni=$6 short_id=$7
    local remark=${8:-$XUI_MANAGED_REMARK} tag=${9:-$XUI_MANAGED_TAG}
    local find_status payload created

    XUI_MANAGED_REMARK=$remark
    XUI_MANAGED_TAG=$tag
    if xui_find_managed_inbound; then
        if ! jq -e '.protocol == "vless" and .streamSettings.network == "tcp" and
            .streamSettings.security == "reality" and
            .settings.clients[0].flow == "xtls-rprx-vision"' \
            > /dev/null <<< "$XUI_MANAGED_INBOUND_JSON"; then
            _xui_error 'Managed inbound identity exists but is not VLESS TCP REALITY Vision'
            return 1
        fi
        _xui_enforce_min_client_version || return 1
        _xui_existing_inbound_values
        declare -g XUI_MANAGED_INBOUND_CREATED=false
        return 0
    else
        find_status=$?
        ((find_status == 1)) || return "$find_status"
    fi

    [[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || return 2
    [[ $short_id =~ ^([0-9A-Fa-f]{2}){1,8}$ ]] || {
        _xui_error 'REALITY short ID must be 2-16 even-length hexadecimal characters'
        return 2
    }
    [[ -n $uuid && -n $email && -n $sub_id && -n $target && -n $sni ]] || return 2
    if [[ -z ${XUI_REALITY_PRIVATE_KEY:-} || -z ${XUI_REALITY_PUBLIC_KEY:-} ]]; then
        xui_generate_x25519 || return 1
    fi
    if declare -F secret_register > /dev/null 2>&1; then
        secret_register "$uuid"
        secret_register "$sub_id"
        secret_register "$short_id"
        secret_register "$XUI_REALITY_PRIVATE_KEY"
    fi
    payload=$(_xui_build_reality_inbound_payload \
        "$port" "$uuid" "$email" "$sub_id" "$target" "$sni" "$short_id" \
        "$XUI_REALITY_PRIVATE_KEY" "$XUI_REALITY_PUBLIC_KEY" "$remark" "$tag") || return 1
    created=$(xui_api_post /panel/api/inbounds/add "$payload") || return 1
    payload=''
    declare -g XUI_MANAGED_INBOUND_ID
    XUI_MANAGED_INBOUND_ID=$(jq -r '.id // empty' <<< "$created")
    [[ $XUI_MANAGED_INBOUND_ID =~ ^[0-9]+$ ]] || {
        _xui_error '3x-ui created the inbound but did not return its numeric ID'
        return 1
    }
    declare -g XUI_CLIENT_UUID="$uuid" XUI_CLIENT_EMAIL="$email" XUI_SUB_ID="$sub_id"
    declare -g XUI_REALITY_SHORT_ID="$short_id"
    declare -g XUI_MANAGED_INBOUND_CREATED=true
}

xui_create_vless_reality_inbound() {
    xui_ensure_vless_reality_inbound "$@"
}

# Create or replace the managed Hosts group that advertises an external NAT or
# public endpoint. Args: inbound-id public-address external-port [remark] [tag]
xui_ensure_external_host() {
    [[ $# -ge 3 && $# -le 5 ]] || return 2
    local inbound_id=$1 public_address=$2 external_port=$3
    local remark=${4:-$XUI_MANAGED_HOST_REMARK} tag=${5:-$XUI_MANAGED_HOST_TAG}
    local groups matches count group_id payload result stored_group_id=''
    [[ $inbound_id =~ ^[0-9]+$ ]] || return 2
    [[ $external_port =~ ^[0-9]+$ ]] && ((external_port >= 1 && external_port <= 65535)) || return 2
    [[ -n $public_address && $public_address != */* ]] || return 2
    [[ -n $tag && $tag != *[[:cntrl:]]* ]] || return 2
    if ! stored_group_id=$(_xui_state_get HOST_GROUP_ID); then
        stored_group_id=''
    fi

    groups=$(xui_api_get "/panel/api/hosts/byInbound/$inbound_id") || return 1
    [[ $groups == null ]] && groups='[]'
    matches=$(jq -c --arg tag "$tag" '
        [.[] | select(
            (.tags // null) as $tags |
            if ($tags | type) == "array" then
                any($tags[]; . == $tag)
            else false end
        )]
    ' <<< "$groups") || return 1
    count=$(jq 'length' <<< "$matches") || return 1
    if ((count > 1)); then
        _xui_error 'Multiple Hosts groups match the one-key-proxy identity; refusing to guess'
        return 1
    fi
    group_id=''
    if ((count == 1)); then
        group_id=$(jq -r '.[0].groupId // empty' <<< "$matches")
        [[ -n $group_id && $group_id != *[[:cntrl:]]* ]] || return 1
        if [[ -n $stored_group_id && $group_id != "$stored_group_id" ]]; then
            _xui_error 'Managed Hosts tag resolves to a group ID different from project state'
            return 1
        fi
    elif [[ -n $stored_group_id ]]; then
        _xui_error 'Stored Hosts group ID exists, but no group has the exact managed tag'
        return 1
    fi

    public_address=${public_address#\[}
    public_address=${public_address%\]}
    payload=$(jq -nc --argjson inbound "$inbound_id" --arg host "$public_address" \
        --argjson port "$external_port" --arg remark "$remark" --arg tag "$tag" '
        {inboundIds: [$inbound], hosts: [$host], port: $port,
         remark: $remark, tags: [$tag], security: "same",
         isDisabled: false, isHidden: false, excludeFromSubTypes: [],
         mihomoIpVersion: "dual"}
    ') || return 1
    if [[ -n $group_id ]]; then
        result=$(xui_api_post "/panel/api/hosts/update/$group_id" "$payload") || return 1
    else
        result=$(xui_api_post /panel/api/hosts/add "$payload") || return 1
        group_id=$(jq -r '.[0].groupId // empty' <<< "$result")
    fi
    [[ -n $group_id ]] || {
        _xui_error '3x-ui did not return a Hosts group ID'
        return 1
    }
    declare -g XUI_MANAGED_HOST_GROUP_ID="$group_id"
}

xui_fetch_sub_links() {
    [[ $# -eq 1 ]] || return 2
    local sub_id=$1 links
    [[ $sub_id =~ ^[A-Za-z0-9_-]+$ ]] || return 2
    if declare -F secret_register > /dev/null 2>&1; then
        secret_register "$sub_id"
    fi
    links=$(xui_api_get "/panel/api/clients/subLinks/$sub_id") || return 1
    jq -e 'type == "array" and all(.[]; type == "string")' > /dev/null 2>&1 <<< "$links" || {
        _xui_error '3x-ui subLinks response is not a string array'
        return 1
    }
    declare -g XUI_SUB_LINKS_JSON="$links"
}

xui_get_sub_links() {
    [[ $# -eq 1 ]] || return 2
    xui_fetch_sub_links "$1" || return 1
    printf '%s\n' "$XUI_SUB_LINKS_JSON"
}

xui_build_subscription_urls() {
    [[ $# -eq 4 ]] || return 2
    local scheme=$1 host=$2 port=$3 sub_id=$4 origin
    origin=$(_xui_public_origin "$scheme" "$host" "$port") || return 1
    declare -g XUI_SUBSCRIPTION_URL="$origin/sub/$sub_id"
    declare -g XUI_JSON_SUBSCRIPTION_URL="$origin/json/$sub_id"
    declare -g XUI_CLASH_SUBSCRIPTION_URL="$origin/clash/$sub_id"
}
