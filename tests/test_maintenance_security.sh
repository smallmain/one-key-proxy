#!/usr/bin/env bash

set -uo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_internal_harness_can_enable_test_paths() {
  local sandbox
  sandbox=$(make_test_temp_dir)
  trap 'rm -rf -- "$sandbox"' RETURN

  OKP_TEST_MODE=true
  OKP_INTERNAL_TEST_HARNESS=one-key-proxy-tests-v1
  CONFIG_DIR=$sandbox/config
  STATE_FILE=$sandbox/state.env
  CERT_DIR=$sandbox/certs
  LOG_FILE=$sandbox/project.log
  BACKUP_DIR=$sandbox/backups
  RESULT_FILE=$sandbox/result.txt
  OKP_OPERATION_LOCK_FILE=$sandbox/operation.lock

  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/maintenance.sh"

  assert_eq true "$OKP_MAINTENANCE_TEST_MODE"
  assert_eq false "$OKP_PRODUCTION_MODE"
  assert_eq "$sandbox/config" "$CONFIG_DIR"
  assert_eq "$sandbox/state.env" "$STATE_FILE"
  assert_eq "$sandbox/operation.lock" "$OKP_OPERATION_LOCK_FILE"
  [[ ! -v OKP_INTERNAL_TEST_HARNESS ]] || fail 'test sentinel must be consumed'
}

test_test_mode_without_sentinel_is_forced_to_production() {
  local source_status=0

  OKP_TEST_MODE=true
  CONFIG_DIR=/tmp/attacker-controlled-config
  STATE_FILE=/tmp/attacker-controlled-state
  OKP_OPERATION_LOCK_FILE=/tmp/attacker-controlled-lock

  # A non-root-owned checkout can fail the production ownership check. The
  # security assertions below must still hold because paths are fixed first.
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/maintenance.sh" >/dev/null 2>&1 || source_status=$?
  : "$source_status"

  assert_eq false "$OKP_MAINTENANCE_TEST_MODE"
  assert_eq true "$OKP_PRODUCTION_MODE"
  assert_eq /etc/one-key-proxy "$CONFIG_DIR"
  assert_eq /etc/one-key-proxy/state.env "$STATE_FILE"
  assert_eq /run/one-key-proxy/operation.lock "$OKP_OPERATION_LOCK_FILE"
  [[ ! -v OKP_TEST_MODE ]] || fail 'untrusted test-mode flag must be removed'
}

test_wrong_sentinel_is_forced_to_production() {
  local source_status=0

  OKP_TEST_MODE=true
  OKP_INTERNAL_TEST_HARNESS=not-the-project-test-harness
  RESULT_FILE=/tmp/attacker-controlled-result

  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/maintenance.sh" >/dev/null 2>&1 || source_status=$?
  : "$source_status"

  assert_eq false "$OKP_MAINTENANCE_TEST_MODE"
  assert_eq true "$OKP_PRODUCTION_MODE"
  assert_eq /root/one-key-proxy-result.txt "$RESULT_FILE"
  [[ ! -v OKP_TEST_MODE ]] || fail 'wrong sentinel must not preserve test mode'
  [[ ! -v OKP_INTERNAL_TEST_HARNESS ]] || fail 'wrong sentinel must be removed'
}

test_direct_entrypoints_clear_test_environment() {
  local install launcher maintenance
  install=$(<"$PROJECT_ROOT/install.sh")
  launcher=$(<"$PROJECT_ROOT/one-key-proxy")
  maintenance=$(<"$PROJECT_ROOT/maintenance.sh")

  assert_contains "$install" 'unset OKP_TEST_MODE OKP_INTERNAL_TEST_HARNESS'
  assert_contains "$launcher" 'unset OKP_TEST_MODE OKP_INTERNAL_TEST_HARNESS'
  assert_contains "$launcher" 'OKP_PRODUCTION_MODE=true'
  assert_contains "$maintenance" '${BASH_SOURCE[0]} != "$0"'
  assert_contains "$maintenance" 'OKP_MAINTENANCE_TEST_MODE=false'
}

test_direct_maintenance_ignores_test_environment_at_runtime() {
  local status=0 trace

  trace=$(env \
    OKP_TEST_MODE=true \
    OKP_INTERNAL_TEST_HARNESS=one-key-proxy-tests-v1 \
    CONFIG_DIR=/tmp/attacker-controlled-config \
    STATE_FILE=/tmp/attacker-controlled-state \
    OKP_OPERATION_LOCK_FILE=/tmp/attacker-controlled-lock \
    bash -x "$PROJECT_ROOT/maintenance.sh" --help 2>&1) || status=$?
  : "$status"

  assert_contains "$trace" '+ OKP_MAINTENANCE_TEST_MODE=false'
  assert_contains "$trace" '+ OKP_PRODUCTION_MODE=true'
  assert_contains "$trace" '+ CONFIG_DIR=/etc/one-key-proxy'
  assert_contains "$trace" '+ STATE_FILE=/etc/one-key-proxy/state.env'
  assert_contains "$trace" '+ OKP_OPERATION_LOCK_FILE=/run/one-key-proxy/operation.lock'
}

test_mutating_update_settles_before_info_backup_and_updater() {
  local sandbox audit
  sandbox=$(make_test_temp_dir)
  audit=$sandbox/audit
  : >"$audit"

  OKP_TEST_MODE=true
  OKP_INTERNAL_TEST_HARNESS=one-key-proxy-tests-v1
  CONFIG_DIR=$sandbox/config
  STATE_FILE=$sandbox/state.env
  CERT_DIR=$sandbox/certs
  LOG_FILE=$sandbox/project.log
  BACKUP_DIR=$sandbox/backups
  RESULT_FILE=$sandbox/result.txt
  OKP_OPERATION_LOCK_FILE=$sandbox/operation.lock
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/maintenance.sh"
  maintenance_temp_register "$sandbox"

  maintenance_require_root() { :; }
  maintenance_require_tty() { :; }
  maintenance_operation_lock() { printf 'lock\n' >>"$audit"; }
  okp_hook_settle_pending_xui_update() {
    printf 'settle:start\n' >>"$audit"
    maintenance_operation_lock
    printf 'settle:end\n' >>"$audit"
  }
  state_init() { :; }
  state_ensure_identity() { :; }
  maintenance_confirm() { return 0; }
  maintenance_backup_create() { printf 'backup\n' >>"$audit"; }
  okp_hook_xui_update_info() { printf 'info\n' >>"$audit"; }
  okp_hook_xui_update() { printf 'updater\n' >>"$audit"; }

  maintenance_main update-3xui

  assert_eq $'settle:start\nlock\nsettle:end\ninfo\nbackup\nupdater' "$(<"$audit")"
}

run_test 'internal sentinel allows repository test harness paths' test_internal_harness_can_enable_test_paths
run_test 'missing sentinel cannot enable maintenance test mode' test_test_mode_without_sentinel_is_forced_to_production
run_test 'wrong sentinel cannot enable maintenance test mode' test_wrong_sentinel_is_forced_to_production
run_test 'direct entrypoints clear inherited test environment' test_direct_entrypoints_clear_test_environment
run_test 'direct maintenance ignores inherited test paths at runtime' test_direct_maintenance_ignores_test_environment_at_runtime
run_test 'mutating update settles before info, backup, and updater' \
  test_mutating_update_settles_before_info_backup_and_updater
finish_tests
