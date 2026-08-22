#!/bin/bash -p
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH DEVELOPER_DIR SDKROOT TOOLCHAINS

usage() {
  cat >&2 <<'USAGE'
Usage: verify-signed-apple-artifacts.sh \
  --platform <ios|maccatalyst|tvos|visionos> \
  --archive <path.xcarchive> \
  --exported <path.ipa|path.pkg|path.zip|export-directory|path.app|path.xcarchive> \
  --build-number <CFBundleVersion> \
  --marketing-version <CFBundleShortVersionString> \
  --team-id <Apple-Team-ID> \
  --archive-signing <strict-distribution|structure-only> \
  [--host-profile-name <exact-name>] \
  [--watch-profile-name <exact-name>] \
  [--installer-identity <exact-name>]
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
installer_identity=""

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
    --installer-identity) [ "$#" -ge 2 ] || usage; installer_identity="$2"; shift 2 ;;
    *) usage ;;
  esac
done

for value in "$platform" "$archive" "$exported" "$build_number" "$marketing_version" "$team_id" "$archive_signing"; do
  [ -n "$value" ] || usage
done
case "$platform" in ios|maccatalyst|tvos|visionos) ;; *) usage ;; esac
case "$archive_signing" in strict-distribution|structure-only) ;; *) usage ;; esac
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$marketing_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || usage
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || usage
if [ "$platform" != maccatalyst ] && [ -n "$installer_identity" ]; then
  usage
fi

codesign_tool=/usr/bin/codesign
security_tool=/usr/bin/security
pkgutil_tool=/usr/sbin/pkgutil
lsbom_tool=/usr/bin/lsbom
if [ -n "${QUAKESIGNAL_TEST_CODESIGN_BIN:-}" ] || \
   [ -n "${QUAKESIGNAL_TEST_SECURITY_BIN:-}" ] || \
   [ -n "${QUAKESIGNAL_TEST_PKGUTIL_BIN:-}" ] || \
   [ -n "${QUAKESIGNAL_TEST_LSBOM_BIN:-}" ]; then
  if [ "${QUAKESIGNAL_ARTIFACT_VERIFIER_TEST_MODE:-}" != fixture-v1 ] || \
     [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${CI_XCODE_CLOUD:-}" ]; then
    echo "::error::Artifact-verifier tool overrides are forbidden outside isolated fixture mode" >&2
    exit 64
  fi
  codesign_tool="${QUAKESIGNAL_TEST_CODESIGN_BIN:?fixture mode requires QUAKESIGNAL_TEST_CODESIGN_BIN}"
  security_tool="${QUAKESIGNAL_TEST_SECURITY_BIN:?fixture mode requires QUAKESIGNAL_TEST_SECURITY_BIN}"
  pkgutil_tool="${QUAKESIGNAL_TEST_PKGUTIL_BIN:?fixture mode requires QUAKESIGNAL_TEST_PKGUTIL_BIN}"
  lsbom_tool="${QUAKESIGNAL_TEST_LSBOM_BIN:?fixture mode requires QUAKESIGNAL_TEST_LSBOM_BIN}"
  [ "${codesign_tool#/}" != "$codesign_tool" ] && [ -x "$codesign_tool" ] || usage
  [ "${security_tool#/}" != "$security_tool" ] && [ -x "$security_tool" ] || usage
  [ "${pkgutil_tool#/}" != "$pkgutil_tool" ] && [ -x "$pkgutil_tool" ] || usage
  [ "${lsbom_tool#/}" != "$lsbom_tool" ] && [ -x "$lsbom_tool" ] || usage
elif [ -n "${QUAKESIGNAL_ARTIFACT_VERIFIER_TEST_MODE:-}" ]; then
  echo "::error::Artifact-verifier fixture mode requires explicit isolated tool paths" >&2
  exit 64
fi

expected_bundle_id="com.quakesignal.app"
expected_application_id="$team_id.$expected_bundle_id"
urgent_audio_sha256="9b8e5b3220bf6534a23b0266f3b7e0cb45516e27659d10ac75fc008abdefbfb8"
japanese_voice_sha256="142c9d6fc382246f327dd37d4fe110f225f8d7a0819e9f861374c0bb74bbe3a6"
audio_attribution_sha256="7dc20bb7f27f9a86e0b98c4efc2a41c7aea22410cb35643243d01cb9a76e140c"
zero_collection_privacy_manifest_sha256="a331d51864743ebe4e00dd22360b4a538b6b3ac26a6b3eb54094e60a36959a12"
case "$platform" in
  ios)
    expected_profile_platform="iOS"
    expected_device_families=(1 2)
    requires_alert_entitlements=true
    requires_embedded_watch=true
    requires_local_alert_audio=true
    requires_zero_collection_privacy_manifest=false
    requires_worker_configuration=true
    uses_mac_bundle_layout=false
    application_identifier_key=application-identifier
    profile_relative_path=embedded.mobileprovision
    info_relative_path=Info.plist
    resources_relative_path=.
    ;;
  maccatalyst)
    expected_profile_platform="OSX"
    expected_device_families=(2)
    requires_alert_entitlements=false
    requires_embedded_watch=false
    requires_local_alert_audio=true
    requires_zero_collection_privacy_manifest=false
    requires_worker_configuration=true
    uses_mac_bundle_layout=true
    application_identifier_key=com.apple.application-identifier
    profile_relative_path=Contents/embedded.provisionprofile
    info_relative_path=Contents/Info.plist
    resources_relative_path=Contents/Resources
    ;;
  tvos)
    expected_profile_platform="tvOS"
    expected_device_families=(3)
    requires_alert_entitlements=false
    requires_embedded_watch=false
    requires_local_alert_audio=true
    requires_zero_collection_privacy_manifest=true
    requires_worker_configuration=false
    uses_mac_bundle_layout=false
    application_identifier_key=application-identifier
    profile_relative_path=embedded.mobileprovision
    info_relative_path=Info.plist
    resources_relative_path=.
    ;;
  visionos)
    expected_profile_platform="visionOS"
    expected_device_families=(7)
    requires_alert_entitlements=false
    requires_embedded_watch=false
    requires_local_alert_audio=true
    requires_zero_collection_privacy_manifest=true
    requires_worker_configuration=false
    uses_mac_bundle_layout=false
    application_identifier_key=application-identifier
    profile_relative_path=embedded.mobileprovision
    info_relative_path=Info.plist
    resources_relative_path=.
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

