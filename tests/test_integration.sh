#!/usr/bin/env bash

set -uo pipefail
# shellcheck source=test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TEST_SANDBOX=$(make_test_temp_dir)
trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
CERT_DIR=$TEST_SANDBOX/certs
mkdir -p "$CERT_DIR"
touch "$CERT_DIR/server.crt"

# shellcheck source=../lib/integration.sh
source "$PROJECT_ROOT/lib/integration.sh"

declare -A TEST_STATE=()

reset_transition_test() {
  TEST_STATE=()
  TEST_CERT_SAN_HOST=''
  TEST_AUDIT=$TEST_SANDBOX/integration-audit
  : >"$TEST_AUDIT"
}

state_get() {
  [[ -n ${TEST_STATE[$1]+present} ]] || return 1
  printf '%s' "${TEST_STATE[$1]}"
}

state_set() {
  TEST_STATE[$1]=$2
}

state_set_many() {
  while (($#)); do
    TEST_STATE[$1]=$2
    shift 2
  done
}

state_unset_many() {
  local key
  for key in "$@"; do
    unset 'TEST_STATE[$key]'
  done
}

state_unset() {
  unset 'TEST_STATE[$1]'
}

log_error() { printf 'error:%s\n' "$*" >>"$TEST_AUDIT"; }
log_warn() { printf 'warn:%s\n' "$*" >>"$TEST_AUDIT"; }
log_info() { printf 'info:%s\n' "$*" >>"$TEST_AUDIT"; }
valid_ipv4() {
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}
_okp_cert_verify_ip_san() {
  [[ $2 == "$TEST_CERT_SAN_HOST" ]]
}
platform_service_restart() {
  printf 'restart:%s\n' "$1" >>"$TEST_AUDIT"
}
platform_service_is_active() { return 0; }
xui_api_get() {
  printf 'api:%s\n' "$1" >>"$TEST_AUDIT"
  printf '{}\n'
}
xui_verify_local_subscriptions() { :; }
sleep() { :; }

make_fake_xui_binary() {
  local binary=$1
  cat >"$binary" <<'EOF'
#!/bin/sh
printf 'xui:%s\n' "$*" >>"$FAKE_XUI_AUDIT"
case "$*" in
  'setting -webBasePath /')
    if [ "${FAKE_XUI_IGNORE_SET:-false}" != true ]; then
      printf '/\n' >"$FAKE_XUI_STATE"
    fi
    ;;
  'setting -show true')
    printf 'current panel settings as follows:\n'
    printf 'port: 2053\n'
    printf 'webBasePath: %s\n' "$(sed -n '1p' "$FAKE_XUI_STATE")"
    ;;
  *) exit 64 ;;
esac
EOF
  chmod 0700 "$binary"
}

test_nat_unchanged_san_does_not_replace_certificate() {
  reset_transition_test
  MODE=nat
  PUBLIC_IPV4=198.51.100.20
  TEST_CERT_SAN_HOST=$PUBLIC_IPV4
  okp_cert_create_self_signed_ip() {
    printf 'create:%s\n' "$1" >>"$TEST_AUDIT"
    return 1
  }

  _okp_i_prepare_identity ''
  assert_eq '' "$(<"$TEST_AUDIT")"
  [[ -z ${TEST_STATE[XUI_TLS_TRANSITION_STATUS]+present} ]] ||
    fail 'unchanged NAT identity created a transition journal'
}

test_nat_replacement_activates_then_commits_transition() {
  reset_transition_test
  MODE=nat
  PUBLIC_IPV4=198.51.100.21
  TEST_CERT_SAN_HOST=198.51.100.20
  okp_cert_create_self_signed_ip() {
    printf 'create:%s\n' "$1" >>"$TEST_AUDIT"
    TEST_CERT_SAN_HOST=$1
  }

  _okp_i_prepare_identity ''
  assert_eq active "${TEST_STATE[XUI_TLS_TRANSITION_STATUS]}"
  assert_eq "$PUBLIC_IPV4" "${TEST_STATE[XUI_TLS_TRANSITION_HOST]}"
  assert_eq $'create:198.51.100.21\nrestart:x-ui\napi:/panel/api/server/status' "$(<"$TEST_AUDIT")"

  _okp_i_complete_tls_transition nat "$PUBLIC_IPV4"
  [[ -z ${TEST_STATE[XUI_TLS_TRANSITION_STATUS]+present} &&
     -z ${TEST_STATE[XUI_TLS_TRANSITION_HOST]+present} ]] ||
    fail 'completed TLS transition journal was not removed'
}

test_preparing_transition_recovery_is_san_bound() {
  reset_transition_test
  TEST_STATE[MODE]=nat
  TEST_STATE[PUBLIC_IPV4]=198.51.100.30
  TEST_STATE[XUI_TLS_TRANSITION_STATUS]=preparing
  TEST_STATE[XUI_TLS_TRANSITION_HOST]=198.51.100.31
  TEST_CERT_SAN_HOST=198.51.100.31
  maintenance_operation_lock() { printf 'lock\n' >>"$TEST_AUDIT"; }

  _okp_i_recover_tls_transition
  assert_eq active "${TEST_STATE[XUI_TLS_TRANSITION_STATUS]}"
  assert_eq $'lock\nwarn:检测到未完成的 TLS 证书切换，正在恢复目标 198.51.100.31。\nrestart:x-ui\napi:/panel/api/server/status' "$(<"$TEST_AUDIT")"

  reset_transition_test
  TEST_STATE[MODE]=nat
  TEST_STATE[PUBLIC_IPV4]=198.51.100.30
  TEST_STATE[XUI_TLS_TRANSITION_STATUS]=preparing
  TEST_STATE[XUI_TLS_TRANSITION_HOST]=198.51.100.31
  TEST_CERT_SAN_HOST=198.51.100.30
  maintenance_operation_lock() { printf 'lock\n' >>"$TEST_AUDIT"; }

  _okp_i_recover_tls_transition
  [[ -z ${TEST_STATE[XUI_TLS_TRANSITION_STATUS]+present} &&
     -z ${TEST_STATE[XUI_TLS_TRANSITION_HOST]+present} ]] ||
    fail 'unused preparing journal was not cleared'
  assert_failure grep -Fq 'restart:x-ui' "$TEST_AUDIT"
}

test_active_transition_recovery_commits_matching_saved_identity() {
  reset_transition_test
  TEST_STATE[MODE]=nat
  TEST_STATE[PUBLIC_IPV4]=198.51.100.35
  TEST_STATE[XUI_TLS_TRANSITION_STATUS]=active
  TEST_STATE[XUI_TLS_TRANSITION_HOST]=198.51.100.35
  TEST_CERT_SAN_HOST=198.51.100.35
  maintenance_operation_lock() { printf 'lock\n' >>"$TEST_AUDIT"; }

  _okp_i_recover_tls_transition
  [[ -z ${TEST_STATE[XUI_TLS_TRANSITION_STATUS]+present} &&
     -z ${TEST_STATE[XUI_TLS_TRANSITION_HOST]+present} ]] ||
    fail 'healthy active transition was not committed'
  assert_eq $'lock\napi:/panel/api/server/status\ninfo:已完成中断的 TLS 证书切换恢复。' "$(<"$TEST_AUDIT")"
}

