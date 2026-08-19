#!/bin/bash
set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
  echo "Skipping signed Apple artifact fixture tests outside macOS."
  exit 0
fi

repository_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
verifier="$repository_root/ios/ci_scripts/verify-signed-apple-artifacts.sh"
test_parent="${QUAKESIGNAL_TEST_TEMP_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
mkdir -p "$test_parent"
test_root="$(mktemp -d "$test_parent/quakesignal-signed-artifacts-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/tmp"

cat > "$test_root/bin/codesign" <<'STUB'
#!/bin/bash
set -euo pipefail
if [ "$1" = "--verify" ]; then
  app="${!#}"
  [ ! -e "$app/.test-invalid-signature" ]
  if [ -e "$app/.test-untrusted-signature" ]; then
    echo 'untrusted signature does not satisfy anchor apple generic' >&2
    exit 1
  fi
  requirement_found=false
  for ((index = 1; index < $#; index += 1)); do
    next=$((index + 1))
    if [ "${!index}" = -R ] && [ "${!next}" = '=anchor apple generic' ]; then
      requirement_found=true
    fi
  done
  [ "$requirement_found" = true ]
  exit 0
fi
if [ "$1" = "-dvv" ]; then
  app="$2"
  printf 'Authority=%s\n' "$(cat "$app/.test-authority")"
  printf 'TeamIdentifier=%s\n' "$(cat "$app/.test-team")"
  exit 0
fi
if [ "$1" = "-d" ] && [ "$2" = "--extract-certificates" ]; then
  prefix="$3"
  app="$4"
  cat "$app/.test-signing-certificate" > "${prefix}0"
  exit 0
fi
if [ "$1" = "-d" ] && [ "$2" = "--entitlements" ]; then
  app="${!#}"
  cat "$app/.test-entitlements.plist"
  exit 0
fi
exit 70
STUB
cat > "$test_root/bin/security" <<'STUB'
#!/bin/bash
set -euo pipefail
if [ "$1" = cms ] && [ "$2" = -D ] && [ "$3" = -i ]; then
  cat "$4"
  exit 0
fi
exit 70
STUB
chmod +x "$test_root/bin/codesign" "$test_root/bin/security"
export PATH="$test_root/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export QUAKESIGNAL_VERIFICATION_TEMP_ROOT="$test_root/tmp"
unset CI GITHUB_ACTIONS CI_XCODE_CLOUD
export QUAKESIGNAL_ARTIFACT_VERIFIER_TEST_MODE=fixture-v1
export QUAKESIGNAL_TEST_CODESIGN_BIN="$test_root/bin/codesign"
export QUAKESIGNAL_TEST_SECURITY_BIN="$test_root/bin/security"

team="5TT564H883"

write_info_plist() {
  local path="$1"
  local bundle_id="$2"
  local profile_platform="$3"
  local alerts="$4"
  local watch_companion="${5:-}"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict>'
    printf '<key>CFBundleIdentifier</key><string>%s</string>\n' "$bundle_id"
    printf '%s\n' '<key>CFBundleShortVersionString</key><string>1.1</string>' '<key>CFBundleVersion</key><string>8</string>'
    case "$profile_platform" in
      iOS) printf '%s\n' '<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>' ;;
      tvOS) printf '%s\n' '<key>UIDeviceFamily</key><array><integer>3</integer></array>' ;;
      visionOS|xrOS) printf '%s\n' '<key>UIDeviceFamily</key><array><integer>7</integer></array>' ;;
      watchOS) printf '%s\n' '<key>UIDeviceFamily</key><array><integer>4</integer></array>' '<key>WKApplication</key><true/>' ;;
    esac
    if [ "$alerts" = true ]; then
      printf '%s\n' '<key>QUAKESIGNAL_API_BASE_URL</key><string>https://quakesignal-api.hopeso.workers.dev</string>' '<key>QUAKESIGNAL_APP_ATTEST_MODE</key><string>production</string>'
    fi
    if [ -n "$watch_companion" ]; then
      printf '<key>WKCompanionAppBundleIdentifier</key><string>%s</string>\n' "$watch_companion"
    fi
    printf '%s\n' '</dict></plist>'
  } > "$path"
}

write_entitlements() {
  local path="$1"
  local app_id="$2"
  local alerts="$3"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict>'
    printf '<key>application-identifier</key><string>%s</string>\n' "$app_id"
    printf '<key>com.apple.developer.team-identifier</key><string>%s</string>\n' "$team"
    printf '%s\n' '<key>get-task-allow</key><false/>' '<key>beta-reports-active</key><true/>'
    if [ "$alerts" = true ]; then
      printf '%s\n' '<key>aps-environment</key><string>production</string>' '<key>com.apple.developer.devicecheck.appattest-environment</key><string>production</string>' '<key>com.apple.developer.usernotifications.time-sensitive</key><true/>'
    fi
    printf '%s\n' '</dict></plist>'
  } > "$path"
}

