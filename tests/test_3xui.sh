#!/usr/bin/env bash

set -uo pipefail
# shellcheck source=test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

command -v jq >/dev/null 2>&1 || {
  printf 'jq is required for 3x-ui tests\n' >&2
  exit 1
}
REAL_JQ=$(command -v jq)

TEST_SANDBOX=$(make_test_temp_dir)
trap 'rm -rf -- "$TEST_SANDBOX"' EXIT

# shellcheck source=../lib/3xui.sh
source "$PROJECT_ROOT/lib/3xui.sh"

test_subscription_urls_handle_default_ports_and_ipv6() {
  xui_build_subscription_urls https 198.51.100.9 443 abc_DEF-123
  assert_eq 'https://198.51.100.9/sub/abc_DEF-123' "$XUI_SUBSCRIPTION_URL"
  assert_eq 'https://198.51.100.9/json/abc_DEF-123' "$XUI_JSON_SUBSCRIPTION_URL"
  assert_eq 'https://198.51.100.9/clash/abc_DEF-123' "$XUI_CLASH_SUBSCRIPTION_URL"

  xui_build_subscription_urls https 2001:db8::5 2096 subid
  assert_eq 'https://[2001:db8::5]:2096/sub/subid' "$XUI_SUBSCRIPTION_URL"
}

test_tls_api_identity_switches_only_after_activation() {
  declare -A tls_state=(
    [PUBLIC_IPV4]=198.51.100.10
    [FQDN]=old.example.com
    [XUI_TLS_TRANSITION_STATUS]=preparing
    [XUI_TLS_TRANSITION_HOST]=new.example.com
  )
  _xui_state_get() {
    [[ -n ${tls_state[$1]+present} ]] || return 1
    printf '%s' "${tls_state[$1]}"
  }

  assert_eq old.example.com "$(_xui_api_tls_identity_host public)"
  tls_state[XUI_TLS_TRANSITION_STATUS]=active
  assert_eq new.example.com "$(_xui_api_tls_identity_host public)"

  unset 'tls_state[XUI_TLS_TRANSITION_HOST]'
  assert_failure _xui_api_tls_identity_host public
  tls_state[XUI_TLS_TRANSITION_HOST]=new.example.com
  tls_state[XUI_TLS_TRANSITION_STATUS]=unknown
  assert_failure _xui_api_tls_identity_host public
}

test_vless_uri_validation_binds_security_fields() {
  local uuid=11111111-2222-4333-8444-555555555555
  local sni=www.cloudflare.com public_key=Public_key-123 short_id=a1b2c3d4
  local query uri
  query="encryption=none&type=tcp&security=reality&flow=xtls-rprx-vision&sni=${sni}&pbk=${public_key}&sid=${short_id}&fp=chrome"
  uri="vless://${uuid}@198.51.100.9:8443?${query}#node"

  xui_vless_uri_matches "$uri" 198.51.100.9 8443 "$uuid" "$sni" "$public_key" "$short_id"
  assert_failure xui_vless_uri_matches "$uri" 198.51.100.9 443 "$uuid" "$sni" "$public_key" "$short_id"
  assert_failure xui_vless_uri_matches "${uri/flow=xtls-rprx-vision/flow=none}" \
    198.51.100.9 8443 "$uuid" "$sni" "$public_key" "$short_id"
  assert_failure xui_vless_uri_matches "${uri/&pbk=${public_key}/}" \
    198.51.100.9 8443 "$uuid" "$sni" "$public_key" "$short_id"
  assert_failure xui_vless_uri_matches "${uri%#node}&sid=deadbeef#node" \
    198.51.100.9 8443 "$uuid" "$sni" "$public_key" "$short_id"
}

test_json_subscription_validation_matches_official_forms() {
  local document=$TEST_SANDBOX/subscription.json
  local uuid=11111111-2222-4333-8444-555555555555
  local sni=reality.example.com public_key=Public_key-123 short_id=a1b2c3d4
  local outbound

  outbound=$(jq -nc --arg host 198.51.100.9 --argjson port 8443 \
    --arg uuid "$uuid" --arg sni "$sni" --arg public "$public_key" --arg sid "$short_id" '
    {
      protocol: "vless", tag: "proxy",
      settings: {address: $host, port: $port, id: $uuid,
        encryption: "none", flow: "xtls-rprx-vision", level: 8},
      streamSettings: {
        network: "tcp", security: "reality",
        tcpSettings: {header: {type: "none"}},
        realitySettings: {serverName: $sni, publicKey: $public,
          shortId: $sid, fingerprint: "chrome"}
      }
    }
  ')
  jq -nc --argjson outbound "$outbound" '{outbounds: [$outbound, {protocol: "freedom"}]}' >"$document"
  xui_json_subscription_matches \
    "$document" 198.51.100.9 8443 "$uuid" "$sni" "$public_key" "$short_id"

  jq -nc --argjson outbound "$outbound" '[{outbounds: [$outbound]}]' >"$document"
  xui_json_subscription_matches \
    "$document" 198.51.100.9 8443 "$uuid" "$sni" "$public_key" "$short_id"

  jq -nc --arg uuid "$uuid" --arg sni "$sni" --arg public "$public_key" --arg sid "$short_id" '
    [{outbounds: [{
      protocol: "vless",
      settings: {vnext: [{address: "2001:db8::5", port: 2443,
        users: [{id: $uuid, encryption: "none", flow: "xtls-rprx-vision"}]}]},
      streamSettings: {network: "tcp", security: "reality",
        realitySettings: {serverName: $sni, publicKey: $public,
          shortId: $sid, fingerprint: "chrome"}}
    }]}]
  ' >"$document"
  xui_json_subscription_matches \
    "$document" '[2001:db8::5]' 2443 "$uuid" "$sni" "$public_key" "$short_id"
}

test_json_subscription_validation_rejects_conflicts_and_duplicates() {
  local document=$TEST_SANDBOX/subscription-invalid.json
  local uuid=11111111-2222-4333-8444-555555555555
  local sni=reality.example.com public_key=Public_key-123 short_id=a1b2c3d4
  local outbound

  outbound=$(jq -nc --arg uuid "$uuid" --arg sni "$sni" --arg public "$public_key" --arg sid "$short_id" '
    {protocol: "vless",
      settings: {address: "198.51.100.9", port: 8443, id: $uuid,
        encryption: "none", flow: "xtls-rprx-vision"},
      streamSettings: {network: "tcp", security: "reality",
        realitySettings: {serverName: $sni, publicKey: $public,
          shortId: $sid, fingerprint: "chrome"}}}
  ')

  jq -nc --argjson outbound "$outbound" '{outbounds: [$outbound]}
    | .outbounds[0].streamSettings.realitySettings.publicKey = "wrong"' >"$document"
  assert_failure xui_json_subscription_matches \
    "$document" 198.51.100.9 8443 "$uuid" "$sni" "$public_key" "$short_id"

  jq -nc --argjson outbound "$outbound" '{outbounds: [$outbound, $outbound]}' >"$document"
  assert_failure xui_json_subscription_matches \
    "$document" 198.51.100.9 8443 "$uuid" "$sni" "$public_key" "$short_id"

  jq -nc --argjson outbound "$outbound" '{outbounds: [$outbound,
    ($outbound | .settings.port = 9443 | .streamSettings.security = "tls")]}' >"$document"
  assert_failure xui_json_subscription_matches \
    "$document" 198.51.100.9 8443 "$uuid" "$sni" "$public_key" "$short_id"

  jq -nc --argjson outbound "$outbound" '{outbounds: [$outbound,
    {protocol: "trojan", settings: {servers: [{address: "198.51.100.9", port: 8443}]}}]}' >"$document"
  assert_failure xui_json_subscription_matches \
    "$document" 198.51.100.9 8443 "$uuid" "$sni" "$public_key" "$short_id"
}

