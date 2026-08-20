#!/usr/bin/env bash

set -uo pipefail
# shellcheck source=test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TEST_SANDBOX=$(make_test_temp_dir)
trap 'rm -rf -- "$TEST_SANDBOX"' EXIT

# shellcheck source=../lib/platform.sh
source "$PROJECT_ROOT/lib/platform.sh"

test_os_family_and_package_manager_detection() {
  local mock_os_id=''
  local mock_os_like=''
  local mock_available_commands=''
  local os_release_fixture=$TEST_SANDBOX/os-release
  local detect_definition

  # Run the production function body against a temporary os-release fixture.
  # The host running these tests may be macOS and need not have /etc/os-release.
  detect_definition=$(declare -f platform_detect_os)
  detect_definition=${detect_definition/#platform_detect_os /platform_detect_os_from_fixture }
  detect_definition=${detect_definition//\/etc\/os-release/$os_release_fixture}
  eval "$detect_definition"

  uname() {
    [[ ${1-} == -s ]] || return 1
    printf 'Linux\n'
  }
  command() {
    if [[ ${1-} == -v && $# -eq 2 ]]; then
      [[ " $mock_available_commands " == *" ${2-} "* ]]
      return
    fi
    builtin command "$@"
  }

  local row expected_family expected_manager
  local -a cases=(
    'debian||debian|apt-get|apt-get'
    'ubuntu||debian|apt-get|apt-get'
    'rocky||rhel|dnf|dnf'
    'centos||rhel|yum|yum'
    'arch||arch|pacman|pacman'
    'opensuse-leap||suse|zypper|zypper'
    'alpine||alpine|apk|apk'
    'linuxmint|ubuntu debian|debian|apt-get|apt-get'
  )

  for row in "${cases[@]}"; do
    IFS='|' read -r mock_os_id mock_os_like expected_family \
      expected_manager mock_available_commands <<<"$row"
    {
      printf 'ID=%q\n' "$mock_os_id"
      printf 'ID_LIKE=%q\n' "$mock_os_like"
      printf 'NAME=%q\n' "Mock $mock_os_id"
      printf 'VERSION_ID=1\n'
      printf 'PRETTY_NAME=%q\n' "Mock $mock_os_id 1"
    } >"$os_release_fixture"
    PLATFORM_OS_ID=''
    PLATFORM_OS_LIKE=''
    PLATFORM_FAMILY=''
    PLATFORM_PACKAGE_MANAGER=''

    platform_detect_os_from_fixture
    assert_eq "$mock_os_id" "$PLATFORM_OS_ID" "OS ID for $mock_os_id"
    assert_eq "$mock_os_like" "$PLATFORM_OS_LIKE" "OS ID_LIKE for $mock_os_id"
    assert_eq "$expected_family" "$PLATFORM_FAMILY" "family for $mock_os_id"
    assert_eq "$expected_manager" "$PLATFORM_PACKAGE_MANAGER" \
      "package manager for $mock_os_id"
  done
}

test_package_install_commands_for_supported_families() {
  local package_audit=$TEST_SANDBOX/package-audit
  : >"$package_audit"

  platform_require_root() { return 0; }
  apt-get() {
    printf 'apt-get|%s|%s\n' "${DEBIAN_FRONTEND-}" "$*" >>"$package_audit"
  }
  apk() { printf 'apk|%s\n' "$*" >>"$package_audit"; }
  dnf() { printf 'dnf|%s\n' "$*" >>"$package_audit"; }
  yum() { printf 'yum|%s\n' "$*" >>"$package_audit"; }
  pacman() { printf 'pacman|%s\n' "$*" >>"$package_audit"; }
  zypper() { printf 'zypper|%s\n' "$*" >>"$package_audit"; }

  _PLATFORM_APT_UPDATED=0
  PLATFORM_FAMILY=debian
  PLATFORM_PACKAGE_MANAGER=apt-get
  platform_install_packages curl jq
  platform_install_packages tar

  PLATFORM_FAMILY=alpine
  PLATFORM_PACKAGE_MANAGER=apk
  platform_install_packages curl jq

  PLATFORM_FAMILY=rhel
  PLATFORM_PACKAGE_MANAGER=dnf
  platform_install_packages curl jq
  PLATFORM_PACKAGE_MANAGER=yum
  platform_install_packages tar

  PLATFORM_FAMILY=arch
  PLATFORM_PACKAGE_MANAGER=pacman
  platform_install_packages curl jq

  PLATFORM_FAMILY=suse
  PLATFORM_PACKAGE_MANAGER=zypper
  platform_install_packages curl jq

  local audit
  audit=$(<"$package_audit")
  assert_eq 1 "$(grep -c '^apt-get||update$' "$package_audit")" \
    'apt-get update should run only once'
  assert_contains "$audit" \
    'apt-get|noninteractive|install -y --no-install-recommends curl jq'
  assert_contains "$audit" \
    'apt-get|noninteractive|install -y --no-install-recommends tar'
  assert_contains "$audit" 'apk|add --no-cache curl jq'
  assert_contains "$audit" 'dnf|-y install curl jq'
  assert_contains "$audit" 'yum|-y install tar'
  assert_contains "$audit" 'pacman|-Syu --noconfirm --needed curl jq'
  assert_contains "$audit" \
    'zypper|--non-interactive install --no-recommends curl jq'
}

test_systemd_service_operations() {
  local systemd_audit=$TEST_SANDBOX/systemd-audit
  : >"$systemd_audit"

  PLATFORM_INIT=systemd
  platform_require_root() { return 0; }
  systemctl() {
    printf 'systemctl %s\n' "$*" >>"$systemd_audit"
    [[ ${1-} != show ]] || printf 'loaded\n'
  }

  platform_service_exists x-ui.service
  platform_service_start x-ui.service
  platform_service_stop x-ui.service
  platform_service_restart x-ui.service
  platform_service_status x-ui.service
  platform_service_is_active x-ui.service
  platform_service_enable x-ui.service
  platform_service_disable x-ui.service

  local audit
  audit=$(<"$systemd_audit")
  assert_contains "$audit" 'systemctl show --property=LoadState --value x-ui.service'
  assert_contains "$audit" 'systemctl start x-ui.service'
  assert_contains "$audit" 'systemctl stop x-ui.service'
  assert_contains "$audit" 'systemctl restart x-ui.service'
  assert_contains "$audit" 'systemctl status --no-pager x-ui.service'
  assert_contains "$audit" 'systemctl is-active --quiet x-ui.service'
  assert_contains "$audit" 'systemctl enable x-ui.service'
  assert_contains "$audit" 'systemctl disable x-ui.service'
}

test_service_probe_distinguishes_absent_inactive_and_indeterminate() {
  local mock_show_status=0 mock_load_state=loaded mock_active_status=3
  PLATFORM_INIT=systemd
  systemctl() {
    case ${1-} in
      show)
        ((mock_show_status == 0)) || return "$mock_show_status"
        printf '%s\n' "$mock_load_state"
        ;;
      is-active) return "$mock_active_status" ;;
      *) return 0 ;;
    esac
  }

  assert_success platform_service_exists x-ui
  mock_load_state=not-found
  assert_status 1 platform_service_exists x-ui
  mock_show_status=1
  assert_status 2 platform_service_exists x-ui

  mock_show_status=0
  mock_load_state=loaded
  mock_active_status=3
  assert_success platform_service_is_inactive x-ui
  mock_active_status=0
  assert_status 1 platform_service_is_inactive x-ui
  mock_active_status=2
  assert_status 2 platform_service_is_inactive x-ui
  mock_active_status=4
  assert_status 2 platform_service_is_inactive x-ui
}

test_openrc_service_operations_and_idempotent_runlevel() {
  local openrc_audit=$TEST_SANDBOX/openrc-audit
  local mock_openrc_enabled=''
  : >"$openrc_audit"

  PLATFORM_INIT=openrc
  platform_require_root() { return 0; }
  rc-service() { printf 'rc-service %s\n' "$*" >>"$openrc_audit"; }
  rc-update() {
    case ${1-} in
      show)
        [[ -z $mock_openrc_enabled ]] || \
          printf '%s | default\n' "$mock_openrc_enabled"
        ;;
      add)
        printf 'rc-update %s\n' "$*" >>"$openrc_audit"
        mock_openrc_enabled=${2-}
        ;;
      del)
        printf 'rc-update %s\n' "$*" >>"$openrc_audit"
        mock_openrc_enabled=''
        ;;
      *) return 2 ;;
    esac
  }

  platform_service_start x-ui.service
  platform_service_stop x-ui.service
  platform_service_restart x-ui.service
  platform_service_status x-ui.service
  platform_service_is_active x-ui.service

  platform_service_enable x-ui.service
  platform_service_enable x-ui.service
  platform_service_disable x-ui.service
  platform_service_disable x-ui.service

  local audit
  audit=$(<"$openrc_audit")
  assert_contains "$audit" 'rc-service x-ui start'
  assert_contains "$audit" 'rc-service x-ui stop'
  assert_contains "$audit" 'rc-service x-ui restart'
  assert_contains "$audit" 'rc-service x-ui status'
  assert_eq 1 "$(grep -c '^rc-update add x-ui default$' "$openrc_audit")" \
    'OpenRC enable should be idempotent'
  assert_eq 1 "$(grep -c '^rc-update del x-ui default$' "$openrc_audit")" \
    'OpenRC disable should be idempotent'
}

