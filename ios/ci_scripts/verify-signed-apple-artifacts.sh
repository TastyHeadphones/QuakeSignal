#!/bin/bash -p
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH DEVELOPER_DIR SDKROOT TOOLCHAINS

usage() {
  cat >&2 <<'USAGE'
Usage: verify-signed-apple-artifacts.sh \
  --platform <ios|tvos|visionos> \
  --archive <path.xcarchive> \
  --exported <path.ipa|path.zip|export-directory|path.app|path.xcarchive> \
  --build-number <CFBundleVersion> \
  --marketing-version <CFBundleShortVersionString> \
  --team-id <Apple-Team-ID> \
  --archive-signing <strict-distribution|structure-only> \
  [--host-profile-name <exact-name>] \
  [--watch-profile-name <exact-name>]
USAGE
  exit 64
}

platform=""
archive=""
exported=""
build_number=""
marketing_version=""
team_id=""
archive_signing=""
host_profile_name=""
watch_profile_name=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --platform) [ "$#" -ge 2 ] || usage; platform="$2"; shift 2 ;;
    --archive) [ "$#" -ge 2 ] || usage; archive="$2"; shift 2 ;;
    --exported) [ "$#" -ge 2 ] || usage; exported="$2"; shift 2 ;;
    --build-number) [ "$#" -ge 2 ] || usage; build_number="$2"; shift 2 ;;
    --marketing-version) [ "$#" -ge 2 ] || usage; marketing_version="$2"; shift 2 ;;
    --team-id) [ "$#" -ge 2 ] || usage; team_id="$2"; shift 2 ;;
    --archive-signing) [ "$#" -ge 2 ] || usage; archive_signing="$2"; shift 2 ;;
    --host-profile-name) [ "$#" -ge 2 ] || usage; host_profile_name="$2"; shift 2 ;;
    --watch-profile-name) [ "$#" -ge 2 ] || usage; watch_profile_name="$2"; shift 2 ;;
    *) usage ;;
  esac
done

for value in "$platform" "$archive" "$exported" "$build_number" "$marketing_version" "$team_id" "$archive_signing"; do
  [ -n "$value" ] || usage
done
case "$platform" in ios|tvos|visionos) ;; *) usage ;; esac
case "$archive_signing" in strict-distribution|structure-only) ;; *) usage ;; esac
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$marketing_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || usage
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || usage

codesign_tool=/usr/bin/codesign
security_tool=/usr/bin/security
if [ -n "${QUAKESIGNAL_TEST_CODESIGN_BIN:-}" ] || [ -n "${QUAKESIGNAL_TEST_SECURITY_BIN:-}" ]; then
  if [ "${QUAKESIGNAL_ARTIFACT_VERIFIER_TEST_MODE:-}" != fixture-v1 ] || \
     [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${CI_XCODE_CLOUD:-}" ]; then
    echo "::error::Artifact-verifier tool overrides are forbidden outside isolated fixture mode" >&2
    exit 64
  fi
  codesign_tool="${QUAKESIGNAL_TEST_CODESIGN_BIN:?fixture mode requires QUAKESIGNAL_TEST_CODESIGN_BIN}"
  security_tool="${QUAKESIGNAL_TEST_SECURITY_BIN:?fixture mode requires QUAKESIGNAL_TEST_SECURITY_BIN}"
  [ "${codesign_tool#/}" != "$codesign_tool" ] && [ -x "$codesign_tool" ] || usage
  [ "${security_tool#/}" != "$security_tool" ] && [ -x "$security_tool" ] || usage
elif [ -n "${QUAKESIGNAL_ARTIFACT_VERIFIER_TEST_MODE:-}" ]; then
  echo "::error::Artifact-verifier fixture mode requires explicit isolated tool paths" >&2
  exit 64
fi

expected_bundle_id="com.quakesignal.app"
expected_application_id="$team_id.$expected_bundle_id"
case "$platform" in
  ios)
    expected_profile_platform="iOS"
    expected_device_families=(1 2)
    requires_alert_entitlements=true
    requires_embedded_watch=true
    ;;
  tvos)
    expected_profile_platform="tvOS"
    expected_device_families=(3)
    requires_alert_entitlements=false
    requires_embedded_watch=false
    ;;
  visionos)
    expected_profile_platform="visionOS"
    expected_device_families=(7)
    requires_alert_entitlements=false
    requires_embedded_watch=false
    ;;
