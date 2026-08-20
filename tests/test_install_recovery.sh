#!/usr/bin/env bash

set -uo pipefail
# shellcheck source=test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

load_install_functions() {
  # The BASH_SOURCE guard defines orchestration without running main. Each test
  # executes in its own subshell, so the production traps cannot leak.
  # shellcheck source=../install.sh
  source "$PROJECT_ROOT/install.sh"
  trap - EXIT HUP INT TERM
  INSTALL_TEMP_PATHS=()
  log_error() { :; }
  log_warn() { :; }
}

install_partial_match_stubs() {
  MOCK_INSTALLED_PORT=41001
  MOCK_INSTALLED_USER=smallmain
  MOCK_INSTALLED_PASSWORD='expected-password-1234'
  MOCK_INSTALLED_PATH=/
  PANEL_INTERNAL_PORT=41001
  PANEL_USERNAME=smallmain
  PANEL_PASSWORD='expected-password-1234'
  xui_partial_install_artifacts_exist() { return 0; }
  read_official_install_value() {
    case $1 in
      XUI_PANEL_PORT) printf '%s' "$MOCK_INSTALLED_PORT" ;;
      XUI_USERNAME) printf '%s' "$MOCK_INSTALLED_USER" ;;
      XUI_WEB_BASE_PATH) printf '%s' "$MOCK_INSTALLED_PATH" ;;
      *) return 1 ;;
    esac
  }
  official_install_serialized_value_matches() {
    [[ $1 == XUI_PASSWORD && $2 == "$MOCK_INSTALLED_PASSWORD" ]]
  }
}

install_cleanup_stubs() {
  PANEL_INTERNAL_PORT=41001
  XUI_INSTALL_GUARD_ACTIVE=true
  MOCK_BINARY_STATUS=0
  MOCK_LOOPBACK_STATUS=0
  MOCK_RESTART_STATUS=1
  MOCK_SERVICE_EXISTS_STATUS=0
  MOCK_STOP_STATUS=0
  MOCK_INACTIVE_STATUS=0
  MOCK_DISABLE_STATUS=0
  MOCK_AUTOSTART_STATUS=0
  MOCK_LISTENER_STATUS=1
  MOCK_STOP_CALLS=0
  MOCK_DISABLE_CALLS=0
  xui_partial_binary_exists() { return "$MOCK_BINARY_STATUS"; }
  xui_set_panel_loopback() { return "$MOCK_LOOPBACK_STATUS"; }
  platform_service_restart() { return "$MOCK_RESTART_STATUS"; }
  wait_for_panel_loopback_http() { return 1; }
  platform_service_exists() { return "$MOCK_SERVICE_EXISTS_STATUS"; }
  platform_service_stop() { MOCK_STOP_CALLS=$((MOCK_STOP_CALLS + 1)); return "$MOCK_STOP_STATUS"; }
  platform_service_is_inactive() { return "$MOCK_INACTIVE_STATUS"; }
  platform_service_disable() { MOCK_DISABLE_CALLS=$((MOCK_DISABLE_CALLS + 1)); return "$MOCK_DISABLE_STATUS"; }
  xui_service_autostart_disabled() { return "$MOCK_AUTOSTART_STATUS"; }
  platform_port_is_listening() { return "$MOCK_LISTENER_STATUS"; }
}

test_partial_install_identity_must_match_atomically() {
  load_install_functions
  install_partial_match_stubs
  assert_success xui_partial_install_matches

  MOCK_INSTALLED_PORT=41002
  assert_failure xui_partial_install_matches
  MOCK_INSTALLED_PORT=41001
  MOCK_INSTALLED_USER=other
  assert_failure xui_partial_install_matches
  MOCK_INSTALLED_USER=smallmain
  MOCK_INSTALLED_PATH=/unexpected
  assert_failure xui_partial_install_matches
  MOCK_INSTALLED_PATH=''
  assert_failure xui_partial_install_matches
  MOCK_INSTALLED_PATH=/
  MOCK_INSTALLED_PASSWORD=different-password-1234
  assert_failure xui_partial_install_matches
}

