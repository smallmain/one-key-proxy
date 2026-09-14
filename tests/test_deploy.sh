#!/usr/bin/env bash

set -uo pipefail
# shellcheck source=test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TEST_SANDBOX=$(make_test_temp_dir)
trap 'rm -rf -- "$TEST_SANDBOX"' EXIT
OKP_TEST_MODE=true
# shellcheck source=../lib/common.sh
source "$PROJECT_ROOT/lib/common.sh"
# shellcheck source=../lib/state.sh
source "$PROJECT_ROOT/lib/state.sh"
# shellcheck source=../lib/config.sh
source "$PROJECT_ROOT/lib/config.sh"

test_defaults_literal_round_trip() {
  local file=$TEST_SANDBOX/defaults.env
  local secret='literal $HOME $(touch should-not-exist) `id` = # secret'
  printf 'OKP_ALI_ACCESS_KEY_SECRET=%s\nOKP_ACME_EMAIL=\n' "$(_state_encode "$secret")" >"$file"
  chmod 600 "$file"
  config_load_defaults_file "$file"
  assert_eq "$secret" "$OKP_ALI_ACCESS_KEY_SECRET"
  assert_eq '' "$OKP_ACME_EMAIL"
  assert_eq '[REDACTED]' "$(redact_sensitive "$secret")"
}

test_defaults_reject_unsafe_input_atomically() {
  local file=$TEST_SANDBOX/bad.env invalid
  for invalid in \
    'OKP_TEST_MODE=dHJ1ZQ==' 'PATH=L3RtcA==' 'SUBLINKPRO_API_KEY=c2VjcmV0' \
    'OKP_MODE=%%%' 'OKP_MODE=YQAK' 'OKP_MODE=YQAA' 'not-an-assignment'; do
    printf 'OKP_FQDN=%s\n%s\n' "$(_state_encode replacement.example.com)" "$invalid" >"$file"
    chmod 600 "$file"
    OKP_FQDN=original.example.com
    assert_failure config_load_defaults_file "$file"
    assert_eq original.example.com "$OKP_FQDN"
  done
  printf 'OKP_MODE=bmF0\nOKP_MODE=cHVibGlj\n' >"$file"
  assert_failure config_load_defaults_file "$file"
  printf 'OKP_MODE=bmF0\n' >"$file"
  chmod 644 "$file"
  assert_failure config_load_defaults_file "$file"
  chmod 600 "$file"
  ln -s "$file" "$file.link"
  assert_failure config_load_defaults_file "$file.link"
}

run_test 'remote defaults remain literal and are registered for redaction' test_defaults_literal_round_trip
run_test 'remote defaults reject unsupported keys, malformed values and unsafe files' test_defaults_reject_unsafe_input_atomically
finish_tests