esac

temp_parent="${QUAKESIGNAL_VERIFICATION_TEMP_ROOT:-${RUNNER_TEMP:-${TMPDIR:-${CI_WORKSPACE_PATH:-/tmp}}}}"
mkdir -p "$temp_parent"
verification_dir="$(mktemp -d "$temp_parent/quakesignal-signed-apple-artifacts.XXXXXX")"
cleanup() {
  rm -rf "$verification_dir"
}
trap cleanup EXIT

error() {
  echo "::error::$*" >&2
  return 1
}

assert_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local label="$4"
  local actual
  if ! actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)"; then
    error "$label is missing required key $key"
    return 1
  fi
  if [ "$actual" != "$expected" ]; then
    error "$label has unexpected $key value ${actual:-<empty>}"
    return 1
  fi
}

assert_plist_array_contains() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local label="$4"
  local index=0
  local actual
  while actual="$(/usr/libexec/PlistBuddy -c "Print :$key:$index" "$plist" 2>/dev/null)"; do
    if [ "$actual" = "$expected" ]; then return 0; fi
    index=$((index + 1))
  done
  error "$label does not include required value $expected for $key"
}

assert_plist_array_exact() {
  local plist="$1"
  local key="$2"
  local label="$3"
  shift 3
  local index=0
  local expected
  local actual
  for expected in "$@"; do
    if ! actual="$(/usr/libexec/PlistBuddy -c "Print :$key:$index" "$plist" 2>/dev/null)"; then
      error "$label is missing required $key entry $expected at index $index"
      return 1
    fi
    if [ "$actual" != "$expected" ]; then
      error "$label has unexpected $key entry $actual at index $index (expected $expected)"
      return 1
    fi
    index=$((index + 1))
  done
  if /usr/libexec/PlistBuddy -c "Print :$key:$index" "$plist" >/dev/null 2>&1; then
    error "$label contains an unexpected additional $key entry"
    return 1
  fi
}

assert_plist_key_absent() {
  local plist="$1"
  local key="$2"
  local label="$3"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    error "$label unexpectedly contains $key"
    return 1
  fi
}

assert_plist_absent() {
  local plist="$1"
  local key="$2"
  local label="$3"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
    error "$label unexpectedly contains foreground-only capability $key"
    return 1
  fi
}

assert_plist_allowed_keys() {
  local plist="$1"
  local label="$2"
  shift 2
  if ! /usr/bin/python3 -I - "$plist" "$label" "$@" <<'PY'
import plistlib
import sys

path, label, *allowed = sys.argv[1:]
with open(path, "rb") as handle:
    value = plistlib.load(handle)
if not isinstance(value, dict):
    raise SystemExit(f"{label} must be a property-list dictionary")
unexpected = sorted(set(value) - set(allowed))
if unexpected:
    raise SystemExit(f"{label} contains unexpected entitlement keys: {', '.join(unexpected)}")
PY
  then
    error "$label contains an unreviewed signed entitlement"
    return 1
  fi
}

assert_distribution_signature() {
  local app="$1"
  local label="$2"
  local details
  "$codesign_tool" --verify --deep --strict --verbose=2 -R '=anchor apple generic' "$app"
  details="$("$codesign_tool" -dvv "$app" 2>&1)"
  if ! grep -Fqx "TeamIdentifier=$team_id" <<<"$details"; then
    error "$label is not signed for Apple team $team_id"
    return 1
  fi
  if ! grep -Fq "Authority=Apple Distribution" <<<"$details"; then
    error "$label is not signed with an Apple Distribution identity"
    return 1
  fi
}

decode_profile() {
  local profile="$1"
  local output="$2"
  local label="$3"
  if ! "$security_tool" cms -D -i "$profile" > "$output"; then
    error "$label could not be decoded"
    return 1
  fi
  plutil -lint "$output" >/dev/null
}

