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
cat > "$test_root/bin/pkgutil" <<'STUB'
#!/bin/bash
set -euo pipefail
case "$1" in
  --check-signature)
    [ "$#" -eq 2 ]
    cat "$2.signature"
    ;;
  --payload-files)
    [ "$#" -eq 2 ]
    cat "$2.payload-files"
    ;;
  --bom)
    [ "$#" -eq 2 ]
    printf '%s\n' "$2.bom"
    ;;
  --expand)
    [ "$#" -eq 3 ]
    [ ! -e "$3" ]
    mkdir -p "$3"
    cp -R "$2.expanded/." "$3/"
    ;;
  *) exit 70 ;;
esac
STUB
cat > "$test_root/bin/lsbom" <<'STUB'
#!/bin/bash
set -euo pipefail
[ "$#" -eq 3 ]
[ "$1" = -p ]
[ "$2" = mf ]
cat "$3.entries"
STUB
chmod +x "$test_root/bin/codesign" "$test_root/bin/security" "$test_root/bin/pkgutil" "$test_root/bin/lsbom"
export PATH="$test_root/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export QUAKESIGNAL_VERIFICATION_TEMP_ROOT="$test_root/tmp"
unset CI GITHUB_ACTIONS CI_XCODE_CLOUD
export QUAKESIGNAL_ARTIFACT_VERIFIER_TEST_MODE=fixture-v1
export QUAKESIGNAL_TEST_CODESIGN_BIN="$test_root/bin/codesign"
export QUAKESIGNAL_TEST_SECURITY_BIN="$test_root/bin/security"
export QUAKESIGNAL_TEST_PKGUTIL_BIN="$test_root/bin/pkgutil"
export QUAKESIGNAL_TEST_LSBOM_BIN="$test_root/bin/lsbom"

team="5TT564H883"
installer_identity="Mac Installer Distribution: QuakeSignal Fixture ($team)"

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
  if [ "$fixture_platform" = ios ] || [ "$fixture_platform" = tvos ] || [ "$fixture_platform" = visionos ]; then
    cp "$repository_root/ios/QuakeSignal/Resources/Audio/quakesignal_urgent.caf" "$archive_app/"
    cp "$repository_root/ios/QuakeSignal/Resources/Audio/quakesignal_japanese_voice.caf" "$archive_app/"
    cp "$repository_root/ios/QuakeSignal/Resources/Audio/ATTRIBUTION.md" "$archive_app/"
  fi
  if [ "$fixture_platform" = tvos ] || [ "$fixture_platform" = visionos ]; then
    cp "$repository_root/ios/QuakeSignalTV/Supporting/PrivacyInfo.xcprivacy" "$archive_app/PrivacyInfo.xcprivacy"
  fi
  mkdir -p "$(dirname "$exported_app")"
  cp -R "$archive_app" "$exported_app"
  if [ "$fixture_platform" = ios ]; then
    create_app "$archive_app/Watch/QuakeSignalWatch.app" com.quakesignal.app.watchkitapp watchOS false 'Watch Profile' com.quakesignal.app
    cp "$repository_root/ios/QuakeSignal/Resources/Audio/quakesignal_urgent.caf" "$archive_app/Watch/QuakeSignalWatch.app/"
    cp "$repository_root/ios/QuakeSignal/Resources/Audio/quakesignal_japanese_voice.caf" "$archive_app/Watch/QuakeSignalWatch.app/"
    cp "$repository_root/ios/QuakeSignal/Resources/Audio/ATTRIBUTION.md" "$archive_app/Watch/QuakeSignalWatch.app/"
    cp "$repository_root/ios/QuakeSignalWatch/Supporting/PrivacyInfo.xcprivacy" "$archive_app/Watch/QuakeSignalWatch.app/PrivacyInfo.xcprivacy"
    mkdir -p "$exported_app/Watch"
    cp -R "$archive_app/Watch/QuakeSignalWatch.app" "$exported_app/Watch/QuakeSignalWatch.app"
  fi
}