assert_regular_file_sha256() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local output
  local actual

  [ -f "$path" ] && [ ! -L "$path" ] || {
    error "$label is missing or is not a regular file"
    return 1
  }
  output="$(/usr/bin/shasum -a 256 "$path")"
  actual="${output%% *}"
  if [ "$actual" != "$expected" ]; then
    error "$label has unexpected SHA-256 $actual"
    return 1
  fi
}

verify_local_alert_audio_resources() {
  local label="$1"
  local app="$2"

  assert_regular_file_sha256 \
    "$app/$resources_relative_path/quakesignal_urgent.caf" \
    "$urgent_audio_sha256" \
    "$label urgent alert audio"
  assert_regular_file_sha256 \
    "$app/$resources_relative_path/quakesignal_japanese_voice.caf" \
    "$japanese_voice_sha256" \
    "$label Japanese Safety Voice audio"
  assert_regular_file_sha256 \
    "$app/$resources_relative_path/ATTRIBUTION.md" \
    "$audio_attribution_sha256" \
    "$label alert-audio attribution"
}

verify_zero_collection_privacy_manifest() {
  local label="$1"
  local app="$2"

  assert_regular_file_sha256 \
    "$app/$resources_relative_path/PrivacyInfo.xcprivacy" \
    "$zero_collection_privacy_manifest_sha256" \
    "$label zero-collection privacy manifest"
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

assert_profile_identifier() {
  local plist="$1"
  local expected="$2"
  local label="$3"
  local found=0
  local key
  local actual

  # Mac profiles have used both spellings across Xcode generations. Accept
  # either spelling, but reject every present mismatch and require at least one.
  for key in \
    Entitlements:com.apple.application-identifier \
    Entitlements:application-identifier; do
    if actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)"; then
      found=1
      if [ "$actual" != "$expected" ]; then
        error "$label has unexpected $key value $actual"
        return 1
      fi
    fi
  done
  if [ "$found" -ne 1 ]; then
    error "$label is missing an application-identifier entitlement"
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
  # Newer macOS codesign releases require the prefix as an option argument
  # (`--extract-certificates=...`); retain the legacy form as a compatibility
  # fallback for older runners and the isolated fixture stub.
  if ! "$codesign_tool" -d "--extract-certificates=$certificate_prefix" "$app" >/dev/null 2>&1 &&
     ! "$codesign_tool" -d --extract-certificates "$certificate_prefix" "$app" >/dev/null 2>&1; then
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
  if [ "$uses_mac_bundle_layout" = false ]; then
    assert_plist_value "$profile_plist" Entitlements:get-task-allow false "$label"
    assert_plist_value "$profile_plist" Entitlements:beta-reports-active true "$label"
  fi
}