test_port_validation_boundaries() {
  assert_success platform_validate_port 1
  assert_success platform_validate_port 443
  assert_success platform_validate_port 65535
  assert_failure platform_validate_port 0
  assert_failure platform_validate_port 65536
  assert_failure platform_validate_port '443/tcp'
  assert_failure platform_validate_port '-1'
}

test_port_listener_matches_exact_tcp_and_udp_ports() {
  ss() {
    case " $* " in
      *' -ltn '*)
        printf '%s\n' \
          'LISTEN 0 128 127.0.0.1:443 0.0.0.0:*' \
          'LISTEN 0 128 [::]:2096 [::]:*' \
          'LISTEN 0 128 0.0.0.0:1443 0.0.0.0:*'
        ;;
      *' -lun '*) printf '%s\n' 'UNCONN 0 0 0.0.0.0:5353 0.0.0.0:*' ;;
      *) return 2 ;;
    esac
  }
  assert_success platform_port_is_listening 443 tcp
  assert_success platform_port_is_listening 2096 tcp
  assert_success platform_port_is_listening 5353 udp
  assert_failure platform_port_is_listening 44 tcp
  assert_failure platform_port_is_listening 143 tcp
  assert_success platform_port_is_available 56666 tcp
  assert_failure platform_port_is_available 443 tcp
}