test_clash_subscription_validation_handles_quoted_scalars_and_ipv6() {
  local document=$TEST_SANDBOX/subscription.yaml
  local uuid=11111111-2222-4333-8444-555555555555
  local sni=reality.example.com public_key=Public_key-123 short_id=2351e1

  printf '%s\n' \
    'proxies:' \
    '- name: reality-node' \
    '  type: vless' \
    '  server: "2001:db8::5"' \
    '  port: "2443"' \
    "  uuid: '${uuid}'" \
    '  network: tcp' \
    '  tls: true' \
    '  flow: xtls-rprx-vision' \
    "  servername: '${sni}'" \
    '  client-fingerprint: chrome' \
    '  reality-opts:' \
    "    public-key: '${public_key}'" \
    "    short-id: '${short_id}'" \
    '- name: unrelated-ws-node' \
    '  type: vmess' \
    '  server: 203.0.113.50' \
    '  port: 443' \
    '  uuid: aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' \
    '  network: ws' \
    '  tls: true' \
    '  ws-opts:' \
    '    path: /socket' \
    '    headers:' \
    '      Host: ws.example.com' \
    'proxy-groups:' \
    '- name: PROXY' >"$document"

  xui_clash_subscription_matches \
    "$document" '[2001:db8::5]' 2443 "$uuid" "$sni" "$public_key" "$short_id"
}

test_clash_subscription_validation_rejects_ambiguity() {
  local document=$TEST_SANDBOX/subscription-invalid.yaml
  local uuid=11111111-2222-4333-8444-555555555555
  local sni=reality.example.com public_key=Public_key-123 short_id=a1b2c3d4
  local proxy

  proxy=$(printf '%s\n' \
    '- name: reality-node' \
    '  type: vless' \
    '  server: 198.51.100.9' \
    '  port: 8443' \
    "  uuid: ${uuid}" \
    '  network: tcp' \
    '  tls: true' \
    '  flow: xtls-rprx-vision' \
    "  servername: ${sni}" \
    '  client-fingerprint: chrome' \
    '  reality-opts:' \
    "    public-key: ${public_key}" \
    "    short-id: ${short_id}")

  printf 'proxies:\n%s\n%s\n' "$proxy" "$proxy" >"$document"
  assert_failure xui_clash_subscription_matches \
    "$document" 198.51.100.9 8443 "$uuid" "$sni" "$public_key" "$short_id"

  printf 'proxies:\n%s\n  uuid: %s\n' "$proxy" "$uuid" >"$document"
  assert_failure xui_clash_subscription_matches \
    "$document" 198.51.100.9 8443 "$uuid" "$sni" "$public_key" "$short_id"

  printf 'proxies:\n%s\n' "${proxy/Public_key-123/wrong-key}" >"$document"
  assert_failure xui_clash_subscription_matches \
    "$document" 198.51.100.9 8443 "$uuid" "$sni" "$public_key" "$short_id"
}

