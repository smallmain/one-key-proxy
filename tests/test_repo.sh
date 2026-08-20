#!/usr/bin/env bash

set -uo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_required_repository_files_exist() {
  local path
  local -a required=(
    bootstrap.sh install.sh maintenance.sh one-key-proxy
    README.md README_EN.md DESIGN.md LICENSE VERSION
    lib/common.sh lib/config.sh lib/platform.sh lib/state.sh lib/3xui.sh
    lib/cert.sh lib/alidns.sh lib/fail2ban.sh lib/integration.sh
    tests/run.sh tests/test_alidns.sh .github/workflows/ci.yml
  )

  for path in "${required[@]}"; do
    [[ -f $PROJECT_ROOT/$path ]] || fail "missing required repository file: $path"
  done
}

test_entrypoints_are_executable() {
  local path
  for path in bootstrap.sh install.sh maintenance.sh one-key-proxy tests/run.sh; do
    [[ -x $PROJECT_ROOT/$path ]] || fail "entrypoint is not executable: $path"
  done
  for path in "$PROJECT_ROOT"/tests/test_*.sh; do
    [[ ${path##*/} == test_helper.sh ]] && continue
    [[ -x $path ]] || fail "test entrypoint is not executable: ${path#"$PROJECT_ROOT/"}"
  done
}

test_readme_links_and_install_urls_are_consistent() {
  local chinese english expected_url expected_curl expected_wget
  chinese=$(<"$PROJECT_ROOT/README.md")
  english=$(<"$PROJECT_ROOT/README_EN.md")
  expected_url='https://raw.githubusercontent.com/smallmain/one-key-proxy/main/bootstrap.sh'
  expected_curl="bash <(curl -fsSL ${expected_url})"
  expected_wget="bash <(wget -qO- ${expected_url})"

  assert_contains "$chinese" '[English](README_EN.md)'
  assert_contains "$english" '[中文](README.md)'
  assert_contains "$chinese" "$expected_curl"
  assert_contains "$chinese" "$expected_wget"
  assert_contains "$english" "$expected_curl"
  assert_contains "$english" "$expected_wget"
  assert_failure grep -Rqs 'README\.en\.md' \
    "$PROJECT_ROOT/README.md" "$PROJECT_ROOT/README_EN.md" "$PROJECT_ROOT/DESIGN.md"
}

test_documented_runtime_paths_match_contract() {
  local design
  design=$(<"$PROJECT_ROOT/DESIGN.md")
  assert_contains "$design" '/var/backups/one-key-proxy/'
  assert_contains "$design" '/var/log/one-key-proxy.log'
  assert_contains "$design" '/usr/local/lib/one-key-proxy/'
}

run_test 'required repository files exist' test_required_repository_files_exist
run_test 'installed entrypoints are executable' test_entrypoints_are_executable
run_test 'README links and install URLs are consistent' test_readme_links_and_install_urls_are_consistent
run_test 'documented runtime paths match the implementation contract' test_documented_runtime_paths_match_contract
finish_tests