test_certificate_renewal_rewrites_result_before_diagnostics() {
  reset_transition_test
  TEST_STATE[TLS_MODE]=SELF_SIGNED
  _okp_i_load_config() {
    MODE=nat
    PUBLIC_IPV4=198.51.100.40
  }
  _okp_i_begin_tls_transition() { printf 'begin:%s:%s\n' "$1" "$2" >>"$TEST_AUDIT"; }
  okp_cert_create_self_signed_ip() { printf 'create:%s\n' "$1" >>"$TEST_AUDIT"; }
  _okp_i_activate_tls_transition() { printf 'activate:%s:%s\n' "$1" "$2" >>"$TEST_AUDIT"; }
  _okp_i_wait_service() { printf 'health\n' >>"$TEST_AUDIT"; }
  _okp_i_verify_subscription_delivery() { printf 'subscriptions:%s\n' "$1" >>"$TEST_AUDIT"; }
  _okp_i_complete_tls_transition() { printf 'complete:%s:%s\n' "$1" "$2" >>"$TEST_AUDIT"; }
  _okp_i_write_result() { printf 'result\n' >>"$TEST_AUDIT"; }
  okp_hook_diagnostics() { printf 'diagnostics\n' >>"$TEST_AUDIT"; }
  maintenance_confirm() { return 0; }
  maintenance_backup_create() { printf 'backup\n' >>"$TEST_AUDIT"; }

  okp_hook_renew_certificate
  assert_eq $'backup\nbegin:nat:198.51.100.40\ncreate:198.51.100.40\nactivate:nat:198.51.100.40\nhealth\nsubscriptions:198.51.100.40\ncomplete:nat:198.51.100.40\nresult\ndiagnostics' "$(<"$TEST_AUDIT")"
}

test_domain_reconfiguration_retires_old_acme_only_after_commit_checks() {
  reset_transition_test
  MODE=public
  FQDN=new.example.com
  TEST_STATE[ACME_PENDING_REMOVE_DOMAIN]=old.example.com
  _okp_i_write_result() { printf 'result\n' >>"$TEST_AUDIT"; }
  okp_hook_diagnostics() { printf 'diagnostics\n' >>"$TEST_AUDIT"; }
  okp_acme_remove_domain() { printf 'remove:%s\n' "$1" >>"$TEST_AUDIT"; }

  _okp_i_finalize_reconfiguration old.example.com

  assert_eq $'result\ndiagnostics\nremove:old.example.com' "$(<"$TEST_AUDIT")"
  [[ -z ${TEST_STATE[ACME_PENDING_REMOVE_DOMAIN]+present} ]] ||
    fail 'successful cleanup left its pending marker behind'
}

test_domain_reconfiguration_never_retires_old_acme_before_success() {
  reset_transition_test
  MODE=public
  FQDN=new.example.com
  TEST_STATE[ACME_PENDING_REMOVE_DOMAIN]=old.example.com
  _okp_i_write_result() {
    printf 'result:failed\n' >>"$TEST_AUDIT"
    return 1
  }
  okp_hook_diagnostics() { printf 'diagnostics\n' >>"$TEST_AUDIT"; }
  okp_acme_remove_domain() { printf 'remove:%s\n' "$1" >>"$TEST_AUDIT"; }

  assert_failure _okp_i_finalize_reconfiguration old.example.com
  assert_eq 'result:failed' "$(<"$TEST_AUDIT")"

  : >"$TEST_AUDIT"
  _okp_i_write_result() { printf 'result\n' >>"$TEST_AUDIT"; }
  okp_hook_diagnostics() {
    printf 'diagnostics:failed\n' >>"$TEST_AUDIT"
    return 1
  }
  assert_failure _okp_i_finalize_reconfiguration old.example.com
  assert_eq $'result\ndiagnostics:failed' "$(<"$TEST_AUDIT")"
  assert_eq old.example.com "${TEST_STATE[ACME_PENDING_REMOVE_DOMAIN]}"
}

test_old_acme_cleanup_failure_keeps_new_service_untouched() {
  reset_transition_test
  MODE=public
  FQDN=new.example.com
  TEST_STATE[ACME_PENDING_REMOVE_DOMAIN]=old.example.com
  _okp_i_write_result() { printf 'result\n' >>"$TEST_AUDIT"; }
  okp_hook_diagnostics() { printf 'diagnostics\n' >>"$TEST_AUDIT"; }
  okp_acme_remove_domain() {
    printf 'remove:failed:%s\n' "$1" >>"$TEST_AUDIT"
    return 1
  }
  platform_service_stop() { printf 'service:stop\n' >>"$TEST_AUDIT"; }
  platform_service_restart() { printf 'service:restart\n' >>"$TEST_AUDIT"; }

  assert_failure _okp_i_finalize_reconfiguration old.example.com

  assert_contains "$(<"$TEST_AUDIT")" $'result\ndiagnostics\nremove:failed:old.example.com'
  assert_failure grep -Fq 'service:' "$TEST_AUDIT"
  assert_contains "$(<"$TEST_AUDIT")" '当前服务保持运行'
  assert_eq old.example.com "${TEST_STATE[ACME_PENDING_REMOVE_DOMAIN]}"
}

test_pending_acme_cleanup_revalidates_new_identity_before_retry() {
  reset_transition_test
  MODE=public
  FQDN=new.example.com
  TEST_STATE[ACME_PENDING_REMOVE_DOMAIN]=old.example.com
  _okp_i_tls_cert_matches_host() {
    printf 'cert:%s:%s\n' "$1" "$2" >>"$TEST_AUDIT"
  }
  _okp_i_wait_service() { printf 'health\n' >>"$TEST_AUDIT"; }
  _okp_i_write_result() { printf 'result\n' >>"$TEST_AUDIT"; }
  okp_hook_diagnostics() { printf 'diagnostics\n' >>"$TEST_AUDIT"; }
  okp_acme_remove_domain() { printf 'remove:%s\n' "$1" >>"$TEST_AUDIT"; }

  _okp_i_resume_pending_acme_cleanup

  assert_eq $'cert:public:new.example.com\nhealth\nresult\ndiagnostics\nremove:old.example.com' \
    "$(<"$TEST_AUDIT")"
  [[ -z ${TEST_STATE[ACME_PENDING_REMOVE_DOMAIN]+present} ]] ||
    fail 'recovered cleanup left its pending marker behind'
}