write_local_subscription_fixtures() {
  local directory=$1 host=$2 port=$3 uuid=$4 sni=$5 public_key=$6 short_id=$7
  local uri outbound
  uri="vless://${uuid}@${host}:${port}?encryption=none&type=tcp&security=reality&flow=xtls-rprx-vision&sni=${sni}&pbk=${public_key}&sid=${short_id}&fp=chrome#node"
  printf '%s\n' "$uri" | base64 | tr -d '\n' >"$directory/sub"
  printf '%s\n' "${uri/:${port}?/:$((port + 1))?}" | base64 | tr -d '\n' >"$directory/sub.bad"

  outbound=$(jq -nc --arg host "$host" --argjson port "$port" --arg uuid "$uuid" \
    --arg sni "$sni" --arg public "$public_key" --arg sid "$short_id" '
    {protocol:"vless", settings:{address:$host, port:$port, id:$uuid,
      encryption:"none", flow:"xtls-rprx-vision"},
      streamSettings:{network:"tcp", security:"reality", tcpSettings:{header:{type:"none"}},
        realitySettings:{serverName:$sni, publicKey:$public, shortId:$sid, fingerprint:"chrome"}}}
  ')
  jq -nc --argjson outbound "$outbound" '{outbounds:[$outbound]}' >"$directory/json"
  jq -nc --argjson outbound "$outbound" '{outbounds:[$outbound]}
    | .outbounds[0].streamSettings.realitySettings.publicKey = "wrong-key"' >"$directory/json.bad"

  printf '%s\n' \
    'proxies:' \
    '- name: reality-node' \
    '  type: vless' \
    "  server: ${host}" \
    "  port: ${port}" \
    "  uuid: ${uuid}" \
    '  network: tcp' \
    '  tls: true' \
    '  flow: xtls-rprx-vision' \
    "  servername: ${sni}" \
    '  client-fingerprint: chrome' \
    '  encryption: none' \
    '  reality-opts:' \
    "    public-key: ${public_key}" \
    "    short-id: ${short_id}" >"$directory/clash"
  sed "s/short-id: ${short_id}/short-id: deadbeef/" \
    "$directory/clash" >"$directory/clash.bad"
}

test_local_subscription_verification_uses_loopback_for_nat_mapping() (
  local fixture_dir=$TEST_SANDBOX/local-subscription-success
  local audit=$fixture_dir/curl-audit cert_file=$fixture_dir/server.crt
  local host=198.51.100.44 sub_internal_port=24444 node_external_port=56667
  local sub_id=natSub_123 uuid=11111111-2222-4333-8444-555555555555
  local sni=www.cloudflare.com public_key=Public_key-123 short_id=a1b2c3d4
  local output_file='' url='' resolve='' cacert='' decoded
  mkdir -p "$fixture_dir"
  : >"$audit"
  printf 'test certificate\n' >"$cert_file"
  write_local_subscription_fixtures "$fixture_dir" "$host" "$node_external_port" \
    "$uuid" "$sni" "$public_key" "$short_id"
  decoded=$(base64 -d <"$fixture_dir/sub")
  xui_vless_uri_matches "$decoded" "$host" "$node_external_port" "$uuid" "$sni" \
    "$public_key" "$short_id" || fail 'decoded Base64 fixture does not match deployment'
  assert_status 0 xui_base64_subscription_matches "$fixture_dir/sub" "$host" \
    "$node_external_port" "$uuid" "$sni" "$public_key" "$short_id"
  xui_json_subscription_matches "$fixture_dir/json" "$host" "$node_external_port" \
    "$uuid" "$sni" "$public_key" "$short_id" || fail 'valid JSON fixture was rejected'
  xui_clash_subscription_matches "$fixture_dir/clash" "$host" "$node_external_port" \
    "$uuid" "$sni" "$public_key" "$short_id" || fail 'valid Clash fixture was rejected'

  curl() {
    output_file='' url='' resolve='' cacert=''
    while (($#)); do
      case $1 in
        --output) output_file=$2; shift 2 ;;
        --url) url=$2; shift 2 ;;
        --resolve) resolve=$2; shift 2 ;;
        --cacert) cacert=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s|%s|%s\n' "$cacert" "$resolve" "$url" >>"$audit"
    case $url in
      */sub/*) command cp "$fixture_dir/sub" "$output_file" ;;
      */json/*) command cp "$fixture_dir/json" "$output_file" ;;
      */clash/*) command cp "$fixture_dir/clash" "$output_file" ;;
      *) return 22 ;;
    esac
    printf '200'
  }

  xui_verify_local_subscriptions "$host" "$sub_internal_port" "$node_external_port" \
    "$sub_id" "$cert_file" "$uuid" "$sni" "$public_key" "$short_id" 1 0

  assert_eq 3 "$(wc -l <"$audit" | tr -d ' ')"
  assert_contains "$(<"$audit")" \
    "${cert_file}|${host}:${sub_internal_port}:127.0.0.1|https://${host}:${sub_internal_port}/sub/${sub_id}"
  assert_contains "$(<"$audit")" "https://${host}:${sub_internal_port}/json/${sub_id}"
  assert_contains "$(<"$audit")" "https://${host}:${sub_internal_port}/clash/${sub_id}"
  assert_failure grep -Fq "https://${host}:${node_external_port}/" "$audit"
)

test_local_subscription_verification_rejects_each_bad_format() (
  local fixture_dir=$TEST_SANDBOX/local-subscription-failures
  local cert_file=$fixture_dir/server.crt host=198.51.100.45
  local sub_internal_port=24445 node_external_port=56668 sub_id=natSub_456
  local uuid=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee sni=www.cloudflare.com
  local public_key=Public_key-456 short_id=11223344 broken_format=''
  local output_file='' url='' source_file=''
  mkdir -p "$fixture_dir"
  printf 'test certificate\n' >"$cert_file"
  write_local_subscription_fixtures "$fixture_dir" "$host" "$node_external_port" \
    "$uuid" "$sni" "$public_key" "$short_id"

  curl() {
    output_file='' url=''
    while (($#)); do
      case $1 in
        --output) output_file=$2; shift 2 ;;
        --url) url=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    case $url in
      */sub/*) source_file=$fixture_dir/sub ;;
      */json/*) source_file=$fixture_dir/json ;;
      */clash/*) source_file=$fixture_dir/clash ;;
      *) return 22 ;;
    esac
    [[ $url == */"${broken_format}"/* ]] && source_file=${source_file}.bad
    command cp "$source_file" "$output_file"
    printf '200'
  }

  for broken_format in sub json clash; do
    assert_failure xui_verify_local_subscriptions "$host" "$sub_internal_port" \
      "$node_external_port" "$sub_id" "$cert_file" "$uuid" "$sni" "$public_key" \
      "$short_id" 1 0
  done
)

test_error_logging_strips_terminal_controls_and_redacts() {
  local audit=$TEST_SANDBOX/error-log-audit
  local calls=$TEST_SANDBOX/error-log-calls
  : >"$audit"
  : >"$calls"
  redact_sensitive() {
    printf 'redact\n' >>"$calls"
    printf '%s' "${1//top-secret-value/[REDACTED]}"
  }
  safe_log_error() {
    local redacted
    printf 'safe\n' >>"$calls"
    redacted=$(redact_sensitive "$*")
    printf '%s' "$redacted" >"$audit"
  }

  _xui_error $'prefix \033[31mRED\033[0m \033]0;osc-bell\a \033]2;osc-st\033\\ password=top-secret-value\nnext\tfield\001 suffix'

  local logged
  logged=$(<"$audit")
  assert_eq $'safe\nredact' "$(<"$calls")" '_xui_error must use safe_log_error and its redaction path'
  assert_failure grep -Fq 'top-secret-value' <<<"$logged"
  assert_failure grep -Fq 'osc-bell' <<<"$logged"
  assert_failure grep -Fq 'osc-st' <<<"$logged"
  [[ $logged != *$'\033'* && $logged != *$'\001'* ]] || fail 'control characters reached the error sink'
  assert_failure grep -Fq '[31m' <<<"$logged"
  assert_contains "$logged" 'prefix RED'
  assert_contains "$logged" 'password=[REDACTED] next field suffix'
}

test_reality_secrets_use_rawfiles_not_jq_argv() {
  local audit=$TEST_SANDBOX/jq-argv-audit
  local uuid=11111111-2222-4333-8444-555555555555
  local sub_id=sub-sensitive-987654
  local short_id=a1b2c3d4
  local private_key=private-sensitive-value-123
  local public_key=public-sensitive-value-456
  local payload arg
  : >"$audit"

  jq() {
    local item
    for item in "$@"; do
      printf '%q ' "$item" >>"$audit"
    done
    printf '\n' >>"$audit"
    "$REAL_JQ" "$@"
  }

  payload=$(_xui_build_reality_inbound_payload \
    8443 "$uuid" client@example.com "$sub_id" \
    www.cloudflare.com:443 www.cloudflare.com "$short_id" \
    "$private_key" "$public_key" managed-remark managed-tag)

  for arg in "$uuid" "$sub_id" "$short_id" "$private_key" "$public_key"; do
    assert_failure grep -Fq -- "$arg" "$audit"
  done
  assert_contains "$(<"$audit")" '--rawfile uuid'
  assert_contains "$(<"$audit")" '--rawfile subId'
  assert_contains "$(<"$audit")" '--rawfile privateKey'
  assert_contains "$(<"$audit")" '--rawfile publicKey'
  "$REAL_JQ" -e --arg uuid "$uuid" --arg sub "$sub_id" --arg sid "$short_id" \
    --arg private "$private_key" --arg public "$public_key" '
      .settings.clients[0].id == $uuid and
      .settings.clients[0].subId == $sub and
      .streamSettings.realitySettings.shortIds[0] == $sid and
      .streamSettings.realitySettings.privateKey == $private and
      .streamSettings.realitySettings.settings.publicKey == $public
    ' >/dev/null <<<"$payload" || fail 'REALITY rawfile values did not survive JSON construction'
}

test_inbound_ownership_requires_exact_tag_and_state_id() {
  local mock_inbound_state_id='' mock_inbound_rows='[]'
  XUI_MANAGED_TAG=one-key-proxy-managed-tag
  unset XUI_MANAGED_INBOUND_ID XUI_MANAGED_INBOUND_JSON
  state_get() {
    [[ $1 == INBOUND_ID && -n $mock_inbound_state_id ]] || return 1
    printf '%s' "$mock_inbound_state_id"
  }
  xui_api_get() {
    [[ $1 == /panel/api/inbounds/list ]] || return 1
    printf '%s\n' "$mock_inbound_rows"
  }

  # A user object may reuse our human-readable remark. Without the exact tag it
  # remains foreign and is treated as absent rather than adopted.
  mock_inbound_rows='[{"id":40,"remark":"one-key-proxy-vless-reality","tag":"foreign-tag","settings":{},"streamSettings":{},"sniffing":{}}]'
  mock_inbound_state_id=''
  assert_status 1 xui_find_managed_inbound
  [[ ! -v XUI_MANAGED_INBOUND_ID ]] || fail 'foreign inbound was adopted by remark'

  # Once state records ownership, loss of the tag is a hard conflict.
  mock_inbound_state_id=40
  assert_status 2 xui_find_managed_inbound

  # An exact tag is still insufficient when it resolves to a different ID.
  mock_inbound_rows='[{"id":42,"remark":"anything","tag":"one-key-proxy-managed-tag","settings":{},"streamSettings":{},"sniffing":{}}]'
  mock_inbound_state_id=41
  assert_status 2 xui_find_managed_inbound

  mock_inbound_state_id=42
  xui_find_managed_inbound
  assert_eq 42 "$XUI_MANAGED_INBOUND_ID"
  assert_jq '.id == 42 and .tag == "one-key-proxy-managed-tag"' "$XUI_MANAGED_INBOUND_JSON"
}

test_hosts_ownership_requires_exact_tag_and_state_id() {
  local mock_host_state_id='' mock_host_rows='[]'
  local audit=$TEST_SANDBOX/hosts-ownership-audit
  : >"$audit"
  state_get() {
    [[ $1 == HOST_GROUP_ID && -n $mock_host_state_id ]] || return 1
    printf '%s' "$mock_host_state_id"
  }
  xui_api_get() {
    [[ $1 == /panel/api/hosts/byInbound/17 ]] || return 1
    printf '%s\n' "$mock_host_rows"
  }
  xui_api_post() {
    printf '%s\t%s\n' "$1" "${2-}" >>"$audit"
    if [[ $1 == /panel/api/hosts/add ]]; then
      printf '%s\n' '[{"groupId":"new-managed-group"}]'
    else
      printf '%s\n' '{}'
    fi
  }

  # Same remark with a foreign tag creates a separate managed group; it must
  # never update the user's group.
  mock_host_rows='[{"groupId":"foreign-group","remark":"shared-remark","tags":["foreign-tag"]}]'
  mock_host_state_id=''
  xui_ensure_external_host 17 198.51.100.44 56667 shared-remark managed-host-tag
  local path payload
  IFS=$'\t' read -r path payload <"$audit"
  assert_eq /panel/api/hosts/add "$path"
  assert_jq '.remark == "shared-remark" and .tags == ["managed-host-tag"]' "$payload"
  assert_eq new-managed-group "$XUI_MANAGED_HOST_GROUP_ID"

  # A stored group that has lost its tag is an ownership conflict.
  : >"$audit"
  mock_host_state_id=foreign-group
  assert_failure xui_ensure_external_host 17 198.51.100.44 56667 shared-remark managed-host-tag
  assert_eq '' "$(<"$audit")"

  # Exact tag but a different immutable group ID must also be rejected.
  mock_host_rows='[{"groupId":"group-42","remark":"shared-remark","tags":["managed-host-tag"]}]'
  mock_host_state_id=group-41
  assert_failure xui_ensure_external_host 17 198.51.100.44 56667 shared-remark managed-host-tag
  assert_eq '' "$(<"$audit")"

  mock_host_state_id=group-42
  xui_ensure_external_host 17 198.51.100.44 56667 shared-remark managed-host-tag
  IFS=$'\t' read -r path payload <"$audit"
  assert_eq /panel/api/hosts/update/group-42 "$path"
  assert_jq '.hosts == ["198.51.100.44"] and .port == 56667 and .tags == ["managed-host-tag"]' "$payload"
  assert_eq group-42 "$XUI_MANAGED_HOST_GROUP_ID"
}

test_settings_merge_preserves_server_fields_and_drops_ui_flags() {
  local calls=$TEST_SANDBOX/settings-calls
  : >"$calls"
  xui_api_post() {
    local path=$1 body=${2:-'{}'}
    if [[ $path == /panel/api/setting/all ]]; then
      printf '%s\n' '{"webPort":1234,"subEnable":false,"untouched":"keep","hasWebPort":true}'
    else
      printf '%s\t%s\n' "$path" "$body" >>"$calls"
      printf '%s\n' '{}'
    fi
  }

  xui_settings_merge_update '{"webPort":2053,"subEnable":true}'
  local update_path update_body
  IFS=$'\t' read -r update_path update_body <"$calls"
  assert_eq /panel/api/setting/update "$update_path"
  assert_jq '.webPort == 2053 and .subEnable == true and .untouched == "keep" and has("hasWebPort") == false' "$update_body"
}

test_reality_inbound_payload_has_required_contract() {
  local calls=$TEST_SANDBOX/inbound-calls
  : >"$calls"
  unset XUI_REALITY_PRIVATE_KEY XUI_REALITY_PUBLIC_KEY
  xui_api_get() {
    case $1 in
      /panel/api/inbounds/list) printf '%s\n' '[]' ;;
      /panel/api/server/getNewX25519Cert)
        printf '%s\n' '{"privateKey":"private-test","publicKey":"public-test"}'
        ;;
      *) return 1 ;;
    esac
  }
  xui_api_post() {
    local body=${2-}
    [[ -n $body ]] || body='{}'
    printf '%s\t%s\n' "$1" "$body" >>"$calls"
    printf '%s\n' '{"id":17}'
  }

  xui_ensure_vless_reality_inbound \
    8443 11111111-1111-4111-8111-111111111111 client testsub \
    www.cloudflare.com:443 www.cloudflare.com a1b2c3d4

  local path payload
  IFS=$'\t' read -r path payload <"$calls"
  assert_eq /panel/api/inbounds/add "$path"
  assert_jq '
    .port == 8443 and .protocol == "vless" and
    .settings.clients[0].flow == "xtls-rprx-vision" and
    .settings.clients[0].subId == "testsub" and
    .streamSettings.network == "tcp" and
    .streamSettings.security == "reality" and
    .streamSettings.realitySettings.target == "www.cloudflare.com:443" and
    .streamSettings.realitySettings.minClientVer == "1.0.0" and
    .streamSettings.realitySettings.shortIds[0] == "a1b2c3d4" and
    .streamSettings.realitySettings.privateKey == "private-test"
  ' "$payload"
  assert_eq 17 "$XUI_MANAGED_INBOUND_ID"
  assert_eq true "$XUI_MANAGED_INBOUND_CREATED"
}

test_external_host_uses_public_nat_mapping() {
  local calls=$TEST_SANDBOX/host-calls
  : >"$calls"
  xui_api_get() {
    [[ $1 == /panel/api/hosts/byInbound/17 ]] || return 1
    printf '%s\n' '[]'
  }
  xui_api_post() {
    local body=${2-}
    [[ -n $body ]] || body='{}'
    printf '%s\t%s\n' "$1" "$body" >>"$calls"
    printf '%s\n' '[{"groupId":"host-7"}]'
  }

  xui_ensure_external_host 17 198.51.100.44 56667
  local path payload
  IFS=$'\t' read -r path payload <"$calls"
  assert_eq /panel/api/hosts/add "$path"
  assert_jq '.inboundIds == [17] and .hosts == ["198.51.100.44"] and .port == 56667 and .security == "same"' "$payload"
  assert_eq host-7 "$XUI_MANAGED_HOST_GROUP_ID"
}

test_xray_runtime_requires_running_core_and_managed_config() {
  local status_reads_file=$TEST_SANDBOX/xray-status-reads status_reads
  printf '0\n' >"$status_reads_file"
  xui_api_get() {
    case $1 in
      /panel/api/server/status)
        status_reads=$(<"$status_reads_file")
        status_reads=$((status_reads + 1))
        printf '%s\n' "$status_reads" >"$status_reads_file"
        if ((status_reads == 1)); then
          printf '%s\n' '{"xray":{"state":"stop","errorMsg":"","version":"v26.7.28"}}'
        else
          printf '%s\n' '{"xray":{"state":"running","errorMsg":"","version":"v26.7.28"}}'
        fi
        ;;
      /panel/api/server/getConfigJson)
        printf '%s\n' '{"inbounds":[{"tag":"managed-runtime-tag","port":8443}]}'
        ;;
      *) return 1 ;;
    esac
  }

  xui_verify_xray_runtime managed-runtime-tag 8443 4 0
  assert_eq v26.7.28 "$XUI_XRAY_VERSION"
  assert_eq 3 "$(<"$status_reads_file")" 'Xray must be healthy in two consecutive snapshots'

  xui_api_get() {
    case $1 in
      /panel/api/server/status)
        printf '%s\n' '{"xray":{"state":"running","errorMsg":"","version":"v26.7.28"}}'
        ;;
      /panel/api/server/getConfigJson)
        printf '%s\n' '{"inbounds":[{"tag":"foreign-tag","port":8443}]}'
        ;;
      *) return 1 ;;
    esac
  }
  assert_failure xui_verify_xray_runtime managed-runtime-tag 8443 2 0
}

test_api_transport_uses_envelope_and_bearer_config() {
  local audit=$TEST_SANDBOX/curl-audit
  : >"$audit"
  XUI_API_TOKEN='token-value-123'
  XUI_API_BASE_URL='http://127.0.0.1:2053'
  XUI_INSTALL_RESULT_FILE=$TEST_SANDBOX/missing-install-result
  MOCK_HTTP_CODE=200

  curl() {
    local output_file='' config_file='' request_method='' url='' arg
    local saw_disable=false saw_noproxy=false argv_snapshot=$*
    while (($#)); do
      arg=$1
      shift
      case $arg in
        --output) output_file=$1; shift ;;
        --config) config_file=$1; shift ;;
        --request) request_method=$1; shift ;;
        --noproxy) [[ $1 == '*' ]] || return 72; saw_noproxy=true; shift ;;
        --connect-timeout|--max-time|--header|--data-binary|--write-out) shift ;;
        --disable) saw_disable=true ;;
        --silent|--show-error|--insecure) ;;
        http://*|https://*) return 73 ;;
      esac
    done
    grep -Fq 'Authorization: Bearer token-value-123' "$config_file" || return 71
    url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$config_file")
    [[ $argv_snapshot != *'/panel/api/test'* ]] || return 74
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$request_method" "$url" "$(file_mode "$config_file")" "$saw_disable" "$saw_noproxy" >>"$audit"
    printf '%s\n' '{"success":true,"msg":"","obj":{"answer":42}}' >"$output_file"
    printf '%s' "$MOCK_HTTP_CODE"
  }

  local response
  response=$(xui_api_get /panel/api/test)
  assert_jq '.answer == 42' "$response"
  assert_eq $'GET\thttp://127.0.0.1:2053/panel/api/test\t600\ttrue\ttrue' "$(<"$audit")"
  assert_failure xui_api_get /not-a-panel-route
  XUI_API_BASE_URL=https://example.com:2053
  assert_failure xui_api_get /panel/api/test
}

test_api_transport_rejects_http_and_bad_envelopes() {
  XUI_API_TOKEN='token-value-123'
  XUI_API_BASE_URL='http://127.0.0.1:2053'
  XUI_INSTALL_RESULT_FILE=$TEST_SANDBOX/missing-install-result
  MOCK_HTTP_CODE=503
  MOCK_BODY='{"success":true,"obj":{}}'
  curl() {
    local output_file='' arg
    while (($#)); do
      arg=$1
      shift
      case $arg in
        --output) output_file=$1; shift ;;
        --config|--request|--connect-timeout|--max-time|--header|--data-binary|--write-out) shift ;;
      esac
    done
    printf '%s\n' "$MOCK_BODY" >"$output_file"
    printf '%s' "$MOCK_HTTP_CODE"
  }
  assert_failure xui_api_get /panel/api/test

  MOCK_HTTP_CODE=200
  MOCK_BODY='{"obj":{}}'
  assert_failure xui_api_get /panel/api/test
}

test_candidate_api_token_is_validated_in_isolated_context() {
  local audit=$TEST_SANDBOX/token-validate-audit
  : >"$audit"
  XUI_API_TOKEN=old-token-value
  XUI_API_BASE_URL=http://127.0.0.1:2053
  XUI_INSTALL_RESULT_FILE=$TEST_SANDBOX/missing-install-result
  _xui_api_request() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$4" >>"$audit"
    printf '%s\n' '[{"id":9,"name":"replacement","enabled":true}]'
  }

  xui_validate_api_token replacement-token-value 9 replacement
  assert_eq $'GET\t/panel/api/setting/apiTokens\treplacement-token-value' "$(<"$audit")"
  assert_eq 9 "$XUI_VALIDATED_API_TOKEN_ID"
  assert_eq replacement "$XUI_VALIDATED_API_TOKEN_NAME"
  assert_failure xui_validate_api_token replacement-token-value 9 wrong-name
  assert_failure xui_validate_api_token $'bad\ntoken' 9 replacement
}

test_api_token_creation_validates_one_time_secret() {
  local audit=$TEST_SANDBOX/token-create-audit
  : >"$audit"
  secret_register() { printf 'secret\t%s\n' "$1" >>"$audit"; }
  xui_api_post() {
    printf 'post\t%s\t%s\n' "$1" "${2-}" >>"$audit"
    printf '%s\n' '{"id":12,"name":"managed-token","token":"new-token-value","enabled":true}'
  }
  xui_validate_api_token() {
    printf 'validate\t%s\t%s\t%s\n' "$1" "$2" "$3" >>"$audit"
  }

  xui_create_api_token managed-token
  assert_eq 12 "$XUI_CREATED_API_TOKEN_ID"
  assert_eq managed-token "$XUI_CREATED_API_TOKEN_NAME"
  assert_eq new-token-value "$XUI_CREATED_API_TOKEN_VALUE"
  local calls
  calls=$(<"$audit")
  assert_contains "$calls" $'post\t/panel/api/setting/apiTokens/create\t{"name":"managed-token"}'
  assert_contains "$calls" $'secret\tnew-token-value'
  assert_contains "$calls" $'validate\tnew-token-value\t12\tmanaged-token'
}

test_api_token_rotation_switches_before_old_token_deletion() {
  local audit=$TEST_SANDBOX/token-rotation-audit
  : >"$audit"
  xui_create_api_token() {
    printf 'create:%s\n' "$1" >>"$audit"
    XUI_CREATED_API_TOKEN_ID=22
    XUI_CREATED_API_TOKEN_NAME=$1
    XUI_CREATED_API_TOKEN_VALUE=new-secret-value
  }
  xui_switch_api_token_context() {
    printf 'switch:%s:%s:%s\n' "$1" "$2" "$3" >>"$audit"
  }
  xui_delete_api_token_by_id() {
    printf 'delete:%s:%s\n' "$1" "$2" >>"$audit"
  }
  xui_recover_pending_api_token() { return 0; }
  xui_validate_api_token() { return 0; }
  state_set_many() { return 0; }
  state_unset_many() { return 0; }
  state_get() {
    case $1 in
      XUI_API_TOKEN) printf '%s' old-secret-value ;;
      XUI_API_TOKEN_ID) printf '%s' 7 ;;
      XUI_API_TOKEN_NAME) printf '%s' old-managed-token ;;
      *) return 1 ;;
    esac
  }

  xui_rotate_api_token one-key-proxy-rotated-token 7
  assert_eq $'create:one-key-proxy-rotated-token\nswitch:new-secret-value:22:one-key-proxy-rotated-token\ndelete:7:old-managed-token' "$(<"$audit")"
  assert_eq 22 "$XUI_ROTATED_API_TOKEN_ID"
  assert_eq one-key-proxy-rotated-token "$XUI_ROTATED_API_TOKEN_NAME"
  assert_eq new-secret-value "$XUI_ROTATED_API_TOKEN_VALUE"
}

test_api_token_delete_binds_id_to_expected_name() {
  local audit=$TEST_SANDBOX/token-delete-audit
  local reads=0
  : >"$audit"
  state_get() {
    [[ $1 == XUI_API_TOKEN_ID ]] || return 1
    printf '%s' 22
  }
  xui_api_tokens_read() {
    reads=$((reads + 1))
    if ((reads == 1)); then
      XUI_API_TOKENS_JSON='[{"id":7,"name":"old-managed-token","enabled":true}]'
    else
      XUI_API_TOKENS_JSON='[]'
    fi
  }
  xui_api_post() {
    printf '%s\t%s\n' "$1" "${2-}" >>"$audit"
    printf '%s\n' '{}'
  }

  assert_failure xui_delete_api_token_by_id 7 unexpected-name
  assert_eq '' "$(<"$audit")" 'name mismatch must not call the delete API'

  reads=0
  xui_delete_api_token_by_id 7 old-managed-token
  assert_eq $'/panel/api/setting/apiTokens/delete/7\t{}' "$(<"$audit")"
  assert_eq 7 "$XUI_DELETED_API_TOKEN_ID"
  assert_eq old-managed-token "$XUI_DELETED_API_TOKEN_NAME"
  assert_failure xui_delete_api_token_by_id 22 old-managed-token
}

configure_orphan_cleanup_mocks() {
  ORPHAN_PENDING_NAME=${ORPHAN_PENDING_NAME:-one-key-proxy-pending-abc}
  ORPHAN_CURRENT_ID=${ORPHAN_CURRENT_ID:-}
  ORPHAN_ROWS=${ORPHAN_ROWS:-'[]'}
  ORPHAN_AFTER_ROWS=${ORPHAN_AFTER_ROWS:-'[]'}
  ORPHAN_READS=0
  ORPHAN_AUDIT=$TEST_SANDBOX/orphan-audit
  : >"$ORPHAN_AUDIT"
  XUI_INSTALL_RESULT_FILE=$TEST_SANDBOX/orphan-install-result.env
  XUI_API_TOKEN=installer-token-value-123456
  XUI_API_BASE_URL=http://127.0.0.1:2053
  printf '%s\n' 'XUI_API_TOKEN=installer-token-value-123456' >"$XUI_INSTALL_RESULT_FILE"
  unset XUI_CURRENT_API_TOKEN_ID XUI_API_TOKEN_MEMORY

  state_get() {
    case $1 in
      XUI_PENDING_API_TOKEN_NAME) printf '%s' "$ORPHAN_PENDING_NAME" ;;
      XUI_API_TOKEN_ID)
        [[ -n $ORPHAN_CURRENT_ID ]] || return 1
        printf '%s' "$ORPHAN_CURRENT_ID"
        ;;
      *) return 1 ;;
    esac
  }
  state_unset_many() { printf 'unset:%s\n' "$*" >>"$ORPHAN_AUDIT"; }
  xui_api_tokens_read() {
    ORPHAN_READS=$((ORPHAN_READS + 1))
    if ((ORPHAN_READS == 1)); then
      XUI_API_TOKENS_JSON=$ORPHAN_ROWS
    else
      XUI_API_TOKENS_JSON=$ORPHAN_AFTER_ROWS
    fi
  }
  xui_api_post() {
    printf 'post:%s:%s\n' "$1" "${2-}" >>"$ORPHAN_AUDIT"
    printf '%s\n' '{}'
  }
}

test_pending_api_token_orphan_cleanup_is_exact_and_verified() {
  ORPHAN_PENDING_NAME=one-key-proxy-pending-abc
  ORPHAN_CURRENT_ID=''
  ORPHAN_ROWS='[{"id":31,"name":"one-key-proxy-pending-abc","enabled":true},{"id":1,"name":"installer","enabled":true}]'
  ORPHAN_AFTER_ROWS='[{"id":1,"name":"installer","enabled":true}]'
  configure_orphan_cleanup_mocks

  xui_cleanup_pending_api_token_orphan
  assert_eq $'post:/panel/api/setting/apiTokens/delete/31:{}\nunset:XUI_PENDING_API_TOKEN_NAME XUI_PENDING_API_TOKEN_OLD_ID XUI_PENDING_API_TOKEN_OLD_NAME' "$(<"$ORPHAN_AUDIT")"
  assert_eq 31 "$XUI_CLEANED_ORPHAN_API_TOKEN_ID"
  assert_eq one-key-proxy-pending-abc "$XUI_CLEANED_ORPHAN_API_TOKEN_NAME"
  assert_eq 2 "$ORPHAN_READS" 'orphan cleanup must verify deletion with a second list read'
}

test_pending_api_token_orphan_cleanup_rejects_unsafe_selectors() {
  ORPHAN_PENDING_NAME=unmanaged-token
  ORPHAN_CURRENT_ID=''
  ORPHAN_ROWS='[{"id":31,"name":"unmanaged-token","enabled":true}]'
  ORPHAN_AFTER_ROWS='[]'
  configure_orphan_cleanup_mocks
  assert_failure xui_cleanup_pending_api_token_orphan
  assert_eq '' "$(<"$ORPHAN_AUDIT")"

  ORPHAN_PENDING_NAME=one-key-proxy-pending-abc
  ORPHAN_CURRENT_ID=22
  ORPHAN_ROWS='[{"id":31,"name":"one-key-proxy-pending-abc","enabled":true}]'
  configure_orphan_cleanup_mocks
  assert_failure xui_cleanup_pending_api_token_orphan
  assert_eq '' "$(<"$ORPHAN_AUDIT")"

  ORPHAN_CURRENT_ID=''
  ORPHAN_ROWS='[]'
  configure_orphan_cleanup_mocks
  xui_cleanup_pending_api_token_orphan
  assert_eq $'unset:XUI_PENDING_API_TOKEN_NAME XUI_PENDING_API_TOKEN_OLD_ID XUI_PENDING_API_TOKEN_OLD_NAME' "$(<"$ORPHAN_AUDIT")"

  ORPHAN_ROWS='[{"id":31,"name":"one-key-proxy-pending-abc","enabled":true},{"id":32,"name":"one-key-proxy-pending-abc","enabled":true}]'
  configure_orphan_cleanup_mocks
  assert_failure xui_cleanup_pending_api_token_orphan
  assert_eq '' "$(<"$ORPHAN_AUDIT")"
}

run_test 'subscription URLs handle default ports and IPv6' test_subscription_urls_handle_default_ports_and_ipv6
run_test 'TLS API identity changes only after transition activation' test_tls_api_identity_switches_only_after_activation
run_test 'VLESS URI validation binds endpoint and REALITY fields' test_vless_uri_validation_binds_security_fields
run_test 'JSON subscriptions match official object, array and legacy forms' test_json_subscription_validation_matches_official_forms
run_test 'JSON subscription validation rejects conflicts and duplicates' test_json_subscription_validation_rejects_conflicts_and_duplicates
run_test 'Clash subscription validation handles quoted scalars and IPv6' test_clash_subscription_validation_handles_quoted_scalars_and_ipv6
run_test 'Clash subscription validation rejects ambiguity' test_clash_subscription_validation_rejects_ambiguity
run_test 'local HTTPS verification separates NAT listener and advertised ports' \
  test_local_subscription_verification_uses_loopback_for_nat_mapping
run_test 'local HTTPS verification rejects a bad Base64, JSON or Clash format' \
  test_local_subscription_verification_rejects_each_bad_format
run_test 'error logging strips terminal controls and redacts secrets' test_error_logging_strips_terminal_controls_and_redacts
run_test 'REALITY secrets never enter jq argv' test_reality_secrets_use_rawfiles_not_jq_argv
run_test 'inbound ownership requires exact tag and state ID' test_inbound_ownership_requires_exact_tag_and_state_id
run_test 'Hosts ownership requires exact tag and state ID' test_hosts_ownership_requires_exact_tag_and_state_id
run_test 'settings merge preserves server fields' test_settings_merge_preserves_server_fields_and_drops_ui_flags
run_test 'REALITY inbound JSON satisfies the protocol contract' test_reality_inbound_payload_has_required_contract
run_test 'Hosts API advertises the external NAT endpoint' test_external_host_uses_public_nat_mapping
run_test 'Xray runtime is healthy and includes the managed inbound' test_xray_runtime_requires_running_core_and_managed_config
run_test 'API transport parses envelopes and protects the bearer token' test_api_transport_uses_envelope_and_bearer_config
run_test 'API transport rejects HTTP errors and malformed envelopes' test_api_transport_rejects_http_and_bad_envelopes
run_test 'candidate API token validation uses the candidate context' test_candidate_api_token_is_validated_in_isolated_context
run_test 'API token creation validates its one-time secret' test_api_token_creation_validates_one_time_secret
run_test 'API token rotation switches before deleting the old token' test_api_token_rotation_switches_before_old_token_deletion
run_test 'API token deletion binds ID to the expected name' test_api_token_delete_binds_id_to_expected_name
run_test 'pending API token orphan is uniquely deleted and verified' test_pending_api_token_orphan_cleanup_is_exact_and_verified
run_test 'orphan cleanup rejects unsafe or ambiguous selectors' test_pending_api_token_orphan_cleanup_rejects_unsafe_selectors

finish_tests