test_serialized_password_match_is_exact_and_non_executable() {
  TEST_SANDBOX=$(make_test_temp_dir)
  trap 'rm -rf -- "$TEST_SANDBOX"' RETURN
  local result_file=$TEST_SANDBOX/install-result.env
  local password='space $(touch /tmp/must-not-run) `false` quote '\'' value'
  load_install_functions
  printf 'XUI_PASSWORD=%q\n' "$password" >"$result_file"
  assert_success install_serialized_value_matches_file "$result_file" XUI_PASSWORD "$password"
  assert_failure install_serialized_value_matches_file "$result_file" XUI_PASSWORD different-password
  printf 'XUI_PASSWORD=%q\nXUI_PASSWORD=%q\n' "$password" "$password" >"$result_file"
  assert_failure install_serialized_value_matches_file "$result_file" XUI_PASSWORD "$password"
}

test_restart_failure_can_only_clear_guard_after_verified_stop() {
  load_install_functions
  install_cleanup_stubs
  assert_success secure_partial_xui_after_failed_install
  assert_eq false "$XUI_INSTALL_GUARD_ACTIVE" \
    'verified stop should clear the install guard'
  assert_eq 1 "$MOCK_STOP_CALLS" 'restart failure must attempt a service stop'
  assert_eq 1 "$MOCK_DISABLE_CALLS" 'restart failure must independently disable autostart'
}

test_indeterminate_service_state_keeps_guard_active() {
  load_install_functions
  install_cleanup_stubs
  MOCK_INACTIVE_STATUS=2
  assert_failure secure_partial_xui_after_failed_install
  assert_eq true "$XUI_INSTALL_GUARD_ACTIVE" \
    'indeterminate service state must keep the guard active'
  assert_eq 1 "$MOCK_DISABLE_CALLS" \
    'autostart disable must still run when inactive state is indeterminate'
}

test_indeterminate_autostart_state_keeps_guard_active() {
  load_install_functions
  install_cleanup_stubs
  MOCK_AUTOSTART_STATUS=2
  assert_failure secure_partial_xui_after_failed_install
  assert_eq true "$XUI_INSTALL_GUARD_ACTIVE" \
    'indeterminate autostart state must keep the guard active'
}

test_stop_and_disable_commands_are_checked_by_independent_readback() {
  load_install_functions
  install_cleanup_stubs
  MOCK_STOP_STATUS=1
  MOCK_DISABLE_STATUS=1
  assert_success secure_partial_xui_after_failed_install
  assert_eq false "$XUI_INSTALL_GUARD_ACTIVE"
  assert_eq 1 "$MOCK_STOP_CALLS"
  assert_eq 1 "$MOCK_DISABLE_CALLS"
}

test_indeterminate_service_presence_keeps_guard_active() {
  load_install_functions
  install_cleanup_stubs
  MOCK_SERVICE_EXISTS_STATUS=2
  assert_failure secure_partial_xui_after_failed_install
  assert_eq true "$XUI_INSTALL_GUARD_ACTIVE" \
    'indeterminate service presence must keep the guard active'
}

test_indeterminate_listener_probe_keeps_guard_active() {
  load_install_functions
  install_cleanup_stubs
  MOCK_SERVICE_EXISTS_STATUS=1
  MOCK_LISTENER_STATUS=2
  assert_failure secure_partial_xui_after_failed_install
  assert_eq true "$XUI_INSTALL_GUARD_ACTIVE" \
    'indeterminate listener state must keep the guard active'
}

