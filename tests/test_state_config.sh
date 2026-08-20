#!/usr/bin/env bash

set -uo pipefail
# shellcheck source=test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TEST_SANDBOX=$(make_test_temp_dir)
trap 'rm -rf -- "$TEST_SANDBOX"' EXIT

load_state_library() {
  OKP_TEST_MODE=true
  CONFIG_DIR=$TEST_SANDBOX/state
  STATE_FILE=$CONFIG_DIR/state.env
  CERT_DIR=$CONFIG_DIR/certs
  STAGE_DIR=$CONFIG_DIR/stages
  LOG_FILE=$TEST_SANDBOX/one-key-proxy.log
  BACKUP_DIR=$TEST_SANDBOX/backups
  RESULT_FILE=$TEST_SANDBOX/result.txt
  # shellcheck source=../lib/state.sh
  source "$PROJECT_ROOT/lib/state.sh"

  # Production requires root. Unit tests replace only the privilege gate while
  # retaining the real state serialization, locking, and atomic-write code.
  state_init() {
    umask 077
    mkdir -p -- "$CONFIG_DIR" "$CERT_DIR" "$STAGE_DIR"
    [[ -e $STATE_FILE ]] || : >"$STATE_FILE"
    chmod 0600 "$STATE_FILE"
  }
}

test_state_round_trip_and_no_source() {
  load_state_library
  local value=$'line one\nline two=$(touch /should-not-run); spaces'
  state_set EXAMPLE_VALUE "$value"
  assert_eq "$value" "$(state_get EXAMPLE_VALUE)" 'state value did not round-trip'
  assert_failure grep -Fq 'touch /should-not-run' "$STATE_FILE"
  assert_eq 600 "$(file_mode "$STATE_FILE")" 'state file mode must be 0600'

  state_set EXAMPLE_VALUE replacement
  assert_eq replacement "$(state_get EXAMPLE_VALUE)"
  assert_eq 1 "$(awk -F= '$1 == "EXAMPLE_VALUE" { count++ } END { print count + 0 }' "$STATE_FILE")" \
    'state_set must replace, not duplicate, a key'
  state_unset EXAMPLE_VALUE
  assert_failure state_has EXAMPLE_VALUE
}

test_state_rejects_bad_keys_and_corrupt_values() {
  load_state_library
  assert_status 2 state_set 'bad-key' value
  printf '%s\n' 'BROKEN=%%%' >"$STATE_FILE"
  assert_status 3 state_get BROKEN
}

test_stage_runner_is_idempotent() {
  load_state_library
  local counter=$TEST_SANDBOX/stage-counter
  increment_stage() {
    local current=0
    [[ ! -f $counter ]] || current=$(<"$counter")
    printf '%s\n' "$((current + 1))" >"$counter"
  }

  stage_run configure increment_stage
  stage_run configure increment_stage
  assert_eq 1 "$(<"$counter")" 'completed stage ran more than once'
  assert_success stage_is_done configure
  assert_eq '' "$(stage_next configure 2>/dev/null || true)"
  stage_clear configure
  assert_failure stage_is_done configure
}

test_stage_marker_requires_matching_valid_payload() {
  load_state_library
  rm -rf -- "$CONFIG_DIR"
  state_init
  local marker=$STAGE_DIR/configured.done

  write_marker() {
    local marker_stage=$1 completed_at=$2
    printf 'STAGE=%s\nCOMPLETED_AT=%s\n' \
      "$(_state_encode "$marker_stage")" "$(_state_encode "$completed_at")" >"$marker"
    chmod 0600 "$marker"
  }

  write_marker configured '2026-08-20T10:20:30Z'
  assert_success stage_is_done configured

  write_marker certificate '2026-08-20T10:20:30Z'
  assert_failure stage_is_done configured

  write_marker configured '2026-02-30T10:20:30Z'
  assert_failure stage_is_done configured

  write_marker configured '2026-08-20 10:20:30Z'
  assert_failure stage_is_done configured

  printf 'STAGE=%s\nSTAGE=%s\nCOMPLETED_AT=%s\n' \
    "$(_state_encode configured)" "$(_state_encode configured)" \
    "$(_state_encode '2026-08-20T10:20:30Z')" >"$marker"
  assert_failure stage_is_done configured
}