test_forced_renewal_is_blocked_during_uncommitted_domain_change() {
  reset_transition_test
  MODE=public
  FQDN=old.example.com
  TEST_STATE[ACME_PENDING_REMOVE_DOMAIN]=old.example.com
  _okp_i_tls_cert_matches_host() { printf 'cert\n' >>"$TEST_AUDIT"; }
  okp_acme_remove_domain() { printf 'remove\n' >>"$TEST_AUDIT"; }

  assert_failure _okp_i_resume_pending_acme_cleanup
  assert_failure grep -Eq '^(cert|remove)$' "$TEST_AUDIT"
  assert_contains "$(<"$TEST_AUDIT")" '拒绝续签全部 ACME 域名'

  : >"$TEST_AUDIT"
  _okp_i_resume_pending_acme_cleanup true
  assert_eq '' "$(<"$TEST_AUDIT")"
}

test_v360_random_path_is_repaired_offline_before_api() {
  local fake_binary=$TEST_SANDBOX/fake-xui-success
  reset_transition_test
  make_fake_xui_binary "$fake_binary"
  OKP_XUI_BINARY_PATH=$fake_binary
  FAKE_XUI_AUDIT=$TEST_AUDIT
  FAKE_XUI_STATE=$TEST_SANDBOX/fake-xui-path-success
  FAKE_XUI_IGNORE_SET=false
  export FAKE_XUI_AUDIT FAKE_XUI_STATE FAKE_XUI_IGNORE_SET
  printf '/official-v3.6-random-path/\n' >"$FAKE_XUI_STATE"
  TEST_SERVICE_STATE=active
  platform_service_is_inactive() {
    [[ $TEST_SERVICE_STATE == inactive ]] && return 0
    [[ $TEST_SERVICE_STATE == active ]] && return 1
    return 2
  }
  platform_service_stop() {
    printf 'service:stop\n' >>"$TEST_AUDIT"
    TEST_SERVICE_STATE=inactive
  }

  _okp_i_restore_xui_root_path_offline

  assert_eq / "$(<"$FAKE_XUI_STATE")"
  assert_eq inactive "$TEST_SERVICE_STATE"
  assert_eq $'service:stop\nxui:setting -webBasePath /\nxui:setting -show true' "$(<"$TEST_AUDIT")"
}

test_update_recovery_calls_api_only_after_offline_root_repair() {
  local fake_binary=$TEST_SANDBOX/fake-xui-recovery
  reset_transition_test
  make_fake_xui_binary "$fake_binary"
  OKP_XUI_BINARY_PATH=$fake_binary
  FAKE_XUI_AUDIT=$TEST_AUDIT
  FAKE_XUI_STATE=$TEST_SANDBOX/fake-xui-path-recovery
  FAKE_XUI_IGNORE_SET=false
  export FAKE_XUI_AUDIT FAKE_XUI_STATE FAKE_XUI_IGNORE_SET
  printf '/official-v3.6-random-path/\n' >"$FAKE_XUI_STATE"
  TEST_STATE[XUI_UPDATE_RECOVERY_STATUS]=restore-root-path
  TEST_STATE[INBOUND_TAG]=one-key-proxy-test
  TEST_STATE[NODE_INTERNAL_PORT]=24443
  TEST_SERVICE_STATE=active
  TEST_AUTOSTART_STATE=disabled
  OKP_OPERATION_LOCK_FD=9
  maintenance_operation_lock() {
    [[ -n ${OKP_OPERATION_LOCK_FD:-} ]] || return 1
    printf 'lock:reused\n' >>"$TEST_AUDIT"
  }
  platform_service_is_inactive() {
    [[ $TEST_SERVICE_STATE == inactive ]] && return 0
    [[ $TEST_SERVICE_STATE == active ]] && return 1
    return 2
  }
  platform_service_is_active() { [[ $TEST_SERVICE_STATE == active ]]; }
  platform_service_stop() {
    printf 'service:stop\n' >>"$TEST_AUDIT"
    TEST_SERVICE_STATE=inactive
  }
  platform_service_start() {
    printf 'service:start\n' >>"$TEST_AUDIT"
    TEST_SERVICE_STATE=active
  }
  platform_service_enable() {
    printf 'service:enable\n' >>"$TEST_AUDIT"
    TEST_AUTOSTART_STATE=enabled
  }
  _okp_i_xui_autostart_status() {
    printf 'autostart:%s\n' "$TEST_AUTOSTART_STATE" >>"$TEST_AUDIT"
    [[ $TEST_AUTOSTART_STATE == enabled ]] && return 0
    [[ $TEST_AUTOSTART_STATE == disabled ]] && return 1
    return 2
  }
  xui_api_get() { printf 'api:%s\n' "$1" >>"$TEST_AUDIT"; }
  xui_check_required_endpoints() { printf 'endpoints\n' >>"$TEST_AUDIT"; }
  xui_verify_xray_runtime() {
    printf 'runtime:%s:%s\n' "$1" "$2" >>"$TEST_AUDIT"
    XUI_XRAY_VERSION=25.8.3
  }

  _okp_i_recover_xui_update_transition

  [[ -z ${TEST_STATE[XUI_UPDATE_RECOVERY_STATUS]+present} ]] ||
    fail 'completed updater recovery marker was not cleared'
  assert_eq 25.8.3 "${TEST_STATE[XUI_XRAY_VERSION]}"
  assert_eq $'lock:reused\nwarn:检测到 3x-ui 更新恢复事务，正在离线恢复面板根路径。\nservice:stop\nxui:setting -webBasePath /\nxui:setting -show true\nservice:enable\nautostart:enabled\nservice:start\napi:/panel/api/server/status\nendpoints\nruntime:one-key-proxy-test:24443\ninfo:3x-ui 面板根路径恢复事务已完成。' "$(<"$TEST_AUDIT")"
}

test_update_recovery_keeps_service_stopped_on_bad_readback() {
  local fake_binary=$TEST_SANDBOX/fake-xui-failure
  reset_transition_test
  make_fake_xui_binary "$fake_binary"
  OKP_XUI_BINARY_PATH=$fake_binary
  FAKE_XUI_AUDIT=$TEST_AUDIT
  FAKE_XUI_STATE=$TEST_SANDBOX/fake-xui-path-failure
  FAKE_XUI_IGNORE_SET=true
  export FAKE_XUI_AUDIT FAKE_XUI_STATE FAKE_XUI_IGNORE_SET
  printf '/official-v3.6-random-path/\n' >"$FAKE_XUI_STATE"
  TEST_STATE[XUI_UPDATE_RECOVERY_STATUS]=restore-root-path
  TEST_SERVICE_STATE=active
  TEST_AUTOSTART_STATE=enabled
  OKP_MAINTENANCE_FATAL=false
  maintenance_operation_lock() { printf 'lock\n' >>"$TEST_AUDIT"; }
  platform_service_is_inactive() {
    [[ $TEST_SERVICE_STATE == inactive ]] && return 0
    [[ $TEST_SERVICE_STATE == active ]] && return 1
    return 2
  }
  platform_service_stop() {
    printf 'service:stop\n' >>"$TEST_AUDIT"
    TEST_SERVICE_STATE=inactive
  }
  platform_service_disable() {
    printf 'service:disable\n' >>"$TEST_AUDIT"
    TEST_AUTOSTART_STATE=disabled
  }
  _okp_i_xui_autostart_status() {
    printf 'autostart:%s\n' "$TEST_AUTOSTART_STATE" >>"$TEST_AUDIT"
    [[ $TEST_AUTOSTART_STATE == enabled ]] && return 0
    [[ $TEST_AUTOSTART_STATE == disabled ]] && return 1
    return 2
  }
  platform_service_start() { printf 'service:start\n' >>"$TEST_AUDIT"; }
  xui_api_get() { printf 'api:%s\n' "$1" >>"$TEST_AUDIT"; }

  assert_failure _okp_i_recover_xui_update_transition

  assert_eq inactive "$TEST_SERVICE_STATE"
  assert_eq true "$OKP_MAINTENANCE_FATAL"
  assert_eq restore-root-path "${TEST_STATE[XUI_UPDATE_RECOVERY_STATUS]}"
  assert_failure grep -Fq 'service:start' "$TEST_AUDIT"
  assert_failure grep -Fq 'api:' "$TEST_AUDIT"
  assert_contains "$(<"$TEST_AUDIT")" 'service:stop'
  assert_contains "$(<"$TEST_AUDIT")" $'service:disable\nautostart:disabled'
}