install_transaction_stubs() {
  RESULT_PATH_STATUS=1
  RESULT_SAFE_STATUS=0
  RESULT_IDENTITY_STATUS=0
  FOREIGN_XUI_STATUS=0
  : >"$TEST_SANDBOX/transaction-audit"
  xui_install_transition_read() { return 0; }
  xui_install_result_path_exists() { return "$RESULT_PATH_STATUS"; }
  xui_install_result_path_is_safe() { return "$RESULT_SAFE_STATUS"; }
  xui_install_result_identity_matches() { return "$RESULT_IDENTITY_STATUS"; }
  foreign_xui_exists() { return "$FOREIGN_XUI_STATUS"; }
  stop_owned_partial_xui_for_retry() { printf 'stop\n' >>"$TEST_SANDBOX/transaction-audit"; }
}

test_binary_only_transaction_is_authorized_for_safe_replay() {
  TEST_SANDBOX=$(make_test_temp_dir)
  trap 'rm -rf -- "$TEST_SANDBOX"' RETURN
  load_install_functions
  install_transaction_stubs

  assert_success prepare_xui_install_transaction
  assert_eq true "$XUI_INSTALL_TRANSACTION_PRESENT"
  assert_eq stop "$(<"$TEST_SANDBOX/transaction-audit")"
}

test_result_without_service_requires_exact_identity() {
  TEST_SANDBOX=$(make_test_temp_dir)
  trap 'rm -rf -- "$TEST_SANDBOX"' RETURN
  load_install_functions
  install_transaction_stubs
  RESULT_PATH_STATUS=0

  assert_success prepare_xui_install_transaction
  assert_eq true "$XUI_INSTALL_TRANSACTION_PRESENT"
  assert_eq stop "$(<"$TEST_SANDBOX/transaction-audit")"

  : >"$TEST_SANDBOX/transaction-audit"
  RESULT_IDENTITY_STATUS=1
  assert_failure prepare_xui_install_transaction
  assert_eq '' "$(<"$TEST_SANDBOX/transaction-audit")"
}