verify_host_structure() {
  local label="$1"
  local app="$2"
  local info="$app/$info_relative_path"

  [ -d "$app" ] || { error "$label app bundle is missing"; return 1; }
  [ -f "$info" ] || { error "$label Info.plist is missing"; return 1; }
  plutil -lint "$info" >/dev/null
  assert_plist_value "$info" CFBundleIdentifier "$expected_bundle_id" "$label Info.plist"
  assert_plist_value "$info" CFBundleShortVersionString "$marketing_version" "$label Info.plist"
  assert_plist_value "$info" CFBundleVersion "$build_number" "$label Info.plist"
  assert_plist_array_exact "$info" UIDeviceFamily "$label Info.plist" "${expected_device_families[@]}"
  if [ "$uses_mac_bundle_layout" = true ]; then
    assert_plist_array_exact "$info" CFBundleSupportedPlatforms "$label Info.plist" MacOSX
    assert_plist_value "$info" LSMinimumSystemVersion 14.0 "$label Info.plist"
    assert_plist_value "$info" LSApplicationCategoryType public.app-category.weather "$label Info.plist"
    assert_plist_key_absent "$info" LSRequiresIPhoneOS "$label Info.plist"
  fi
  if [ "$requires_worker_configuration" = true ]; then
    assert_plist_value "$info" QUAKESIGNAL_API_BASE_URL "https://quakesignal-api.hopeso.workers.dev" "$label Info.plist"
    assert_plist_value "$info" QUAKESIGNAL_APP_ATTEST_MODE production "$label Info.plist"
  else
    assert_plist_key_absent "$info" QUAKESIGNAL_API_BASE_URL "$label Info.plist"
    assert_plist_key_absent "$info" QUAKESIGNAL_APP_ATTEST_MODE "$label Info.plist"
  fi
  if [ "$requires_local_alert_audio" = true ]; then
    verify_local_alert_audio_resources "$label" "$app"
  fi
  if [ "$requires_zero_collection_privacy_manifest" = true ]; then
    verify_zero_collection_privacy_manifest "$label" "$app"
  fi
}