test_listener_probe_failure_is_indeterminate() {
  ss() { return 42; }
  assert_status 2 platform_port_is_listening 443 tcp
  assert_status 2 platform_port_is_available 443 tcp
}

install_firewall_stubs() {
  FIREWALL_AUDIT=$TEST_SANDBOX/firewall-audit
  : >"$FIREWALL_AUDIT"
  MOCK_UFW_ACTIVE=false
  MOCK_UFW_RULES=''
  MOCK_FIREWALLD_ACTIVE=false
  MOCK_FIREWALLD_DEFAULT_ZONE=public
  MOCK_FIREWALLD_ACTIVE_ZONES=public
  MOCK_FIREWALLD_RULES=''

  platform_require_root() { return 0; }
  ufw() {
    if [[ ${1-} == status ]]; then
      if [[ $MOCK_UFW_ACTIVE == true ]]; then
        printf 'Status: active\n'
      else
        printf 'Status: inactive\n'
      fi
      [[ -z $MOCK_UFW_RULES ]] || printf '%s\n' "$MOCK_UFW_RULES"
      return 0
    fi
    printf 'ufw %s\n' "$*" >>"$FIREWALL_AUDIT"
  }
  firewall-cmd() {
    local query_port='' argument
    case ${1-} in
      --state)
        [[ $MOCK_FIREWALLD_ACTIVE == true ]] && printf 'running\n' || printf 'not running\n'
        ;;
      --get-active-zones)
        local zone
        for zone in $MOCK_FIREWALLD_ACTIVE_ZONES; do
          printf '%s\n  interfaces: eth0\n' "$zone"
        done
        ;;
      --get-default-zone) printf '%s\n' "$MOCK_FIREWALLD_DEFAULT_ZONE" ;;
      *)
        for argument in "$@"; do
          if [[ $argument == --query-port=* ]]; then
            query_port=${argument#*=}
          fi
        done
        if [[ -n $query_port ]]; then
          [[ " $MOCK_FIREWALLD_RULES " == *" $query_port "* ]]
        else
          printf 'firewall-cmd %s\n' "$*" >>"$FIREWALL_AUDIT"
        fi
        ;;
    esac
  }
}

