#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: capture-ios-screenshot-set.sh <absolute-output-directory>

Builds once and captures the exact ten English iPhone 6.5-inch/iPad 13-inch
frames from exactly two disposable simulators. The complete source-addressed
Debug evidence set is published atomically and remains explicitly unapproved.
USAGE
}

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 64
fi
if [ -n "${QUAKESIGNAL_SCREENSHOT_LOCALE:-}" ] && \
   [ "$QUAKESIGNAL_SCREENSHOT_LOCALE" != "en" ]; then
  echo "error: the reviewed iOS/iPadOS set contains English (U.S.) only" >&2
  exit 64
fi

requested_output="$1"
if [[ "$requested_output" != /* ]]; then
  echo "error: output directory must be absolute" >&2
  exit 64
fi

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
ios_root="$(cd "$script_dir/.." && pwd -P)"
repo_root="$(cd "$ios_root/.." && pwd -P)"
# shellcheck source=screenshot-process-guard.sh
. "$script_dir/screenshot-process-guard.sh"
debug_local_override="$repo_root/ios/QuakeSignal/Supporting/Debug.local.xcconfig"
manifest_file="ios/AppStore/screenshot-manifest-v1.1-build17.template.json"
manifest_path="$repo_root/$manifest_file"
output_parent="$(dirname "$requested_output")"
if [ ! -d "$output_parent" ] || [ -L "$output_parent" ]; then
  echo "error: output parent must already be a plain canonical directory" >&2
  exit 64
fi
output_parent="$(cd "$output_parent" && pwd -P)"
output="$output_parent/$(basename "$requested_output")"
if [ "$requested_output" != "$output" ]; then
  echo "error: output directory must be a canonical absolute path" >&2
  exit 64
fi
case "$output" in
  "$repo_root"|"$repo_root"/*)
    echo "error: screenshot output must be outside the repository: $repo_root" >&2
    exit 64
    ;;
esac
output_parent_identity="$(quakesignal_screenshot_capture_parent_identity "$output_parent")" || {
  echo "error: could not bind the canonical screenshot-set output parent identity" >&2
  exit 64
}
if [ -e "$output" ] || [ -L "$output" ]; then
  echo "error: refusing to overwrite existing capture directory: $output" >&2
  exit 73
fi

for required_command in git xcodebuild xcrun ruby shasum uname ditto; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "error: required command not found: $required_command" >&2
    exit 69
  fi
done

source_commit="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}')"
if [[ ! "$source_commit" =~ ^[0-9a-f]{40}$ ]] || \
   [ -n "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]; then
  echo "error: iOS/iPadOS screenshot sets require an exact clean source commit" >&2
  exit 65
fi
if [ -e "$debug_local_override" ] || [ -L "$debug_local_override" ]; then
  echo "error: ignored Debug.local.xcconfig is forbidden for exact screenshot sets" >&2
  exit 65
fi
manifest_sha256="$(shasum -a 256 "$manifest_path" | awk '{ print $1 }')"
commit_manifest_sha256="$(git -C "$repo_root" show "$source_commit:$manifest_file" | shasum -a 256 | awk '{ print $1 }')" || {
  echo "error: iOS/iPadOS plan is unavailable at the source commit" >&2
  exit 65
}
if [ "$manifest_sha256" != "$commit_manifest_sha256" ]; then
  echo "error: iOS/iPadOS plan is not frozen at the source commit" >&2
  exit 65
fi

temporary_root="$(mktemp -d "$output_parent/.quakesignal-ios-set.XXXXXX")"
temporary_root_identity="$(quakesignal_screenshot_capture_directory_identity "$temporary_root")"
payload="$temporary_root/payload"
plan_tsv="$temporary_root/plan.tsv"
build_log="$temporary_root/xcodebuild.log"
build_settings="$temporary_root/build-settings.txt"
validator="$temporary_root/ios-screenshot-content-validator"
iphone_simulator_id=""
ipad_simulator_id=""
iphone_simulator_name=""
ipad_simulator_name=""
simulator_lease_token=""
simulator_lease_file=""
simulator_lease_active=false
quakesignal_screenshot_active_child_pid=""
mkdir -p \
  "$payload/en-US/iphone-6.5" \
  "$payload/en-US/ipad-13" \
  "$payload/app-logs" \
  "$payload/build-logs" \
  "$payload/build-bindings" \
  "$payload/build-lists" \
  "$payload/build-project-evidence" \
  "$payload/build-source-snapshots" \
  "$payload/post-build-source-snapshots" \
  "$payload/build-results" \
  "$payload/build-settings" \
  "$payload/build-swift-inputs" \
  "$payload/frame-capture-evidence" \
  "$payload/install-evidence" \
  "$payload/install-logs" \
  "$payload/launch-evidence" \
  "$payload/raw-simulator-captures" \
  "$payload/semantic-evidence" \
  "$payload/semantic-rejections" \
  "$payload/simulator-absence-evidence" \
  "$payload/transformation-evidence"
payload_identity="$(quakesignal_screenshot_capture_directory_identity "$payload")"

cleanup() {
  quakesignal_screenshot_stop_processes "$quakesignal_screenshot_active_child_pid"
  quakesignal_screenshot_active_child_pid=""
  if ! quakesignal_screenshot_parent_identity_matches "$output_parent" "$output_parent_identity"; then
    echo "warning: screenshot-set output parent identity changed; preserving the original temp tree and lease for recovery" >&2
    return
  fi
  if [ "$simulator_lease_active" = true ] && [ -f "$simulator_lease_file" ] && [ ! -L "$simulator_lease_file" ]; then
    cleanup_inventory="$temporary_root/cleanup-owned-simulators.json"
    xcrun simctl list devices -j >"$cleanup_inventory" 2>/dev/null || true
    if [ -z "$iphone_simulator_id" ]; then
      iphone_simulator_id="$(/usr/bin/ruby "$script_dir/ios-screenshot-simulator-lease.rb" resolve \
        "$simulator_lease_file" "$simulator_lease_token" "$cleanup_inventory" iphone-6.5 2>/dev/null || true)"
    fi
    if [ -z "$ipad_simulator_id" ]; then
      ipad_simulator_id="$(/usr/bin/ruby "$script_dir/ios-screenshot-simulator-lease.rb" resolve \
        "$simulator_lease_file" "$simulator_lease_token" "$cleanup_inventory" ipad-13 2>/dev/null || true)"
    fi
  fi
  for simulator_id in "$iphone_simulator_id" "$ipad_simulator_id"; do
    if [ -n "$simulator_id" ]; then
      xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
      xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
    fi
  done
  quakesignal_screenshot_remove_bound_tree \
    "$temporary_root" "$output_parent" "$output_parent_identity" "$temporary_root_identity" ||
    echo "warning: could not remove the identity-bound screenshot-set temp tree" >&2
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

capture_absence_query() {
  local query="$1"
  local destination="$2"
  local attempt=0
  local candidate="$temporary_root/absence-query-$(basename "$destination").json"
  while [ "$attempt" -lt 20 ]; do
    quakesignal_screenshot_run_tracked xcrun simctl list devices "$query" -j >"$candidate"
    if /usr/bin/ruby -rjson -e '
      record = JSON.parse(File.read(ARGV.fetch(0)))
      abort "unexpected simctl schema" unless record.is_a?(Hash) && record.keys == ["devices"]
      devices = record.fetch("devices")
      abort "device remains" unless devices.is_a?(Hash) && devices.values.all? { |items| items.is_a?(Array) && items.empty? }
    ' "$candidate"; then
      mv "$candidate" "$destination"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  echo "error: disposable simulator remained visible after exact delete query: $query" >&2
  return 70
}

complete_set_simulator_cleanup() {
  if ! quakesignal_screenshot_parent_identity_matches "$output_parent" "$output_parent_identity"; then
    echo "error: screenshot-set output parent changed before simulator cleanup" >&2
    return 65
  fi
  if [ "$simulator_lease_active" != true ] || [ ! -f "$simulator_lease_file" ] || \
     [ -L "$simulator_lease_file" ] || [ -z "$iphone_simulator_id" ] || [ -z "$ipad_simulator_id" ]; then
    echo "error: set cleanup lacks its exact assigned persistent simulator lease" >&2
    return 65
  fi
  cp "$simulator_lease_file" "$payload/simulator-lease-evidence.json"
  for simulator_id in "$iphone_simulator_id" "$ipad_simulator_id"; do
    quakesignal_screenshot_run_tracked xcrun simctl terminate \
      "$simulator_id" com.quakesignal.app >/dev/null 2>&1 || true
    quakesignal_screenshot_run_tracked xcrun simctl shutdown "$simulator_id"
    quakesignal_screenshot_run_tracked xcrun simctl delete "$simulator_id"
  done
  capture_absence_query \
    "$iphone_simulator_id" "$payload/simulator-absence-evidence/iphone-6.5-uuid.json"
  capture_absence_query \
    "$iphone_simulator_name" "$payload/simulator-absence-evidence/iphone-6.5-name.json"
  capture_absence_query \
    "$ipad_simulator_id" "$payload/simulator-absence-evidence/ipad-13-uuid.json"
  capture_absence_query \
    "$ipad_simulator_name" "$payload/simulator-absence-evidence/ipad-13-name.json"
  cleanup_verified_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  /usr/bin/ruby "$script_dir/ios-screenshot-simulator-lease.rb" complete \
    "$simulator_lease_file" "$simulator_lease_token" \
    "$payload/simulator-lease-evidence.json" "$payload/simulator-absence-evidence" \
    "$payload/simulator-cleanup-evidence.json" "$cleanup_verified_at"
  if [ -e "$simulator_lease_file" ] || [ -L "$simulator_lease_file" ]; then
    echo "error: verified set-simulator lease was not retired" >&2
    return 70
  fi
  simulator_lease_active=false
  iphone_simulator_id=""
  ipad_simulator_id=""
}

configure_ipados_full_screen_apps_mode() {
  local simulator_id="$1"
  local runtime_identifier="$2"
  local windowing_enabled=""

  # iPadOS 26 Simulator defaults to Windowed Apps. simctl captures the
  # complete device in that mode, not just the app's floating window. This is
  # a disposable capture device, so use the Settings-equivalent defaults and
  # reboot it before recording a full-device App Store candidate.
  case "$runtime_identifier" in
    com.apple.CoreSimulator.SimRuntime.iOS-2[6-9]-*|com.apple.CoreSimulator.SimRuntime.iOS-[3-9][0-9]-*) ;;
    *) return 0 ;;
  esac

  windowing_enabled="$(quakesignal_screenshot_run_tracked xcrun simctl spawn \
    "$simulator_id" defaults read com.apple.springboard SBChamoisWindowingEnabled 2>/dev/null || true)"
  if [ "$(printf '%s' "$windowing_enabled" | tr -d '[:space:]')" = "0" ]; then
    return 0
  fi

  for key in \
    SBChamoisWindowingEnabled \
    SBMedusaMultitaskingEnabled \
    SBFlexibleWindowingPreviouslyEnabledAutomaticStageCreation; do
    quakesignal_screenshot_run_tracked xcrun simctl spawn \
      "$simulator_id" defaults write com.apple.springboard "$key" -bool false
  done
  quakesignal_screenshot_run_tracked xcrun simctl shutdown "$simulator_id"
  quakesignal_screenshot_run_tracked xcrun simctl boot "$simulator_id"
  quakesignal_screenshot_run_tracked xcrun simctl bootstatus "$simulator_id" -b

  windowing_enabled="$(quakesignal_screenshot_run_tracked xcrun simctl spawn \
    "$simulator_id" defaults read com.apple.springboard SBChamoisWindowingEnabled)"
  if [ "$(printf '%s' "$windowing_enabled" | tr -d '[:space:]')" != "0" ]; then
    echo "error: disposable iPad screenshot simulator did not enter Full Screen Apps mode" >&2
    exit 69
  fi
}

/usr/bin/ruby "$script_dir/ios-screenshot-plan.rb" --tsv >"$plan_tsv"
if [ "$(wc -l <"$plan_tsv" | tr -d ' ')" != "10" ]; then
  echo "error: reviewed iOS/iPadOS plan must contain exactly ten frames" >&2
  exit 65
fi
if [ "$(cut -f2 "$plan_tsv" | sort -u | tr '\n' ' ')" != "ipad-13 iphone-6.5 " ]; then
  echo "error: reviewed plan must contain exactly the two approved display classes" >&2
  exit 65
fi

runtime_identifier="$(xcrun simctl list runtimes available -j | /usr/bin/ruby -rjson -e '
  runtimes = JSON.parse(STDIN.read).fetch("runtimes")
  matches = runtimes.select { |runtime| runtime["isAvailable"] != false && runtime.fetch("name", "").start_with?("iOS") }
  exit 1 if matches.empty?
  chosen = matches.max_by { |runtime| runtime.fetch("version", "0").scan(/[0-9]+/).map(&:to_i) }
  puts chosen.fetch("identifier")
')" || {
  echo "error: no available iOS Simulator runtime" >&2
  exit 69
}
available_device_types="$(xcrun simctl list devicetypes -j)"
assert_device_type() {
  local identifier="$1"
  local expected_name="$2"
  /usr/bin/ruby -rjson -e '
    identifier, expected_name = ARGV
    type = JSON.parse(STDIN.read).fetch("devicetypes").find { |candidate| candidate.fetch("identifier") == identifier }
    exit 1 unless type && type.fetch("name") == expected_name
  ' "$identifier" "$expected_name" <<<"$available_device_types"
}
iphone_device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max"
ipad_device_type="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB"
if ! assert_device_type "$iphone_device_type" "iPhone 11 Pro Max" || \
   ! assert_device_type "$ipad_device_type" "iPad Pro 13-inch (M4)"; then
  echo "error: one or both exact reviewed simulator device types are unavailable" >&2
  exit 69
fi

simulator_lease_token="$(/usr/bin/ruby -rsecurerandom -e 'print SecureRandom.hex(16)')"
iphone_simulator_name="QuakeSignal iPhone screenshot set $simulator_lease_token"
ipad_simulator_name="QuakeSignal iPad screenshot set $simulator_lease_token"
simulator_lease_file="$output_parent/.quakesignal-ios-simulator-lease-$simulator_lease_token.json"
lease_specs="$(/usr/bin/ruby -rjson -e '
  puts JSON.generate([
    {
      "displayClass" => "iphone-6.5", "name" => ARGV.fetch(0),
      "runtimeIdentifier" => ARGV.fetch(2), "deviceTypeIdentifier" => ARGV.fetch(3),
    },
    {
      "displayClass" => "ipad-13", "name" => ARGV.fetch(1),
      "runtimeIdentifier" => ARGV.fetch(2), "deviceTypeIdentifier" => ARGV.fetch(4),
    },
  ])
' "$iphone_simulator_name" "$ipad_simulator_name" "$runtime_identifier" \
  "$iphone_device_type" "$ipad_device_type")"
/usr/bin/ruby "$script_dir/ios-screenshot-simulator-lease.rb" create \
  "$simulator_lease_file" "$source_commit" "$simulator_lease_token" "$$" "$lease_specs"
simulator_lease_active=true
iphone_create_result="$temporary_root/iphone-simctl-create.txt"
ipad_create_result="$temporary_root/ipad-simctl-create.txt"
quakesignal_screenshot_run_tracked xcrun simctl create \
  "$iphone_simulator_name" "$iphone_device_type" "$runtime_identifier" >"$iphone_create_result"
iphone_simulator_id="$(tr -d '[:space:]' <"$iphone_create_result")"
/usr/bin/ruby "$script_dir/ios-screenshot-simulator-lease.rb" assign \
  "$simulator_lease_file" "$simulator_lease_token" iphone-6.5 "$iphone_simulator_id"
quakesignal_screenshot_run_tracked xcrun simctl create \
  "$ipad_simulator_name" "$ipad_device_type" "$runtime_identifier" >"$ipad_create_result"
ipad_simulator_id="$(tr -d '[:space:]' <"$ipad_create_result")"
/usr/bin/ruby "$script_dir/ios-screenshot-simulator-lease.rb" assign \
  "$simulator_lease_file" "$simulator_lease_token" ipad-13 "$ipad_simulator_id"
if [ -z "$iphone_simulator_id" ] || [ -z "$ipad_simulator_id" ] || \
   [ "$iphone_simulator_id" = "$ipad_simulator_id" ]; then
  echo "error: exactly two distinct disposable simulators were not created" >&2
  exit 69
fi
quakesignal_screenshot_run_tracked xcrun simctl boot "$iphone_simulator_id"
quakesignal_screenshot_run_tracked xcrun simctl boot "$ipad_simulator_id"
quakesignal_screenshot_run_tracked xcrun simctl bootstatus "$iphone_simulator_id" -b
quakesignal_screenshot_run_tracked xcrun simctl bootstatus "$ipad_simulator_id" -b
configure_ipados_full_screen_apps_mode "$ipad_simulator_id" "$runtime_identifier"

derived_data="$temporary_root/DerivedData"
if [ -e "$derived_data" ] || [ -L "$derived_data" ]; then
  echo "error: unique screenshot DerivedData root unexpectedly exists before build" >&2
  exit 65
fi
mkdir -p "$derived_data/Results"
result_bundle="$derived_data/Results/QuakeSignal-build.xcresult"
result_bundle_archive="$derived_data/Results/QuakeSignal-build.xcresult.zip"
build_list="$temporary_root/xcode-list.json"

build_ios_root="$temporary_root/BuildSource/ios"
build_source_evidence="$temporary_root/build-source-evidence.json"
mkdir "$temporary_root/BuildSource"
host_architecture="$(uname -m)"
case "$host_architecture" in
  arm64|x86_64) ;;
  *)
    echo "error: unsupported screenshot-build host architecture: $host_architecture" >&2
    exit 69
    ;;
esac
build_overrides=(
  "SYMROOT=$derived_data/Build/Products"
  "OBJROOT=$derived_data/Build/Intermediates.noindex"
  "BUILD_DIR=$derived_data/Build/Products"
  "BUILD_ROOT=$derived_data/Build"
  "CONFIGURATION_BUILD_DIR=$derived_data/Build/Products/Debug-iphonesimulator"
  "SHARED_PRECOMPS_DIR=$derived_data/SharedPrecompiledHeaders"
  "CLANG_MODULE_CACHE_PATH=$derived_data/ModuleCache.noindex"
  "DSTROOT=$derived_data/Dst"
  "ARCHS=$host_architecture"
  "ONLY_ACTIVE_ARCH=NO"
  "CODE_SIGNING_ALLOWED=NO"
  "CODE_SIGNING_REQUIRED=NO"
  "CODE_SIGN_IDENTITY="
  "COMPILER_INDEX_STORE_ENABLE=NO"
)
quakesignal_screenshot_run_tracked /usr/bin/ruby \
  "$script_dir/prepare-ios-screenshot-build-source.rb" \
  "$source_commit" "$build_ios_root" "$build_source_evidence"
quakesignal_screenshot_run_tracked xcodebuild -list -json \
  -project "$build_ios_root/QuakeSignal.xcodeproj" >"$build_list"

prebuild_source_snapshot="$temporary_root/pre-build-source-snapshot.json"
quakesignal_screenshot_run_tracked /usr/bin/ruby \
  "$script_dir/prepare-ios-screenshot-build-source.rb" snapshot \
  "$source_commit" "$build_ios_root" "$build_source_evidence" pre-build \
  "$prebuild_source_snapshot"

postbuild_source_snapshot="$temporary_root/post-build-source-snapshot.json"
quakesignal_screenshot_run_tracked xcodebuild build \
  -project "$build_ios_root/QuakeSignal.xcodeproj" \
  -scheme QuakeSignal \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  "${build_overrides[@]}" >"$build_log" 2>&1
quakesignal_screenshot_run_tracked /usr/bin/ruby \
  "$script_dir/prepare-ios-screenshot-build-source.rb" snapshot \
  "$source_commit" "$build_ios_root" "$build_source_evidence" post-build \
  "$postbuild_source_snapshot"
quakesignal_screenshot_run_tracked xcodebuild -showBuildSettings -json \
  -project "$build_ios_root/QuakeSignal.xcodeproj" \
  -scheme QuakeSignal \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_data" \
  "${build_overrides[@]}" >"$build_settings"
if [ ! -d "$result_bundle" ] || [ -L "$result_bundle" ]; then
  echo "error: xcodebuild did not retain a plain xcresult bundle" >&2
  exit 70
fi
quakesignal_screenshot_run_tracked /usr/bin/ditto -c -k --norsrc --keepParent \
  "$result_bundle" "$result_bundle_archive"
parsed_build_settings="$(/usr/bin/ruby "$script_dir/parse-ios-screenshot-build-settings.rb" <"$build_settings")"
target_build_dir="$(/usr/bin/ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("targetBuildDirectory")' <<<"$parsed_build_settings")"
wrapper_name="$(/usr/bin/ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("wrapperName")' <<<"$parsed_build_settings")"
app_path="$target_build_dir/$wrapper_name"
if [ ! -d "$app_path" ] || [ -L "$app_path" ]; then
  echo "error: could not locate the single prebuilt simulator app" >&2
  exit 70
fi
/usr/bin/ruby -rjson -rpathname -e '
  root = Pathname.new(ARGV.fetch(0))
  abort "DerivedData root is not canonical" unless root.realpath == root
  [ARGV.fetch(1), ARGV.fetch(2), ARGV.fetch(3)].each do |value|
    real = Pathname.new(value).realpath.to_s
    abort "build output escaped DerivedData" unless real.start_with?("#{root}#{File::SEPARATOR}")
  end
  settings = JSON.parse(Pathname.new(ARGV.fetch(4)).read).find { |record| record["target"] == "QuakeSignal" }.fetch("buildSettings")
  %w[BUILD_DIR BUILD_ROOT CONFIGURATION_BUILD_DIR OBJROOT SYMROOT SHARED_PRECOMPS_DIR CLANG_MODULE_CACHE_PATH DSTROOT].each do |key|
    path = Pathname.new(settings.fetch(key))
    next unless path.exist?
    abort "#{key} escaped DerivedData" unless path.realpath.to_s.start_with?("#{root}#{File::SEPARATOR}")
  end
' "$derived_data" "$app_path" "$result_bundle" "$result_bundle_archive" "$build_settings" || {
  echo "error: resolved build outputs escaped the fresh screenshot DerivedData root" >&2
  exit 65
}
build_binding="$temporary_root/build-binding.json"
swift_inputs="$temporary_root/swift-inputs.json"
quakesignal_screenshot_run_tracked /usr/bin/ruby \
  "$script_dir/ios-screenshot-swift-inputs.rb" \
  "$source_commit" "$build_source_evidence" "$build_log" \
  "$derived_data" "$build_ios_root" "$host_architecture" "$swift_inputs"
quakesignal_screenshot_run_tracked /usr/bin/ruby \
  "$script_dir/ios-screenshot-build-binding.rb" write \
  "$source_commit" "$build_source_evidence" "$build_settings" \
  "$build_log" "$build_list" "$result_bundle_archive" "$swift_inputs" "$app_path" "$build_binding" \
  "$prebuild_source_snapshot" "$postbuild_source_snapshot" "$build_ios_root"
quakesignal_screenshot_run_tracked xcrun swiftc -O \
  "$script_dir/ios-screenshot-content-validator.swift" -o "$validator"

while IFS=$'\t' read -r selector display_class device_type planned_file width height; do
  case "$display_class:$device_type:$width:$height" in
    iphone-6.5:com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max:1242:2688)
      simulator_id="$iphone_simulator_id"
      device_model="iPhone 11 Pro Max"
      ;;
    ipad-13:com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB:2064:2752)
      simulator_id="$ipad_simulator_id"
      device_model="iPad Pro 13-inch (M4)"
      ;;
    *)
      echo "error: plan entry drifted after the two exact simulators were created" >&2
      exit 65
      ;;
  esac

  single_package="$temporary_root/single-$selector"
  quakesignal_screenshot_run_tracked env \
    QUAKESIGNAL_IOS_SCREENSHOT_PREBUILT_APP="$app_path" \
    QUAKESIGNAL_IOS_SCREENSHOT_BUILD_LOG="$build_log" \
    QUAKESIGNAL_IOS_SCREENSHOT_BUILD_SOURCE_EVIDENCE="$build_source_evidence" \
    QUAKESIGNAL_IOS_SCREENSHOT_PREBUILD_SOURCE_SNAPSHOT="$prebuild_source_snapshot" \
    QUAKESIGNAL_IOS_SCREENSHOT_POSTBUILD_SOURCE_SNAPSHOT="$postbuild_source_snapshot" \
    QUAKESIGNAL_IOS_SCREENSHOT_BUILD_SETTINGS="$build_settings" \
    QUAKESIGNAL_IOS_SCREENSHOT_BUILD_LIST="$build_list" \
    QUAKESIGNAL_IOS_SCREENSHOT_RESULT_BUNDLE_ARCHIVE="$result_bundle_archive" \
    QUAKESIGNAL_IOS_SCREENSHOT_SWIFT_INPUTS="$swift_inputs" \
    QUAKESIGNAL_IOS_SCREENSHOT_BUILD_BINDING="$build_binding" \
    QUAKESIGNAL_IOS_SCREENSHOT_SIMULATOR_UDID="$simulator_id" \
    QUAKESIGNAL_IOS_SCREENSHOT_SIMULATOR_LEASE="$simulator_lease_file" \
    QUAKESIGNAL_IOS_SCREENSHOT_SIMULATOR_LEASE_TOKEN="$simulator_lease_token" \
    QUAKESIGNAL_IOS_SCREENSHOT_RUNTIME_IDENTIFIER="$runtime_identifier" \
    QUAKESIGNAL_IOS_SCREENSHOT_DEVICE_TYPE_IDENTIFIER="$device_type" \
    QUAKESIGNAL_IOS_SCREENSHOT_DEVICE_MODEL="$device_model" \
    QUAKESIGNAL_IOS_SCREENSHOT_VALIDATOR="$validator" \
      "$script_dir/capture-ios-screenshot.sh" "$selector" "$single_package"

  mv "$single_package/$planned_file" "$payload/$planned_file"
  mv "$single_package/app-logs/$selector.stdout.log" "$payload/app-logs/$selector.stdout.log"
  mv "$single_package/app-logs/$selector.stderr.log" "$payload/app-logs/$selector.stderr.log"
  mv "$single_package/build-logs/$selector.log" "$payload/build-logs/$selector.log"
  mv "$single_package/build-bindings/$selector.json" "$payload/build-bindings/$selector.json"
  mv "$single_package/build-lists/$selector.json" "$payload/build-lists/$selector.json"
  mv "$single_package/build-project-evidence/$selector.json" "$payload/build-project-evidence/$selector.json"
  mv "$single_package/build-source-snapshots/$selector.json" "$payload/build-source-snapshots/$selector.json"
  mv "$single_package/post-build-source-snapshots/$selector.json" "$payload/post-build-source-snapshots/$selector.json"
  mv "$single_package/build-settings/$selector.json" "$payload/build-settings/$selector.json"
  mv "$single_package/build-swift-inputs/$selector.json" "$payload/build-swift-inputs/$selector.json"
  mv "$single_package/build-results/$selector.xcresult.zip" "$payload/build-results/$selector.xcresult.zip"
  mv "$single_package/frame-capture-evidence/$selector.json" "$payload/frame-capture-evidence/$selector.json"
  mv "$single_package/install-evidence/$selector.json" "$payload/install-evidence/$selector.json"
  mv "$single_package/install-logs/$selector.log" "$payload/install-logs/$selector.log"
  mv "$single_package/launch-evidence/$selector.json" "$payload/launch-evidence/$selector.json"
  mv "$single_package/raw-simulator-captures/$selector.png" "$payload/raw-simulator-captures/$selector.png"
  mv "$single_package/semantic-evidence/$selector-raw.json" "$payload/semantic-evidence/$selector-raw.json"
  mv "$single_package/semantic-evidence/$selector-final.json" "$payload/semantic-evidence/$selector-final.json"
  rejection="$single_package/semantic-rejections/$selector-attempt-1.json"
  rejection_image="$single_package/semantic-rejections/$selector-attempt-1.png"
  if [ -f "$rejection" ] && [ ! -L "$rejection" ]; then
    if [ ! -f "$rejection_image" ] || [ -L "$rejection_image" ]; then
      echo "error: semantic retry evidence is missing its rejected raw PNG" >&2
      exit 65
    fi
    mv "$rejection" "$payload/semantic-rejections/$selector-attempt-1.json"
    mv "$rejection_image" "$payload/semantic-rejections/$selector-attempt-1.png"
  elif [ -e "$rejection_image" ] || [ -L "$rejection_image" ]; then
    echo "error: rejected raw PNG exists without semantic rejection evidence" >&2
    exit 65
  fi
  mv "$single_package/transformation-evidence/$selector.json" "$payload/transformation-evidence/$selector.json"
done <"$plan_tsv"

complete_set_simulator_cleanup

/usr/bin/ruby "$script_dir/assemble-ios-screenshot-provenance.rb" \
  "$payload" "$payload/capture-provenance.json"
if [ ! -s "$payload/capture-provenance.json" ]; then
  echo "error: aggregate iOS/iPadOS provenance was not assembled" >&2
  exit 65
fi
/usr/bin/ruby "$script_dir/seal-screenshot-capture-package.rb" \
  ios-ipados "$source_commit" "$payload" "$payload/capture-package-manifest.json"
if [ "$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}')" != "$source_commit" ] || \
   [ -n "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]; then
  echo "error: source commit/tree changed during iOS/iPadOS set capture" >&2
  exit 65
fi
if [ -e "$debug_local_override" ] || [ -L "$debug_local_override" ]; then
  echo "error: ignored Debug.local.xcconfig appeared during iOS/iPadOS set capture" >&2
  exit 65
fi
if [ -e "$output" ] || [ -L "$output" ]; then
  echo "error: output appeared during publication; refusing to overwrite" >&2
  exit 73
fi
quakesignal_screenshot_publish_directory \
  "$payload" "$output" "$output_parent_identity" "$temporary_root_identity" "$payload_identity" || {
  echo "error: screenshot-set output parent changed during atomic publication" >&2
  exit 73
}
echo "Captured exact unapproved ten-frame iOS/iPadOS screenshot set: $output"
echo "No screenshot in this directory is approved for upload."