test_update_recovery_rereads_journal_under_lock() {
  reset_transition_test
  TEST_STATE[XUI_UPDATE_RECOVERY_STATUS]=restore-root-path
  maintenance_operation_lock() {
    printf 'lock\n' >>"$TEST_AUDIT"
    unset 'TEST_STATE[XUI_UPDATE_RECOVERY_STATUS]'
  }
  platform_service_stop() { printf 'service:stop\n' >>"$TEST_AUDIT"; }

  _okp_i_recover_xui_update_transition

  assert_eq lock "$(<"$TEST_AUDIT")"
}

test_invalid_update_journal_locks_then_fails_closed() {
  reset_transition_test
  TEST_STATE[XUI_UPDATE_RECOVERY_STATUS]=corrupt
  TEST_SERVICE_STATE=active
  TEST_AUTOSTART_STATE=enabled
  OKP_MAINTENANCE_FATAL=false
  maintenance_operation_lock() { printf 'lock\n' >>"$TEST_AUDIT"; }
  platform_service_is_inactive() {
    [[ $TEST_SERVICE_STATE == inactive ]] && return 0
    [[ $TEST_SERVICE_STATE == active ]] && return 1
    return 2
  }
  platform_service_stop() {
    printf 'service:stop\n' >>"$TEST_AUDIT"
    TEST_SERVICE_STATE=inactive
  }
  platform_service_disable() {
    printf 'service:disable\n' >>"$TEST_AUDIT"
    TEST_AUTOSTART_STATE=disabled
  }
  _okp_i_xui_autostart_status() {
    printf 'autostart:%s\n' "$TEST_AUTOSTART_STATE" >>"$TEST_AUDIT"
    [[ $TEST_AUTOSTART_STATE == enabled ]] && return 0
    [[ $TEST_AUTOSTART_STATE == disabled ]] && return 1
    return 2
  }

  assert_failure _okp_i_recover_xui_update_transition

  assert_eq inactive "$TEST_SERVICE_STATE"
  assert_eq disabled "$TEST_AUTOSTART_STATE"
  assert_eq true "$OKP_MAINTENANCE_FATAL"
  assert_eq corrupt "${TEST_STATE[XUI_UPDATE_RECOVERY_STATUS]}"
  assert_contains "$(<"$TEST_AUDIT")" $'error:3x-ui 更新恢复事务状态无效。\nlock\nerror:3x-ui 更新恢复事务状态无效。\nservice:stop\nservice:disable\nautostart:disabled'
}

test_update_recovery_fail_closes_on_unverified_autostart() {
  local fake_binary=$TEST_SANDBOX/fake-xui-autostart-failure
  reset_transition_test
  make_fake_xui_binary "$fake_binary"
  OKP_XUI_BINARY_PATH=$fake_binary
  FAKE_XUI_AUDIT=$TEST_AUDIT
  FAKE_XUI_STATE=$TEST_SANDBOX/fake-xui-path-autostart-failure
  FAKE_XUI_IGNORE_SET=false
  export FAKE_XUI_AUDIT FAKE_XUI_STATE FAKE_XUI_IGNORE_SET
  printf '/official-v3.6-random-path/\n' >"$FAKE_XUI_STATE"
  TEST_STATE[XUI_UPDATE_RECOVERY_STATUS]=restore-root-path
  TEST_SERVICE_STATE=active
  TEST_AUTOSTART_STATE=disabled
  OKP_MAINTENANCE_FATAL=false
  maintenance_operation_lock() { printf 'lock\n' >>"$TEST_AUDIT"; }
  platform_service_is_inactive() {
    [[ $TEST_SERVICE_STATE == inactive ]] && return 0
    [[ $TEST_SERVICE_STATE == active ]] && return 1
    return 2
  }
  platform_service_stop() {
    printf 'service:stop\n' >>"$TEST_AUDIT"
    TEST_SERVICE_STATE=inactive
  }
  platform_service_enable() {
    printf 'service:enable\n' >>"$TEST_AUDIT"
    TEST_AUTOSTART_STATE=unknown
  }
  platform_service_disable() {
    printf 'service:disable\n' >>"$TEST_AUDIT"
    TEST_AUTOSTART_STATE=disabled
  }
  _okp_i_xui_autostart_status() {
    printf 'autostart:%s\n' "$TEST_AUTOSTART_STATE" >>"$TEST_AUDIT"
    [[ $TEST_AUTOSTART_STATE == enabled ]] && return 0
    [[ $TEST_AUTOSTART_STATE == disabled ]] && return 1
    return 2
  }
  platform_service_start() { printf 'service:start\n' >>"$TEST_AUDIT"; }
  xui_api_get() { printf 'api:%s\n' "$1" >>"$TEST_AUDIT"; }

  assert_failure _okp_i_recover_xui_update_transition

  assert_eq inactive "$TEST_SERVICE_STATE"
  assert_eq disabled "$TEST_AUTOSTART_STATE"
  assert_eq true "$OKP_MAINTENANCE_FATAL"
  assert_eq restore-root-path "${TEST_STATE[XUI_UPDATE_RECOVERY_STATUS]}"
  assert_failure grep -Fq 'service:start' "$TEST_AUDIT"
  assert_failure grep -Fq 'api:' "$TEST_AUDIT"
  assert_contains "$(<"$TEST_AUDIT")" $'service:enable\nautostart:unknown'
  assert_contains "$(<"$TEST_AUDIT")" $'service:stop\nservice:disable\nautostart:disabled'
}

