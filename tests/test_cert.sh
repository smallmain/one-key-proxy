#!/usr/bin/env bash

set -uo pipefail
# shellcheck source=test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

command -v openssl >/dev/null 2>&1 || {
  printf 'openssl is required for certificate tests\n' >&2
  exit 1
}

TEST_SANDBOX=$(make_test_temp_dir)
trap 'rm -rf -- "$TEST_SANDBOX"' EXIT

CONFIG_DIR=$TEST_SANDBOX/config
CERT_DIR=$CONFIG_DIR/certs
OKP_SECRET_DIR=$CONFIG_DIR/secrets
OKP_ALIDNS_CREDENTIALS_FILE=$OKP_SECRET_DIR/alidns.credentials
OKP_ACME_HOME=$CONFIG_DIR/acme
OKP_ACME_CONFIG_HOME=$OKP_ACME_HOME/config
OKP_ACME_CERT_HOME=$OKP_ACME_HOME/certificates
OKP_ACME_BIN=$OKP_ACME_HOME/acme.sh
OKP_ACME_RENEW_BIN=$TEST_SANDBOX/bin/acme-renew
OKP_XUI_RELOAD_HOOK=$TEST_SANDBOX/bin/reload-x-ui
OKP_ACME_SYSTEMD_SERVICE=$TEST_SANDBOX/systemd/acme.service
OKP_ACME_SYSTEMD_TIMER=$TEST_SANDBOX/systemd/acme.timer
OKP_ACME_OPENRC_DAILY=$TEST_SANDBOX/periodic/acme
OKP_OPERATION_LOCK_FILE=$TEST_SANDBOX/run/operation.lock

# shellcheck source=../lib/cert.sh
source "$PROJECT_ROOT/lib/cert.sh"

# Restrict the bypass to the test process: all certificate outputs still point
# into TEST_SANDBOX and no network-facing ACME operation is called.
_okp_cert_require_root() { return 0; }

test_self_signed_ip_certificate_contract() {
  local state_log=$TEST_SANDBOX/cert-state
  local cert_file=$CERT_DIR/server.crt
  local key_file=$CERT_DIR/server.key
  : >"$state_log"
  state_set() { printf '%s=%s\n' "$1" "$2" >>"$state_log"; }

  okp_cert_create_self_signed_ip 198.51.100.77 "$cert_file" "$key_file"
  assert_file_exists "$cert_file"
  assert_file_exists "$key_file"
  assert_eq 644 "$(file_mode "$cert_file")" 'certificate mode must be 0644'
  assert_eq 600 "$(file_mode "$key_file")" 'private key mode must be 0600'
  openssl x509 -in "$cert_file" -noout -text | grep -Fq 'IP Address:198.51.100.77'
  openssl x509 -in "$cert_file" -noout -text | grep -Eq 'Public-Key: \(2048 bit\)|Public Key Algorithm: rsaEncryption'
  openssl x509 -in "$cert_file" -noout -checkend $((9 * 365 * 86400))
  openssl pkey -in "$key_file" -noout -check
  assert_contains "$(<"$state_log")" 'TLS_MODE=SELF_SIGNED'
  assert_contains "$(<"$state_log")" 'TLS_SUBJECT=198.51.100.77'
}

test_invalid_ip_never_creates_certificate() {
  local cert_file=$CERT_DIR/invalid.crt
  local key_file=$CERT_DIR/invalid.key
  assert_failure okp_cert_create_self_signed_ip 999.51.100.77 "$cert_file" "$key_file"
  assert_file_not_exists "$cert_file"
  assert_file_not_exists "$key_file"
}

test_certificate_validators_are_strict() {
  assert_success _okp_cert_validate_ipv4 203.0.113.1
  assert_failure _okp_cert_validate_ipv4 203.0.113
  assert_failure _okp_cert_validate_ipv4 203.0.113.999
  assert_success _okp_cert_validate_domain node.example.com
  assert_failure _okp_cert_validate_domain '-node.example.com'
  assert_failure _okp_cert_validate_domain localhost
  assert_eq node.example.com "$(_okp_cert_normalize_domain Node.Example.COM.)"
}

