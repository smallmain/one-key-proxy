#!/usr/bin/env bash

set -uo pipefail
# shellcheck source=test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TEST_SANDBOX=$(make_test_temp_dir)
trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
BOOTSTRAP_LIBRARY=$TEST_SANDBOX/bootstrap-library.sh

# bootstrap.sh deliberately executes main. Strip only its final invocation so
# the POSIX functions can be exercised with local command stubs.
sed '$d' "$PROJECT_ROOT/bootstrap.sh" >"$BOOTSTRAP_LIBRARY"
# shellcheck source=/dev/null
source "$BOOTSTRAP_LIBRARY"
trap 'rm -rf -- "$TEST_SANDBOX"' EXIT

test_source_coordinates_are_strict() {
  REPOSITORY=smallmain/one-key-proxy
  REF=main
  bootstrap_validate_source

  assert_failure bash -c '
    source "$1"
    REPOSITORY="owner/repo;touch-pwned"
    REF=main
    bootstrap_validate_source
  ' _ "$BOOTSTRAP_LIBRARY"
  assert_failure bash -c '
    source "$1"
    REPOSITORY=owner/repo
    REF="../../main"
    bootstrap_validate_source
  ' _ "$BOOTSTRAP_LIBRARY"
  assert_file_not_exists "$TEST_SANDBOX/touch-pwned"
}

test_fetch_enforces_https_options_without_network() {
  local destination=$TEST_SANDBOX/download
  local audit=$destination.audit
  local fake_bin=$TEST_SANDBOX/fetch-bin
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/bin/sh' \
    'output=' \
    'args=$*' \
    'while [ "$#" -gt 0 ]; do' \
    '  if [ "$1" = --output ]; then output=$2; shift 2; else shift; fi' \
    'done' \
    'printf "%s\n" "$args" >"$output.audit"' \
    'printf "CURL_CA_BUNDLE=%s\n" "${CURL_CA_BUNDLE-unset}" >>"$output.audit"' \
    'printf "HTTPS_PROXY=%s\n" "${HTTPS_PROXY-unset}" >>"$output.audit"' \
    'printf "downloaded\n" >"$output"' >"$fake_bin/curl"
  chmod 0755 "$fake_bin/curl"
  PATH="$fake_bin:$PATH"
  CURL_CA_BUNDLE=/untrusted/ca.pem
  HTTPS_PROXY=https://untrusted.invalid
  export CURL_CA_BUNDLE HTTPS_PROXY
  bootstrap_fetch https://example.invalid/archive.tar.gz "$destination"
  assert_eq downloaded "$(<"$destination")"
  local args
  args=$(<"$audit")
  assert_contains "$args" '--proto =https'
  assert_contains "$args" '--tlsv1.2'
  assert_contains "$args" '--retry 3'
  assert_contains "$args" 'CURL_CA_BUNDLE=unset'
  assert_contains "$args" 'HTTPS_PROXY=unset'
}

test_commit_resolution_pins_a_full_sha() {
  TEMP_DIR=$TEST_SANDBOX/commit
  mkdir -p "$TEMP_DIR"
  REPOSITORY=smallmain/one-key-proxy
  REF=main
  local audit=$TEST_SANDBOX/commit-url
  bootstrap_fetch() {
    printf '%s\n' "$1" >"$audit"
    printf '%s\n' '{' '  "sha": "0123456789abcdef0123456789abcdef01234567",' '  "other": "ignored"' '}' >"$2"
  }
  bootstrap_resolve_commit
  assert_eq 0123456789abcdef0123456789abcdef01234567 "$RESOLVED_COMMIT"
  assert_eq 'https://api.github.com/repos/smallmain/one-key-proxy/commits/main' "$(<"$audit")"
}

test_archive_extraction_is_secured_before_use() {
  TEMP_DIR=$TEST_SANDBOX/bootstrap-extract
  mkdir -p "$TEMP_DIR"
  REPOSITORY=smallmain/one-key-proxy
  RESOLVED_COMMIT=0123456789abcdef0123456789abcdef01234567
  local expected_dir=$TEMP_DIR/one-key-proxy-$RESOLVED_COMMIT
  local audit=$TEST_SANDBOX/archive-audit

  bootstrap_secure_temp_dir() {
    printf '%s\n' secure-temp >>"$audit"
  }
  bootstrap_fetch() {
    printf 'archive\n' >"$2"
  }
  tar() {
    printf 'tar %s\n' "$*" >>"$audit"
    case " $* " in
      *' -tzf '*)
        printf '%s\n' \
          "one-key-proxy-$RESOLVED_COMMIT/" \
          "one-key-proxy-$RESOLVED_COMMIT/install.sh"
        ;;
      *' -tvzf '*)
        printf '%s\n' \
          'drwxr-xr-x root/root 0 2026-01-01 00:00 one-key-proxy/' \
          '-rwxr-xr-x root/root 0 2026-01-01 00:00 one-key-proxy/install.sh'
        ;;
      *' --no-same-owner -xzf '*)
        mkdir -p "$expected_dir"
        printf '#!/bin/sh\n' >"$expected_dir/install.sh"
        ;;
      *) return 1 ;;
    esac
  }
  chown() {
    printf 'chown %s\n' "$*" >>"$audit"
  }
  chmod() {
    printf 'chmod %s\n' "$*" >>"$audit"
  }
  bootstrap_verify_secure_tree() {
    printf 'verify %s\n' "$1" >>"$audit"
  }

  bootstrap_download_project

  local events
  events=$(<"$audit")
  assert_contains "$events" "tar --no-same-owner -xzf $TEMP_DIR/project.tar.gz -C $TEMP_DIR"
  assert_contains "$events" "chown -R 0:0 $expected_dir"
  assert_contains "$events" "chmod -R go-w $expected_dir"
  assert_contains "$events" "verify $TEMP_DIR"

  local extraction_line chown_line chmod_line verify_line
  extraction_line=$(grep -n '^tar --no-same-owner ' "$audit" | cut -d: -f1)
  chown_line=$(grep -n '^chown -R ' "$audit" | cut -d: -f1)
  chmod_line=$(grep -n '^chmod -R ' "$audit" | cut -d: -f1)
  verify_line=$(grep -n '^verify ' "$audit" | cut -d: -f1)
  ((extraction_line < chown_line))
  ((chown_line < chmod_line))
  ((chmod_line < verify_line))
}