assert_signing_certificate_in_profile() {
  local app="$1"
  local profile_plist="$2"
  local label="$3"
  local certificate_prefix="$verification_dir/$label-signing-certificate-"
  if ! "$codesign_tool" -d --extract-certificates "$certificate_prefix" "$app" >/dev/null 2>&1; then
    error "$label signing certificate could not be extracted"
    return 1
  fi
  local leaf_certificate="${certificate_prefix}0"
  [ -f "$leaf_certificate" ] || { error "$label leaf signing certificate is missing"; return 1; }
  if ! /usr/bin/python3 -I - "$profile_plist" "$leaf_certificate" <<'PY'
import hmac
import plistlib
import sys

profile_path, leaf_path = sys.argv[1:]
with open(profile_path, "rb") as handle:
    profile = plistlib.load(handle)
with open(leaf_path, "rb") as handle:
    leaf = handle.read()
certificates = profile.get("DeveloperCertificates") if isinstance(profile, dict) else None
if not isinstance(certificates, list) or not certificates:
    raise SystemExit("profile has no DeveloperCertificates")
if not any(isinstance(certificate, bytes) and hmac.compare_digest(certificate, leaf) for certificate in certificates):
    raise SystemExit("leaf signing certificate is absent from DeveloperCertificates")
PY
  then
    error "$label leaf signing certificate is not authorized by its provisioning profile"
    return 1
  fi
}

assert_profile_platform() {
  local profile_plist="$1"
  local label="$2"
  if [ "$platform" = visionos ]; then
    if assert_plist_array_contains "$profile_plist" Platform visionOS "$label" >/dev/null 2>&1; then
      return 0
    fi
    if assert_plist_array_contains "$profile_plist" Platform xrOS "$label" >/dev/null 2>&1; then
      return 0
    fi
    error "$label is not authorized for visionOS or xrOS"
    return 1
  fi
  assert_plist_array_contains "$profile_plist" Platform "$expected_profile_platform" "$label"
}

assert_app_store_profile() {
  local profile_plist="$1"
  local label="$2"
  assert_plist_key_absent "$profile_plist" ProvisionedDevices "$label"
  assert_plist_key_absent "$profile_plist" ProvisionsAllDevices "$label"
  assert_plist_value "$profile_plist" Entitlements:get-task-allow false "$label"
  assert_plist_value "$profile_plist" Entitlements:beta-reports-active true "$label"
}

verify_host_structure() {
  local label="$1"
  local app="$2"

  [ -d "$app" ] || { error "$label app bundle is missing"; return 1; }
  [ -f "$app/Info.plist" ] || { error "$label Info.plist is missing"; return 1; }
  plutil -lint "$app/Info.plist" >/dev/null
  assert_plist_value "$app/Info.plist" CFBundleIdentifier "$expected_bundle_id" "$label Info.plist"
  assert_plist_value "$app/Info.plist" CFBundleShortVersionString "$marketing_version" "$label Info.plist"
  assert_plist_value "$app/Info.plist" CFBundleVersion "$build_number" "$label Info.plist"
  assert_plist_array_exact "$app/Info.plist" UIDeviceFamily "$label Info.plist" "${expected_device_families[@]}"
  if [ "$requires_alert_entitlements" = true ]; then
    assert_plist_value "$app/Info.plist" QUAKESIGNAL_API_BASE_URL "https://quakesignal-api.hopeso.workers.dev" "$label Info.plist"
    assert_plist_value "$app/Info.plist" QUAKESIGNAL_APP_ATTEST_MODE production "$label Info.plist"
  else
    assert_plist_key_absent "$app/Info.plist" QUAKESIGNAL_API_BASE_URL "$label Info.plist"
    assert_plist_key_absent "$app/Info.plist" QUAKESIGNAL_APP_ATTEST_MODE "$label Info.plist"
  fi
}