test_state_reads_reject_hard_links() {
  load_state_library
  rm -rf -- "$CONFIG_DIR"
  state_init
  state_set EXAMPLE_VALUE expected
  ln "$STATE_FILE" "$TEST_SANDBOX/state-hard-link"
  assert_failure state_get EXAMPLE_VALUE
  rm -f -- "$TEST_SANDBOX/state-hard-link"
  assert_eq expected "$(state_get EXAMPLE_VALUE)"
}

test_abandoned_initial_state_cleanup_is_conservative() {
  load_state_library
  rm -rf -- "$CONFIG_DIR"
  state_init

  no_external_resource() { return 1; }
  external_resource_exists() { return 0; }
  resource_probe_failed() { return 2; }

  assert_success state_remove_abandoned_initial no_external_resource
  assert_file_not_exists "$STATE_FILE"
  state_init
  state_set MANAGED_BY one-key-proxy
  stage_mark_done configured
  assert_failure state_remove_abandoned_initial no_external_resource
  assert_file_exists "$STATE_FILE"
  stage_clear configured

  : >"$CERT_DIR/server.crt"
  assert_failure state_remove_abandoned_initial no_external_resource
  assert_file_exists "$STATE_FILE"
  rm -f -- "$CERT_DIR/server.crt"

  assert_failure state_remove_abandoned_initial external_resource_exists
  assert_failure state_remove_abandoned_initial resource_probe_failed
  assert_file_exists "$STATE_FILE"

  state_set MANAGED_BY another-project
  assert_failure state_remove_abandoned_initial no_external_resource
  assert_file_exists "$STATE_FILE"

  state_set MANAGED_BY one-key-proxy
  assert_success state_remove_abandoned_initial no_external_resource
  assert_file_not_exists "$STATE_FILE"
}

test_redaction_covers_registered_and_structured_secrets() {
  load_state_library
  secret_register 'super-secret-token'
  local redacted
  redacted=$(redact_sensitive \
    'value=super-secret-token password=hunter2 "privateKey":"private-value" Authorization: Bearer abc123')
  assert_failure grep -Fq 'super-secret-token' <<<"$redacted"
  assert_failure grep -Fq 'hunter2' <<<"$redacted"
  assert_failure grep -Fq 'private-value' <<<"$redacted"
  assert_failure grep -Fq 'abc123' <<<"$redacted"
  assert_contains "$redacted" '[REDACTED]'
}

load_config_libraries() {
  LOG_FILE=$TEST_SANDBOX/config.log
  # shellcheck source=../lib/common.sh
  source "$PROJECT_ROOT/lib/common.sh"
  # shellcheck source=../lib/config.sh
  source "$PROJECT_ROOT/lib/config.sh"
}

set_valid_nat_config() {
  MODE=nat
  PUBLIC_IPV4=198.51.100.12
  PUBLIC_IPV6=''
  ENABLE_IPV6=false
  PANEL_USERNAME=smallmain
  PANEL_PASSWORD='a-long-panel-password'
  PANEL_PATH=/
  PANEL_EXTERNAL_PORT=56666
  PANEL_INTERNAL_PORT=2053
  NODE_EXTERNAL_PORT=56667
  NODE_INTERNAL_PORT=443
  SUB_EXTERNAL_PORT=56668
  SUB_INTERNAL_PORT=2096
  NODE_NAME=test-reality
  REALITY_TARGET=www.cloudflare.com:443
  REALITY_SNI=www.cloudflare.com
  MIN_CLIENT_VERSION=1.0.0
  FQDN=''
  ALI_ACCESS_KEY_ID=''
  ALI_ACCESS_KEY_SECRET=''
  ACME_EMAIL=''
  SSH_CONNECTION=''
}

test_port_mapping_parser() {
  load_config_libraries
  local external='' internal=''
  parse_port_map 56666:2053 external internal
  assert_eq 56666 "$external"
  assert_eq 2053 "$internal"
  assert_failure parse_port_map 56666 external internal
  assert_failure parse_port_map 0:2053 external internal
  assert_failure parse_port_map 56666:65536 external internal
  assert_failure parse_port_map 1:2:3 external internal
}