test_fail_close_disables_autostart_when_stop_is_indeterminate() {
  reset_transition_test
  TEST_AUTOSTART_STATE=enabled
  OKP_MAINTENANCE_FATAL=false
  platform_service_stop() { printf 'service:stop\n' >>"$TEST_AUDIT"; }
  platform_service_is_inactive() { return 2; }
  platform_service_disable() {
    printf 'service:disable\n' >>"$TEST_AUDIT"
    TEST_AUTOSTART_STATE=disabled
  }
  _okp_i_xui_autostart_status() {
    printf 'autostart:%s\n' "$TEST_AUTOSTART_STATE" >>"$TEST_AUDIT"
    [[ $TEST_AUTOSTART_STATE == enabled ]] && return 0
    [[ $TEST_AUTOSTART_STATE == disabled ]] && return 1
    return 2
  }

  assert_failure _okp_i_fail_close_xui_update

  assert_eq disabled "$TEST_AUTOSTART_STATE"
  assert_eq true "$OKP_MAINTENANCE_FATAL"
  assert_contains "$(<"$TEST_AUDIT")" 'service:stop'
  assert_contains "$(<"$TEST_AUDIT")" $'service:disable\nautostart:disabled'
}

test_fail_close_verifies_disabled_state_after_disable_command_failure() {
  reset_transition_test
  TEST_AUTOSTART_STATE=disabled
  OKP_MAINTENANCE_FATAL=false
  platform_service_stop() { printf 'service:stop\n' >>"$TEST_AUDIT"; }
  platform_service_is_inactive() { return 0; }
  platform_service_disable() {
    printf 'service:disable:failed\n' >>"$TEST_AUDIT"
    return 1
  }
  _okp_i_xui_autostart_status() {
    printf 'autostart:%s\n' "$TEST_AUTOSTART_STATE" >>"$TEST_AUDIT"
    [[ $TEST_AUTOSTART_STATE == disabled ]] && return 1
    return 2
  }

  assert_failure _okp_i_fail_close_xui_update

  assert_eq true "$OKP_MAINTENANCE_FATAL"
  assert_eq $'service:stop\nservice:disable:failed\nerror:无法执行 x-ui 开机自启禁用命令；正在独立核验实际状态。\nautostart:disabled' \
    "$(<"$TEST_AUDIT")"
  assert_failure grep -Fq '更新失败关闭未能同时确认' "$TEST_AUDIT"
}

test_supervised_updater_reaps_process_group_before_exit_cleanup() {
  local process_dir=$TEST_SANDBOX/supervised-process
  local updater=$process_dir/updater.sh harness=$process_dir/harness.sh
  local parent_pid updater_pid descendant_pid status=0 attempt
  mkdir -p "$process_dir"
  cat >"$updater" <<'EOF'
#!/usr/bin/env bash
set -u
process_dir=$1
printf '%s\n' "$$" >"$process_dir/updater.pid"
sleep 300 &
printf '%s\n' "$!" >"$process_dir/descendant.pid"
wait
EOF
  cat >"$harness" <<'EOF'
#!/usr/bin/env bash
set -Euo pipefail
project_root=$1
process_dir=$2
source "$project_root/lib/integration.sh"
log_error() { printf 'error:%s\n' "$*" >>"$process_dir/audit"; }
log_warn() { printf 'warn:%s\n' "$*" >>"$process_dir/audit"; }
log_info() { printf 'info:%s\n' "$*" >>"$process_dir/audit"; }
_okp_i_recover_xui_update_transition() {
  printf 'recover\n' >>"$process_dir/audit"
}
maintenance_cleanup_temp_paths() {
  printf 'cleanup\n' >>"$process_dir/audit"
}
trap maintenance_cleanup_temp_paths EXIT
if _okp_i_run_supervised_xui_updater "$process_dir/updater.sh" "$process_dir" \
    /usr/bin:/bin "$process_dir/updater-output"; then
  status=0
else
  status=$?
fi
printf 'return:%s\n' "$status" >>"$process_dir/audit"
exit "$status"
EOF
  chmod 0700 "$updater" "$harness"
  : >"$process_dir/audit"

  bash "$harness" "$PROJECT_ROOT" "$process_dir" >"$process_dir/harness-output" 2>&1 &
  parent_pid=$!
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -s $process_dir/updater.pid && -s $process_dir/descendant.pid ]] && break
    command sleep 0.05
  done
  [[ -s $process_dir/updater.pid && -s $process_dir/descendant.pid ]] || {
    kill -KILL "$parent_pid" 2>/dev/null || true
    wait "$parent_pid" 2>/dev/null || true
    fail 'supervised updater did not publish its process IDs'
    return 1
  }
  updater_pid=$(<"$process_dir/updater.pid")
  descendant_pid=$(<"$process_dir/descendant.pid")
  [[ $updater_pid =~ ^[1-9][0-9]*$ && $descendant_pid =~ ^[1-9][0-9]*$ ]] ||
    fail 'supervised updater wrote invalid process IDs'

  kill -TERM "$parent_pid"
  if wait "$parent_pid"; then
    status=0
  else
    status=$?
  fi
  assert_eq 143 "$status" 'TERM should be returned only after supervised recovery'

  for ((attempt = 0; attempt < 100; attempt++)); do
    if ! kill -0 "$updater_pid" 2>/dev/null &&
        ! kill -0 "$descendant_pid" 2>/dev/null; then
      break
    fi
    command sleep 0.05
  done
  ! kill -0 "$updater_pid" 2>/dev/null || fail 'updater survived supervised TERM recovery'
  ! kill -0 "$descendant_pid" 2>/dev/null || fail 'updater descendant survived process-group termination'
  assert_eq $'recover\nreturn:143\ncleanup' "$(<"$process_dir/audit")"
}

test_proc_group_status_treats_zombies_as_settled() {
  local proc_root=$TEST_SANDBOX/fake-proc-group
  local status=0
  mkdir -p "$proc_root/101" "$proc_root/102"
  printf '101 (zombie child) Z 1 4242 1 0 0 0\n' >"$proc_root/101/stat"
  printf '102 (also ) zombie) X 1 4242 1 0 0 0\n' >"$proc_root/102/stat"

  if _okp_i_xui_update_proc_group_status 4242 "$proc_root"; then
    status=0
  else
    status=$?
  fi
  assert_eq 1 "$status" 'zombie-only process groups should be settled'

  printf '102 (live child) S 1 4242 1 0 0 0\n' >"$proc_root/102/stat"
  _okp_i_xui_update_proc_group_status 4242 "$proc_root"

  printf '102 (other group) S 1 5252 1 0 0 0\n' >"$proc_root/102/stat"
  if _okp_i_xui_update_proc_group_status 6262 "$proc_root"; then
    status=0
  else
    status=$?
  fi
  assert_eq 2 "$status" 'an unobservable process group must remain indeterminate'
}

