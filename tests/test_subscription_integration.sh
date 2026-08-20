#!/usr/bin/env bash

set -uo pipefail
# shellcheck source=test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TEST_SANDBOX=$(make_test_temp_dir)
trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
CERT_DIR=$TEST_SANDBOX/certs
mkdir -p "$CERT_DIR"
printf 'test certificate\n' >"$CERT_DIR/server.crt"

# shellcheck source=../lib/3xui.sh
source "$PROJECT_ROOT/lib/3xui.sh"
# shellcheck source=../lib/integration.sh
source "$PROJECT_ROOT/lib/integration.sh"

declare -A TEST_STATE=()

state_get() {
  [[ -n ${TEST_STATE[$1]+present} ]] || return 1
  printf '%s' "${TEST_STATE[$1]}"
}

test_nat_delivery_uses_internal_listener_and_external_node_port() (
  local audit=$TEST_SANDBOX/nat-delivery-audit
  : >"$audit"
  MODE=nat
  PUBLIC_IPV4=198.51.100.60
  SUB_INTERNAL_PORT=24444
  NODE_EXTERNAL_PORT=56667
  TEST_STATE[SUB_ID]=natSub_123
  TEST_STATE[CLIENT_UUID]=11111111-2222-4333-8444-555555555555
  TEST_STATE[REALITY_SNI]=www.cloudflare.com
  TEST_STATE[REALITY_PUBLIC_KEY]=Public_key-123
  TEST_STATE[REALITY_SHORT_ID]=a1b2c3d4
  log_error() { printf 'error:%s\n' "$*" >>"$audit"; }
  xui_verify_local_subscriptions() { printf '%s\n' "$*" >>"$audit"; }

  _okp_i_verify_subscription_delivery

  assert_eq \
    "198.51.100.60 24444 56667 natSub_123 $CERT_DIR/server.crt 11111111-2222-4333-8444-555555555555 www.cloudflare.com Public_key-123 a1b2c3d4" \
    "$(<"$audit")"
)

test_result_commit_is_blocked_by_subscription_failure() (
  local audit=$TEST_SANDBOX/result-gate-audit
  local host=198.51.100.61 uuid=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
  local sni=www.cloudflare.com public_key=Public_key-456 short_id=11223344 uri
  : >"$audit"
  TEST_STATE[SUB_ID]=natSub_456
  TEST_STATE[CLIENT_UUID]=$uuid
  TEST_STATE[REALITY_SNI]=$sni
  TEST_STATE[REALITY_PUBLIC_KEY]=$public_key
  TEST_STATE[REALITY_SHORT_ID]=$short_id
  uri="vless://${uuid}@${host}:56668?type=tcp&security=reality&flow=xtls-rprx-vision&sni=${sni}&pbk=${public_key}&sid=${short_id}#node"
  _okp_i_load_config() {
    MODE=nat
    PUBLIC_IPV4=$host
    PANEL_EXTERNAL_PORT=56666
    NODE_EXTERNAL_PORT=56668
    SUB_EXTERNAL_PORT=56669
    SUB_INTERNAL_PORT=24445
  }
  xui_get_sub_links() { jq -nc --arg uri "$uri" '[$uri]'; }
  xui_verify_local_subscriptions() {
    printf 'verify:%s\n' "$*" >>"$audit"
    return 1
  }
  state_set_many() { printf 'state-write\n' >>"$audit"; }
  result_reset() { printf 'result-reset\n' >>"$audit"; }
  log_error() { printf 'error:%s\n' "$*" >>"$audit"; }

  assert_failure _okp_i_write_result

  assert_contains "$(<"$audit")" "verify:${host} 24445 56668 natSub_456"
  assert_contains "$(<"$audit")" 'error:三类订阅未通过本机 HTTPS、公开节点地址或 REALITY 身份校验。'
  assert_failure grep -Fq 'state-write' "$audit"
  assert_failure grep -Fq 'result-reset' "$audit"
)

