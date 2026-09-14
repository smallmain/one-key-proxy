#!/usr/bin/env bash

set -uo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
failures=0
executed=0

printf 'Syntax checks\n'
while IFS= read -r -d '' script; do
  executed=$((executed + 1))
  if [[ $script == "$PROJECT_ROOT/bootstrap.sh" ]]; then
    if sh -n "$script"; then
      printf '  ok - %s (POSIX sh)\n' "${script#"$PROJECT_ROOT/"}"
    else
      printf '  not ok - %s (POSIX sh)\n' "${script#"$PROJECT_ROOT/"}" >&2
      failures=$((failures + 1))
    fi
  elif bash -n "$script"; then
    printf '  ok - %s\n' "${script#"$PROJECT_ROOT/"}"
  else
    printf '  not ok - %s\n' "${script#"$PROJECT_ROOT/"}" >&2
    failures=$((failures + 1))
  fi
done < <(find "$PROJECT_ROOT" -type f \( -name '*.sh' -o -name 'one-key-proxy' \) \
  -not -path '*/.git/*' -print0 | sort -z)

test_scripts=(
  test_state_config.sh
  test_3xui.sh
  test_integration.sh
  test_subscription_integration.sh
  test_cert.sh
  test_alidns.sh
  test_platform.sh
  test_install_recovery.sh
  test_install_dns.sh
  test_xui_supply.sh
  test_bootstrap.sh
  test_deploy.sh
  test_maintenance_security.sh
  test_repo.sh
)

for test_script in "${test_scripts[@]}"; do
  executed=$((executed + 1))
  printf '\n%s\n' "$test_script"
  if bash "$TEST_DIR/$test_script"; then
    printf 'PASS %s\n' "$test_script"
  else
    printf 'FAIL %s\n' "$test_script" >&2
    failures=$((failures + 1))
  fi
done

executed=$((executed + 1))
printf '\nLocal deployment and SublinkPro tests\n'
if ! python3 -m unittest discover -s "$TEST_DIR" -p 'test_deploy*.py'; then
  failures=$((failures + 1))
fi

printf '\nExecuted %d syntax/test groups; failures: %d\n' "$executed" "$failures"
((failures == 0))
