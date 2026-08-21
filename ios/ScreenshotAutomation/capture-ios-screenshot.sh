#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: capture-ios-screenshot.sh <ios-frame-selector> <absolute-output-directory>

Captures one exact reviewed iPhone/iPad frame from a clean Debug source commit.
The atomic unapproved output contains the native PNG, opaque JPEG, semantic
validation, build/install/launch evidence, and a source-addressed sidecar.

Internal set-capture environment (validated before use):
  QUAKESIGNAL_IOS_SCREENSHOT_PREBUILT_APP=/absolute/QuakeSignal.app
  QUAKESIGNAL_IOS_SCREENSHOT_BUILD_LOG=/absolute/xcodebuild.log
  QUAKESIGNAL_IOS_SCREENSHOT_BUILD_SOURCE_EVIDENCE=/absolute/build-source.json
  QUAKESIGNAL_IOS_SCREENSHOT_PREBUILD_SOURCE_SNAPSHOT=/absolute/pre-build-source-snapshot.json
  QUAKESIGNAL_IOS_SCREENSHOT_POSTBUILD_SOURCE_SNAPSHOT=/absolute/post-build-source-snapshot.json
  QUAKESIGNAL_IOS_SCREENSHOT_BUILD_SETTINGS=/absolute/build-settings.json
  QUAKESIGNAL_IOS_SCREENSHOT_BUILD_LIST=/absolute/xcode-list.json
  QUAKESIGNAL_IOS_SCREENSHOT_RESULT_BUNDLE_ARCHIVE=/absolute/xcresult.zip
  QUAKESIGNAL_IOS_SCREENSHOT_SWIFT_INPUTS=/absolute/swift-inputs.json
  QUAKESIGNAL_IOS_SCREENSHOT_BUILD_BINDING=/absolute/build-binding.json
  QUAKESIGNAL_IOS_SCREENSHOT_SIMULATOR_UDID=<disposable simulator UDID>
  QUAKESIGNAL_IOS_SCREENSHOT_SIMULATOR_LEASE=/absolute/parent-owned-lease.json
  QUAKESIGNAL_IOS_SCREENSHOT_SIMULATOR_LEASE_TOKEN=<32 lowercase hex characters>
  QUAKESIGNAL_IOS_SCREENSHOT_RUNTIME_IDENTIFIER=<runtime identifier>
  QUAKESIGNAL_IOS_SCREENSHOT_DEVICE_TYPE_IDENTIFIER=<exact device type>
  QUAKESIGNAL_IOS_SCREENSHOT_DEVICE_MODEL=<exact model name>
  QUAKESIGNAL_IOS_SCREENSHOT_VALIDATOR=/absolute/validator-binary
USAGE
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 64
fi

frame_selector="$1"
requested_output="$2"
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
ios_root="$(cd "$script_dir/.." && pwd -P)"
repo_root="$(cd "$ios_root/.." && pwd -P)"
# shellcheck source=screenshot-process-guard.sh
. "$script_dir/screenshot-process-guard.sh"
debug_local_override="$repo_root/ios/QuakeSignal/Supporting/Debug.local.xcconfig"
manifest_file="ios/AppStore/screenshot-manifest-v1.1-build8.template.json"
manifest_path="$repo_root/$manifest_file"
bundle_identifier="com.quakesignal.app"