test_exit_guard_delays_cleanup_until_settlement() {
  local status=0
  reset_transition_test
  if (
    OKP_XUI_UPDATE_SUPERVISION_ARMED=true
    OKP_XUI_UPDATE_RECOVERY_SETTLED=false
    TEST_SETTLE_ATTEMPT=0
    _okp_i_settle_interrupted_xui_update() {
      ((TEST_SETTLE_ATTEMPT += 1))
      printf 'settle:%s\n' "$TEST_SETTLE_ATTEMPT" >>"$TEST_AUDIT"
      if ((TEST_SETTLE_ATTEMPT == 1)); then
        return 1
      fi
      OKP_XUI_UPDATE_RECOVERY_SETTLED=true
      OKP_XUI_UPDATE_SETTLEMENT_MODE=fail-closed
    }
    maintenance_cleanup_temp_paths() { printf 'cleanup\n' >>"$TEST_AUDIT"; }
    sleep() { :; }
    _okp_i_xui_update_exit_guard 77
  ); then
    status=0
  else
    status=$?
  fi

  assert_eq 77 "$status"
  assert_eq $'settle:1\nerror:3x-ui 更新事务尚未安全收敛；进程将继续持有操作锁并重试，请立即人工检查。\nsettle:2\ncleanup' "$(<"$TEST_AUDIT")"
}

test_term_after_quick_child_waits_for_recovery() {
  local process_dir=$TEST_SANDBOX/post-child-signal
  local updater=$process_dir/updater.sh harness=$process_dir/harness.sh
  local parent_pid status=0 attempt
  mkdir -p "$process_dir"
  cat >"$updater" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$harness" <<'EOF'
#!/usr/bin/env bash
set -Euo pipefail
project_root=$1
process_dir=$2
source "$project_root/lib/integration.sh"
log_error() { printf 'error:%s\n' "$*" >>"$process_dir/audit"; }
log_warn() { printf 'warn:%s\n' "$*" >>"$process_dir/audit"; }
log_info() { printf 'info:%s\n' "$*" >>"$process_dir/audit"; }
_okp_i_recover_xui_update_transition() {
  printf 'recover:start\n' >>"$process_dir/audit"
  : >"$process_dir/recovery-started"
  while [[ ! -e $process_dir/recovery-release ]]; do
    command sleep 0.05 || true
  done
  printf 'recover:end\n' >>"$process_dir/audit"
}
maintenance_cleanup_temp_paths() { printf 'cleanup\n' >>"$process_dir/audit"; }
trap maintenance_cleanup_temp_paths EXIT
if _okp_i_run_supervised_xui_updater "$process_dir/updater.sh" unused \
    /usr/bin:/bin "$process_dir/updater-output"; then
  status=0
else
  status=$?
fi
printf 'return:%s\n' "$status" >>"$process_dir/audit"
exit "$status"
EOF
  chmod 0700 "$updater" "$harness"
  : >"$process_dir/audit"

  bash "$harness" "$PROJECT_ROOT" "$process_dir" >"$process_dir/harness-output" 2>&1 &
  parent_pid=$!
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -e $process_dir/recovery-started ]] && break
    command sleep 0.05
  done
  if [[ ! -e $process_dir/recovery-started ]]; then
    kill -TERM "$parent_pid" 2>/dev/null || true
    : >"$process_dir/recovery-release"
    wait "$parent_pid" 2>/dev/null || true
    fail 'quick updater did not enter supervised post-child recovery'
    return 1
  fi
  kill -TERM "$parent_pid"
  : >"$process_dir/recovery-release"
  if wait "$parent_pid"; then
    status=0
  else
    status=$?
  fi

  assert_eq 143 "$status"
  assert_eq $'recover:start\nrecover:end\nreturn:143\ncleanup' "$(<"$process_dir/audit")"
}

test_term_during_orphan_recovery_waits_before_cleanup() {
  local process_dir=$TEST_SANDBOX/orphan-recovery-signal
  local harness=$process_dir/harness.sh parent_pid status=0 attempt
  mkdir -p "$process_dir"
  cat >"$harness" <<'EOF'
#!/usr/bin/env bash
set -Euo pipefail
project_root=$1
process_dir=$2
source "$project_root/lib/integration.sh"
log_error() { printf 'error:%s\n' "$*" >>"$process_dir/audit"; }
log_warn() { printf 'warn:%s\n' "$*" >>"$process_dir/audit"; }
log_info() { printf 'info:%s\n' "$*" >>"$process_dir/audit"; }
maintenance_operation_lock() { printf 'lock\n' >>"$process_dir/audit"; }
_okp_i_recover_xui_update_transition() {
  printf 'recover:start\n' >>"$process_dir/audit"
  : >"$process_dir/recovery-started"
  while [[ ! -e $process_dir/recovery-release ]]; do
    command sleep 0.05 || true
  done
  printf 'recover:end\n' >>"$process_dir/audit"
}
maintenance_cleanup_temp_paths() { printf 'cleanup\n' >>"$process_dir/audit"; }
trap maintenance_cleanup_temp_paths EXIT
if okp_hook_settle_pending_xui_update; then
  status=0
else
  status=$?
fi
printf 'return:%s\n' "$status" >>"$process_dir/audit"
exit "$status"
EOF
  chmod 0700 "$harness"
  : >"$process_dir/audit"

  bash "$harness" "$PROJECT_ROOT" "$process_dir" >"$process_dir/harness-output" 2>&1 &
  parent_pid=$!
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -e $process_dir/recovery-started ]] && break
    command sleep 0.05
  done
  if [[ ! -e $process_dir/recovery-started ]]; then
    kill -TERM "$parent_pid" 2>/dev/null || true
    : >"$process_dir/recovery-release"
    wait "$parent_pid" 2>/dev/null || true
    fail 'orphan journal did not enter supervised recovery'
    return 1
  fi

  kill -TERM "$parent_pid"
  : >"$process_dir/recovery-release"
  if wait "$parent_pid"; then
    status=0
  else
    status=$?
  fi

  assert_eq 143 "$status"
  assert_eq $'lock\nrecover:start\nrecover:end\nreturn:143\ncleanup' \
    "$(<"$process_dir/audit")"
}

test_term_while_acquiring_orphan_recovery_lock_is_supervised() {
  local process_dir=$TEST_SANDBOX/orphan-lock-signal
  local harness=$process_dir/harness.sh status=0
  mkdir -p "$process_dir"
  cat >"$harness" <<'EOF'
#!/usr/bin/env bash
set -Euo pipefail
project_root=$1
process_dir=$2
source "$project_root/lib/integration.sh"
log_error() { printf 'error:%s\n' "$*" >>"$process_dir/audit"; }
log_warn() { printf 'warn:%s\n' "$*" >>"$process_dir/audit"; }
log_info() { printf 'info:%s\n' "$*" >>"$process_dir/audit"; }
maintenance_operation_lock() {
  printf 'lock:start\n' >>"$process_dir/audit"
  kill -TERM "$$"
  printf 'lock:end\n' >>"$process_dir/audit"
}
_okp_i_recover_xui_update_transition() {
  printf 'recover\n' >>"$process_dir/audit"
}
maintenance_cleanup_temp_paths() { printf 'cleanup\n' >>"$process_dir/audit"; }
trap maintenance_cleanup_temp_paths EXIT
if okp_hook_settle_pending_xui_update; then
  status=0
else
  status=$?
fi
printf 'return:%s\n' "$status" >>"$process_dir/audit"
exit "$status"
EOF
  chmod 0700 "$harness"
  : >"$process_dir/audit"

  if bash "$harness" "$PROJECT_ROOT" "$process_dir" \
      >"$process_dir/harness-output" 2>&1; then
    status=0
  else
    status=$?
  fi

  assert_eq 143 "$status"
  assert_eq $'lock:start\nlock:end\nrecover\nreturn:143\ncleanup' \
    "$(<"$process_dir/audit")"
}