test_reconfiguration_does_not_finalize_failed_subscriptions() (
  local audit=$TEST_SANDBOX/reconfigure-gate-audit
  : >"$audit"
  MODE=nat
  PANEL_INTERNAL_PORT=24443
  NODE_INTERNAL_PORT=24444
  NODE_EXTERNAL_PORT=56667
  SUB_INTERNAL_PORT=24445
  SUB_EXTERNAL_PORT=56668
  XUI_MANAGED_INBOUND_ID=17
  XUI_MANAGED_HOST_GROUP_ID=group-17
  OKP_NEW_MANAGED_FIREWALL_PORTS=24443,24444,24445
  _okp_i_prepare_identity() { printf 'identity\n' >>"$audit"; }
  _okp_i_add_firewall_ports() { printf 'firewall:add\n' >>"$audit"; }
  _okp_i_update_inbound_port() { printf 'inbound:%s\n' "$1" >>"$audit"; }
  _okp_i_public_host() { printf '198.51.100.62'; }
  _okp_i_update_owned_host() { printf 'host:%s:%s\n' "$2" "$3" >>"$audit"; }
  xui_configure_subscription() { printf 'subscription-config\n' >>"$audit"; }
  xui_configure_panel_tls() { printf 'panel-config\n' >>"$audit"; }
  xui_restart_panel() { printf 'restart\n' >>"$audit"; }
  config_save_state() { printf 'config-save\n' >>"$audit"; }
  state_set_many() { printf 'state-save\n' >>"$audit"; }
  _okp_i_wait_service() { printf 'health\n' >>"$audit"; }
  _okp_i_verify_subscription_delivery() {
    printf 'subscription-verify:%s\n' "$1" >>"$audit"
    return 1
  }
  _okp_i_complete_tls_transition() { printf 'tls-complete\n' >>"$audit"; }
  _okp_i_remove_old_firewall_ports() { printf 'firewall:remove\n' >>"$audit"; }

  assert_failure _okp_i_apply_reconfiguration '' 24440

  assert_contains "$(<"$audit")" $'health\nsubscription-verify:198.51.100.62'
  assert_failure grep -Fq 'tls-complete' "$audit"
  assert_failure grep -Fq 'firewall:remove' "$audit"
)

test_xui_reassertion_propagates_subscription_failure() (
  local audit=$TEST_SANDBOX/xui-update-gate-audit
  : >"$audit"
  _okp_i_load_config() {
    NODE_INTERNAL_PORT=24444
    NODE_EXTERNAL_PORT=56667
    SUB_INTERNAL_PORT=24445
    SUB_EXTERNAL_PORT=56668
    PANEL_INTERNAL_PORT=24443
    XUI_MANAGED_INBOUND_ID=17
  }
  _okp_i_public_host() { printf '198.51.100.63'; }
  _okp_i_update_inbound_port() { printf 'inbound\n' >>"$audit"; }
  _okp_i_update_owned_host() { printf 'host\n' >>"$audit"; }
  xui_configure_subscription() { printf 'subscription-config\n' >>"$audit"; }
  xui_configure_panel_tls() { printf 'panel-config\n' >>"$audit"; }
  xui_restart_panel() { printf 'restart\n' >>"$audit"; }
  _okp_i_wait_service() { printf 'health\n' >>"$audit"; }
  _okp_i_verify_subscription_delivery() {
    printf 'subscription-verify:%s\n' "$1" >>"$audit"
    return 1
  }

  assert_failure _okp_i_reassert_xui_configuration
  assert_contains "$(<"$audit")" $'health\nsubscription-verify:198.51.100.63'
)