verify_host_app() {
  local label="$1"
  local app="$2"
  local entitlements="$verification_dir/$label-entitlements.plist"
  local profile="$app/embedded.mobileprovision"
  local profile_plist="$verification_dir/$label-profile.plist"

  verify_host_structure "$label" "$app"
  [ -f "$profile" ] || { error "$label embedded provisioning profile is missing"; return 1; }
  assert_distribution_signature "$app" "$label"

  "$codesign_tool" -d --entitlements :- "$app" > "$entitlements" 2>/dev/null
  plutil -lint "$entitlements" >/dev/null
  assert_plist_value "$entitlements" application-identifier "$expected_application_id" "$label signed entitlements"
  assert_plist_value "$entitlements" com.apple.developer.team-identifier "$team_id" "$label signed entitlements"
  assert_plist_value "$entitlements" get-task-allow false "$label signed entitlements"
  assert_plist_value "$entitlements" beta-reports-active true "$label signed entitlements"

  decode_profile "$profile" "$profile_plist" "$label provisioning profile"
  assert_signing_certificate_in_profile "$app" "$profile_plist" "$label"
  if [ -n "$host_profile_name" ]; then
    assert_plist_value "$profile_plist" Name "$host_profile_name" "$label provisioning profile"
  fi
  assert_plist_value "$profile_plist" ApplicationIdentifierPrefix:0 "$team_id" "$label provisioning profile"
  assert_plist_value "$profile_plist" TeamIdentifier:0 "$team_id" "$label provisioning profile"
  assert_plist_value "$profile_plist" Entitlements:application-identifier "$expected_application_id" "$label provisioning profile"
  assert_plist_value "$profile_plist" Entitlements:com.apple.developer.team-identifier "$team_id" "$label provisioning profile"
  assert_profile_platform "$profile_plist" "$label provisioning profile"
  assert_app_store_profile "$profile_plist" "$label provisioning profile"

  if [ "$requires_alert_entitlements" = true ]; then
    assert_plist_value "$entitlements" aps-environment production "$label signed entitlements"
    assert_plist_value "$entitlements" com.apple.developer.devicecheck.appattest-environment production "$label signed entitlements"
    assert_plist_value "$entitlements" com.apple.developer.usernotifications.time-sensitive true "$label signed entitlements"
    assert_plist_value "$profile_plist" Entitlements:aps-environment production "$label provisioning profile"
    assert_plist_array_contains "$profile_plist" Entitlements:com.apple.developer.devicecheck.appattest-environment production "$label provisioning profile"
    assert_plist_value "$profile_plist" Entitlements:com.apple.developer.usernotifications.time-sensitive true "$label provisioning profile"
  else
    for capability in aps-environment com.apple.developer.devicecheck.appattest-environment com.apple.developer.usernotifications.time-sensitive; do
      assert_plist_absent "$entitlements" "$capability" "$label signed entitlements"
    done
  fi
  local allowed_entitlement_keys=(
    application-identifier
    beta-reports-active
    com.apple.developer.team-identifier
    get-task-allow
    keychain-access-groups
  )
  if [ "$requires_alert_entitlements" = true ]; then
    allowed_entitlement_keys+=(
      aps-environment
      com.apple.developer.devicecheck.appattest-environment
      com.apple.developer.usernotifications.time-sensitive
    )
  fi
  assert_plist_allowed_keys "$entitlements" "$label signed entitlements" "${allowed_entitlement_keys[@]}"
  if /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups' "$entitlements" >/dev/null 2>&1; then
    assert_plist_array_exact "$entitlements" keychain-access-groups "$label signed entitlements" "$expected_application_id"
  fi
}

verify_watch_structure() {
  local label="$1"
  local app="$2"
  local watch_bundle_id="com.quakesignal.app.watchkitapp"

  [ -d "$app" ] || { error "$label Watch app bundle is missing"; return 1; }
  [ -f "$app/Info.plist" ] || { error "$label Info.plist is missing"; return 1; }
  plutil -lint "$app/Info.plist" >/dev/null
  assert_plist_value "$app/Info.plist" CFBundleIdentifier "$watch_bundle_id" "$label Info.plist"
  assert_plist_value "$app/Info.plist" CFBundleShortVersionString "$marketing_version" "$label Info.plist"
  assert_plist_value "$app/Info.plist" CFBundleVersion "$build_number" "$label Info.plist"
  assert_plist_value "$app/Info.plist" WKCompanionAppBundleIdentifier "$expected_bundle_id" "$label Info.plist"
  assert_plist_value "$app/Info.plist" WKApplication true "$label Info.plist"
  assert_plist_array_exact "$app/Info.plist" UIDeviceFamily "$label Info.plist" 4
  assert_plist_key_absent "$app/Info.plist" QUAKESIGNAL_API_BASE_URL "$label Info.plist"
  assert_plist_key_absent "$app/Info.plist" QUAKESIGNAL_APP_ATTEST_MODE "$label Info.plist"
}