write_profile() {
  local path="$1"
  local name="$2"
  local app_id="$3"
  local profile_platform="$4"
  local alerts="$5"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict>'
    printf '<key>Name</key><string>%s</string>\n' "$name"
    printf '<key>ApplicationIdentifierPrefix</key><array><string>%s</string></array>\n' "$team"
    printf '<key>TeamIdentifier</key><array><string>%s</string></array>\n' "$team"
    printf '<key>Platform</key><array><string>%s</string></array>\n' "$profile_platform"
    printf '%s\n' '<key>DeveloperCertificates</key><array><data>Zml4dHVyZS1sZWFmLWNlcnQ=</data></array>'
    printf '%s\n' '<key>Entitlements</key><dict>'
    printf '<key>application-identifier</key><string>%s</string>\n' "$app_id"
    printf '<key>com.apple.developer.team-identifier</key><string>%s</string>\n' "$team"
    printf '%s\n' '<key>get-task-allow</key><false/>' '<key>beta-reports-active</key><true/>'
    if [ "$alerts" = true ]; then
      printf '%s\n' '<key>aps-environment</key><string>production</string>' '<key>com.apple.developer.devicecheck.appattest-environment</key><array><string>development</string><string>production</string></array>' '<key>com.apple.developer.usernotifications.time-sensitive</key><true/>'
    fi
    printf '%s\n' '</dict></dict></plist>'
  } > "$path"
}

create_app() {
  local app="$1"
  local bundle_id="$2"
  local profile_platform="$3"
  local alerts="$4"
  local profile_name="$5"
  local companion="${6:-}"
  mkdir -p "$app"
  write_info_plist "$app/Info.plist" "$bundle_id" "$profile_platform" "$alerts" "$companion"
  write_entitlements "$app/.test-entitlements.plist" "$team.$bundle_id" "$alerts"
  write_profile "$app/embedded.mobileprovision" "$profile_name" "$team.$bundle_id" "$profile_platform" "$alerts"
  printf '%s\n' "$team" > "$app/.test-team"
  printf '%s\n' 'Apple Distribution: QuakeSignal Fixture' > "$app/.test-authority"
  printf '%s' 'fixture-leaf-cert' > "$app/.test-signing-certificate"
}

create_fixture() {
  local fixture="$1"
  local fixture_platform="$2"
  local profile_platform="$3"
  local alerts="$4"
  rm -rf "$fixture"
  local archive_app="$fixture/Archive.xcarchive/Products/Applications/QuakeSignal.app"
  local exported_app="$fixture/export/Payload/QuakeSignal.app"
  create_app "$archive_app" com.quakesignal.app "$profile_platform" "$alerts" 'Host Profile'
  if [ "$fixture_platform" = ios ] || [ "$fixture_platform" = visionos ]; then
    cp "$repository_root/ios/QuakeSignal/Resources/Audio/quakesignal_urgent.caf" "$archive_app/"
    cp "$repository_root/ios/QuakeSignal/Resources/Audio/quakesignal_japanese_voice.caf" "$archive_app/"
    cp "$repository_root/ios/QuakeSignal/Resources/Audio/ATTRIBUTION.md" "$archive_app/"
  fi
  mkdir -p "$(dirname "$exported_app")"
  cp -R "$archive_app" "$exported_app"
  if [ "$fixture_platform" = ios ]; then
    create_app "$archive_app/Watch/QuakeSignalWatch.app" com.quakesignal.app.watchkitapp watchOS false 'Watch Profile' com.quakesignal.app
    mkdir -p "$exported_app/Watch"
    cp -R "$archive_app/Watch/QuakeSignalWatch.app" "$exported_app/Watch/QuakeSignalWatch.app"
  fi
}

run_verifier_mode() {
  local fixture="$1"
  local fixture_platform="$2"
  local archive_mode="$3"
  local exported_path="${4:-$fixture/export}"
  "$verifier" \
    --platform "$fixture_platform" \
    --archive "$fixture/Archive.xcarchive" \
    --exported "$exported_path" \
    --build-number 8 \
    --marketing-version 1.1 \
    --team-id "$team" \
    --archive-signing "$archive_mode" \
    --host-profile-name 'Host Profile' \
    --watch-profile-name 'Watch Profile'
}