create_mac_catalyst_app() {
  local app="$1"
  local profile_name="$2"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict>'
    printf '%s\n' \
      '<key>CFBundleIdentifier</key><string>com.quakesignal.app</string>' \
      '<key>CFBundleExecutable</key><string>QuakeSignal</string>' \
      '<key>CFBundleShortVersionString</key><string>1.1</string>' \
      '<key>CFBundleVersion</key><string>8</string>' \
      '<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>' \
      '<key>LSMinimumSystemVersion</key><string>14.0</string>' \
      '<key>LSApplicationCategoryType</key><string>public.app-category.weather</string>' \
      '<key>UIDeviceFamily</key><array><integer>2</integer></array>' \
      '<key>QUAKESIGNAL_API_BASE_URL</key><string>https://quakesignal-api.hopeso.workers.dev</string>' \
      '<key>QUAKESIGNAL_APP_ATTEST_MODE</key><string>production</string>'
    printf '%s\n' '</dict></plist>'
  } > "$app/Contents/Info.plist"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict>'
    printf '<key>com.apple.application-identifier</key><string>%s.com.quakesignal.app</string>\n' "$team"
    printf '<key>com.apple.developer.team-identifier</key><string>%s</string>\n' "$team"
    printf '%s\n' \
      '<key>com.apple.security.app-sandbox</key><true/>' \
      '<key>com.apple.security.network.client</key><true/>' \
      '<key>com.apple.security.personal-information.location</key><true/>'
    printf '%s\n' '</dict></plist>'
  } > "$app/.test-entitlements.plist"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict>'
    printf '<key>Name</key><string>%s</string>\n' "$profile_name"
    printf '<key>ApplicationIdentifierPrefix</key><array><string>%s</string></array>\n' "$team"
    printf '<key>TeamIdentifier</key><array><string>%s</string></array>\n' "$team"
    printf '%s\n' '<key>Platform</key><array><string>OSX</string></array>' '<key>DeveloperCertificates</key><array><data>Zml4dHVyZS1sZWFmLWNlcnQ=</data></array>' '<key>Entitlements</key><dict>'
    printf '<key>com.apple.application-identifier</key><string>%s.com.quakesignal.app</string>\n' "$team"
    printf '<key>com.apple.developer.team-identifier</key><string>%s</string>\n' "$team"
    printf '%s\n' '</dict></dict></plist>'
  } > "$app/Contents/embedded.provisionprofile"
  printf '%s\n' "$team" > "$app/.test-team"
  printf '%s\n' 'Apple Distribution: QuakeSignal Fixture' > "$app/.test-authority"
  printf '%s' 'fixture-leaf-cert' > "$app/.test-signing-certificate"
  printf '%s\n' '#!/bin/true' > "$app/Contents/MacOS/QuakeSignal"
  chmod 755 "$app/Contents/MacOS/QuakeSignal"
  cp "$repository_root/ios/QuakeSignal/Resources/Audio/quakesignal_urgent.caf" "$app/Contents/Resources/"
  cp "$repository_root/ios/QuakeSignal/Resources/Audio/quakesignal_japanese_voice.caf" "$app/Contents/Resources/"
  cp "$repository_root/ios/QuakeSignal/Resources/Audio/ATTRIBUTION.md" "$app/Contents/Resources/"
}

create_mac_catalyst_fixture() {
  local fixture="$1"
  rm -rf "$fixture"
  local archive_app="$fixture/Archive.xcarchive/Products/Applications/QuakeSignal.app"
  local exported_app="$fixture/export/QuakeSignal.app"
  create_mac_catalyst_app "$archive_app" 'Catalyst Profile'
  mkdir -p "$(dirname "$exported_app")"
  cp -R "$archive_app" "$exported_app"
}