test_term_reaps_initial_installer_group_before_fail_close() {
  TEST_SANDBOX=$(make_test_temp_dir)
  trap 'rm -rf -- "$TEST_SANDBOX"' RETURN
  local process_dir=$TEST_SANDBOX/initial-signal
  local updater=$process_dir/updater.sh harness=$process_dir/harness.sh
  local parent_pid updater_pid descendant_pid status=0 attempt state
  mkdir -p "$process_dir"
  cat >"$updater" <<'EOF'
#!/usr/bin/env bash
process_dir=$1
printf '%s\n' "$$" >"$process_dir/updater.pid"
sleep 300 &
printf '%s\n' "$!" >"$process_dir/descendant.pid"
: >"$process_dir/ready"
wait
EOF
  cat >"$harness" <<'EOF'
#!/usr/bin/env bash
set -Euo pipefail
project_root=$1
process_dir=$2
source "$project_root/install.sh"
log_error() { printf 'error:%s\n' "$*" >>"$process_dir/audit"; }
log_warn() { :; }
log_info() { :; }
process_is_executable() {
  local pid=$1 state
  kill -0 "$pid" 2>/dev/null || return 1
  state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
  [[ $state != Z* && $state != X* ]]
}
secure_partial_xui_after_failed_install() {
  local updater_pid descendant_pid attempts=0
  updater_pid=$(<"$process_dir/updater.pid")
  descendant_pid=$(<"$process_dir/descendant.pid")
  if process_is_executable "$updater_pid" || process_is_executable "$descendant_pid"; then
    printf 'unsafe\n' >>"$process_dir/audit"
    return 1
  fi
  [[ ! -r $process_dir/settle-attempts ]] || attempts=$(<"$process_dir/settle-attempts")
  attempts=$((attempts + 1))
  printf '%s\n' "$attempts" >"$process_dir/settle-attempts"
  if ((attempts < 2)); then
    printf 'retry:%s\n' "$attempts" >>"$process_dir/audit"
    return 1
  fi
  printf 'safe\n' >>"$process_dir/audit"
  XUI_INSTALL_GUARD_ACTIVE=false
}
PANEL_USERNAME=test-user
PANEL_PASSWORD=test-password-1234
PANEL_INTERNAL_PORT=41001
PUBLIC_IPV4=192.0.2.10
XUI_INSTALL_GUARD_ACTIVE=true
if run_supervised_xui_installer "$process_dir/updater.sh" "$process_dir" \
    /usr/bin:/bin "$process_dir/updater-output"; then
  status=0
else
  status=$?
fi
install_settle_partial_xui_install
printf 'return:%s\n' "$status" >>"$process_dir/audit"
exit "$status"
EOF
  chmod 0700 "$updater" "$harness"
  : >"$process_dir/audit"

  bash "$harness" "$PROJECT_ROOT" "$process_dir" >"$process_dir/harness-output" 2>&1 &
  parent_pid=$!
  for ((attempt = 0; attempt < 200; attempt++)); do
    [[ -e $process_dir/ready ]] && break
    command sleep 0.05
  done
  [[ -e $process_dir/ready ]] || {
    kill -TERM "$parent_pid" 2>/dev/null || true
    wait "$parent_pid" 2>/dev/null || true
    fail 'initial installer process group did not become ready'
    return 1
  }
  kill -TERM "$parent_pid"
  if wait "$parent_pid"; then
    status=0
  else
    status=$?
  fi
  updater_pid=$(<"$process_dir/updater.pid")
  descendant_pid=$(<"$process_dir/descendant.pid")

  assert_eq 143 "$status"
  for parent_pid in "$updater_pid" "$descendant_pid"; do
    if kill -0 "$parent_pid" 2>/dev/null; then
      state=$(ps -o stat= -p "$parent_pid" 2>/dev/null | tr -d '[:space:]' || true)
      [[ $state == Z* || $state == X* ]] || fail "installer process remained executable: $parent_pid ($state)"
    fi
  done
  local audit
  audit=$(<"$process_dir/audit")
  assert_contains "$audit" 'retry:1'
  assert_contains "$audit" 'safe'
  assert_contains "$audit" 'return:143'
  [[ $audit != *unsafe* ]] || fail 'fail-close ran before the installer process group was reaped'
}

test_nonzero_installer_holds_process_until_fail_close_settles() {
  TEST_SANDBOX=$(make_test_temp_dir)
  trap 'rm -rf -- "$TEST_SANDBOX"' RETURN
  local process_dir=$TEST_SANDBOX/initial-failure
  local updater=$process_dir/updater.sh harness=$process_dir/harness.sh
  local parent_pid status=0 attempt audit
  mkdir -p "$process_dir"
  cat >"$updater" <<'EOF'
#!/usr/bin/env bash
process_dir=$1
: >"$process_dir/ready"
exit 37
EOF
  cat >"$harness" <<'EOF'
#!/usr/bin/env bash
set -Euo pipefail
project_root=$1
process_dir=$2
source "$project_root/install.sh"
log_error() { printf 'error:%s\n' "$*" >>"$process_dir/audit"; }
log_warn() { :; }
log_info() { :; }
secure_partial_xui_after_failed_install() {
  printf 'retry\n' >>"$process_dir/audit"
  [[ -e $process_dir/allow-settle ]] || return 1
  printf 'safe\n' >>"$process_dir/audit"
  XUI_INSTALL_GUARD_ACTIVE=false
}
PANEL_USERNAME=test-user
PANEL_PASSWORD=test-password-1234
PANEL_INTERNAL_PORT=41001
PUBLIC_IPV4=192.0.2.10
XUI_INSTALL_GUARD_ACTIVE=true
if run_supervised_xui_installer "$process_dir/updater.sh" "$process_dir" \
    /usr/bin:/bin "$process_dir/updater-output"; then
  status=0
else
  status=$?
fi
install_settle_partial_xui_install
printf 'return:%s\n' "$status" >>"$process_dir/audit"
exit "$status"
EOF
  chmod 0700 "$updater" "$harness"
  : >"$process_dir/audit"

  bash "$harness" "$PROJECT_ROOT" "$process_dir" >"$process_dir/harness-output" 2>&1 &
  parent_pid=$!
  for ((attempt = 0; attempt < 200; attempt++)); do
    grep -Fxq retry "$process_dir/audit" 2>/dev/null && break
    command sleep 0.05
  done
  grep -Fxq retry "$process_dir/audit" 2>/dev/null || {
    kill -KILL "$parent_pid" 2>/dev/null || true
    wait "$parent_pid" 2>/dev/null || true
    fail 'nonzero installer did not enter fail-close settlement'
    return 1
  }
  kill -0 "$parent_pid" 2>/dev/null || {
    fail 'installer exited while fail-close remained unsafe'
    return 1
  }
  : >"$process_dir/allow-settle"
  if wait "$parent_pid"; then
    status=0
  else
    status=$?
  fi
  assert_eq 37 "$status"
  audit=$(<"$process_dir/audit")
  assert_contains "$audit" 'retry'
  assert_contains "$audit" 'safe'
  assert_contains "$audit" 'return:37'
}