test_config_accepts_valid_nat_and_public_values() {
  load_config_libraries
  set_valid_nat_config
  config_validate
  assert_eq www.cloudflare.com "$REALITY_SNI"

  MODE=public
  FQDN=node.example.com
  ALI_ACCESS_KEY_ID=test-id
  ALI_ACCESS_KEY_SECRET=test-secret
  PANEL_EXTERNAL_PORT=$PANEL_INTERNAL_PORT
  NODE_EXTERNAL_PORT=$NODE_INTERNAL_PORT
  SUB_EXTERNAL_PORT=$SUB_INTERNAL_PORT
  config_validate
}

test_config_rejects_invalid_and_colliding_values() {
  load_config_libraries
  set_valid_nat_config
  PUBLIC_IPV4=999.51.100.12
  assert_failure config_validate

  set_valid_nat_config
  NODE_INTERNAL_PORT=$PANEL_INTERNAL_PORT
  assert_failure config_validate

  set_valid_nat_config
  PANEL_PASSWORD=short
  assert_failure config_validate

  set_valid_nat_config
  SSH_CONNECTION='203.0.113.5 40000 198.51.100.12 2053'
  assert_failure config_validate
}

test_reality_target_tls_probe_uses_secure_curl_and_accepts_http_errors() {
  load_config_libraries
  local fake_bin=$TEST_SANDBOX/reality-curl-bin
  local audit=$TEST_SANDBOX/reality-curl-audit
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$@" >"$CURL_AUDIT"' \
    'exit "${CURL_STATUS:-0}"' >"$fake_bin/curl"
  chmod 0755 "$fake_bin/curl"

  CURL_AUDIT=$audit CURL_STATUS=0 PATH="$fake_bin:$PATH" \
    assert_reality_target_tls_reachable example.com:8443

  local arguments
  arguments=$(<"$audit")
  assert_contains "$arguments" '--disable'
  assert_contains "$arguments" '--noproxy'
  assert_contains "$arguments" '*'
  assert_contains "$arguments" '--proto'
  assert_contains "$arguments" '=https'
  assert_contains "$arguments" '--proto-redir'
  assert_contains "$arguments" '--tlsv1.2'
  assert_contains "$arguments" '--connect-timeout'
  assert_contains "$arguments" '5'
  assert_contains "$arguments" '--max-time'
  assert_contains "$arguments" '10'
  assert_contains "$arguments" '--output'
  assert_contains "$arguments" '/dev/null'
  assert_contains "$arguments" 'https://example.com:8443/'
  assert_failure grep -Eq -- '(^|[[:space:]])(--fail|-f)([[:space:]]|$)' <<<"$arguments"
}

test_reality_target_tls_probe_propagates_transport_failure() {
  load_config_libraries
  local fake_bin=$TEST_SANDBOX/reality-failing-curl-bin
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit "${CURL_STATUS:-35}"' >"$fake_bin/curl"
  chmod 0755 "$fake_bin/curl"

  CURL_STATUS=35 PATH="$fake_bin:$PATH" assert_failure probe_reality_target_tls example.com:443
  CURL_STATUS=35 PATH="$fake_bin:$PATH" assert_failure assert_reality_target_tls_reachable example.com:443
  assert_status 2 probe_reality_target_tls 'https://example.com:443'
}

run_test 'state safely round-trips opaque values' test_state_round_trip_and_no_source
run_test 'state rejects invalid keys and corrupt Base64' test_state_rejects_bad_keys_and_corrupt_values
run_test 'stage runner resumes idempotently' test_stage_runner_is_idempotent
run_test 'stage markers require matching valid payloads' test_stage_marker_requires_matching_valid_payload
run_test 'state reads reject hard links' test_state_reads_reject_hard_links
run_test 'abandoned initial state cleanup is conservative' test_abandoned_initial_state_cleanup_is_conservative
run_test 'state redaction removes secrets' test_redaction_covers_registered_and_structured_secrets
run_test 'NAT port mappings are strict' test_port_mapping_parser
run_test 'valid NAT and public configurations pass' test_config_accepts_valid_nat_and_public_values
run_test 'invalid and colliding configuration is rejected' test_config_rejects_invalid_and_colliding_values
run_test 'REALITY TLS probe uses hardened curl and accepts HTTP statuses' test_reality_target_tls_probe_uses_secure_curl_and_accepts_http_errors
run_test 'REALITY TLS probe rejects transport and malformed targets' test_reality_target_tls_probe_propagates_transport_failure

finish_tests