create_mac_catalyst_package_fixture() {
  local fixture="$1"
  local package="$fixture/QuakeSignal.pkg"
  local expanded="$package.expanded"
  rm -rf \
    "$package" \
    "$package.signature" \
    "$package.payload-files" \
    "$package.bom" \
    "$package.bom.entries" \
    "$expanded"
  : > "$package"
  mkdir -p "$expanded"
  (
    cd "$fixture/export"
    /usr/bin/find QuakeSignal.app -print > "$package.payload-files"
    /usr/bin/ditto -c --norsrc --keepParent QuakeSignal.app "$expanded/Payload"
  )
  printf '%s\n' \
    'Package "QuakeSignal.pkg":' \
    '   Status: signed by a certificate trusted by macOS' \
    '   Certificate Chain:' \
    "    1. $installer_identity" > "$package.signature"
  : > "$package.bom"
  printf '%s\t%s\n' \
    0 . \
    40755 './QuakeSignal.app' \
    40755 './QuakeSignal.app/Contents' \
    40755 './QuakeSignal.app/Contents/MacOS' \
    100755 './QuakeSignal.app/Contents/MacOS/QuakeSignal' \
    100644 './QuakeSignal.app/Contents/Info.plist' > "$package.bom.entries"
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

run_catalyst_verifier_mode() {
  local fixture="$1"
  local archive_mode="$2"
  "$verifier" \
    --platform maccatalyst \
    --archive "$fixture/Archive.xcarchive" \
    --exported "$fixture/export/QuakeSignal.app" \
    --build-number 8 \
    --marketing-version 1.1 \
    --team-id "$team" \
    --archive-signing "$archive_mode" \
    --host-profile-name 'Catalyst Profile'
}

run_catalyst_verifier() {
  run_catalyst_verifier_mode "$1" strict-distribution
}

run_catalyst_export_directory_verifier() {
  local fixture="$1"
  "$verifier" \
    --platform maccatalyst \
    --archive "$fixture/Archive.xcarchive" \
    --exported "$fixture/export" \
    --build-number 8 \
    --marketing-version 1.1 \
    --team-id "$team" \
    --archive-signing strict-distribution \
    --host-profile-name 'Catalyst Profile'
}

run_catalyst_package_verifier() {
  local fixture="$1"
  "$verifier" \
    --platform maccatalyst \
    --archive "$fixture/Archive.xcarchive" \
    --exported "$fixture/QuakeSignal.pkg" \
    --build-number 8 \
    --marketing-version 1.1 \
    --team-id "$team" \
    --archive-signing strict-distribution \
    --host-profile-name 'Catalyst Profile' \
    --installer-identity "$installer_identity"
}

run_catalyst_package_verifier_without_identity() {
  local fixture="$1"
  "$verifier" \
    --platform maccatalyst \
    --archive "$fixture/Archive.xcarchive" \
    --exported "$fixture/QuakeSignal.pkg" \
    --build-number 8 \
    --marketing-version 1.1 \
    --team-id "$team" \
    --archive-signing strict-distribution \
    --host-profile-name 'Catalyst Profile'
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
expect_failure ambiguous-export 'unambiguous direct app, Payload app, IPA, or xcarchive' run_verifier "$ios_fixture" ios

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

rm "$ios_fixture/export/Payload/QuakeSignal.app/Watch/QuakeSignalWatch.app/quakesignal_japanese_voice.caf"
expect_failure watch-missing-japanese-voice 'Japanese Safety Voice audio.*missing' run_verifier "$ios_fixture" ios
create_fixture "$ios_fixture" ios iOS true

rm "$ios_fixture/export/Payload/QuakeSignal.app/Watch/QuakeSignalWatch.app/PrivacyInfo.xcprivacy"
expect_failure watch-missing-privacy-manifest 'zero-collection privacy manifest.*missing' run_verifier "$ios_fixture" ios
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

catalyst_fixture="$test_root/maccatalyst"
create_mac_catalyst_fixture "$catalyst_fixture"
run_catalyst_verifier "$catalyst_fixture"
run_catalyst_export_directory_verifier "$catalyst_fixture"
create_mac_catalyst_package_fixture "$catalyst_fixture"
run_catalyst_package_verifier "$catalyst_fixture"

expect_failure catalyst-package-missing-installer-identity 'requires an exact Mac Installer Distribution identity' run_catalyst_package_verifier_without_identity "$catalyst_fixture"

rm "$catalyst_fixture/QuakeSignal.pkg.signature"
expect_failure catalyst-package-signature-command-failure 'invalid or untrusted signature' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_package_fixture "$catalyst_fixture"

printf '%s\n' \
  'Package "QuakeSignal.pkg":' \
  '   Status: signed by an untrusted certificate' \
  '   Certificate Chain:' \
  "    1. $installer_identity" > "$catalyst_fixture/QuakeSignal.pkg.signature"
expect_failure catalyst-package-untrusted-status 'expected trusted installer signature' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_package_fixture "$catalyst_fixture"

printf '%s\n' \
  'Package "QuakeSignal.pkg":' \
  '   Status: signed by a certificate trusted by macOS' \
  '   Certificate Chain:' \
  "    1. Mac Installer Distribution: Other Fixture ($team)" > "$catalyst_fixture/QuakeSignal.pkg.signature"
expect_failure catalyst-package-wrong-installer-identity 'expected trusted installer signature' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_package_fixture "$catalyst_fixture"

printf '%s\n' '../escape' >> "$catalyst_fixture/QuakeSignal.pkg.payload-files"
expect_failure catalyst-package-unsafe-path 'unsafe or unexpected payload inventory' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_package_fixture "$catalyst_fixture"

printf '%s\t%s\n' \
  40755 . \
  40755 './QuakeSignal.app' \
  100755 './QuakeSignal.app/Contents/MacOS/QuakeSignal' \
  100600 './QuakeSignal.app/Contents/Info.plist' > "$catalyst_fixture/QuakeSignal.pkg.bom.entries"
expect_failure catalyst-package-unreadable-bom-file 'payload file unreadable after installation' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_package_fixture "$catalyst_fixture"

printf '%s\t%s\n' \
  40755 . \
  40750 './QuakeSignal.app/Contents' \
  100755 './QuakeSignal.app/Contents/MacOS/QuakeSignal' > "$catalyst_fixture/QuakeSignal.pkg.bom.entries"
expect_failure catalyst-package-unsearchable-bom-directory 'payload directory unsearchable after installation' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_package_fixture "$catalyst_fixture"

printf '%s\t%s\n' \
  40755 . \
  40755 './QuakeSignal.app' \
  40755 './QuakeSignal.app/Contents/MacOS' \
  100644 './QuakeSignal.app/Contents/MacOS/QuakeSignal' \
  100644 './QuakeSignal.app/Contents/Info.plist' > "$catalyst_fixture/QuakeSignal.pkg.bom.entries"
expect_failure catalyst-package-nonexecutable-main-bom-entry 'main executable is not executable after installation' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_package_fixture "$catalyst_fixture"

printf '%s\t%s\n' \
  40755 . \
  40755 './QuakeSignal.app' \
  40755 './QuakeSignal.app/Contents/MacOS' \
  100644 './QuakeSignal.app/Contents/Info.plist' > "$catalyst_fixture/QuakeSignal.pkg.bom.entries"
expect_failure catalyst-package-missing-main-bom-entry 'exactly one regular main executable entry' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_package_fixture "$catalyst_fixture"

printf '%s\t%s\n' \
  40755 . \
  40755 './QuakeSignal.app' \
  40755 './QuakeSignal.app/Contents/MacOS' \
  100755 './QuakeSignal.app/Contents/MacOS/QuakeSignal' \
  120777 './QuakeSignal.app/Contents/Resources/unapproved-link' > "$catalyst_fixture/QuakeSignal.pkg.bom.entries"
expect_failure catalyst-package-unapproved-bom-entry-type 'unapproved entry type' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_package_fixture "$catalyst_fixture"

chmod 644 "$catalyst_fixture/export/QuakeSignal.app/Contents/MacOS/QuakeSignal"
create_mac_catalyst_package_fixture "$catalyst_fixture"
expect_failure catalyst-package-extracted-main-not-executable 'CFBundleExecutable is not a regular non-symlink executable' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_fixture "$catalyst_fixture"

/usr/libexec/PlistBuddy -c 'Delete :CFBundleExecutable' "$catalyst_fixture/export/QuakeSignal.app/Contents/Info.plist"
create_mac_catalyst_package_fixture "$catalyst_fixture"
expect_failure catalyst-package-missing-cfbundleexecutable 'invalid or missing CFBundleExecutable' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_fixture "$catalyst_fixture"

rm "$catalyst_fixture/export/QuakeSignal.app/Contents/MacOS/QuakeSignal"
ln -s /bin/true "$catalyst_fixture/export/QuakeSignal.app/Contents/MacOS/QuakeSignal"
create_mac_catalyst_package_fixture "$catalyst_fixture"
expect_failure catalyst-package-symlinked-main-executable 'payload must not contain symbolic links' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_fixture "$catalyst_fixture"

mkdir -p "$catalyst_fixture/QuakeSignal.pkg.expanded/Scripts"
expect_failure catalyst-package-installer-scripts 'must not contain installer scripts' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_package_fixture "$catalyst_fixture"

mkdir -p "$catalyst_fixture/QuakeSignal.pkg.expanded/nested"
cp "$catalyst_fixture/QuakeSignal.pkg.expanded/Payload" "$catalyst_fixture/QuakeSignal.pkg.expanded/nested/Payload"
expect_failure catalyst-package-multiple-payloads 'exactly one regular payload' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_fixture "$catalyst_fixture"

ln -s /dev/null "$catalyst_fixture/export/QuakeSignal.app/Contents/Resources/unexpected-link"
create_mac_catalyst_package_fixture "$catalyst_fixture"
expect_failure catalyst-package-symbolic-link 'payload must not contain symbolic links' run_catalyst_package_verifier "$catalyst_fixture"
create_mac_catalyst_fixture "$catalyst_fixture"

/usr/libexec/PlistBuddy -c 'Set :com.apple.security.app-sandbox false' "$catalyst_fixture/export/QuakeSignal.app/.test-entitlements.plist"
expect_failure catalyst-sandbox 'app-sandbox.*false' run_catalyst_verifier "$catalyst_fixture"
create_mac_catalyst_fixture "$catalyst_fixture"

/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.personal-information.location' "$catalyst_fixture/export/QuakeSignal.app/.test-entitlements.plist"
expect_failure catalyst-location-entitlement 'personal-information.location' run_catalyst_verifier "$catalyst_fixture"
create_mac_catalyst_fixture "$catalyst_fixture"

/usr/libexec/PlistBuddy -c 'Set :LSApplicationCategoryType public.app-category.utilities' "$catalyst_fixture/export/QuakeSignal.app/Contents/Info.plist"
expect_failure catalyst-category 'LSApplicationCategoryType.*utilities' run_catalyst_verifier "$catalyst_fixture"
create_mac_catalyst_fixture "$catalyst_fixture"

/usr/libexec/PlistBuddy -c 'Set :Platform:0 iOS' "$catalyst_fixture/export/QuakeSignal.app/Contents/embedded.provisionprofile"
expect_failure catalyst-profile-platform 'required value OSX' run_catalyst_verifier "$catalyst_fixture"
create_mac_catalyst_fixture "$catalyst_fixture"

rm "$catalyst_fixture/Archive.xcarchive/Products/Applications/QuakeSignal.app/Contents/embedded.provisionprofile"
printf '%s\n' 'Apple Development: QuakeSignal Fixture' > "$catalyst_fixture/Archive.xcarchive/Products/Applications/QuakeSignal.app/.test-authority"
run_catalyst_verifier_mode "$catalyst_fixture" structure-only

tvos_fixture="$test_root/tvos"
create_fixture "$tvos_fixture" tvos tvOS false
run_verifier "$tvos_fixture" tvos
rm "$tvos_fixture/export/Payload/QuakeSignal.app/PrivacyInfo.xcprivacy"
expect_failure tvos-missing-privacy-manifest 'zero-collection privacy manifest.*missing' run_verifier "$tvos_fixture" tvos
create_fixture "$tvos_fixture" tvos tvOS false
rm "$tvos_fixture/export/Payload/QuakeSignal.app/quakesignal_urgent.caf"
expect_failure tvos-missing-urgent-audio 'urgent alert audio.*missing' run_verifier "$tvos_fixture" tvos
create_fixture "$tvos_fixture" tvos tvOS false
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

rm "$vision_fixture/export/Payload/QuakeSignal.app/PrivacyInfo.xcprivacy"
expect_failure vision-missing-privacy-manifest 'zero-collection privacy manifest.*missing' run_verifier "$vision_fixture" visionos
create_fixture "$vision_fixture" visionos xrOS false

rm "$vision_fixture/export/Payload/QuakeSignal.app/quakesignal_japanese_voice.caf"
expect_failure vision-missing-japanese-voice 'Japanese Safety Voice audio.*missing' run_verifier "$vision_fixture" visionos

echo "Signed Apple artifact verifier mutation tests passed."