verify_watch_app() {
  local label="$1"
  local app="$2"
  local watch_bundle_id="com.quakesignal.app.watchkitapp"
  local watch_application_id="$team_id.$watch_bundle_id"
  local entitlements="$verification_dir/$label-entitlements.plist"
  local profile="$app/embedded.mobileprovision"
  local profile_plist="$verification_dir/$label-profile.plist"

  verify_watch_structure "$label" "$app"
  [ -f "$profile" ] || { error "$label embedded provisioning profile is missing"; return 1; }
  assert_distribution_signature "$app" "$label"

  "$codesign_tool" -d --entitlements :- "$app" > "$entitlements" 2>/dev/null
  plutil -lint "$entitlements" >/dev/null
  assert_plist_value "$entitlements" application-identifier "$watch_application_id" "$label signed entitlements"
  assert_plist_value "$entitlements" com.apple.developer.team-identifier "$team_id" "$label signed entitlements"
  assert_plist_value "$entitlements" get-task-allow false "$label signed entitlements"
  assert_plist_value "$entitlements" beta-reports-active true "$label signed entitlements"

  decode_profile "$profile" "$profile_plist" "$label provisioning profile"
  assert_signing_certificate_in_profile "$app" "$profile_plist" "$label"
  if [ -n "$watch_profile_name" ]; then
    assert_plist_value "$profile_plist" Name "$watch_profile_name" "$label provisioning profile"
  fi
  assert_plist_value "$profile_plist" ApplicationIdentifierPrefix:0 "$team_id" "$label provisioning profile"
  assert_plist_value "$profile_plist" TeamIdentifier:0 "$team_id" "$label provisioning profile"
  assert_plist_value "$profile_plist" Entitlements:application-identifier "$watch_application_id" "$label provisioning profile"
  assert_plist_value "$profile_plist" Entitlements:com.apple.developer.team-identifier "$team_id" "$label provisioning profile"
  assert_plist_array_contains "$profile_plist" Platform watchOS "$label provisioning profile"
  assert_app_store_profile "$profile_plist" "$label provisioning profile"
  for capability in aps-environment com.apple.developer.devicecheck.appattest-environment com.apple.developer.usernotifications.time-sensitive; do
    assert_plist_absent "$entitlements" "$capability" "$label signed entitlements"
  done
  assert_plist_allowed_keys "$entitlements" "$label signed entitlements" \
    application-identifier \
    beta-reports-active \
    com.apple.developer.team-identifier \
    get-task-allow \
    keychain-access-groups
  if /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups' "$entitlements" >/dev/null 2>&1; then
    assert_plist_array_exact "$entitlements" keychain-access-groups "$label signed entitlements" "$watch_application_id"
  fi
}