if [[ "$requested_output" != /* ]]; then
  echo "error: output directory must be absolute" >&2
  exit 64
fi
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
  echo "error: could not bind the canonical screenshot output parent identity" >&2
  exit 64
}
if [ -e "$output" ] || [ -L "$output" ]; then
  echo "error: refusing to overwrite existing capture directory: $output" >&2
  exit 73
fi

plan_entry="$(/usr/bin/ruby "$script_dir/ios-screenshot-plan.rb" --tsv | \
  awk -F '\t' -v selector="$frame_selector" '$1 == selector { print; matches += 1 } END { exit(matches == 1 ? 0 : 1) }')" || {
  echo "error: frame selector '$frame_selector' is not in the exact reviewed iOS/iPadOS plan" >&2
  exit 64
}
IFS=$'\t' read -r planned_selector display_class expected_device_type planned_file expected_width expected_height <<<"$plan_entry"
if [ "$planned_selector" != "$frame_selector" ]; then
  echo "error: selector disagrees with the exact iOS/iPadOS plan" >&2
  exit 65
fi
case "$display_class:$expected_width:$expected_height" in
  iphone-6.5:1242:2688) expected_device_model="iPhone 11 Pro Max" ;;
  ipad-13:2064:2752) expected_device_model="iPad Pro 13-inch (M4)" ;;
  *)
    echo "error: plan contains an unreviewed display class or pixel size" >&2
    exit 65
    ;;
esac

for required_command in git xcodebuild xcrun ruby sips shasum sw_vers uname ditto; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "error: required command not found: $required_command" >&2
    exit 69
  fi
done
if [ ! -x /usr/libexec/PlistBuddy ]; then
  echo "error: required command not found: /usr/libexec/PlistBuddy" >&2
  exit 69
fi

source_commit="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}')"
if [[ ! "$source_commit" =~ ^[0-9a-f]{40}$ ]] || \
   [ -n "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]; then
  echo "error: iOS/iPadOS screenshots require an exact clean source commit" >&2
  exit 65
fi
if [ -e "$debug_local_override" ] || [ -L "$debug_local_override" ]; then
  echo "error: ignored Debug.local.xcconfig is forbidden for exact screenshot builds" >&2
  exit 65
fi
manifest_sha256="$(shasum -a 256 "$manifest_path" | awk '{ print $1 }')"
plan_manifest_sha256="$(/usr/bin/ruby "$script_dir/ios-screenshot-plan.rb" --json | \
  /usr/bin/ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("manifestSha256")')"
commit_manifest_sha256="$(git -C "$repo_root" show "$source_commit:$manifest_file" | shasum -a 256 | awk '{ print $1 }')" || {
  echo "error: iOS/iPadOS plan is unavailable at the source commit" >&2
  exit 65
}
if [ "$manifest_sha256" != "$plan_manifest_sha256" ] || \
   [ "$manifest_sha256" != "$commit_manifest_sha256" ]; then
  echo "error: iOS/iPadOS plan hash is not frozen at the source commit" >&2
  exit 65
fi

temporary_root="$(mktemp -d "$output_parent/.quakesignal-ios-frame.XXXXXX")"
temporary_root_identity="$(quakesignal_screenshot_capture_directory_identity "$temporary_root")"
payload="$temporary_root/payload"
created_simulator_id=""
simulator_name=""
simulator_lease_file=""
simulator_lease_token=""
owns_simulator=false
app_pid=""
quakesignal_screenshot_active_child_pid=""
mkdir -p \
  "$payload/$(dirname "$planned_file")" \
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
    echo "warning: screenshot output parent identity changed; preserving the original temp tree and lease for recovery" >&2
    return
  fi
  if [ -n "${simulator_id:-}" ]; then
    xcrun simctl terminate "$simulator_id" "$bundle_identifier" >/dev/null 2>&1 || true
  fi
  if [ "$owns_simulator" = true ] && [ -f "$simulator_lease_file" ] && [ ! -L "$simulator_lease_file" ]; then
    cleanup_id="$created_simulator_id"
    if [ -z "$cleanup_id" ]; then
      cleanup_inventory="$temporary_root/cleanup-owned-simulator.json"
      xcrun simctl list devices -j >"$cleanup_inventory" 2>/dev/null || true
      cleanup_id="$(/usr/bin/ruby "$script_dir/ios-screenshot-simulator-lease.rb" resolve \
        "$simulator_lease_file" "$simulator_lease_token" "$cleanup_inventory" "$display_class" 2>/dev/null || true)"
    fi
    if [ -n "$cleanup_id" ]; then
      xcrun simctl shutdown "$cleanup_id" >/dev/null 2>&1 || true
      xcrun simctl delete "$cleanup_id" >/dev/null 2>&1 || true
    fi
  fi
  quakesignal_screenshot_remove_bound_tree \
    "$temporary_root" "$output_parent" "$output_parent_identity" "$temporary_root_identity" ||
    echo "warning: could not remove the identity-bound screenshot temp tree" >&2
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

complete_owned_simulator_cleanup() {
  [ "$owns_simulator" = true ] || return 0
  if ! quakesignal_screenshot_parent_identity_matches "$output_parent" "$output_parent_identity"; then
    echo "error: screenshot output parent changed before owned simulator cleanup" >&2
    return 65
  fi
  if [ -z "$created_simulator_id" ] || [ ! -f "$simulator_lease_file" ] || [ -L "$simulator_lease_file" ]; then
    echo "error: owned simulator cleanup lacks its assigned persistent lease" >&2
    return 65
  fi
  cp "$simulator_lease_file" "$payload/simulator-lease-evidence.json"
  quakesignal_screenshot_run_tracked xcrun simctl terminate \
    "$created_simulator_id" "$bundle_identifier" >/dev/null 2>&1 || true
  quakesignal_screenshot_run_tracked xcrun simctl shutdown "$created_simulator_id"
  quakesignal_screenshot_run_tracked xcrun simctl delete "$created_simulator_id"
  capture_absence_query \
    "$created_simulator_id" "$payload/simulator-absence-evidence/$display_class-uuid.json"
  capture_absence_query \
    "$simulator_name" "$payload/simulator-absence-evidence/$display_class-name.json"
  cleanup_verified_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  /usr/bin/ruby "$script_dir/ios-screenshot-simulator-lease.rb" complete \
    "$simulator_lease_file" "$simulator_lease_token" \
    "$payload/simulator-lease-evidence.json" "$payload/simulator-absence-evidence" \
    "$payload/simulator-cleanup-evidence.json" "$cleanup_verified_at"
  if [ -e "$simulator_lease_file" ] || [ -L "$simulator_lease_file" ]; then
    echo "error: verified owned-simulator lease was not retired" >&2
    return 70
  fi
  owns_simulator=false
  created_simulator_id=""
  simulator_id=""
}

runtime_identifier="${QUAKESIGNAL_IOS_SCREENSHOT_RUNTIME_IDENTIFIER:-}"
simulator_id="${QUAKESIGNAL_IOS_SCREENSHOT_SIMULATOR_UDID:-}"
selected_device_type="${QUAKESIGNAL_IOS_SCREENSHOT_DEVICE_TYPE_IDENTIFIER:-}"
selected_device_model="${QUAKESIGNAL_IOS_SCREENSHOT_DEVICE_MODEL:-}"
if [ -n "$simulator_id" ]; then
  if [ -z "$runtime_identifier" ]; then
    echo "error: reused simulator requires its claimed runtime for observed cross-checking" >&2
    exit 65
  fi
  simulator_lease_file="${QUAKESIGNAL_IOS_SCREENSHOT_SIMULATOR_LEASE:-}"
  simulator_lease_token="${QUAKESIGNAL_IOS_SCREENSHOT_SIMULATOR_LEASE_TOKEN:-}"
  case "$display_class" in
    iphone-6.5) simulator_name="QuakeSignal iPhone screenshot set $simulator_lease_token" ;;
    ipad-13) simulator_name="QuakeSignal iPad screenshot set $simulator_lease_token" ;;
  esac
  if [[ "$simulator_lease_file" != /* ]] || [ ! -f "$simulator_lease_file" ] || \
     [ -L "$simulator_lease_file" ] || [[ ! "$simulator_lease_token" =~ ^[0-9a-f]{32}$ ]]; then
    echo "error: reused simulator requires an exact parent-owned lease and token" >&2
    exit 65
  fi
  /usr/bin/ruby -rpathname -e '
    repo = Pathname.new(ARGV.fetch(0)).realpath.to_s
    lease = Pathname.new(ARGV.fetch(1)).realpath.to_s
    abort "lease is inside repository" if lease == repo || lease.start_with?("#{repo}#{File::SEPARATOR}")
  ' "$repo_root" "$simulator_lease_file" || {
    echo "error: reused simulator lease must remain outside the repository" >&2
    exit 65
  }
  /usr/bin/ruby "$script_dir/ios-screenshot-simulator-lease.rb" verify \
    "$simulator_lease_file" "$source_commit" "$simulator_lease_token" "$PPID" \
    "$display_class" "$simulator_name" "$simulator_id" "$runtime_identifier" "$expected_device_type" || {
      echo "error: reused simulator is not owned by the invoking exact set capture" >&2
      exit 65
    }
else
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
  selected_device_model="$(/usr/bin/ruby -rjson -e '
    identifier = ARGV.fetch(0)
    type = JSON.parse(STDIN.read).fetch("devicetypes").find { |candidate| candidate.fetch("identifier") == identifier }
    abort "missing exact device type" unless type
    puts type.fetch("name")
  ' "$expected_device_type" <<<"$available_device_types")" || {
    echo "error: exact simulator device type is unavailable: $expected_device_type" >&2
    exit 69
  }
  if [ "$selected_device_model" != "$expected_device_model" ]; then
    echo "error: installed device model name disagrees with the reviewed plan" >&2
    exit 69
  fi
  selected_device_type="$expected_device_type"
  simulator_lease_token="$(/usr/bin/ruby -rsecurerandom -e 'print SecureRandom.hex(16)')"
  simulator_name="QuakeSignal $display_class screenshot frame $simulator_lease_token"
  simulator_lease_file="$output_parent/.quakesignal-ios-simulator-lease-$simulator_lease_token.json"
  lease_specs="$(/usr/bin/ruby -rjson -e '
    puts JSON.generate([{
      "displayClass" => ARGV.fetch(0), "name" => ARGV.fetch(1),
      "runtimeIdentifier" => ARGV.fetch(2), "deviceTypeIdentifier" => ARGV.fetch(3),
    }])
  ' "$display_class" "$simulator_name" "$runtime_identifier" "$selected_device_type")"
  /usr/bin/ruby "$script_dir/ios-screenshot-simulator-lease.rb" create \
    "$simulator_lease_file" "$source_commit" "$simulator_lease_token" "$$" "$lease_specs"
  owns_simulator=true
  create_result="$temporary_root/simctl-create.txt"
  if ! quakesignal_screenshot_run_tracked xcrun simctl create \
    "$simulator_name" "$selected_device_type" "$runtime_identifier" >"$create_result"; then
    echo "error: exact simulator could not be created for $display_class" >&2
    exit 69
  fi
  created_simulator_id="$(tr -d '[:space:]' <"$create_result")"
  /usr/bin/ruby "$script_dir/ios-screenshot-simulator-lease.rb" assign \
    "$simulator_lease_file" "$simulator_lease_token" "$display_class" "$created_simulator_id"
  simulator_id="$created_simulator_id"
  quakesignal_screenshot_run_tracked xcrun simctl boot "$simulator_id"
  quakesignal_screenshot_run_tracked xcrun simctl bootstatus "$simulator_id" -b
fi

simulator_devices_json="$temporary_root/simctl-devices.json"
simulator_types_json="$temporary_root/simctl-device-types.json"
xcrun simctl list devices -j >"$simulator_devices_json"
xcrun simctl list devicetypes -j >"$simulator_types_json"
observed_simulator="$(/usr/bin/ruby "$script_dir/resolve-ios-screenshot-simulator.rb" \
  "$simulator_devices_json" "$simulator_types_json" "$simulator_id" \
  "$runtime_identifier" "$expected_device_type" "$expected_device_model" "$simulator_name")" || {
  echo "error: selected simulator does not match the observed exact display-class plan" >&2
  exit 69
}
runtime_identifier="$(/usr/bin/ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("runtimeIdentifier")' <<<"$observed_simulator")"
selected_device_type="$(/usr/bin/ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("deviceTypeIdentifier")' <<<"$observed_simulator")"
selected_device_model="$(/usr/bin/ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("deviceModel")' <<<"$observed_simulator")"
simulator_id="$(/usr/bin/ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("deviceIdentifier")' <<<"$observed_simulator")"

build_log="$payload/build-logs/$frame_selector.log"
build_binding="$payload/build-bindings/$frame_selector.json"
app_path="${QUAKESIGNAL_IOS_SCREENSHOT_PREBUILT_APP:-}"
external_build_log="${QUAKESIGNAL_IOS_SCREENSHOT_BUILD_LOG:-}"
if [ -n "$app_path" ]; then
  external_build_source_evidence="${QUAKESIGNAL_IOS_SCREENSHOT_BUILD_SOURCE_EVIDENCE:-}"
  external_prebuild_source_snapshot="${QUAKESIGNAL_IOS_SCREENSHOT_PREBUILD_SOURCE_SNAPSHOT:-}"
  external_postbuild_source_snapshot="${QUAKESIGNAL_IOS_SCREENSHOT_POSTBUILD_SOURCE_SNAPSHOT:-}"
  external_build_settings="${QUAKESIGNAL_IOS_SCREENSHOT_BUILD_SETTINGS:-}"
  external_build_list="${QUAKESIGNAL_IOS_SCREENSHOT_BUILD_LIST:-}"
  external_result_bundle="${QUAKESIGNAL_IOS_SCREENSHOT_RESULT_BUNDLE_ARCHIVE:-}"
  external_swift_inputs="${QUAKESIGNAL_IOS_SCREENSHOT_SWIFT_INPUTS:-}"
  external_build_binding="${QUAKESIGNAL_IOS_SCREENSHOT_BUILD_BINDING:-}"
  if [[ "$app_path" != /* ]] || [ ! -d "$app_path" ] || [ -L "$app_path" ] || \
     [ -z "$external_build_log" ] || [[ "$external_build_log" != /* ]] || \
     [ ! -f "$external_build_log" ] || [ -L "$external_build_log" ] || \
     [ -z "$external_build_source_evidence" ] || [[ "$external_build_source_evidence" != /* ]] || \
     [ ! -f "$external_build_source_evidence" ] || [ -L "$external_build_source_evidence" ] || \
     [ -z "$external_prebuild_source_snapshot" ] || [[ "$external_prebuild_source_snapshot" != /* ]] || \
     [ ! -f "$external_prebuild_source_snapshot" ] || [ -L "$external_prebuild_source_snapshot" ] || \
     [ -z "$external_postbuild_source_snapshot" ] || [[ "$external_postbuild_source_snapshot" != /* ]] || \
     [ ! -f "$external_postbuild_source_snapshot" ] || [ -L "$external_postbuild_source_snapshot" ]; then
    echo "error: prebuilt app/build-log/build-source/snapshot evidence is not a plain absolute input" >&2
    exit 65
  fi
  if [ -z "$external_build_settings" ] || [[ "$external_build_settings" != /* ]] || \
     [ ! -f "$external_build_settings" ] || [ -L "$external_build_settings" ] || \
     [ -z "$external_build_list" ] || [[ "$external_build_list" != /* ]] || \
     [ ! -f "$external_build_list" ] || [ -L "$external_build_list" ] || \
     [ -z "$external_result_bundle" ] || [[ "$external_result_bundle" != /* ]] || \
     [ ! -f "$external_result_bundle" ] || [ -L "$external_result_bundle" ] || \
     [ -z "$external_swift_inputs" ] || [[ "$external_swift_inputs" != /* ]] || \
     [ ! -f "$external_swift_inputs" ] || [ -L "$external_swift_inputs" ] || \
     [ -z "$external_build_binding" ] || [[ "$external_build_binding" != /* ]] || \
     [ ! -f "$external_build_binding" ] || [ -L "$external_build_binding" ]; then
    echo "error: prebuilt build-settings/binding evidence is not a plain absolute input" >&2
    exit 65
  fi
  quakesignal_screenshot_run_tracked /usr/bin/ruby \
    "$script_dir/ios-screenshot-build-binding.rb" verify \
    "$source_commit" "$external_build_source_evidence" "$external_build_settings" \
    "$external_build_log" "$external_build_list" "$external_result_bundle" "$external_swift_inputs" \
    "$app_path" "$external_build_binding" "$external_prebuild_source_snapshot" \
    "$external_postbuild_source_snapshot" -
  /usr/bin/ruby -rpathname -e '
    root = Pathname.new(ARGV.shift).realpath.to_s
    ARGV.each do |value|
      real = Pathname.new(value).realpath.to_s
      abort "prebuilt capture input is inside the repository" if real == root || real.start_with?("#{root}#{File::SEPARATOR}")
    end
  ' "$repo_root" "$app_path" "$external_build_log" "$external_build_source_evidence" \
    "$external_prebuild_source_snapshot" "$external_postbuild_source_snapshot" \
    "$external_build_settings" "$external_build_list" "$external_result_bundle" "$external_swift_inputs" \
    "$external_build_binding" || {
      echo "error: prebuilt capture inputs must remain outside the repository" >&2
      exit 64
    }
  cp "$external_build_log" "$build_log"
  cp "$external_build_source_evidence" "$payload/build-project-evidence/$frame_selector.json"
  cp "$external_prebuild_source_snapshot" "$payload/build-source-snapshots/$frame_selector.json"
  cp "$external_postbuild_source_snapshot" "$payload/post-build-source-snapshots/$frame_selector.json"
  cp "$external_build_settings" "$payload/build-settings/$frame_selector.json"
  cp "$external_build_list" "$payload/build-lists/$frame_selector.json"
  cp "$external_result_bundle" "$payload/build-results/$frame_selector.xcresult.zip"
  cp "$external_swift_inputs" "$payload/build-swift-inputs/$frame_selector.json"
  cp "$external_build_binding" "$build_binding"
else
  derived_data="$temporary_root/DerivedData"
  build_ios_root="$temporary_root/BuildSource/ios"
  mkdir "$temporary_root/BuildSource"
  if [ -e "$derived_data" ] || [ -L "$derived_data" ]; then
    echo "error: unique screenshot DerivedData root unexpectedly exists before build" >&2
    exit 65
  fi
  mkdir -p "$derived_data/Results"
  result_bundle="$derived_data/Results/QuakeSignal-build.xcresult"
  result_bundle_archive="$derived_data/Results/QuakeSignal-build.xcresult.zip"
  build_list="$temporary_root/xcode-list.json"
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
    "$source_commit" "$build_ios_root" \
    "$payload/build-project-evidence/$frame_selector.json"
  quakesignal_screenshot_run_tracked xcodebuild -list -json \
    -project "$build_ios_root/QuakeSignal.xcodeproj" >"$build_list"
  prebuild_source_snapshot="$payload/build-source-snapshots/$frame_selector.json"
  quakesignal_screenshot_run_tracked /usr/bin/ruby \
    "$script_dir/prepare-ios-screenshot-build-source.rb" snapshot \
    "$source_commit" "$build_ios_root" \
    "$payload/build-project-evidence/$frame_selector.json" pre-build \
    "$prebuild_source_snapshot"
  postbuild_source_snapshot="$payload/post-build-source-snapshots/$frame_selector.json"
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
    "$source_commit" "$build_ios_root" \
    "$payload/build-project-evidence/$frame_selector.json" post-build \
    "$postbuild_source_snapshot"
  build_settings="$temporary_root/build-settings.txt"
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
  /usr/bin/ruby -rjson -rpathname -e '
    root = Pathname.new(ARGV.fetch(0))
    abort "DerivedData root is not canonical" unless root.realpath == root
    [ARGV.fetch(1), ARGV.fetch(2), ARGV.fetch(3)].each do |value|
      path = Pathname.new(value)
      real = path.realpath
      root_string = root.to_s
      abort "build output escaped DerivedData" unless real.to_s.start_with?("#{root_string}#{File::SEPARATOR}")
    end
    settings = JSON.parse(Pathname.new(ARGV.fetch(4)).read).find { |record| record["target"] == "QuakeSignal" }.fetch("buildSettings")
    %w[BUILD_DIR BUILD_ROOT CONFIGURATION_BUILD_DIR OBJROOT SYMROOT SHARED_PRECOMPS_DIR CLANG_MODULE_CACHE_PATH DSTROOT].each do |key|
      path = Pathname.new(settings.fetch(key))
      next unless path.exist?
      real = path.realpath.to_s
      abort "#{key} escaped DerivedData" unless real.start_with?("#{root}#{File::SEPARATOR}")
    end
  ' "$derived_data" "$app_path" "$result_bundle" "$result_bundle_archive" "$build_settings" || {
    echo "error: resolved build outputs escaped the fresh screenshot DerivedData root" >&2
    exit 65
  }
  cp "$build_settings" "$payload/build-settings/$frame_selector.json"
  cp "$build_list" "$payload/build-lists/$frame_selector.json"
  cp "$result_bundle_archive" "$payload/build-results/$frame_selector.xcresult.zip"
  swift_inputs="$payload/build-swift-inputs/$frame_selector.json"
  quakesignal_screenshot_run_tracked /usr/bin/ruby \
    "$script_dir/ios-screenshot-swift-inputs.rb" \
    "$source_commit" "$payload/build-project-evidence/$frame_selector.json" "$build_log" \
    "$derived_data" "$build_ios_root" "$host_architecture" "$swift_inputs"
fi
build_source_evidence="$payload/build-project-evidence/$frame_selector.json"
prebuild_source_snapshot="$payload/build-source-snapshots/$frame_selector.json"
postbuild_source_snapshot="$payload/post-build-source-snapshots/$frame_selector.json"
if [ ! -f "$build_source_evidence" ] || [ -L "$build_source_evidence" ]; then
  echo "error: temporary no-Watch build-source evidence is missing" >&2
  exit 65
fi
if [ ! -f "$prebuild_source_snapshot" ] || [ -L "$prebuild_source_snapshot" ]; then
  echo "error: pre-build materialized-source snapshot is missing" >&2
  exit 65
fi
if [ ! -f "$postbuild_source_snapshot" ] || [ -L "$postbuild_source_snapshot" ]; then
  echo "error: post-build materialized-source snapshot is missing" >&2
  exit 65
fi
if [ ! -d "$app_path" ] || [ -L "$app_path" ]; then
  echo "error: built simulator app is unavailable or not a plain directory" >&2
  exit 70
fi
if [ -z "${external_build_binding:-}" ]; then
  swift_inputs="$payload/build-swift-inputs/$frame_selector.json"
  quakesignal_screenshot_run_tracked /usr/bin/ruby \
    "$script_dir/ios-screenshot-build-binding.rb" write \
    "$source_commit" "$build_source_evidence" "$build_settings" \
    "$build_log" "$build_list" "$result_bundle_archive" "$swift_inputs" "$app_path" "$build_binding" \
    "$prebuild_source_snapshot" "$postbuild_source_snapshot" "$build_ios_root"
fi
info_plist="$app_path/Info.plist"
if [ ! -f "$info_plist" ] || [ -L "$info_plist" ]; then
  echo "error: built simulator app has no plain Info.plist" >&2
  exit 70
fi
actual_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
executable_path="$app_path/$executable_name"
if [ "$actual_bundle_identifier" != "$bundle_identifier" ] || \
   [ "$marketing_version" != "1.1" ] || [ "$build_number" != "8" ] || \
   [ ! -f "$executable_path" ] || [ -L "$executable_path" ]; then
  echo "error: built app identity differs from build 8 capture contract" >&2
  exit 65
fi

tree_hash() {
  /usr/bin/ruby -rdigest -rpathname -e '
    root = Pathname.new(ARGV.fetch(0)).realpath
    records = []
    visit = lambda do |directory|
      directory.children.sort_by(&:to_s).each do |entry|
        stat = entry.lstat
        relative = entry.relative_path_from(root).to_s
        if stat.directory? && !entry.symlink?
          visit.call(entry)
        elsif stat.file? && !entry.symlink?
          records << "#{Digest::SHA256.file(entry).hexdigest}  #{relative}\n"
        else
          abort "app bundle contains a symlink or special entry: #{relative}"
        end
      end
    end
    visit.call(root)
    puts Digest::SHA256.hexdigest(records.sort.join)
  ' "$1"
}

app_bundle_tree_sha256="$(tree_hash "$app_path")"
executable_sha256="$(shasum -a 256 "$executable_path" | awk '{ print $1 }')"
build_log_sha256="$(shasum -a 256 "$build_log" | awk '{ print $1 }')"
build_source_evidence_sha256="$(shasum -a 256 "$build_source_evidence" | awk '{ print $1 }')"
prebuild_source_snapshot_sha256="$(shasum -a 256 "$prebuild_source_snapshot" | awk '{ print $1 }')"
postbuild_source_snapshot_sha256="$(shasum -a 256 "$postbuild_source_snapshot" | awk '{ print $1 }')"
build_settings_evidence="$payload/build-settings/$frame_selector.json"
build_settings_evidence_sha256="$(shasum -a 256 "$build_settings_evidence" | awk '{ print $1 }')"
build_list_evidence="$payload/build-lists/$frame_selector.json"
build_list_evidence_sha256="$(shasum -a 256 "$build_list_evidence" | awk '{ print $1 }')"
build_result_evidence="$payload/build-results/$frame_selector.xcresult.zip"
build_result_evidence_sha256="$(shasum -a 256 "$build_result_evidence" | awk '{ print $1 }')"
swift_inputs_evidence="$payload/build-swift-inputs/$frame_selector.json"
swift_inputs_evidence_sha256="$(shasum -a 256 "$swift_inputs_evidence" | awk '{ print $1 }')"
build_binding_sha256="$(shasum -a 256 "$build_binding" | awk '{ print $1 }')"
if [ -e "$app_path/Watch" ] || [ -L "$app_path/Watch" ]; then
  echo "error: detached no-Watch screenshot build unexpectedly contains a Watch payload" >&2
  exit 65
fi

install_log="$temporary_root/install.log"
quakesignal_screenshot_run_tracked xcrun simctl uninstall \
  "$simulator_id" "$bundle_identifier" >/dev/null 2>&1 || true
if ! quakesignal_screenshot_run_tracked xcrun simctl install \
  "$simulator_id" "$app_path" >"$install_log" 2>&1; then
  /bin/cat "$install_log" >&2
  echo "error: exact detached no-Watch simulator app failed its initial install" >&2
  exit 70
fi
installed_container_result="$temporary_root/installed-app-container.txt"
quakesignal_screenshot_run_tracked xcrun simctl get_app_container \
  "$simulator_id" "$bundle_identifier" app >"$installed_container_result"
installed_app_path="$(/usr/bin/ruby -rpathname -e '
  source = Pathname.new(ARGV.fetch(0)).read.strip
  abort "installed app container path must be absolute" unless source.start_with?(File::SEPARATOR)
  requested = Pathname.new(source)
  real = requested.realpath
  abort "installed app container must be canonical" unless requested == real
  stat = real.lstat
  abort "installed app container must be a plain directory" unless stat.directory? && !real.symlink?
  abort "installed app container must be QuakeSignal.app" unless real.basename.to_s == "QuakeSignal.app"
  puts real
' "$installed_container_result")" || {
  echo "error: simulator did not expose the exact installed QuakeSignal.app container" >&2
  exit 70
}
if [ -e "$installed_app_path/Watch" ] || [ -L "$installed_app_path/Watch" ]; then
  echo "error: installed simulator app unexpectedly contains a Watch payload" >&2
  exit 65
fi
installed_tree_manifest="$temporary_root/installed-app-tree.json"
/usr/bin/ruby -I"$script_dir" -rjson -rios-screenshot-build-binding -e '
  root = Pathname.new(ARGV.fetch(0)).realpath
  File.write(
    ARGV.fetch(1),
    JSON.generate(QuakeSignalIOSScreenshotBuildBinding.tree_manifest(root, "installed app")),
    mode: "wx",
  )
' "$installed_app_path" "$installed_tree_manifest"
installed_info="$installed_app_path/Info.plist"
installed_executable="$installed_app_path/$executable_name"
if [ ! -f "$installed_info" ] || [ -L "$installed_info" ] || \
   [ ! -f "$installed_executable" ] || [ -L "$installed_executable" ]; then
  echo "error: installed app lacks the bound plain Info.plist or main executable" >&2
  exit 65
fi
/usr/bin/ruby -rjson -rdigest -e '
  binding = JSON.parse(File.read(ARGV.fetch(0)))
  installed_tree = JSON.parse(File.read(ARGV.fetch(1)))
  app = binding.fetch("app")
  abort "installed app tree differs from the source-bound app" unless installed_tree == app.fetch("bundleTree")
  abort "installed Info.plist differs from the source-bound app" unless
    Digest::SHA256.file(ARGV.fetch(2)).hexdigest == app.fetch("infoPlistSha256")
  abort "installed main executable differs from the source-bound app" unless
    app.fetch("mainExecutableFile") == "QuakeSignal" &&
    Digest::SHA256.file(ARGV.fetch(3)).hexdigest == app.fetch("mainExecutableSha256")
' "$build_binding" "$installed_tree_manifest" "$installed_info" "$installed_executable" || {
  echo "error: installed simulator app bytes differ from the exact source-bound build" >&2
  exit 65
}

install_evidence="$payload/install-evidence/$frame_selector.json"
install_log_artifact="$payload/install-logs/$frame_selector.log"
cp "$install_log" "$install_log_artifact"
export IOS_INSTALL_SELECTOR="$frame_selector"
export IOS_INSTALL_UDID="$simulator_id"
export IOS_INSTALL_LOG_SHA="$(shasum -a 256 "$install_log" | awk '{ print $1 }')"
export IOS_INSTALL_CONTAINER="$installed_app_path"
export IOS_INSTALL_INFO_SHA="$(shasum -a 256 "$installed_info" | awk '{ print $1 }')"
export IOS_INSTALL_EXECUTABLE_SHA="$(shasum -a 256 "$installed_executable" | awk '{ print $1 }')"
/usr/bin/ruby -rjson -e '
  tree = JSON.parse(File.read(ARGV.fetch(1)))
  record = {
    "schemaVersion" => 1,
    "captureSelector" => ENV.fetch("IOS_INSTALL_SELECTOR"),
    "simulatorDeviceIdentifier" => ENV.fetch("IOS_INSTALL_UDID"),
    "installExitStatus" => 0,
    "installLogFile" => "install-logs/#{ENV.fetch("IOS_INSTALL_SELECTOR")}.log",
    "installLogSha256" => ENV.fetch("IOS_INSTALL_LOG_SHA"),
    "installedAppContainer" => ENV.fetch("IOS_INSTALL_CONTAINER"),
    "bundleName" => "QuakeSignal.app",
    "bundleTree" => tree,
    "watchPayloadPresent" => false,
    "infoPlistSha256" => ENV.fetch("IOS_INSTALL_INFO_SHA"),
    "mainExecutableFile" => "QuakeSignal",
    "mainExecutableSha256" => ENV.fetch("IOS_INSTALL_EXECUTABLE_SHA"),
  }
  File.write(ARGV.fetch(0), JSON.pretty_generate(record) + "\n", mode: "wx")
' "$install_evidence" "$installed_tree_manifest"

quakesignal_screenshot_run_tracked xcrun simctl status_bar \
  "$simulator_id" clear >/dev/null 2>&1 || true
quakesignal_screenshot_run_tracked xcrun simctl status_bar "$simulator_id" override \
  --time '2026-01-01T09:41:00+00:00' \
  --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --operatorName '' \
  --batteryState charged --batteryLevel 100
quakesignal_screenshot_run_tracked xcrun simctl ui "$simulator_id" appearance dark
quakesignal_screenshot_run_tracked xcrun simctl privacy \
  "$simulator_id" reset all "$bundle_identifier" >/dev/null 2>&1 || true

app_stdout="$payload/app-logs/$frame_selector.stdout.log"
app_stderr="$payload/app-logs/$frame_selector.stderr.log"
launch_fixture() {
  local result_file="$1"
  quakesignal_screenshot_run_tracked /usr/bin/env \
    SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_AUTOMATION=1 \
    SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_FRAME="$frame_selector" \
    'SIMCTL_CHILD_AppleLanguages=(en)' \
    SIMCTL_CHILD_AppleLocale=en_US \
    SIMCTL_CHILD_TZ=UTC \
    xcrun simctl launch \
      --terminate-running-process \
      "--stdout=$app_stdout" \
      "--stderr=$app_stderr" \
      "$simulator_id" \
      "$bundle_identifier" \
      --quakesignal-screenshot-automation \
      "--quakesignal-screenshot-frame=$frame_selector" >"$result_file"
}

capture_started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
launch_result="$temporary_root/launch-result.txt"
launch_fixture "$launch_result" || {
  echo "error: exact screenshot fixture launch failed" >&2
  exit 70
}
launch_output="$(<"$launch_result")"
app_pid="$(awk -F ': ' 'NF == 2 { print $2; exit }' <<<"$launch_output")"
if [[ ! "$app_pid" =~ ^[0-9]+$ ]]; then
  echo "error: simctl launch did not return an app process identifier" >&2
  exit 70
fi

validator="${QUAKESIGNAL_IOS_SCREENSHOT_VALIDATOR:-}"
if [ -n "$validator" ]; then
  if [[ "$validator" != /* ]] || [ ! -x "$validator" ]; then
    echo "error: semantic validator must be an executable absolute path" >&2
    exit 64
  fi
else
  validator="$temporary_root/ios-screenshot-content-validator"
  quakesignal_screenshot_run_tracked xcrun swiftc -O \
    "$script_dir/ios-screenshot-content-validator.swift" -o "$validator"
fi

settle_seconds=8
capture_attempt_count=0
retry_performed=false
first_rejection_file=""
first_rejection_sha256=""
accepted_raw="$payload/raw-simulator-captures/$frame_selector.png"
accepted_raw_semantic="$payload/semantic-evidence/$frame_selector-raw.json"
for attempt in 1 2; do
  capture_attempt_count="$attempt"
  sleep "$settle_seconds"
  attempt_raw="$temporary_root/$frame_selector-attempt-$attempt.png"
  attempt_semantic="$temporary_root/$frame_selector-attempt-$attempt.json"
  quakesignal_screenshot_run_tracked xcrun simctl io \
    "$simulator_id" screenshot --type=png --mask=black "$attempt_raw"
  validator_status=0
  quakesignal_screenshot_run_tracked \
    "$validator" "$frame_selector" "$attempt_raw" "$attempt_semantic" || validator_status="$?"
  if [ "$validator_status" -eq 0 ]; then
    mv "$attempt_raw" "$accepted_raw"
    mv "$attempt_semantic" "$accepted_raw_semantic"
    break
  fi
  if [ "$validator_status" -ne 65 ] || [ "$attempt" -eq 2 ]; then
    echo "error: iOS/iPadOS semantic validation failed with status $validator_status" >&2
    exit "$validator_status"
  fi
  retry_performed=true
  first_rejection_file="semantic-rejections/$frame_selector-attempt-1.json"
  first_rejection_image_file="semantic-rejections/$frame_selector-attempt-1.png"
  mv "$attempt_semantic" "$payload/$first_rejection_file"
  mv "$attempt_raw" "$payload/$first_rejection_image_file"
  first_rejection_sha256="$(shasum -a 256 "$payload/$first_rejection_file" | awk '{ print $1 }')"
  first_rejection_image_sha256="$(shasum -a 256 "$payload/$first_rejection_image_file" | awk '{ print $1 }')"
  launch_fixture "$launch_result" || {
    echo "error: exact screenshot fixture relaunch failed" >&2
    exit 70
  }
  launch_output="$(<"$launch_result")"
  app_pid="$(awk -F ': ' 'NF == 2 { print $2; exit }' <<<"$launch_output")"
  if [[ ! "$app_pid" =~ ^[0-9]+$ ]]; then
    echo "error: exact screenshot fixture relaunch did not return a numeric process identifier" >&2
    exit 70
  fi
done
if [ ! -f "$accepted_raw" ] || [ -L "$accepted_raw" ] || \
   [ ! -f "$accepted_raw_semantic" ] || [ -L "$accepted_raw_semantic" ]; then
  echo "error: semantic capture did not produce accepted evidence" >&2
  exit 65
fi

raw_width="$(sips -g pixelWidth "$accepted_raw" | awk '/pixelWidth:/ { print $2 }')"
raw_height="$(sips -g pixelHeight "$accepted_raw" | awk '/pixelHeight:/ { print $2 }')"
raw_format="$(sips -g format "$accepted_raw" | awk '/format:/ { print tolower($2) }')"
raw_alpha="$(sips -g hasAlpha "$accepted_raw" | awk '/hasAlpha:/ { print tolower($2) }')"
if [ "$raw_width" != "$expected_width" ] || [ "$raw_height" != "$expected_height" ] || \
   [ "$raw_format" != "png" ]; then
  echo "error: accepted native capture is not the exact planned PNG dimensions" >&2
  exit 65
fi

final_screenshot="$payload/$planned_file"
quakesignal_screenshot_run_tracked sips -s format jpeg -s formatOptions 100 \
  "$accepted_raw" --out "$final_screenshot" >/dev/null
final_width="$(sips -g pixelWidth "$final_screenshot" | awk '/pixelWidth:/ { print $2 }')"
final_height="$(sips -g pixelHeight "$final_screenshot" | awk '/pixelHeight:/ { print $2 }')"
final_format="$(sips -g format "$final_screenshot" | awk '/format:/ { print tolower($2) }')"
final_alpha="$(sips -g hasAlpha "$final_screenshot" | awk '/hasAlpha:/ { print tolower($2) }')"
if [ "$final_width" != "$expected_width" ] || [ "$final_height" != "$expected_height" ] || \
   [ "$final_format" != "jpeg" ] || [ "$final_alpha" = "yes" ]; then
  echo "error: final screenshot is not the exact opaque no-resize JPEG contract" >&2
  exit 65
fi
accepted_semantic="$payload/semantic-evidence/$frame_selector-final.json"
final_validator_status=0
quakesignal_screenshot_run_tracked \
  "$validator" "$frame_selector" "$final_screenshot" "$accepted_semantic" || final_validator_status="$?"
if [ "$final_validator_status" -ne 0 ] || [ ! -f "$accepted_semantic" ] || [ -L "$accepted_semantic" ]; then
  echo "error: final encoded JPEG failed semantic validation" >&2
  exit 65
fi

raw_sha256="$(shasum -a 256 "$accepted_raw" | awk '{ print $1 }')"
final_sha256="$(shasum -a 256 "$final_screenshot" | awk '{ print $1 }')"
semantic_sha256="$(shasum -a 256 "$accepted_semantic" | awk '{ print $1 }')"
raw_semantic_sha256="$(shasum -a 256 "$accepted_raw_semantic" | awk '{ print $1 }')"
install_sha256="$(shasum -a 256 "$install_evidence" | awk '{ print $1 }')"
capture_completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

transformation_evidence="$payload/transformation-evidence/$frame_selector.json"
export IOS_TRANSFORM_SELECTOR="$frame_selector"
export IOS_TRANSFORM_WIDTH="$expected_width"
export IOS_TRANSFORM_HEIGHT="$expected_height"
export IOS_TRANSFORM_RAW_ALPHA="$raw_alpha"
/usr/bin/ruby -rjson -e '
  record = {
    "schemaVersion" => 1,
    "captureSelector" => ENV.fetch("IOS_TRANSFORM_SELECTOR"),
    "operation" => "format-conversion",
    "rawFormat" => "png",
    "finalFormat" => "jpeg",
    "encoder" => "sips",
    "quality" => 100,
    "resizePerformed" => false,
    "rawHasAlpha" => ENV.fetch("IOS_TRANSFORM_RAW_ALPHA") == "yes",
    "finalHasAlpha" => false,
    "pixels" => [Integer(ENV.fetch("IOS_TRANSFORM_WIDTH"), 10), Integer(ENV.fetch("IOS_TRANSFORM_HEIGHT"), 10)],
  }
  File.write(ARGV.fetch(0), JSON.pretty_generate(record) + "\n", mode: "wx")
' "$transformation_evidence"
transformation_sha256="$(shasum -a 256 "$transformation_evidence" | awk '{ print $1 }')"

launch_evidence="$payload/launch-evidence/$frame_selector.json"
export IOS_LAUNCH_SELECTOR="$frame_selector"
export IOS_LAUNCH_PID="$app_pid"
export IOS_LAUNCH_ATTEMPTS="$capture_attempt_count"
export IOS_LAUNCH_RETRY="$retry_performed"
export IOS_LAUNCH_STDOUT_SHA="$(shasum -a 256 "$app_stdout" | awk '{ print $1 }')"
export IOS_LAUNCH_STDERR_SHA="$(shasum -a 256 "$app_stderr" | awk '{ print $1 }')"
/usr/bin/ruby -rjson -e '
  record = {
    "schemaVersion" => 1,
    "captureSelector" => ENV.fetch("IOS_LAUNCH_SELECTOR"),
    "processId" => Integer(ENV.fetch("IOS_LAUNCH_PID"), 10),
    "launchArgumentGatePresent" => true,
    "launchEnvironmentGatePresent" => true,
    "frameArgumentEnvironmentMatch" => true,
    "appleLanguages" => ["en"],
    "appleLocale" => "en_US",
    "timeZone" => "UTC",
    "appearance" => "dark",
    "statusBarTime" => "2026-01-01T09:41:00+00:00",
    "captureAttemptCount" => Integer(ENV.fetch("IOS_LAUNCH_ATTEMPTS"), 10),
    "retryPerformed" => ENV.fetch("IOS_LAUNCH_RETRY") == "true",
    "stdoutSha256" => ENV.fetch("IOS_LAUNCH_STDOUT_SHA"),
    "stderrSha256" => ENV.fetch("IOS_LAUNCH_STDERR_SHA"),
  }
  File.write(ARGV.fetch(0), JSON.pretty_generate(record) + "\n", mode: "wx")
' "$launch_evidence"
launch_sha256="$(shasum -a 256 "$launch_evidence" | awk '{ print $1 }')"

xcode_version="$(xcodebuild -version | tr '\n' ';' | sed 's/;$//')"
operating_system="$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
frame_evidence="$payload/frame-capture-evidence/$frame_selector.json"
export IOS_FRAME_SELECTOR="$frame_selector"
export IOS_FRAME_CLASS="$display_class"
export IOS_FRAME_FILE="$planned_file"
export IOS_FRAME_WIDTH="$expected_width"
export IOS_FRAME_HEIGHT="$expected_height"
export IOS_FRAME_STARTED="$capture_started_at"
export IOS_FRAME_COMPLETED="$capture_completed_at"
export IOS_FRAME_SOURCE_COMMIT="$source_commit"
export IOS_FRAME_PLAN_SHA="$manifest_sha256"
export IOS_FRAME_XCODE="$xcode_version"
export IOS_FRAME_OS="$operating_system"
export IOS_FRAME_RUNTIME="$runtime_identifier"
export IOS_FRAME_DEVICE_TYPE="$selected_device_type"
export IOS_FRAME_DEVICE_MODEL="$selected_device_model"
export IOS_FRAME_UDID="$simulator_id"
export IOS_FRAME_APP_TREE_SHA="$app_bundle_tree_sha256"
export IOS_FRAME_EXECUTABLE="$executable_name"
export IOS_FRAME_EXECUTABLE_SHA="$executable_sha256"
export IOS_FRAME_BUILD_LOG_SHA="$build_log_sha256"
export IOS_FRAME_BUILD_SOURCE_SHA="$build_source_evidence_sha256"
export IOS_FRAME_PREBUILD_SOURCE_SNAPSHOT_SHA="$prebuild_source_snapshot_sha256"
export IOS_FRAME_POSTBUILD_SOURCE_SNAPSHOT_SHA="$postbuild_source_snapshot_sha256"
export IOS_FRAME_BUILD_SETTINGS_SHA="$build_settings_evidence_sha256"
export IOS_FRAME_BUILD_LIST_SHA="$build_list_evidence_sha256"
export IOS_FRAME_BUILD_RESULT_SHA="$build_result_evidence_sha256"
export IOS_FRAME_SWIFT_INPUTS_SHA="$swift_inputs_evidence_sha256"
export IOS_FRAME_BUILD_BINDING_SHA="$build_binding_sha256"
export IOS_FRAME_INSTALL_SHA="$install_sha256"
export IOS_FRAME_LAUNCH_SHA="$launch_sha256"
export IOS_FRAME_SEMANTIC_SHA="$semantic_sha256"
export IOS_FRAME_RAW_SEMANTIC_SHA="$raw_semantic_sha256"
export IOS_FRAME_TRANSFORM_SHA="$transformation_sha256"
export IOS_FRAME_RAW_SHA="$raw_sha256"
export IOS_FRAME_RAW_ALPHA="$raw_alpha"
export IOS_FRAME_FINAL_SHA="$final_sha256"
export IOS_FRAME_CAPTURE_ATTEMPTS="$capture_attempt_count"
export IOS_FRAME_RETRY="$retry_performed"
export IOS_FRAME_FIRST_REJECTION_FILE="$first_rejection_file"
export IOS_FRAME_FIRST_REJECTION_SHA="$first_rejection_sha256"
export IOS_FRAME_FIRST_REJECTION_IMAGE_FILE="${first_rejection_image_file:-}"
export IOS_FRAME_FIRST_REJECTION_IMAGE_SHA="${first_rejection_image_sha256:-}"
/usr/bin/ruby -rjson -e '
  selector = ENV.fetch("IOS_FRAME_SELECTOR")
  first_rejection = if ENV.fetch("IOS_FRAME_FIRST_REJECTION_FILE").empty?
    nil
  else
    {
      "file" => ENV.fetch("IOS_FRAME_FIRST_REJECTION_FILE"),
      "sha256" => ENV.fetch("IOS_FRAME_FIRST_REJECTION_SHA"),
      "status" => "rejected",
      "validatorExitStatus" => 65,
      "imageFile" => ENV.fetch("IOS_FRAME_FIRST_REJECTION_IMAGE_FILE"),
      "imageSha256" => ENV.fetch("IOS_FRAME_FIRST_REJECTION_IMAGE_SHA"),
    }
  end
  width = Integer(ENV.fetch("IOS_FRAME_WIDTH"), 10)
  height = Integer(ENV.fetch("IOS_FRAME_HEIGHT"), 10)
  record = {
    "schemaVersion" => 1,
    "status" => "unapproved-debug-ios-ipados-capture-evidence",
    "uploadApproved" => false,
    "reviewer" => nil,
    "approval" => nil,
    "platform" => "ios-ipados",
    "locale" => "en-US",
    "captureSelector" => selector,
    "displayClass" => ENV.fetch("IOS_FRAME_CLASS"),
    "plannedFile" => ENV.fetch("IOS_FRAME_FILE"),
    "captureWindowUtc" => {
      "startedAt" => ENV.fetch("IOS_FRAME_STARTED"),
      "completedAt" => ENV.fetch("IOS_FRAME_COMPLETED"),
    },
    "source" => {
      "commit" => ENV.fetch("IOS_FRAME_SOURCE_COMMIT"),
      "treeState" => "clean",
      "debugLocalOverridePresent" => false,
    },
    "planManifest" => {
      "file" => "ios/AppStore/screenshot-manifest-v1.1-build8.template.json",
      "sha256" => ENV.fetch("IOS_FRAME_PLAN_SHA"),
    },
    "product" => {
      "bundleIdentifier" => "com.quakesignal.app",
      "marketingVersion" => "1.1",
      "build" => 8,
      "scheme" => "QuakeSignal",
      "destination" => "generic/platform=iOS Simulator",
      "configuration" => "Debug",
    },
    "captureEnvironment" => {
      "kind" => "simulator",
      "xcodeVersion" => ENV.fetch("IOS_FRAME_XCODE"),
      "operatingSystem" => ENV.fetch("IOS_FRAME_OS"),
      "runtimeIdentifier" => ENV.fetch("IOS_FRAME_RUNTIME"),
      "deviceTypeIdentifier" => ENV.fetch("IOS_FRAME_DEVICE_TYPE"),
      "deviceModel" => ENV.fetch("IOS_FRAME_DEVICE_MODEL"),
      "deviceIdentifier" => ENV.fetch("IOS_FRAME_UDID"),
    },
    "app" => {
      "bundleName" => "QuakeSignal.app",
      "bundleTreeSha256" => ENV.fetch("IOS_FRAME_APP_TREE_SHA"),
      "mainExecutableFile" => ENV.fetch("IOS_FRAME_EXECUTABLE"),
      "mainExecutableSha256" => ENV.fetch("IOS_FRAME_EXECUTABLE_SHA"),
    },
    "build" => {
      "logFile" => "build-logs/#{selector}.log",
      "logSha256" => ENV.fetch("IOS_FRAME_BUILD_LOG_SHA"),
      "sourceEvidenceFile" => "build-project-evidence/#{selector}.json",
      "sourceEvidenceSha256" => ENV.fetch("IOS_FRAME_BUILD_SOURCE_SHA"),
      "preBuildSourceSnapshotFile" => "build-source-snapshots/#{selector}.json",
      "preBuildSourceSnapshotSha256" => ENV.fetch("IOS_FRAME_PREBUILD_SOURCE_SNAPSHOT_SHA"),
      "postBuildSourceSnapshotFile" => "post-build-source-snapshots/#{selector}.json",
      "postBuildSourceSnapshotSha256" => ENV.fetch("IOS_FRAME_POSTBUILD_SOURCE_SNAPSHOT_SHA"),
      "settingsFile" => "build-settings/#{selector}.json",
      "settingsSha256" => ENV.fetch("IOS_FRAME_BUILD_SETTINGS_SHA"),
      "projectListFile" => "build-lists/#{selector}.json",
      "projectListSha256" => ENV.fetch("IOS_FRAME_BUILD_LIST_SHA"),
      "resultBundleArchiveFile" => "build-results/#{selector}.xcresult.zip",
      "resultBundleArchiveSha256" => ENV.fetch("IOS_FRAME_BUILD_RESULT_SHA"),
      "swiftInputsFile" => "build-swift-inputs/#{selector}.json",
      "swiftInputsSha256" => ENV.fetch("IOS_FRAME_SWIFT_INPUTS_SHA"),
      "bindingFile" => "build-bindings/#{selector}.json",
      "bindingSha256" => ENV.fetch("IOS_FRAME_BUILD_BINDING_SHA"),
      "debugLocalOverridePresent" => false,
    },
    "installEvidence" => {
      "file" => "install-evidence/#{selector}.json",
      "sha256" => ENV.fetch("IOS_FRAME_INSTALL_SHA"),
    },
    "launchEvidence" => {
      "file" => "launch-evidence/#{selector}.json",
      "sha256" => ENV.fetch("IOS_FRAME_LAUNCH_SHA"),
    },
    "semanticValidation" => {
      "status" => "accepted",
      "settleSeconds" => 8,
      "captureAttemptCount" => Integer(ENV.fetch("IOS_FRAME_CAPTURE_ATTEMPTS"), 10),
      "retryPerformed" => ENV.fetch("IOS_FRAME_RETRY") == "true",
      "rawEvidence" => {
        "file" => "semantic-evidence/#{selector}-raw.json",
        "sha256" => ENV.fetch("IOS_FRAME_RAW_SEMANTIC_SHA"),
        "status" => "accepted",
      },
      "finalEvidence" => {
        "file" => "semantic-evidence/#{selector}-final.json",
        "sha256" => ENV.fetch("IOS_FRAME_SEMANTIC_SHA"),
        "status" => "accepted",
      },
      "firstRejection" => first_rejection,
    },
    "transformation" => {
      "file" => "transformation-evidence/#{selector}.json",
      "sha256" => ENV.fetch("IOS_FRAME_TRANSFORM_SHA"),
      "operation" => "format-conversion",
      "resizePerformed" => false,
      "encoder" => "sips",
      "quality" => 100,
    },
    "artifacts" => {
      "rawSimulator" => {
        "file" => "raw-simulator-captures/#{selector}.png",
        "sha256" => ENV.fetch("IOS_FRAME_RAW_SHA"),
        "pixels" => [width, height],
        "format" => "png",
        "hasAlpha" => ENV.fetch("IOS_FRAME_RAW_ALPHA") == "yes",
      },
      "finalScreenshot" => {
        "file" => ENV.fetch("IOS_FRAME_FILE"),
        "sha256" => ENV.fetch("IOS_FRAME_FINAL_SHA"),
        "pixels" => [width, height],
        "format" => "jpeg",
        "hasAlpha" => false,
      },
      "stdoutLog" => {
        "file" => "app-logs/#{selector}.stdout.log",
        "sha256" => ENV.fetch("IOS_LAUNCH_STDOUT_SHA"),
      },
      "stderrLog" => {
        "file" => "app-logs/#{selector}.stderr.log",
        "sha256" => ENV.fetch("IOS_LAUNCH_STDERR_SHA"),
      },
    },
  }
  File.write(ARGV.fetch(0), JSON.pretty_generate(record) + "\n", mode: "wx")
' "$frame_evidence"

complete_owned_simulator_cleanup

if [ "$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}')" != "$source_commit" ] || \
   [ -n "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]; then
  echo "error: source commit/tree changed during iOS/iPadOS frame capture" >&2
  exit 65
fi
if [ -e "$debug_local_override" ] || [ -L "$debug_local_override" ]; then
  echo "error: ignored Debug.local.xcconfig appeared during iOS/iPadOS capture" >&2
  exit 65
fi
if [ -e "$output" ] || [ -L "$output" ]; then
  echo "error: output appeared during publication; refusing to overwrite" >&2
  exit 73
fi
quakesignal_screenshot_publish_directory \
  "$payload" "$output" "$output_parent_identity" "$temporary_root_identity" "$payload_identity" || {
  echo "error: screenshot output parent changed during atomic publication" >&2
  exit 73
}
echo "$final_sha256  $output/$planned_file"
echo "Captured exact unapproved iOS/iPadOS frame evidence: $output"