test_generated_hook_stays_inside_test_sandbox() {
  okp_cert_install_xui_reload_hook
  assert_file_exists "$OKP_XUI_RELOAD_HOOK"
  assert_eq 755 "$(file_mode "$OKP_XUI_RELOAD_HOOK")"
  local hook
  hook=$(<"$OKP_XUI_RELOAD_HOOK")
  assert_contains "$hook" 'systemctl restart x-ui.service'
  assert_contains "$hook" 'rc-service x-ui restart'
  sh -n "$OKP_XUI_RELOAD_HOOK"
}

test_acme_remove_domain_keeps_active_domain_and_certificate() {
  local fake_acme=$TEST_SANDBOX/fake-acme.sh
  local domain_dir=${fake_acme}.domains
  local cert_file=$CERT_DIR/server.crt key_file=$CERT_DIR/server.key

  mkdir -p "$OKP_ACME_HOME" "$OKP_ACME_CONFIG_HOME" "$OKP_ACME_CERT_HOME" \
    "$domain_dir" "$CERT_DIR"
  cat >"$fake_acme" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >"${0}.audit"
[ "${1-}" = --remove ] || exit 64
shift
domain=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = -d ]; then
    shift
    domain=${1-}
  fi
  shift || true
done
[ -n "$domain" ] || exit 65
rm -f -- "${0}.domains/$domain"
EOF
  chmod 0700 "$fake_acme"
  : >"$domain_dir/old.example.com"
  : >"$domain_dir/new.example.com"
  printf 'active-certificate\n' >"$cert_file"
  printf 'active-private-key\n' >"$key_file"
  OKP_ACME_BIN=$fake_acme

  okp_acme_remove_domain Old.Example.COM.

  assert_file_not_exists "$domain_dir/old.example.com"
  assert_file_exists "$domain_dir/new.example.com"
  assert_eq 'active-certificate' "$(<"$cert_file")"
  assert_eq 'active-private-key' "$(<"$key_file")"
  assert_contains "$(<"${fake_acme}.audit")" '--remove -d old.example.com --ecc'
  assert_contains "$(<"${fake_acme}.audit")" "--home $OKP_ACME_HOME"
  assert_contains "$(<"${fake_acme}.audit")" "--config-home $OKP_ACME_CONFIG_HOME"
  assert_contains "$(<"${fake_acme}.audit")" "--cert-home $OKP_ACME_CERT_HOME"
}

test_acme_renew_wrapper_blocks_pending_domain_transition() {
  local wrapper

  _okp_acme_write_renew_wrapper
  assert_file_exists "$OKP_ACME_RENEW_BIN"
  wrapper=$(<"$OKP_ACME_RENEW_BIN")
  assert_contains "$wrapper" "state_file=$CONFIG_DIR/state.env"
  assert_contains "$wrapper" '[ -f "$state_file" ] && [ ! -L "$state_file" ]'
  assert_contains "$wrapper" 'grep -q "^ACME_PENDING_REMOVE_DOMAIN=" "$state_file"'
  assert_contains "$wrapper" '检测到未完成的域名切换，拒绝自动续签'
  assert_contains "$wrapper" "exec \"\$@\""
  sh -n "$OKP_ACME_RENEW_BIN"
}

run_test 'NAT certificate is RSA-2048, long-lived, and has an IP SAN' test_self_signed_ip_certificate_contract
run_test 'invalid IP cannot produce certificate files' test_invalid_ip_never_creates_certificate
run_test 'certificate IP/domain validators are strict' test_certificate_validators_are_strict
run_test 'x-ui certificate reload hook is valid POSIX shell' test_generated_hook_stays_inside_test_sandbox
run_test 'retiring one ACME domain preserves the active domain and certificate' \
  test_acme_remove_domain_keeps_active_domain_and_certificate
run_test 'automatic renewal is blocked while old-domain cleanup is pending' \
  test_acme_renew_wrapper_blocks_pending_domain_transition

finish_tests