test_help_exit_cleanup_uses_defined_settlement_helpers() {
  local output
  output=$(bash "$PROJECT_ROOT/install.sh" --help 2>&1) || return 1
  [[ $output != *'command not found'* ]] || fail 'help cleanup called an undefined function'
}

test_early_signal_handler_tolerates_helpers_not_yet_defined() {
  local output status=0
  if output=$(bash -c '
      source "$1"
      trap - EXIT HUP INT TERM
      unset -f install_settle_xui_process_group install_settle_partial_xui_install
      install_handle_signal TERM
    ' _ "$PROJECT_ROOT/install.sh" 2>&1); then
    status=0
  else
    status=$?
  fi
  assert_eq 143 "$status"
  [[ $output != *'command not found'* ]] || fail 'early signal handler called an undefined helper'
}

run_test 'partial install identity requires matching port, user, password, and root path' \
  test_partial_install_identity_must_match_atomically
run_test 'serialized password matching is exact and non-executable' \
  test_serialized_password_match_is_exact_and_non_executable
run_test 'restart failure clears guard only after a verified stop' \
  test_restart_failure_can_only_clear_guard_after_verified_stop
run_test 'indeterminate service state keeps the install guard active' \
  test_indeterminate_service_state_keeps_guard_active
run_test 'indeterminate autostart state keeps the install guard active' \
  test_indeterminate_autostart_state_keeps_guard_active
run_test 'stop and disable commands use independent state readback' \
  test_stop_and_disable_commands_are_checked_by_independent_readback
run_test 'indeterminate service presence keeps the install guard active' \
  test_indeterminate_service_presence_keeps_guard_active
run_test 'indeterminate listener probe keeps the install guard active' \
  test_indeterminate_listener_probe_keeps_guard_active
run_test 'binary-only initial transaction is authorized for safe replay' \
  test_binary_only_transaction_is_authorized_for_safe_replay
run_test 'result-without-service replay requires the exact saved identity' \
  test_result_without_service_requires_exact_identity
run_test 'TERM reaps the initial installer group before fail-close handling' \
  test_term_reaps_initial_installer_group_before_fail_close
run_test 'nonzero installer keeps the process alive until fail-close settles' \
  test_nonzero_installer_holds_process_until_fail_close_settles
run_test 'help cleanup only calls defined settlement helpers' \
  test_help_exit_cleanup_uses_defined_settlement_helpers
run_test 'early signal handler tolerates settlement helpers not yet defined' \
  test_early_signal_handler_tolerates_helpers_not_yet_defined

finish_tests