test_term_between_spawn_and_pid_publish_reaps_child() {
  local process_dir=$TEST_SANDBOX/pre-pid-signal
  local updater=$process_dir/updater.sh harness=$process_dir/harness.sh
  local parent_pid child_pid status=0 attempt
  mkdir -p "$process_dir"
  cat >"$updater" <<'EOF'
#!/usr/bin/env bash
sleep 300
EOF
  cat >"$harness" <<'EOF'
#!/usr/bin/env bash
set -ETuo pipefail
project_root=$1
process_dir=$2
source "$project_root/lib/integration.sh"
log_error() { printf 'error:%s\n' "$*" >>"$process_dir/audit"; }
log_warn() { printf 'warn:%s\n' "$*" >>"$process_dir/audit"; }
log_info() { printf 'info:%s\n' "$*" >>"$process_dir/audit"; }
_okp_i_recover_xui_update_transition() { printf 'recover\n' >>"$process_dir/audit"; }
maintenance_cleanup_temp_paths() { printf 'cleanup\n' >>"$process_dir/audit"; }
trap maintenance_cleanup_temp_paths EXIT
TEST_PRE_PID_SIGNAL_SENT=false
signal_before_pid_publish() {
  if [[ $TEST_PRE_PID_SIGNAL_SENT == false &&
      ${BASH_COMMAND-} == 'OKP_XUI_UPDATE_CHILD_PID=$!' ]]; then
    TEST_PRE_PID_SIGNAL_SENT=true
    printf '%s\n' "$!" >"$process_dir/child.pid"
    : >"$process_dir/pre-pid-signal"
    kill -TERM "$$"
  fi
}
trap signal_before_pid_publish DEBUG
if _okp_i_run_supervised_xui_updater "$process_dir/updater.sh" unused \
    /usr/bin:/bin "$process_dir/updater-output"; then
  status=0
else
  status=$?
fi
trap - DEBUG
printf 'return:%s\n' "$status" >>"$process_dir/audit"
exit "$status"
EOF
  chmod 0700 "$updater" "$harness"
  : >"$process_dir/audit"

  bash "$harness" "$PROJECT_ROOT" "$process_dir" >"$process_dir/harness-output" 2>&1 &
  parent_pid=$!
  for ((attempt = 0; attempt < 200; attempt++)); do
    ! kill -0 "$parent_pid" 2>/dev/null && break
    command sleep 0.05
  done
  if kill -0 "$parent_pid" 2>/dev/null; then
    kill -TERM "$parent_pid" 2>/dev/null || true
  fi
  if wait "$parent_pid"; then
    status=0
  else
    status=$?
  fi
  [[ -e $process_dir/pre-pid-signal && -s $process_dir/child.pid ]] || {
    fail 'DEBUG harness did not inject TERM before updater PID publication'
    return 1
  }
  child_pid=$(<"$process_dir/child.pid")

  assert_eq 143 "$status"
  ! kill -0 "$child_pid" 2>/dev/null || fail 'pre-publication signal left updater child alive'
  assert_eq $'recover\nreturn:143\ncleanup' "$(<"$process_dir/audit")"
}

test_backup_and_restore_reject_ambiguous_service_state() {
  reset_transition_test
  platform_service_exists() { return 0; }
  platform_service_is_inactive() { return 2; }
  platform_service_stop() { printf 'service:stop\n' >>"$TEST_AUDIT"; }

  assert_failure okp_hook_before_backup
  assert_failure okp_hook_before_restore
  assert_failure grep -Fq 'service:stop' "$TEST_AUDIT"
  assert_contains "$(<"$TEST_AUDIT")" '备份已取消'
  assert_contains "$(<"$TEST_AUDIT")" '拒绝恢复'
}

test_uninstall_rejects_indeterminate_service_presence() {
  reset_transition_test
  platform_service_exists() { return 2; }
  platform_service_disable() { printf 'service:disable\n' >>"$TEST_AUDIT"; }

  assert_failure _okp_i_uninstall_xui

  assert_failure grep -Fq 'service:disable' "$TEST_AUDIT"
  assert_contains "$(<"$TEST_AUDIT")" '拒绝卸载'
}

test_combined_xui_database_uninstall_removes_secure_install_result() {
  local xui_dir=$TEST_SANDBOX/uninstall-combined
  reset_transition_test
  mkdir -p "$xui_dir"
  : >"$xui_dir/x-ui.db"
  : >"$xui_dir/install-result.env"
  TEST_STATE[XUI_DB_PATH]=$xui_dir/x-ui.db
  OKP_XUI_INSTALL_RESULT_PATH=$xui_dir/install-result.env
  OKP_UNINSTALL_COMPONENTS=(xui database)
  _okp_i_path_is_safe_under() { return 0; }
  platform_service_exists() { return 1; }
  state_unset() { unset 'TEST_STATE[$1]'; }
  stat() {
    case $2 in
      %u) printf '0\n' ;;
      %h) printf '1\n' ;;
      *) command stat "$@" ;;
    esac
  }

  _okp_i_uninstall_database

  assert_file_not_exists "$xui_dir/x-ui.db"
  assert_file_not_exists "$xui_dir/install-result.env"
}

test_single_database_uninstall_preserves_install_result() {
  local xui_dir=$TEST_SANDBOX/uninstall-database-only
  reset_transition_test
  mkdir -p "$xui_dir"
  : >"$xui_dir/x-ui.db"
  : >"$xui_dir/install-result.env"
  TEST_STATE[XUI_DB_PATH]=$xui_dir/x-ui.db
  OKP_XUI_INSTALL_RESULT_PATH=$xui_dir/install-result.env
  OKP_UNINSTALL_COMPONENTS=(database)
  _okp_i_path_is_safe_under() { return 0; }
  platform_service_exists() { return 1; }
  state_unset() { unset 'TEST_STATE[$1]'; }

  _okp_i_uninstall_database

  assert_file_not_exists "$xui_dir/x-ui.db"
  assert_file_exists "$xui_dir/install-result.env"
}

test_single_xui_uninstall_preserves_install_result() {
  local xui_dir=$TEST_SANDBOX/uninstall-xui-only
  reset_transition_test
  mkdir -p "$xui_dir"
  : >"$xui_dir/install-result.env"
  OKP_XUI_INSTALL_RESULT_PATH=$xui_dir/install-result.env
  OKP_UNINSTALL_COMPONENTS=(xui)
  platform_service_exists() { return 1; }
  systemctl() { return 0; }

  (
    rm() { return 0; }
    _okp_i_uninstall_xui
  )

  assert_file_exists "$xui_dir/install-result.env"
}