verify_host_app() {
  local label="$1"
  local app="$2"
  local entitlements="$verification_dir/$label-entitlements.plist"
  local profile="$app/$profile_relative_path"
  local profile_plist="$verification_dir/$label-profile.plist"

  verify_host_structure "$label" "$app"
  [ -f "$profile" ] || { error "$label embedded provisioning profile is missing"; return 1; }
  assert_distribution_signature "$app" "$label"

  "$codesign_tool" -d --entitlements :- "$app" > "$entitlements" 2>/dev/null
  plutil -lint "$entitlements" >/dev/null
  assert_plist_value "$entitlements" "$application_identifier_key" "$expected_application_id" "$label signed entitlements"
  assert_plist_value "$entitlements" com.apple.developer.team-identifier "$team_id" "$label signed entitlements"
  if [ "$uses_mac_bundle_layout" = false ]; then
    assert_plist_value "$entitlements" get-task-allow false "$label signed entitlements"
    assert_plist_value "$entitlements" beta-reports-active true "$label signed entitlements"
  fi

  decode_profile "$profile" "$profile_plist" "$label provisioning profile"
  assert_signing_certificate_in_profile "$app" "$profile_plist" "$label"
  if [ -n "$host_profile_name" ]; then
    assert_plist_value "$profile_plist" Name "$host_profile_name" "$label provisioning profile"
  fi
  assert_plist_value "$profile_plist" ApplicationIdentifierPrefix:0 "$team_id" "$label provisioning profile"
  assert_plist_value "$profile_plist" TeamIdentifier:0 "$team_id" "$label provisioning profile"
  if [ "$uses_mac_bundle_layout" = true ]; then
    assert_profile_identifier "$profile_plist" "$expected_application_id" "$label provisioning profile"
  else
    assert_plist_value "$profile_plist" Entitlements:application-identifier "$expected_application_id" "$label provisioning profile"
  fi
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
  local allowed_entitlement_keys
  if [ "$uses_mac_bundle_layout" = true ]; then
    assert_plist_value "$entitlements" com.apple.security.app-sandbox true "$label signed entitlements"
    assert_plist_value "$entitlements" com.apple.security.network.client true "$label signed entitlements"
    assert_plist_value "$entitlements" com.apple.security.personal-information.location true "$label signed entitlements"
    allowed_entitlement_keys=(
      application-identifier
      beta-reports-active
      com.apple.application-identifier
      com.apple.developer.team-identifier
      com.apple.security.app-sandbox
      com.apple.security.get-task-allow
      com.apple.security.network.client
      com.apple.security.personal-information.location
      get-task-allow
      keychain-access-groups
    )
  else
    allowed_entitlement_keys=(
      application-identifier
      beta-reports-active
      com.apple.developer.team-identifier
      get-task-allow
      keychain-access-groups
    )
  fi
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
  verify_local_alert_audio_resources "$label" "$app"
  assert_regular_file_sha256 \
    "$app/PrivacyInfo.xcprivacy" \
    "$zero_collection_privacy_manifest_sha256" \
    "$label zero-collection privacy manifest"
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
  # Apple currently emits App Store profiles for a watch companion with the
  # companion bundle's Platform array headed by iOS (and, on newer portals,
  # xrOS/visionOS), even though the embedded product itself is watchOS. Older
  # profiles used watchOS directly. Accept either Apple representation while
  # retaining the explicit watch bundle identifier and entitlements checks.
  if assert_plist_array_contains "$profile_plist" Platform watchOS "$label provisioning profile" >/dev/null 2>&1; then
    :
  elif assert_plist_array_contains "$profile_plist" Platform iOS "$label provisioning profile" >/dev/null 2>&1; then
    :
  else
    error "$label provisioning profile does not include watchOS or Apple's iOS companion platform"
    return 1
  fi
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

assert_app_bundle_permissions() {
  local label="$1"
  local app="$2"
  local path
  local failed=false

  while IFS= read -r -d '' path; do
    error "$label contains a regular file that is unreadable after installation"
    failed=true
    break
  done < <(find "$app" -type f ! -perm -0004 -print0)
  while IFS= read -r -d '' path; do
    error "$label contains a directory that is not searchable after installation"
    failed=true
    break
  done < <(find "$app" -type d ! -perm -0001 -print0)
  [ "$failed" = false ]
}

assert_package_payload_permissions() {
  local package="$1"
  local main_executable="$2"
  local bom
  local bom_listing="$verification_dir/exported-package-boms.txt"
  local bom_index=0
  local listing
  local boms=()
  local listings=()

  if ! "$pkgutil_tool" --bom "$package" > "$bom_listing"; then
    error "Exported Mac Catalyst installer package BOM inventory could not be read"
    return 1
  fi
  while IFS= read -r bom; do
    [ -n "$bom" ] || continue
    [ -f "$bom" ] && [ ! -L "$bom" ] || {
      error "Exported Mac Catalyst installer package exposed an invalid BOM"
      return 1
    }
    boms[${#boms[@]}]="$bom"
  done < "$bom_listing"
  if [ "${#boms[@]}" -eq 0 ]; then
    error "Exported Mac Catalyst installer package does not expose a payload BOM"
    return 1
  fi

  for bom in "${boms[@]}"; do
    listing="$verification_dir/exported-package-bom-$bom_index.txt"
    if ! "$lsbom_tool" -p mf "$bom" > "$listing"; then
      error "Exported Mac Catalyst installer package entry types and permissions could not be read"
      return 1
    fi
    listings[${#listings[@]}]="$listing"
    bom_index=$((bom_index + 1))
  done

  if ! /usr/bin/python3 -I - "$main_executable" "${listings[@]}" <<'PY'
import re
import stat
import sys

main_executable, *listing_paths = sys.argv[1:]
expected_executable = f"QuakeSignal.app/Contents/MacOS/{main_executable}"
files_seen = 0
directories_seen = 0
main_executable_entries = 0

def normalized_path(raw):
    if not raw or any(ord(character) < 32 or ord(character) == 127 for character in raw):
        raise SystemExit("package BOM contains an empty or control-bearing path")
    if raw in {".", "./"}:
        return "."
    value = raw[2:] if raw.startswith("./") else raw
    if value.startswith("/"):
        raise SystemExit("package BOM contains an absolute path")
    parts = value.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise SystemExit("package BOM contains an unsafe path component")
    if parts[0] == "Applications":
        parts = parts[1:]
        if not parts:
            return "Applications"
    normalized = "/".join(parts)
    if normalized != "QuakeSignal.app" and not normalized.startswith("QuakeSignal.app/"):
        raise SystemExit("package BOM contains content outside QuakeSignal.app")
    return normalized

for listing_path in listing_paths:
    with open(listing_path, encoding="utf-8") as handle:
        for raw_record in handle:
            record = raw_record.rstrip("\n")
            if not record:
                continue
            if record.count("\t") != 1:
                raise SystemExit("package BOM contains a malformed entry")
            raw_mode, raw_path = record.split("\t")
            if not re.fullmatch(r"0*[0-7]+", raw_mode):
                raise SystemExit("package BOM contains an invalid entry mode")
            mode = int(raw_mode, 8)
            path = normalized_path(raw_path)
            # pkgutil exposes the component's synthetic, non-installed root as
            # `.` with mode 0 on real product packages. It is inventory
            # scaffolding rather than a payload filesystem entry.
            if path == ".":
                continue
            kind = stat.S_IFMT(mode)
            if kind == stat.S_IFREG:
                files_seen += 1
                if mode & stat.S_IROTH == 0:
                    raise SystemExit("package BOM contains a payload file unreadable after installation")
                if path == expected_executable:
                    main_executable_entries += 1
                    if mode & stat.S_IXOTH == 0:
                        raise SystemExit("package BOM main executable is not executable after installation")
            elif kind == stat.S_IFDIR:
                if path not in {".", "Applications"}:
                    directories_seen += 1
                if path != "." and mode & stat.S_IXOTH == 0:
                    raise SystemExit("package BOM contains a payload directory unsearchable after installation")
            else:
                raise SystemExit(f"package BOM contains an unapproved entry type with mode {raw_mode}")

if files_seen == 0 or directories_seen == 0:
    raise SystemExit("package BOM has an incomplete payload inventory")
if main_executable_entries != 1:
    raise SystemExit("package BOM must contain exactly one regular main executable entry")
PY
  then
    error "Exported Mac Catalyst installer package has unsafe entry types, paths, or install-time permissions"
    return 1
  fi
}

resolve_installer_package_app() {
  local package="$1"
  local signature
  local signature_listing="$verification_dir/exported-package-signature.txt"
  local expanded="$verification_dir/exported-package"
  local payload_listing="$verification_dir/exported-package-payload-files.txt"
  local payload_root="$verification_dir/exported-package-payload"
  local candidate
  local main_executable
  local main_executable_path
  local payloads=()
  local apps=()

  [ "$platform" = maccatalyst ] || {
    error "Only the Mac Catalyst route may supply an exported installer package"
    return 1
  }
  [ -f "$package" ] && [ ! -L "$package" ] || {
    error "Exported Mac Catalyst installer must be a regular package file"
    return 1
  }
  case "$installer_identity" in
    "Mac Installer Distribution: "*" ($team_id)"|"3rd Party Mac Developer Installer: "*" ($team_id)") ;;
    *) error "Mac Catalyst package verification requires an exact Mac Installer Distribution identity"; return 1 ;;
  esac
  if ! signature="$("$pkgutil_tool" --check-signature "$package" 2>&1)"; then
    error "Exported Mac Catalyst installer package has an invalid or untrusted signature"
    return 1
  fi
  printf '%s\n' "$signature" > "$signature_listing"
  if ! /usr/bin/python3 -I - "$installer_identity" "$signature_listing" <<'PY'
import re
import sys

expected_identity = sys.argv[1]
lines = open(sys.argv[2], encoding="utf-8").read().splitlines()
trusted_statuses = {
    "Status: signed by a certificate trusted by macOS",
    "Status: signed by a certificate trusted by Mac OS X",
}
statuses = [line.strip() for line in lines if line.strip().startswith("Status:")]
if len(statuses) != 1 or statuses[0] not in trusted_statuses:
    raise SystemExit("package signature status is missing, ambiguous, or untrusted")
leaf_identities = []
for line in lines:
    match = re.fullmatch(r"\s*1\.\s+(.+?)\s*", line)
    if match:
        leaf_identities.append(match.group(1))
if leaf_identities != [expected_identity]:
    raise SystemExit("package leaf installer identity does not match")
PY
  then
    error "Exported Mac Catalyst installer package does not have the expected trusted installer signature"
    return 1
  fi

  if ! "$pkgutil_tool" --payload-files "$package" > "$payload_listing"; then
    error "Exported Mac Catalyst installer package payload inventory could not be read"
    return 1
  fi
  if ! /usr/bin/python3 -I - "$payload_listing" <<'PY'
import sys

lines = [line.rstrip("\n") for line in open(sys.argv[1], encoding="utf-8")]
if not lines:
    raise SystemExit("package payload inventory is empty")
seen_app = False
for raw in lines:
    if not raw or any(ord(character) < 32 or ord(character) == 127 for character in raw):
        raise SystemExit("package payload inventory contains an empty or control-bearing path")
    if raw in {".", "./"}:
        continue
    value = raw[2:] if raw.startswith("./") else raw
    if value.startswith("/"):
        raise SystemExit("package payload inventory contains an absolute path")
    parts = value.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise SystemExit("package payload inventory contains an unsafe path component")
    normalized = "/".join(parts)
    if normalized == "Applications":
        continue
    if normalized.startswith("Applications/"):
        normalized = normalized[len("Applications/"):]
    if normalized != "QuakeSignal.app" and not normalized.startswith("QuakeSignal.app/"):
        raise SystemExit("package payload contains content outside QuakeSignal.app")
    seen_app = True
if not seen_app:
    raise SystemExit("package payload does not contain QuakeSignal.app")
PY
  then
    error "Exported Mac Catalyst installer package has an unsafe or unexpected payload inventory"
    return 1
  fi
  if ! "$pkgutil_tool" --expand "$package" "$expanded"; then
    error "Exported Mac Catalyst installer package could not be expanded"
    return 1
  fi
  if [ -n "$(find "$expanded" \( -type f -o -type d -o -type l \) -name Scripts -print -quit)" ]; then
    error "Exported Mac Catalyst installer package must not contain installer scripts"
    return 1
  fi
  while IFS= read -r -d '' candidate; do
    payloads[${#payloads[@]}]="$candidate"
  done < <(find "$expanded" -type f -name Payload -print0)
  if [ "${#payloads[@]}" -ne 1 ]; then
    error "Exported Mac Catalyst installer package must contain exactly one regular payload"
    return 1
  fi

  mkdir -p "$payload_root"
  if ! /usr/bin/ditto -x --noqtn "${payloads[0]}" "$payload_root"; then
    error "Exported Mac Catalyst installer package payload could not be extracted"
    return 1
  fi
  while IFS= read -r -d '' candidate; do
    apps[${#apps[@]}]="$candidate"
  done < <(find "$payload_root" -type d -name '*.app' -prune -print0)
  if [ "${#apps[@]}" -ne 1 ] || [ "${apps[0]##*/}" != QuakeSignal.app ]; then
    error "Exported Mac Catalyst installer package must contain exactly QuakeSignal.app"
    return 1
  fi
  if [ -n "$(find "$payload_root" -type l -print -quit)" ]; then
    error "Exported Mac Catalyst installer package payload must not contain symbolic links"
    return 1
  fi
  assert_app_bundle_permissions "exported Mac Catalyst package app" "${apps[0]}"
  if ! main_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${apps[0]}/Contents/Info.plist" 2>/dev/null)" || \
     [ -z "$main_executable" ] || [[ "$main_executable" == */* ]] || \
     [[ "$main_executable" == *$'\t'* ]] || [[ "$main_executable" == *$'\n'* ]] || \
     [[ "$main_executable" == *$'\r'* ]] || \
     [ "$main_executable" = . ] || [ "$main_executable" = .. ]; then
    error "Exported Mac Catalyst package app has an invalid or missing CFBundleExecutable"
    return 1
  fi
  main_executable_path="${apps[0]}/Contents/MacOS/$main_executable"
  if [ ! -f "$main_executable_path" ] || [ -L "$main_executable_path" ] || [ ! -x "$main_executable_path" ]; then
    error "Exported Mac Catalyst package app CFBundleExecutable is not a regular non-symlink executable"
    return 1
  fi
  assert_package_payload_permissions "$package" "$main_executable"
  exported_app="${apps[0]}"
}

shopt -s nullglob
archive_apps=("$archive"/Products/Applications/*.app)
if [ ! -d "$archive" ] || [ "${#archive_apps[@]}" -ne 1 ]; then
  error "Expected exactly one application in archive $archive"
  exit 1
fi

exported_app=""
exported_is_installer=false
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
    *.pkg)
      resolve_installer_package_app "$exported"
      exported_is_installer=true
      ;;
    *) error "Exported artifact must be an IPA, PKG, ZIP, app bundle, or directory"; exit 1 ;;
  esac
elif [ -d "$exported" ]; then
  if [[ "$exported" == *.app ]]; then
    exported_app="$exported"
  else
    exported_direct_apps=("$exported"/*.app)
    exported_apps=("$exported"/Payload/*.app)
    exported_ipas=("$exported"/*.ipa)
    exported_archive_apps=("$exported"/Products/Applications/*.app)
    if [ "${#exported_direct_apps[@]}" -eq 1 ] && [ "${#exported_apps[@]}" -eq 0 ] && [ "${#exported_ipas[@]}" -eq 0 ] && [ "${#exported_archive_apps[@]}" -eq 0 ]; then
      exported_app="${exported_direct_apps[0]}"
    elif [ "${#exported_direct_apps[@]}" -eq 0 ] && [ "${#exported_apps[@]}" -eq 1 ] && [ "${#exported_ipas[@]}" -eq 0 ] && [ "${#exported_archive_apps[@]}" -eq 0 ]; then
      exported_app="${exported_apps[0]}"
    elif [ "${#exported_direct_apps[@]}" -eq 0 ] && [ "${#exported_apps[@]}" -eq 0 ] && [ "${#exported_ipas[@]}" -eq 1 ] && [ "${#exported_archive_apps[@]}" -eq 0 ]; then
      exported_root="$verification_dir/exported"
      mkdir -p "$exported_root"
      ditto -x -k "${exported_ipas[0]}" "$exported_root"
      exported_apps=("$exported_root"/Payload/*.app)
      [ "${#exported_apps[@]}" -eq 1 ] || { error "Expected exactly one app in ${exported_ipas[0]}"; exit 1; }
      exported_app="${exported_apps[0]}"
    elif [ "${#exported_direct_apps[@]}" -eq 0 ] && [ "${#exported_apps[@]}" -eq 0 ] && [ "${#exported_ipas[@]}" -eq 0 ] && [ "${#exported_archive_apps[@]}" -eq 1 ]; then
      exported_app="${exported_archive_apps[0]}"
    else
      error "Expected exactly one unambiguous direct app, Payload app, IPA, or xcarchive application below exported directory $exported"
      exit 1
    fi
  fi
else
  error "Exported App Store artifact $exported is missing"
  exit 1
fi
if [ -n "$installer_identity" ] && [ "$exported_is_installer" != true ]; then
  error "An installer identity may only accompany an exported Mac Catalyst package"
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
