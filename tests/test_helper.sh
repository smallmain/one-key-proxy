#!/usr/bin/env bash

set -uo pipefail

TEST_FILE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_FILE_DIR/.." && pwd)
TEST_COUNT=0
TEST_FAILURES=0

fail() {
  printf '    assertion failed: %s\n' "$*" >&2
  return 1
}

assert_eq() {
  local expected=${1-}
  local actual=${2-}
  local label=${3:-values differ}
  if [[ $expected != "$actual" ]]; then
    printf '    %s\n      expected: %q\n      actual:   %q\n' \
      "$label" "$expected" "$actual" >&2
    return 1
  fi
}

assert_contains() {
  local haystack=${1-}
  local needle=${2-}
  local label=${3:-text does not contain expected value}
  [[ $haystack == *"$needle"* ]] || \
    fail "$label (missing $(printf '%q' "$needle"))"
}

assert_file_exists() {
  [[ -f ${1-} ]] || fail "expected file to exist: ${1-}"
}

assert_file_not_exists() {
  [[ ! -e ${1-} ]] || fail "expected path not to exist: ${1-}"
}

assert_success() {
  "$@" || fail "command unexpectedly failed with status $?: $(printf '%q ' "$@")"
}

assert_failure() {
  local status
  if "$@"; then
    fail "command unexpectedly succeeded: $(printf '%q ' "$@")"
    return 1
  else
    status=$?
  fi
  ((status != 0))
}

assert_status() {
  local expected=$1
  shift
  local status
  if "$@"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$expected" "$status" "unexpected command status"
}

assert_jq() {
  local filter=$1
  local document=$2
  jq -e "$filter" >/dev/null <<<"$document" || \
    fail "jq predicate failed: $filter; document=$document"
}

file_mode() {
  local path=$1
  if stat -f '%Lp' "$path" >/dev/null 2>&1; then
    stat -f '%Lp' "$path"
  else
    stat -c '%a' "$path"
  fi
}

make_test_temp_dir() {
  mktemp -d "${TMPDIR:-/tmp}/one-key-proxy-test.XXXXXX"
}

run_test() {
  local name=$1
  shift
  local status
  TEST_COUNT=$((TEST_COUNT + 1))

  set +e
  (
    set -eEuo pipefail
    "$@"
  )
  status=$?
  set -e

  if ((status == 0)); then
    printf '  ok %d - %s\n' "$TEST_COUNT" "$name"
  else
    printf '  not ok %d - %s\n' "$TEST_COUNT" "$name" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
  fi
}

finish_tests() {
  if ((TEST_FAILURES != 0)); then
    printf '  %d of %d tests failed\n' "$TEST_FAILURES" "$TEST_COUNT" >&2
    return 1
  fi
  printf '  %d tests passed\n' "$TEST_COUNT"
}