test_security_guards_cover_parent_and_execution() {
  local script
  script=$(<"$PROJECT_ROOT/bootstrap.sh")
  assert_contains "$script" 'chown 0:0 "$TEMP_DIR"'
  assert_contains "$script" 'chmod 0700 "$TEMP_DIR"'
  assert_contains "$script" '[ -d /tmp ] && [ ! -L /tmp ]'
  assert_contains "$script" '! -perm -1000'
  assert_contains "$script" 'bootstrap_verify_secure_tree "$TEMP_DIR"'
  assert_contains "$script" 'find "$secure_tree" -xdev -type l'
  assert_contains "$script" '! -user 0 -o ! -group 0'
  assert_contains "$script" '-perm -020 -o -perm -002'
  assert_contains "$script" 'env -i PATH="$PATH" HOME=/root'
  assert_contains "$script" 'ONE_KEY_PROXY_SOURCE_COMMIT="$RESOLVED_COMMIT"'
}

test_bootstrap_entrypoint_contract_is_present() {
  local script
  script=$(<"$PROJECT_ROOT/bootstrap.sh")
  assert_contains "$script" 'bootstrap_require_root'
  assert_contains "$script" 'bootstrap_require_tty'
  assert_contains "$script" 'bootstrap_require_service_manager'
  assert_contains "$script" 'bash "$PROJECT_DIR/install.sh" "$@" </dev/tty >/dev/tty 2>&1'
  assert_contains "$script" 'main "$@"'
}

test_local_project_bootstrap_uses_uploaded_sources() {
  local project=$TEST_SANDBOX/uploaded-project defaults=$TEST_SANDBOX/defaults.env
  mkdir -p "$project"
  printf 'uploaded-source\n' >"$project/install.sh"
  : >"$defaults"
  bootstrap_require_root() { :; }
  bootstrap_require_tty() { :; }
  bootstrap_require_linux_arch() { :; }
  bootstrap_detect_family() { :; }
  bootstrap_require_service_manager() { :; }
  bootstrap_install_prerequisites() { :; }
  bootstrap_secure_temp_dir() { :; }
  bootstrap_verify_secure_tree() { [[ -d $1 ]]; }
  bootstrap_resolve_commit() { fail 'local deployment must not resolve a remote commit'; }
  bootstrap_download_project() { fail 'local deployment must not download project code'; }
  bootstrap_run_installer() {
    assert_eq uploaded-source "$(<"$PROJECT_DIR/install.sh")"
    assert_eq local "$RESOLVED_COMMIT"
    assert_eq "$defaults" "$DEFAULTS_FILE"
    [[ $PROJECT_DIR == "$TEMP_DIR"/* && $PROJECT_DIR != "$project" ]]
  }
  main --local-project "$project" --defaults-file "$defaults"
  bootstrap_cleanup
}

test_bootstrap_rejects_malformed_local_arguments() {
  assert_failure bash -c 'source "$1"; bootstrap_parse_args --defaults-file relative' _ "$BOOTSTRAP_LIBRARY"
  assert_failure bash -c 'source "$1"; bootstrap_parse_args --local-project' _ "$BOOTSTRAP_LIBRARY"
  assert_failure bash -c 'source "$1"; bootstrap_parse_args --unknown' _ "$BOOTSTRAP_LIBRARY"
}

run_test 'bootstrap repository and ref inputs reject injection' test_source_coordinates_are_strict
run_test 'bootstrap fetch forces HTTPS and TLS 1.2' test_fetch_enforces_https_options_without_network
run_test 'bootstrap resolves and pins a full Git commit SHA' test_commit_resolution_pins_a_full_sha
run_test 'bootstrap secures archive extraction before verification' test_archive_extraction_is_secured_before_use
run_test 'bootstrap guards the extraction parent and execution tree' test_security_guards_cover_parent_and_execution
run_test 'bootstrap retains root, TTY, init, and direct-run guards' test_bootstrap_entrypoint_contract_is_present
run_test 'local bootstrap uses uploaded sources and explicit defaults' test_local_project_bootstrap_uses_uploaded_sources
run_test 'bootstrap rejects malformed local source arguments' test_bootstrap_rejects_malformed_local_arguments

finish_tests