verify_bundle_inventory() {
  local label="$1"
  local app="$2"
  local allowed_watch="${3:-}"
  local candidate
  local bundle_paths=()

  while IFS= read -r -d '' candidate; do
    bundle_paths[${#bundle_paths[@]}]="$candidate"
  done < <(find "$app" \( -type d -o -type l \) \( -name '*.app' -o -name '*.appex' \) -print0)

  local expected_count=1
  [ -z "$allowed_watch" ] || expected_count=2
  if [ "${#bundle_paths[@]}" -ne "$expected_count" ]; then
    error "$label contains an unexpected nested app or app extension bundle"
    return 1
  fi
  for candidate in "${bundle_paths[@]}"; do
    if [ -L "$candidate" ]; then
      error "$label contains a symlinked app or app extension bundle"
      return 1
    fi
    if [ "$candidate" != "$app" ] && { [ -z "$allowed_watch" ] || [ "$candidate" != "$allowed_watch" ]; }; then
      error "$label contains unexpected bundle $candidate"
      return 1
    fi
  done
}

shopt -s nullglob
archive_apps=("$archive"/Products/Applications/*.app)
if [ ! -d "$archive" ] || [ "${#archive_apps[@]}" -ne 1 ]; then
  error "Expected exactly one application in archive $archive"
  exit 1
fi

exported_app=""
if [ -f "$exported" ]; then
  case "$exported" in
    *.ipa|*.zip)
      exported_root="$verification_dir/exported"
      mkdir -p "$exported_root"
      ditto -x -k "$exported" "$exported_root"
      exported_apps=("$exported_root"/Payload/*.app)
      [ "${#exported_apps[@]}" -eq 1 ] || { error "Expected exactly one app in exported archive $exported"; exit 1; }
      exported_app="${exported_apps[0]}"
      ;;
    *) error "Exported artifact must be an IPA, ZIP, app bundle, or directory"; exit 1 ;;
  esac
elif [ -d "$exported" ]; then
  if [[ "$exported" == *.app ]]; then
    exported_app="$exported"
  else
    exported_apps=("$exported"/Payload/*.app)
    exported_ipas=("$exported"/*.ipa)
    exported_archive_apps=("$exported"/Products/Applications/*.app)
    if [ "${#exported_apps[@]}" -eq 1 ] && [ "${#exported_ipas[@]}" -eq 0 ] && [ "${#exported_archive_apps[@]}" -eq 0 ]; then
      exported_app="${exported_apps[0]}"
    elif [ "${#exported_apps[@]}" -eq 0 ] && [ "${#exported_ipas[@]}" -eq 1 ] && [ "${#exported_archive_apps[@]}" -eq 0 ]; then
      exported_root="$verification_dir/exported"
      mkdir -p "$exported_root"
      ditto -x -k "${exported_ipas[0]}" "$exported_root"
      exported_apps=("$exported_root"/Payload/*.app)
      [ "${#exported_apps[@]}" -eq 1 ] || { error "Expected exactly one app in ${exported_ipas[0]}"; exit 1; }
      exported_app="${exported_apps[0]}"
    elif [ "${#exported_apps[@]}" -eq 0 ] && [ "${#exported_ipas[@]}" -eq 0 ] && [ "${#exported_archive_apps[@]}" -eq 1 ]; then
      exported_app="${exported_archive_apps[0]}"
    else
      error "Expected exactly one unambiguous Payload app, IPA, or xcarchive application below exported directory $exported"
      exit 1
    fi
  fi
else
  error "Exported App Store artifact $exported is missing"
  exit 1
fi

if [ "$archive_signing" = strict-distribution ]; then
  verify_host_app archive "${archive_apps[0]}"
else
  verify_host_structure archive "${archive_apps[0]}"
fi
verify_host_app exported "$exported_app"

archive_watch_apps=("${archive_apps[0]}"/Watch/*.app)
exported_watch_apps=("$exported_app"/Watch/*.app)
if [ "$requires_embedded_watch" = true ]; then
  if [ "${#archive_watch_apps[@]}" -ne 1 ] || [ "${#exported_watch_apps[@]}" -ne 1 ]; then
    error "Expected exactly one embedded Watch app in both the iOS archive and App Store artifact"
    exit 1
  fi
  if [ "$archive_signing" = strict-distribution ]; then
    verify_watch_app archive-watch "${archive_watch_apps[0]}"
  else
    verify_watch_structure archive-watch "${archive_watch_apps[0]}"
  fi
  verify_watch_app exported-watch "${exported_watch_apps[0]}"
  verify_bundle_inventory archive "${archive_apps[0]}" "${archive_watch_apps[0]}"
  verify_bundle_inventory exported "$exported_app" "${exported_watch_apps[0]}"
elif [ "${#archive_watch_apps[@]}" -ne 0 ] || [ "${#exported_watch_apps[@]}" -ne 0 ]; then
  error "$platform artifacts must not embed the iOS companion Watch app"
  exit 1
else
  verify_bundle_inventory archive "${archive_apps[0]}"
  verify_bundle_inventory exported "$exported_app"
fi

echo "Verified signed $platform archive and App Store artifact for QuakeSignal $marketing_version ($build_number), Apple team $team_id."
