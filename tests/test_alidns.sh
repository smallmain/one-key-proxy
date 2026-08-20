#!/usr/bin/env bash

set -uo pipefail
# shellcheck source=test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TEST_SANDBOX=$(make_test_temp_dir)
trap 'rm -rf -- "$TEST_SANDBOX"' EXIT

CONFIG_DIR=$TEST_SANDBOX/config
OKP_SECRET_DIR=$CONFIG_DIR/secrets
OKP_STATE_DIR=$CONFIG_DIR/state
OKP_ALIDNS_CREDENTIALS_FILE=$OKP_SECRET_DIR/alidns.credentials
OKP_ALIDNS_RECORDS_FILE=$OKP_STATE_DIR/alidns-records.tsv
OKP_ALIYUN_BIN=$TEST_SANDBOX/bin/aliyun

# shellcheck source=../lib/alidns.sh
source "$PROJECT_ROOT/lib/alidns.sh"

# Tests keep every path inside TEST_SANDBOX and never call the network API.
_okp_alidns_require_root() { return 0; }

reset_alidns_paths() {
  local label=$1
  CONFIG_DIR=$TEST_SANDBOX/$label/config
  OKP_SECRET_DIR=$CONFIG_DIR/secrets
  OKP_STATE_DIR=$CONFIG_DIR/state
  OKP_ALIDNS_CREDENTIALS_FILE=$OKP_SECRET_DIR/alidns.credentials
  OKP_ALIDNS_RECORDS_FILE=$OKP_STATE_DIR/alidns-records.tsv
}

test_credentials_are_atomic_and_private() {
  reset_alidns_paths credentials
  okp_alidns_save_credentials test-access-id test-access-secret
  assert_eq 600 "$(file_mode "$OKP_ALIDNS_CREDENTIALS_FILE")"
  _okp_alidns_load_credentials
  assert_eq test-access-id "$(sed -n '1p' "$OKP_ALIDNS_CREDENTIALS_FILE")"
  assert_eq test-access-secret "$(sed -n '2p' "$OKP_ALIDNS_CREDENTIALS_FILE")"

  okp_alidns_save_credentials replacement-id replacement-secret
  _okp_alidns_load_credentials
  assert_eq replacement-id "$(sed -n '1p' "$OKP_ALIDNS_CREDENTIALS_FILE")"
  assert_eq replacement-secret "$(sed -n '2p' "$OKP_ALIDNS_CREDENTIALS_FILE")"
}

test_credentials_reject_links() {
  local target=$TEST_SANDBOX/link-target hardlink=$TEST_SANDBOX/hardlink
  reset_alidns_paths links
  mkdir -p "$OKP_SECRET_DIR"
  printf '%s\n%s\n' target-id target-secret >"$target"
  chmod 0600 "$target"
  ln -s "$target" "$OKP_ALIDNS_CREDENTIALS_FILE"
  assert_failure _okp_alidns_load_credentials
  assert_failure okp_alidns_save_credentials new-id new-secret
  assert_contains "$(<"$target")" target-secret 'symlink target was modified'

  rm -f "$OKP_ALIDNS_CREDENTIALS_FILE"
  ln "$target" "$hardlink"
  ln "$target" "$OKP_ALIDNS_CREDENTIALS_FILE"
  assert_failure _okp_alidns_load_credentials
  assert_failure okp_alidns_save_credentials new-id new-secret
  rm -f "$hardlink"
}

test_record_ledger_is_private_and_owned_by_identity() {
  reset_alidns_paths ledger
  _okp_alidns_track_record example.com node node.example.com A 12345 198.51.100.44
  assert_eq 600 "$(file_mode "$OKP_ALIDNS_RECORDS_FILE")"
  assert_success _okp_alidns_is_managed_id 12345 node.example.com A
  assert_failure _okp_alidns_is_managed_id 99999 node.example.com A

  _okp_alidns_track_record example.com node node.example.com A 12345 198.51.100.45
  assert_eq 1 "$(awk -F '\t' '$5 == "12345" { count++ } END { print count + 0 }' "$OKP_ALIDNS_RECORDS_FILE")"
  assert_contains "$(<"$OKP_ALIDNS_RECORDS_FILE")" $'198.51.100.45'
}

test_absent_record_type_assertion_succeeds() {
  _okp_alidns_list_address_records() {
    printf '%s\n' $'a-record\tA\tnode\t198.51.100.44'
  }

  assert_success okp_alidns_assert_no_record_type Node.Example.COM. aaaa EXAMPLE.COM.
}

