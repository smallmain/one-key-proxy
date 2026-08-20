#!/usr/bin/env bash

set -uo pipefail
# shellcheck source=test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

load_install_functions() {
  # shellcheck source=../install.sh
  source "$PROJECT_ROOT/install.sh"
  trap - EXIT HUP INT TERM
  INSTALL_TEMP_PATHS=()
  log_error() { :; }
  log_warn() { :; }
}

set_public_dns_values() {
  MODE=public
  FQDN=node.example.com
  PUBLIC_IPV4=198.51.100.44
  PUBLIC_IPV6=2001:db8::44
  ENABLE_IPV6=true
  DNS_AUDIT=''
  DNS_SINGLE_STATUS=0
  DNS_ABSENT_STATUS=0
  state_get() {
    case $1 in
      ALIDNS_ZONE) printf '%s' example.com ;;
      TLS_MODE) printf '%s' ACME ;;
      *) return 1 ;;
    esac
  }
  okp_alidns_assert_single_record_value() {
    DNS_AUDIT+="single:$2:$3:$4;"
    return "$DNS_SINGLE_STATUS"
  }
  okp_alidns_assert_no_record_type() {
    DNS_AUDIT+="absent:$2:$3;"
    return "$DNS_ABSENT_STATUS"
  }
}

test_public_dns_postcondition_checks_unique_a_and_enabled_aaaa() {
  load_install_functions
  set_public_dns_values

  assert_success public_dns_postcondition_ok
  assert_eq \
    'single:A:198.51.100.44:example.com;single:AAAA:2001:db8::44:example.com;' \
    "$DNS_AUDIT"
}

test_public_dns_postcondition_requires_no_aaaa_when_disabled() {
  load_install_functions
  set_public_dns_values
  ENABLE_IPV6=false

  assert_success public_dns_postcondition_ok
  assert_eq \
    'single:A:198.51.100.44:example.com;absent:AAAA:example.com;' \
    "$DNS_AUDIT"
}

test_public_dns_postcondition_fails_closed() {
  load_install_functions
  set_public_dns_values

  DNS_SINGLE_STATUS=1
  assert_failure public_dns_postcondition_ok

  DNS_SINGLE_STATUS=0
  DNS_ABSENT_STATUS=1
  ENABLE_IPV6=false
  assert_failure public_dns_postcondition_ok

  DNS_ABSENT_STATUS=0
  ENABLE_IPV6=unexpected
  assert_failure public_dns_postcondition_ok

  state_get() { return 1; }
  ENABLE_IPV6=true
  assert_failure public_dns_postcondition_ok
}

test_nat_certificate_postcondition_does_not_call_alidns() {
  local sandbox
  sandbox=$(make_test_temp_dir)
  trap 'rm -rf -- "$sandbox"' RETURN
  load_install_functions
  CERT_DIR=$sandbox/certs
  mkdir -p "$CERT_DIR"
  : >"$CERT_DIR/server.crt"
  : >"$CERT_DIR/server.key"
  MODE=nat
  PUBLIC_IPV4=198.51.100.44
  DNS_AUDIT=''
  state_get() {
    [[ $1 == TLS_MODE ]] && printf '%s' SELF_SIGNED
  }
  openssl() { return 0; }
  _okp_cert_verify_ip_san() { return 0; }
  okp_alidns_assert_single_record_value() { DNS_AUDIT+='single;'; return 1; }
  okp_alidns_assert_no_record_type() { DNS_AUDIT+='absent;'; return 1; }

  assert_success certificate_postcondition_ok
  assert_eq '' "$DNS_AUDIT"
}

test_public_certificate_postcondition_requires_dns() {
  local sandbox
  sandbox=$(make_test_temp_dir)
  trap 'rm -rf -- "$sandbox"' RETURN
  load_install_functions
  set_public_dns_values
  CERT_DIR=$sandbox/certs
  mkdir -p "$CERT_DIR"
  : >"$CERT_DIR/server.crt"
  : >"$CERT_DIR/server.key"
  openssl() { return 0; }
  _okp_cert_verify_dns_san() { return 0; }

  assert_success certificate_postcondition_ok
  DNS_SINGLE_STATUS=1
  assert_failure certificate_postcondition_ok
}

test_final_verification_requires_public_dns_before_success() {
  load_install_functions
  set_public_dns_values
  DNS_SINGLE_STATUS=1
  SERVICE_PROBED=false
  platform_service_is_active() { SERVICE_PROBED=true; return 0; }

  assert_failure stage_verify_and_result
  assert_eq false "$SERVICE_PROBED" \
    'final verification continued after the DNS postcondition failed'
}

run_test 'public DNS postcondition checks one exact A and enabled AAAA' \
  test_public_dns_postcondition_checks_unique_a_and_enabled_aaaa
run_test 'public DNS postcondition requires AAAA absence when IPv6 is disabled' \
  test_public_dns_postcondition_requires_no_aaaa_when_disabled
run_test 'public DNS postcondition fails closed on read errors and invalid state' \
  test_public_dns_postcondition_fails_closed
run_test 'NAT certificate postcondition never calls AliDNS' \
  test_nat_certificate_postcondition_does_not_call_alidns
run_test 'public certificate postcondition requires the DNS postcondition' \
  test_public_certificate_postcondition_requires_dns
run_test 'final verification fails before success when public DNS is invalid' \
  test_final_verification_requires_public_dns_before_success

finish_tests