test_combined_uninstall_rejects_unsafe_install_result() {
  local xui_dir=$TEST_SANDBOX/uninstall-unsafe target=$TEST_SANDBOX/uninstall-target
  reset_transition_test
  mkdir -p "$xui_dir"
  : >"$xui_dir/x-ui.db"
  : >"$target"
  ln -s "$target" "$xui_dir/install-result.env"
  TEST_STATE[XUI_DB_PATH]=$xui_dir/x-ui.db
  OKP_XUI_INSTALL_RESULT_PATH=$xui_dir/install-result.env
  OKP_UNINSTALL_COMPONENTS=(xui database)
  _okp_i_path_is_safe_under() { return 0; }
  platform_service_exists() { return 1; }

  assert_failure _okp_i_uninstall_database

  assert_file_exists "$xui_dir/x-ui.db"
  [[ -L $xui_dir/install-result.env ]] || fail 'unsafe install-result symlink was removed'
  assert_file_exists "$target"
}

test_database_delete_failure_preserves_install_result_and_state() {
  local xui_dir=$TEST_SANDBOX/uninstall-delete-failure
  reset_transition_test
  mkdir -p "$xui_dir"
  : >"$xui_dir/x-ui.db"
  : >"$xui_dir/install-result.env"
  TEST_STATE[XUI_DB_PATH]=$xui_dir/x-ui.db
  OKP_XUI_INSTALL_RESULT_PATH=$xui_dir/install-result.env
  OKP_UNINSTALL_COMPONENTS=(xui database)
  _okp_i_path_is_safe_under() { return 0; }
  platform_service_exists() { return 1; }
  stat() {
    case $2 in
      %u) printf '0\n' ;;
      %h) printf '1\n' ;;
      *) command stat "$@" ;;
    esac
  }
  rm() { return 1; }

  assert_failure _okp_i_uninstall_database
  unset -f rm

  assert_file_exists "$xui_dir/x-ui.db"
  assert_file_exists "$xui_dir/install-result.env"
  assert_eq "$xui_dir/x-ui.db" "${TEST_STATE[XUI_DB_PATH]}"
}

test_remote_relay_guard_protects_pending_records_and_uninstall() {
  CONFIG_DIR=$TEST_SANDBOX/relay-guard-state
  mkdir -p "$CONFIG_DIR/remote-relays"
  assert_success _okp_i_require_no_remote_relays
  printf '{}\n' >"$CONFIG_DIR/remote-relays/pending.json"
  log_error() { printf '%s\n' "$*" >&2; }
  assert_failure _okp_i_require_no_remote_relays
  _okp_i_uninstall_clients() { printf touched >"$CONFIG_DIR/touched"; }
  assert_failure okp_hook_uninstall_component clients
  [[ ! -e $CONFIG_DIR/touched ]] || return 1
  rm -- "$CONFIG_DIR/remote-relays/pending.json"
  assert_success _okp_i_require_no_remote_relays
}

run_test 'NAT port-only changes reuse a matching IP certificate' test_nat_unchanged_san_does_not_replace_certificate
run_test 'NAT certificate replacement activates and commits its journal' test_nat_replacement_activates_then_commits_transition
run_test 'preparing TLS transition recovery is bound to certificate SAN' test_preparing_transition_recovery_is_san_bound
run_test 'active TLS transition recovery commits a healthy saved identity' test_active_transition_recovery_commits_matching_saved_identity
run_test 'certificate renewal refreshes result before diagnostics' test_certificate_renewal_rewrites_result_before_diagnostics
run_test 'domain reconfiguration retires old ACME only after result and diagnostics' \
  test_domain_reconfiguration_retires_old_acme_only_after_commit_checks
run_test 'failed result or diagnostics keeps the old ACME renewal config' \
  test_domain_reconfiguration_never_retires_old_acme_before_success
run_test 'old ACME cleanup failure does not mutate the active service' \
  test_old_acme_cleanup_failure_keeps_new_service_untouched
run_test 'pending ACME cleanup revalidates the committed new identity before retry' \
  test_pending_acme_cleanup_revalidates_new_identity_before_retry
run_test 'forced renewal is blocked while a domain change remains uncommitted' \
  test_forced_renewal_is_blocked_during_uncommitted_domain_change
run_test 'v3.6 random panel path is repaired offline before API use' test_v360_random_path_is_repaired_offline_before_api
run_test 'updater recovery reaches API only after root-path readback' test_update_recovery_calls_api_only_after_offline_root_repair
run_test 'bad root-path readback leaves the service stopped and journaled' test_update_recovery_keeps_service_stopped_on_bad_readback
run_test 'updater recovery rereads its journal while holding the operation lock' test_update_recovery_rereads_journal_under_lock
run_test 'invalid updater journal locks and fails closed' test_invalid_update_journal_locks_then_fails_closed
run_test 'unverified autostart fails closed before service or API activation' test_update_recovery_fail_closes_on_unverified_autostart
run_test 'fail-close disables autostart even when stop status is indeterminate' \
  test_fail_close_disables_autostart_when_stop_is_indeterminate
run_test 'fail-close verifies disabled autostart after the disable command fails' \
  test_fail_close_verifies_disabled_state_after_disable_command_failure
run_test 'TERM reaps the updater process group before recovery and lock cleanup' test_supervised_updater_reaps_process_group_before_exit_cleanup
run_test 'zombie-only updater groups are settled without hiding live members' test_proc_group_status_treats_zombies_as_settled
run_test 'EXIT guard withholds cleanup until settlement is verified' test_exit_guard_delays_cleanup_until_settlement
run_test 'TERM after a quick updater waits for post-child recovery' test_term_after_quick_child_waits_for_recovery
run_test 'TERM during orphan journal recovery waits before lock cleanup' \
  test_term_during_orphan_recovery_waits_before_cleanup
run_test 'TERM while acquiring orphan recovery lock is supervised' \
  test_term_while_acquiring_orphan_recovery_lock_is_supervised
run_test 'TERM before updater PID publication still reaps the child' test_term_between_spawn_and_pid_publish_reaps_child
run_test 'backup and restore reject ambiguous service activity' test_backup_and_restore_reject_ambiguous_service_state
run_test 'uninstall rejects indeterminate service presence' test_uninstall_rejects_indeterminate_service_presence
run_test 'combined xui/database uninstall removes a secure install result' \
  test_combined_xui_database_uninstall_removes_secure_install_result
run_test 'database-only uninstall preserves the install result' \
  test_single_database_uninstall_preserves_install_result
run_test 'xui-only uninstall preserves the install result' \
  test_single_xui_uninstall_preserves_install_result
run_test 'combined uninstall rejects an unsafe install result path' \
  test_combined_uninstall_rejects_unsafe_install_result
run_test 'database deletion failure preserves the install result and state' \
  test_database_delete_failure_preserves_install_result_and_state
run_test 'remote relay guard protects pending transactions and client uninstall' \
  test_remote_relay_guard_protects_pending_records_and_uninstall

finish_tests