test_ufw_detection_and_idempotent_allow() {
  install_firewall_stubs
  MOCK_UFW_ACTIVE=true
  MOCK_UFW_RULES=$'2053/tcp ALLOW Anywhere\n443/tcp ALLOW Anywhere'
  platform_detect_firewall
  assert_eq ufw "$PLATFORM_FIREWALL"

  platform_firewall_allow_tcp 2053
  assert_eq '' "$(<"$FIREWALL_AUDIT")" 'existing UFW rule must not be changed'
  assert_eq 0 "$PLATFORM_FIREWALL_RULE_CHANGED"

  platform_firewall_allow_tcp 2096
  assert_contains "$(<"$FIREWALL_AUDIT")" 'ufw allow 2096/tcp'
  assert_eq 1 "$PLATFORM_FIREWALL_RULE_CHANGED"
}

test_firewalld_uses_active_default_zone() {
  install_firewall_stubs
  MOCK_FIREWALLD_ACTIVE=true
  MOCK_FIREWALLD_DEFAULT_ZONE=public
  MOCK_FIREWALLD_ACTIVE_ZONES=$'public\ninternal'
  platform_detect_firewall
  assert_eq firewalld "$PLATFORM_FIREWALL"
  assert_eq public "$PLATFORM_FIREWALL_ZONE"

  platform_firewall_allow_tcp 8443
  local audit
  audit=$(<"$FIREWALL_AUDIT")
  assert_contains "$audit" '--permanent --zone=public --add-port=8443/tcp'
  assert_contains "$audit" '--zone=public --add-port=8443/tcp'
}

test_ambiguous_firewalls_are_rejected() {
  install_firewall_stubs
  MOCK_UFW_ACTIVE=true
  MOCK_FIREWALLD_ACTIVE=true
  assert_status 2 platform_detect_firewall
  assert_eq ambiguous "$PLATFORM_FIREWALL"

  MOCK_UFW_ACTIVE=false
  MOCK_FIREWALLD_ACTIVE=true
  MOCK_FIREWALLD_DEFAULT_ZONE=drop
  MOCK_FIREWALLD_ACTIVE_ZONES=$'public\ninternal'
  assert_status 2 platform_detect_firewall
  assert_eq ambiguous "$PLATFORM_FIREWALL"
}

run_test 'OS families select their native package managers' test_os_family_and_package_manager_detection
run_test 'package installs use family-specific commands' test_package_install_commands_for_supported_families
run_test 'systemd service operations use systemctl' test_systemd_service_operations
run_test 'service probes distinguish absent, inactive, and indeterminate states' \
  test_service_probe_distinguishes_absent_inactive_and_indeterminate
run_test 'OpenRC service operations and runlevel changes are idempotent' test_openrc_service_operations_and_idempotent_runlevel
run_test 'port validation enforces 1-65535' test_port_validation_boundaries
run_test 'listener detection matches exact TCP/UDP ports' test_port_listener_matches_exact_tcp_and_udp_ports
run_test 'listener command failures remain indeterminate' \
  test_listener_probe_failure_is_indeterminate
run_test 'UFW rules are detected and added idempotently' test_ufw_detection_and_idempotent_allow
run_test 'firewalld uses the active default zone' test_firewalld_uses_active_default_zone
run_test 'ambiguous firewall ownership is rejected' test_ambiguous_firewalls_are_rejected

finish_tests