run_verifier() {
  run_verifier_mode "$1" "$2" strict-distribution
}

expect_failure() {
  local label="$1"
  local expected="$2"
  shift 2
  local log="$test_root/$label.log"
  if "$@" >"$log" 2>&1; then
    echo "Expected $label to fail" >&2
    exit 1
  fi
  if ! grep -Eiq "$expected" "$log"; then
    echo "$label failed for an unexpected reason:" >&2
    cat "$log" >&2
    exit 1
  fi
}

ios_fixture="$test_root/ios"
create_fixture "$ios_fixture" ios iOS true
run_verifier "$ios_fixture" ios

rm "$ios_fixture/export/Payload/QuakeSignal.app/quakesignal_urgent.caf"
expect_failure missing-urgent-audio 'urgent alert audio.*missing' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

printf 'mutated' > "$ios_fixture/export/Payload/QuakeSignal.app/quakesignal_japanese_voice.caf"
expect_failure mutated-japanese-voice 'Japanese Safety Voice audio.*SHA-256' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

rm "$ios_fixture/export/Payload/QuakeSignal.app/ATTRIBUTION.md"
ln -s /dev/null "$ios_fixture/export/Payload/QuakeSignal.app/ATTRIBUTION.md"
expect_failure symlinked-audio-attribution 'alert-audio attribution.*not a regular file' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

ios_exported_archive="$ios_fixture/QuakeSignal.ipa"
(cd "$ios_fixture/export" && ditto -c -k --keepParent Payload "$ios_exported_archive")
run_verifier_mode "$ios_fixture" ios strict-distribution "$ios_exported_archive"
mkdir -p "$ios_fixture/apple-signed-export"
cp "$ios_exported_archive" "$ios_fixture/apple-signed-export/QuakeSignal.ipa"
run_verifier_mode "$ios_fixture" ios strict-distribution "$ios_fixture/apple-signed-export"
cp -R "$ios_fixture/Archive.xcarchive" "$ios_fixture/AppleSignedExport.xcarchive"
run_verifier_mode "$ios_fixture" ios strict-distribution "$ios_fixture/AppleSignedExport.xcarchive"
cp "$ios_exported_archive" "$ios_fixture/export/Unexpected.ipa"
expect_failure ambiguous-export 'unambiguous Payload app, IPA, or xcarchive' run_verifier "$ios_fixture" ios

create_fixture "$ios_fixture" ios iOS true
printf '%s\n' 'Apple Development: QuakeSignal Fixture' > "$ios_fixture/Archive.xcarchive/Products/Applications/QuakeSignal.app/.test-authority"
printf '%s\n' 'Apple Development: QuakeSignal Fixture' > "$ios_fixture/Archive.xcarchive/Products/Applications/QuakeSignal.app/Watch/QuakeSignalWatch.app/.test-authority"
rm "$ios_fixture/Archive.xcarchive/Products/Applications/QuakeSignal.app/embedded.mobileprovision"
rm "$ios_fixture/Archive.xcarchive/Products/Applications/QuakeSignal.app/Watch/QuakeSignalWatch.app/embedded.mobileprovision"
run_verifier_mode "$ios_fixture" ios structure-only
expect_failure cloud-raw-strict 'embedded provisioning profile is missing|Apple Distribution' run_verifier "$ios_fixture" ios
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.mutated' "$ios_fixture/Archive.xcarchive/Products/Applications/QuakeSignal.app/Info.plist"
expect_failure cloud-raw-structure 'CFBundleIdentifier.*com.example.mutated' run_verifier_mode "$ios_fixture" ios structure-only
create_fixture "$ios_fixture" ios iOS true

/usr/libexec/PlistBuddy -c 'Set :QUAKESIGNAL_API_BASE_URL https://attacker.invalid' "$ios_fixture/export/Payload/QuakeSignal.app/Info.plist"
expect_failure wrong-worker-origin 'QUAKESIGNAL_API_BASE_URL.*attacker.invalid' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

/usr/libexec/PlistBuddy -c 'Set :QUAKESIGNAL_APP_ATTEST_MODE development' "$ios_fixture/Archive.xcarchive/Products/Applications/QuakeSignal.app/Info.plist"
expect_failure wrong-app-attest-mode 'QUAKESIGNAL_APP_ATTEST_MODE.*development' run_verifier_mode "$ios_fixture" ios structure-only
create_fixture "$ios_fixture" ios iOS true

/usr/libexec/PlistBuddy -c 'Delete :UIDeviceFamily:1' "$ios_fixture/export/Payload/QuakeSignal.app/Info.plist"
expect_failure missing-ipad-family 'UIDeviceFamily.*index 1' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