test_xui_recovery_keeps_journal_when_subscriptions_fail() (
  local audit=$TEST_SANDBOX/xui-recovery-subscription-gate
  : >"$audit"
  TEST_STATE[XUI_UPDATE_RECOVERY_STATUS]=restore-root-path
  TEST_STATE['INBOUND_TAG']='managed-inbound'
  TEST_STATE[NODE_INTERNAL_PORT]=24444
  maintenance_operation_lock() { printf 'lock\n' >>"$audit"; }
  _okp_i_restore_xui_root_path_offline() { printf 'root-path\n' >>"$audit"; }
  platform_service_enable() { printf 'enable\n' >>"$audit"; }
  _okp_i_xui_autostart_status() { return 0; }
  platform_service_start() { printf 'start\n' >>"$audit"; }
  platform_service_is_active() { return 0; }
  xui_api_get() { printf '{}'; }
  xui_check_required_endpoints() { return 0; }
  xui_verify_xray_runtime() { XUI_XRAY_VERSION=25.8.3; }
  _okp_i_verify_subscription_delivery() {
    printf 'subscription-failed\n' >>"$audit"
    return 1
  }
  _okp_i_fail_close_xui_update() { printf 'fail-close\n' >>"$audit"; }
  state_set() { printf 'state-set:%s\n' "$1" >>"$audit"; }
  state_unset_many() {
    printf 'journal-cleared\n' >>"$audit"
    unset 'TEST_STATE[XUI_UPDATE_RECOVERY_STATUS]'
  }
  log_warn() { :; }
  log_error() { :; }
  log_info() { :; }

  assert_failure _okp_i_recover_xui_update_transition

  assert_eq restore-root-path "${TEST_STATE[XUI_UPDATE_RECOVERY_STATUS]}"
  assert_contains "$(<"$audit")" $'subscription-failed\nfail-close'
  assert_failure grep -Fq 'journal-cleared' "$audit"
  assert_failure grep -Fq 'state-set:' "$audit"
)

test_tls_recovery_keeps_journal_when_subscriptions_fail() (
  local audit=$TEST_SANDBOX/tls-recovery-subscription-gate
  : >"$audit"
  TEST_STATE[MODE]=nat
  TEST_STATE[PUBLIC_IPV4]=198.51.100.64
  TEST_STATE[XUI_TLS_TRANSITION_STATUS]=active
  TEST_STATE[XUI_TLS_TRANSITION_HOST]=198.51.100.64
  maintenance_operation_lock() { printf 'lock\n' >>"$audit"; }
  _okp_i_tls_cert_matches_host() { return 0; }
  _okp_i_wait_transition_api() { printf 'api-health\n' >>"$audit"; }
  _okp_i_verify_subscription_delivery() {
    printf 'subscription-failed:%s\n' "$1" >>"$audit"
    return 1
  }
  state_unset_many() {
    printf 'journal-cleared\n' >>"$audit"
    unset 'TEST_STATE[XUI_TLS_TRANSITION_STATUS]' 'TEST_STATE[XUI_TLS_TRANSITION_HOST]'
  }
  log_error() { :; }
  log_info() { :; }

  assert_failure _okp_i_recover_tls_transition

  assert_eq active "${TEST_STATE[XUI_TLS_TRANSITION_STATUS]}"
  assert_eq 198.51.100.64 "${TEST_STATE[XUI_TLS_TRANSITION_HOST]}"
  assert_contains "$(<"$audit")" $'api-health\nsubscription-failed:198.51.100.64'
  assert_failure grep -Fq 'journal-cleared' "$audit"
)

test_restore_loads_restored_config_before_health_check() (
  local audit=$TEST_SANDBOX/restore-config-order
  : >"$audit"
  _okp_i_load_saved_config() { printf 'config-load\n' >>"$audit"; }
  platform_detect() { printf 'platform\n' >>"$audit"; }
  platform_service_enable() { printf 'enable\n' >>"$audit"; }
  platform_service_restart() { printf 'restart\n' >>"$audit"; }
  _okp_i_wait_service() { printf 'health\n' >>"$audit"; }
  _okp_i_write_result() {
    printf 'unexpected-result\n' >>"$audit"
    return 1
  }

  okp_hook_after_restore

  assert_eq $'config-load\nplatform\nenable\nrestart\nhealth' "$(<"$audit")"
)

run_test 'NAT delivery verifies internal subscription and external VLESS ports' \
  test_nat_delivery_uses_internal_listener_and_external_node_port
run_test 'subscription failure blocks result state and file commits' \
  test_result_commit_is_blocked_by_subscription_failure
run_test 'subscription failure blocks reconfiguration finalization' \
  test_reconfiguration_does_not_finalize_failed_subscriptions
run_test 'subscription failure propagates from 3x-ui reassertion' \
  test_xui_reassertion_propagates_subscription_failure
run_test 'subscription failure retains the 3x-ui recovery journal' \
  test_xui_recovery_keeps_journal_when_subscriptions_fail
run_test 'subscription failure retains the TLS recovery journal' \
  test_tls_recovery_keeps_journal_when_subscriptions_fail
run_test 'restore loads restored configuration before health checks' \
  test_restore_loads_restored_config_before_health_check

finish_tests