test_single_record_type_assertion_fails() {
  local output
  _okp_alidns_list_address_records() {
    printf '%s\n' $'aaaa-record\tAAAA\tnode\t2001:db8::44'
  }

  if output=$(okp_alidns_assert_no_record_type node.example.com AAAA example.com 2>&1); then
    fail 'single matching AAAA record was accepted'
    return 1
  fi
  assert_contains "$output" '仍存在 1 条 AAAA 记录'
}

test_multiple_record_type_assertion_fails() {
  local output
  _okp_alidns_list_address_records() {
    printf '%s\n' \
      $'aaaa-record-1\tAAAA\tnode\t2001:db8::44' \
      $'aaaa-record-2\tAAAA\tnode\t2001:db8::45'
  }

  if output=$(okp_alidns_assert_no_record_type node.example.com AAAA example.com 2>&1); then
    fail 'multiple matching AAAA records were accepted'
    return 1
  fi
  assert_contains "$output" '仍存在 2 条 AAAA 记录'
}

test_record_type_assertion_propagates_list_error() {
  _okp_alidns_list_address_records() {
    return 42
  }

  assert_failure okp_alidns_assert_no_record_type node.example.com AAAA example.com
}

test_single_record_value_assertion_accepts_exact_unique_value() {
  _okp_alidns_list_address_records() {
    printf '%s\n' \
      $'a-record\tA\tnode\t198.51.100.44' \
      $'aaaa-record\tAAAA\tnode\t2001:db8::44'
  }

  assert_success okp_alidns_assert_single_record_value \
    Node.Example.COM. a 198.51.100.44 EXAMPLE.COM.
  assert_success okp_alidns_assert_single_record_value \
    node.example.com AAAA 2001:DB8::44 example.com
}

test_single_record_value_assertion_rejects_missing_wrong_and_duplicate_values() {
  _okp_alidns_list_address_records() {
    printf '%s\n' $'aaaa-record\tAAAA\tnode\t2001:db8::44'
  }
  assert_failure okp_alidns_assert_single_record_value \
    node.example.com A 198.51.100.44 example.com

  _okp_alidns_list_address_records() {
    printf '%s\n' $'a-record\tA\tnode\t198.51.100.45'
  }
  assert_failure okp_alidns_assert_single_record_value \
    node.example.com A 198.51.100.44 example.com

  _okp_alidns_list_address_records() {
    printf '%s\n' \
      $'a-record-1\tA\tnode\t198.51.100.44' \
      $'a-record-2\tA\tnode\t198.51.100.44'
  }
  assert_failure okp_alidns_assert_single_record_value \
    node.example.com A 198.51.100.44 example.com
}

test_single_record_value_assertion_fails_closed_on_cname_and_list_errors() {
  _okp_alidns_list_address_records() {
    printf '%s\n' \
      $'a-record\tA\tnode\t198.51.100.44' \
      $'cname-record\tCNAME\tnode\tother.example.com'
  }
  assert_failure okp_alidns_assert_single_record_value \
    node.example.com A 198.51.100.44 example.com

  _okp_alidns_list_address_records() { return 42; }
  assert_failure okp_alidns_assert_single_record_value \
    node.example.com A 198.51.100.44 example.com
}

run_test 'AliDNS credentials are atomically stored as 0600' test_credentials_are_atomic_and_private
run_test 'AliDNS credentials reject symbolic and hard links' test_credentials_reject_links
run_test 'AliDNS ownership ledger is private and identity-bound' test_record_ledger_is_private_and_owned_by_identity
run_test 'AliDNS absent record-type assertion succeeds' test_absent_record_type_assertion_succeeds
run_test 'AliDNS single record-type assertion fails' test_single_record_type_assertion_fails
run_test 'AliDNS multiple record-type assertion fails' test_multiple_record_type_assertion_fails
run_test 'AliDNS record-type assertion propagates listing errors' test_record_type_assertion_propagates_list_error
run_test 'AliDNS exact-value assertion accepts one exact record' \
  test_single_record_value_assertion_accepts_exact_unique_value
run_test 'AliDNS exact-value assertion rejects missing, wrong, and duplicate records' \
  test_single_record_value_assertion_rejects_missing_wrong_and_duplicate_values
run_test 'AliDNS exact-value assertion fails closed on CNAME and API errors' \
  test_single_record_value_assertion_fails_closed_on_cname_and_list_errors

finish_tests