/usr/libexec/PlistBuddy -c 'Delete :WKApplication' "$ios_fixture/export/Payload/QuakeSignal.app/Watch/QuakeSignalWatch.app/Info.plist"
expect_failure watch-marker 'WKApplication' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

/usr/libexec/PlistBuddy -c 'Set :Entitlements:beta-reports-active false' "$ios_fixture/export/Payload/QuakeSignal.app/embedded.mobileprovision"
expect_failure app-store-profile 'beta-reports-active.*false' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

/usr/libexec/PlistBuddy -c 'Add :ProvisionedDevices array' "$ios_fixture/export/Payload/QuakeSignal.app/embedded.mobileprovision"
/usr/libexec/PlistBuddy -c 'Add :ProvisionedDevices:0 string TEST-DEVICE' "$ios_fixture/export/Payload/QuakeSignal.app/embedded.mobileprovision"
expect_failure adhoc-profile 'ProvisionedDevices' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 9' "$ios_fixture/export/Payload/QuakeSignal.app/Info.plist"
expect_failure wrong-build 'CFBundleVersion.*9' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

rm -rf "$ios_fixture/export/Payload/QuakeSignal.app/Watch"
expect_failure missing-watch 'embedded Watch app' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

mkdir -p "$ios_fixture/export/Payload/QuakeSignal.app/PlugIns/Unexpected.appex"
expect_failure unexpected-extension 'unexpected nested app or app extension bundle|unexpected bundle' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

/usr/libexec/PlistBuddy -c 'Add :aps-environment string production' "$ios_fixture/export/Payload/QuakeSignal.app/Watch/QuakeSignalWatch.app/.test-entitlements.plist"
expect_failure watch-capability 'foreground-only capability aps-environment' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

touch "$ios_fixture/export/Payload/QuakeSignal.app/.test-untrusted-signature"
expect_failure untrusted-signature 'anchor apple generic|signature' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

printf '%s' 'different-leaf-certificate' > "$ios_fixture/export/Payload/QuakeSignal.app/.test-signing-certificate"
expect_failure profile-certificate-mismatch 'leaf signing certificate.*not authorized' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

/usr/libexec/PlistBuddy -c 'Add :com.apple.developer.associated-domains array' "$ios_fixture/export/Payload/QuakeSignal.app/.test-entitlements.plist"
/usr/libexec/PlistBuddy -c 'Add :com.apple.developer.associated-domains:0 string applinks:attacker.invalid' "$ios_fixture/export/Payload/QuakeSignal.app/.test-entitlements.plist"
expect_failure unexpected-signed-entitlement 'unexpected entitlement|unreviewed signed entitlement' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

printf '%s\n' 'ABCDEFGHIJ' > "$ios_fixture/export/Payload/QuakeSignal.app/.test-team"
expect_failure wrong-team 'not signed for Apple team' run_verifier "$ios_fixture" ios

tvos_fixture="$test_root/tvos"
create_fixture "$tvos_fixture" tvos tvOS false
run_verifier "$tvos_fixture" tvos
for profile in \
  "$tvos_fixture/Archive.xcarchive/Products/Applications/QuakeSignal.app/embedded.mobileprovision" \
  "$tvos_fixture/export/Payload/QuakeSignal.app/embedded.mobileprovision"; do
  /usr/libexec/PlistBuddy -c 'Add :Entitlements:aps-environment string production' "$profile"
  /usr/libexec/PlistBuddy -c 'Add :Entitlements:com.apple.developer.devicecheck.appattest-environment array' "$profile"
  /usr/libexec/PlistBuddy -c 'Add :Entitlements:com.apple.developer.devicecheck.appattest-environment:0 string production' "$profile"
  /usr/libexec/PlistBuddy -c 'Add :Entitlements:com.apple.developer.usernotifications.time-sensitive bool true' "$profile"
done
run_verifier "$tvos_fixture" tvos
/usr/libexec/PlistBuddy -c 'Add :aps-environment string production' "$tvos_fixture/export/Payload/QuakeSignal.app/.test-entitlements.plist"
expect_failure tvos-capability 'foreground-only capability aps-environment' run_verifier "$tvos_fixture" tvos

vision_fixture="$test_root/visionos"
create_fixture "$vision_fixture" visionos xrOS false
run_verifier "$vision_fixture" visionos

rm "$vision_fixture/export/Payload/QuakeSignal.app/quakesignal_japanese_voice.caf"
expect_failure vision-missing-japanese-voice 'Japanese Safety Voice audio.*missing' run_verifier "$vision_fixture" visionos

echo "Signed Apple artifact verifier mutation tests passed."
