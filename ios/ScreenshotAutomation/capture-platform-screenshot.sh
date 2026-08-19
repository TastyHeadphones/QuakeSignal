#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: capture-platform-screenshot.sh <tvos|watchos|visionos> <frame-selector> <absolute-output.png>

Builds a Debug simulator app, launches it with QuakeSignal's deterministic
screenshot fixture at one exact reviewed frame, and captures an unmodified
native PNG. The frame selector must belong to the checked-in platform plan.
The requested platform runtime must already be installed. Captures inside the
repository are rejected so review candidates remain CI/manual artifacts until
approved.

Optional environment:
  QUAKESIGNAL_SCREENSHOT_LOCALE=en|ja|zh-Hans  (default: en)
  QUAKESIGNAL_SCREENSHOT_KEEP_SIMULATOR=1      (preserve disposable simulator)
  QUAKESIGNAL_SCREENSHOT_DERIVED_DATA=/absolute/cache/directory
      Reuse an unsigned build cache across frames. It must be outside the repo.
  QUAKESIGNAL_SCREENSHOT_PROVENANCE_OUTPUT=/absolute/path.json
      Write an explicitly unapproved capture sidecar containing the exact
      selected Simulator runtime identifier and device type/model.
USAGE
}

if [ "$#" -ne 3 ]; then
  usage >&2
  exit 64
fi

platform="$1"
frame_selector="$2"
requested_output="$3"
locale="${QUAKESIGNAL_SCREENSHOT_LOCALE:-en}"
keep_simulator="${QUAKESIGNAL_SCREENSHOT_KEEP_SIMULATOR:-0}"
requested_provenance_output="${QUAKESIGNAL_SCREENSHOT_PROVENANCE_OUTPUT:-}"
requested_derived_data="${QUAKESIGNAL_SCREENSHOT_DERIVED_DATA:-}"

case "$locale" in
  en) apple_locale="en_US" ;;
  ja) apple_locale="ja_JP" ;;
  zh-Hans) apple_locale="zh_Hans_CN" ;;
  *)
    echo "error: unsupported locale '$locale' (expected en, ja, or zh-Hans)" >&2
    exit 64
    ;;
esac

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
ios_root="$(cd "$script_dir/.." && pwd -P)"
repo_root="$(cd "$ios_root/.." && pwd -P)"
source "$script_dir/watch-capture-guard.sh"

if [[ "$requested_output" != /* ]] || [[ "$requested_output" != *.png ]]; then
  echo "error: output must be an absolute .png path" >&2
  exit 64
fi

output_dir="$(dirname "$requested_output")"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
output="$output_dir/$(basename "$requested_output")"

case "$output" in
  "$repo_root"/*)
    echo "error: screenshot output must be outside the repository: $repo_root" >&2
    exit 64
    ;;
esac
if [ -e "$output" ] || [ -L "$output" ]; then
  echo "error: refusing to overwrite existing artifact: $output" >&2
  exit 73
fi

provenance_output=""
if [ -n "$requested_provenance_output" ]; then
  if [[ "$requested_provenance_output" != /* ]] || [[ "$requested_provenance_output" != *.json ]]; then
    echo "error: provenance output must be an absolute .json path" >&2
    exit 64
  fi

  provenance_output_dir="$(dirname "$requested_provenance_output")"
  mkdir -p "$provenance_output_dir"
  provenance_output_dir="$(cd "$provenance_output_dir" && pwd -P)"
  provenance_output="$provenance_output_dir/$(basename "$requested_provenance_output")"
  case "$provenance_output" in
    "$repo_root"/*)
      echo "error: provenance output must be outside the repository: $repo_root" >&2
      exit 64
      ;;
  esac
  if [ -e "$provenance_output" ] || [ -L "$provenance_output" ]; then
    echo "error: refusing to overwrite existing provenance artifact: $provenance_output" >&2
    exit 73
  fi
fi

case "$platform" in
  tvos)
    runtime_name="tvOS"
    scheme="QuakeSignalTV"
    destination_platform="tvOS Simulator"
    bundle_id="com.quakesignal.app"
    expected_width=1920
    expected_height=1080
    device_types=(
      com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p
      com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-2nd-generation-1080p
      com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-1080p
      com.apple.CoreSimulator.SimDeviceType.Apple-TV-1080p
    )
    ;;
  visionos)
    runtime_name="visionOS"
    scheme="QuakeSignalVision"
    destination_platform="visionOS Simulator"
    bundle_id="com.quakesignal.app"
    expected_width=3840
    expected_height=2160
    device_types=(com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro-4K)
    ;;
  watchos)
    runtime_name="watchOS"
    scheme="QuakeSignalWatch"
    destination_platform="watchOS Simulator"
    bundle_id="com.quakesignal.app.watchkitapp"
    expected_width=410
    expected_height=502
    device_types=(
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-2-49mm
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-49mm
    )
    ;;
  *)
    echo "error: unsupported platform '$platform'" >&2
    usage >&2
    exit 64
    ;;
esac

plan_entry="$(/usr/bin/ruby "$script_dir/platform-screenshot-plan.rb" "$platform" --tsv | \
  awk -F '\t' -v selector="$frame_selector" '$1 == selector { print; matches += 1 } END { exit(matches == 1 ? 0 : 1) }')" || {
  echo "error: frame selector '$frame_selector' is not the exact reviewed $platform plan" >&2
  exit 64
}
IFS=$'\t' read -r planned_selector planned_file planned_width planned_height <<<"$plan_entry"
if [ "$planned_selector" != "$frame_selector" ] || \
   [ "$planned_width" != "$expected_width" ] || \
   [ "$planned_height" != "$expected_height" ]; then
  echo "error: frame selector '$frame_selector' disagrees with the platform capture contract" >&2
  exit 65
fi

derived_data=""
if [ -n "$requested_derived_data" ]; then
  if [[ "$requested_derived_data" != /* ]]; then
    echo "error: derived-data cache must be an absolute path" >&2
    exit 64
  fi
  mkdir -p "$requested_derived_data"
  derived_data="$(cd "$requested_derived_data" && pwd -P)"
  case "$derived_data" in
    "$repo_root"|"$repo_root"/*)
      echo "error: derived-data cache must be outside the repository: $repo_root" >&2
      exit 64
      ;;
  esac
fi

for required_command in xcodebuild xcrun ruby sips; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "error: required command not found: $required_command" >&2
    exit 69
  fi
done

runtime_identifier="$({ xcrun simctl list runtimes available -j; } | /usr/bin/ruby -rjson -e '
  requested = ARGV.fetch(0)
  runtimes = JSON.parse(STDIN.read).fetch("runtimes")
  matches = runtimes.select do |runtime|
    next false if runtime["isAvailable"] == false
    name = runtime.fetch("name", "")
    identifier = runtime.fetch("identifier", "")
    name.start_with?(requested) ||
      (requested == "visionOS" && identifier.include?(".xrOS-"))
  end
  exit 1 if matches.empty?
  chosen = matches.max_by do |runtime|
    runtime.fetch("version", "0").scan(/[0-9]+/).map(&:to_i)
  end
  puts chosen.fetch("identifier")
' "$runtime_name")" || {
  echo "error: no available $runtime_name Simulator runtime" >&2
  echo "Install it first: xcodebuild -downloadPlatform $runtime_name -architectureVariant arm64" >&2
  exit 69
}

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/quakesignal-screenshot.XXXXXX")"
simulator_id=""
paired_phone_id=""
screenshot_pid=""
watch_reactivation_pid=""

cleanup() {
  quakesignal_stop_processes "$screenshot_pid" "$watch_reactivation_pid"
  if [ -n "$simulator_id" ] && [ "$keep_simulator" != "1" ]; then
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
  fi
  if [ -n "$paired_phone_id" ] && [ "$keep_simulator" != "1" ]; then
    xcrun simctl shutdown "$paired_phone_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$paired_phone_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$temporary_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

available_device_types="$(xcrun simctl list devicetypes -j)"
selected_device_type=""
selected_device_model=""
for candidate in "${device_types[@]}"; do
  if ! /usr/bin/ruby -rjson -e '
    requested = ARGV.fetch(0)
    types = JSON.parse(STDIN.read).fetch("devicetypes")
    exit(types.any? { |type| type["identifier"] == requested } ? 0 : 1)
  ' "$candidate" <<<"$available_device_types"; then
    continue
  fi

  if created_id="$(xcrun simctl create \
      "QuakeSignal $platform screenshot $$" \
      "$candidate" \
      "$runtime_identifier" 2>/dev/null)"; then
    simulator_id="$created_id"
    selected_device_type="$candidate"
    selected_device_model="$(/usr/bin/ruby -rjson -e '
      requested = ARGV.fetch(0)
      types = JSON.parse(STDIN.read).fetch("devicetypes")
      selected = types.find { |type| type["identifier"] == requested }
      abort "missing selected device type" unless selected
      puts selected.fetch("name")
    ' "$candidate" <<<"$available_device_types")"
    break
  fi
done

if [ -z "$simulator_id" ]; then
  echo "error: the installed $runtime_name runtime supports none of the accepted screenshot devices" >&2
  exit 69
fi

echo "Using runtime: $runtime_identifier"
echo "Using device:  $selected_device_type"
echo "Device model:  $selected_device_model"
echo "Simulator:     $simulator_id"

if [ "$platform" = "watchos" ]; then
  ios_runtime_identifier="$({ xcrun simctl list runtimes available -j; } | /usr/bin/ruby -rjson -e '
    runtimes = JSON.parse(STDIN.read).fetch("runtimes")
    matches = runtimes.select do |runtime|
      runtime["isAvailable"] != false && runtime.fetch("name", "").start_with?("iOS")
    end
    exit 1 if matches.empty?
    chosen = matches.max_by do |runtime|
      runtime.fetch("version", "0").scan(/[0-9]+/).map(&:to_i)
    end
    puts chosen.fetch("identifier")
  ')" || {
    echo "error: watchOS Simulator capture needs an available paired iOS runtime" >&2
    exit 69
  }

  phone_device_types=(
    com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
    com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro
    com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro
    com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro
    com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro
  )
  for phone_candidate in "${phone_device_types[@]}"; do
    if ! /usr/bin/ruby -rjson -e '
      requested = ARGV.fetch(0)
      types = JSON.parse(STDIN.read).fetch("devicetypes")
      exit(types.any? { |type| type["identifier"] == requested } ? 0 : 1)
    ' "$phone_candidate" <<<"$available_device_types"; then
      continue
    fi
    if created_phone_id="$(xcrun simctl create \
        "QuakeSignal watch host $$" \
        "$phone_candidate" \
        "$ios_runtime_identifier" 2>/dev/null)"; then
      paired_phone_id="$created_phone_id"
      break
    fi
  done
  if [ -z "$paired_phone_id" ]; then
    echo "error: could not create the paired iPhone Simulator required by watchOS" >&2
    exit 69
  fi
  xcrun simctl pair "$simulator_id" "$paired_phone_id"
  echo "Paired phone:  $paired_phone_id"
  xcrun simctl boot "$paired_phone_id"
  xcrun simctl bootstatus "$paired_phone_id" -b
fi

xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b

if [ -z "$derived_data" ]; then
  derived_data="$temporary_root/DerivedData"
fi
build_destination="generic/platform=$destination_platform"

xcodebuild build \
  -project "$ios_root/QuakeSignal.xcodeproj" \
  -scheme "$scheme" \
  -configuration Debug \
  -destination "$build_destination" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO

build_settings="$temporary_root/build-settings.txt"
xcodebuild -showBuildSettings \
  -project "$ios_root/QuakeSignal.xcodeproj" \
  -scheme "$scheme" \
  -configuration Debug \
  -destination "$build_destination" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO > "$build_settings"

target_build_dir="$(awk -F ' = ' '$1 ~ /TARGET_BUILD_DIR$/ { print $2; exit }' "$build_settings")"
wrapper_name="$(awk -F ' = ' '$1 ~ /WRAPPER_NAME$/ { print $2; exit }' "$build_settings")"
app_path="$target_build_dir/$wrapper_name"
if [ -z "$target_build_dir" ] || [ -z "$wrapper_name" ] || [ ! -d "$app_path" ]; then
  echo "error: could not locate built app from Xcode build settings" >&2
  exit 70
fi

xcrun simctl install "$simulator_id" "$app_path"

launch_fixture_app() {
  local selected_frame="$1"
  shift
  /usr/bin/env \
    SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_AUTOMATION=1 \
    SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_FRAME="$selected_frame" \
    "SIMCTL_CHILD_AppleLanguages=($locale)" \
    "SIMCTL_CHILD_AppleLocale=$apple_locale" \
    SIMCTL_CHILD_TZ=UTC \
    xcrun simctl launch "$@" \
    "$simulator_id" \
    "$bundle_id" \
    --quakesignal-screenshot-automation \
    "--quakesignal-screenshot-frame=$selected_frame"
}

launch_fixture_app "$frame_selector" --terminate-running-process

# SwiftUI needs a short, bounded settling period after the process becomes
# launchable. The fixture does not issue network or permission requests.
sleep 5

candidate="$temporary_root/$platform-$locale.png"
# Simulator's black device mask preserves native pixels while avoiding a
# transparent corner channel on rounded Watch captures.
if [ "$platform" = "watchos" ]; then
  # CoreSimulator can take several minutes to service the first Watch request.
  # Keep the app foregrounded every 45 seconds, bound each request to five
  # minutes, and allow one semantically validated retry after a transition.
  watch_capture_status=0
  quakesignal_capture_validated_watch_screenshot \
    "$simulator_id" "$bundle_id" "$candidate" "$locale" "$apple_locale" \
    "$frame_selector" 300 45 "$temporary_root" \
    "$expected_width" "$expected_height" \
    "$script_dir/validate-watch-foreground-badge.rb" 5 sips /usr/bin/ruby || \
    watch_capture_status=$?
  if [ "$watch_capture_status" -ne 0 ]; then
    echo "error: Watch screenshot capture/validation failed with status $watch_capture_status" >&2
    exit "$watch_capture_status"
  fi
else
  xcrun simctl io "$simulator_id" screenshot --type=png --mask=black "$candidate"
fi

pixel_width="$(sips -g pixelWidth "$candidate" | awk '/pixelWidth:/ { print $2 }')"
pixel_height="$(sips -g pixelHeight "$candidate" | awk '/pixelHeight:/ { print $2 }')"
has_alpha="$(sips -g hasAlpha "$candidate" | awk '/hasAlpha:/ { print $2 }')"

if [ "$pixel_width" != "$expected_width" ] || [ "$pixel_height" != "$expected_height" ]; then
  echo "error: native capture is ${pixel_width}x${pixel_height}; expected ${expected_width}x${expected_height}" >&2
  echo "No resize was performed. Select the exact simulator device named above." >&2
  exit 65
fi
if [ "$has_alpha" = "yes" ]; then
  echo "error: native capture contains an alpha channel, which App Store Connect rejects" >&2
  exit 65
fi

if [ -e "$output" ] || [ -L "$output" ]; then
  echo "error: artifact output appeared during capture; refusing to overwrite: $output" >&2
  exit 73
fi
mv "$candidate" "$output"
screenshot_sha256="$(shasum -a 256 "$output" | awk '{ print $1 }')"
echo "$screenshot_sha256  $output"
echo "Captured native review candidate: $output (${pixel_width}x${pixel_height})"
echo "This artifact still requires named visual review before any metadata upload."

if [ -n "$provenance_output" ]; then
  export CAPTURE_PLATFORM="$platform"
  export CAPTURE_LOCALE="$locale"
  export CAPTURE_FRAME_SELECTOR="$frame_selector"
  export CAPTURE_PLANNED_FILE="$planned_file"
  export CAPTURE_SCREENSHOT_FILE="$(basename "$output")"
  export CAPTURE_SCREENSHOT_SHA256="$screenshot_sha256"
  export CAPTURE_PIXEL_WIDTH="$pixel_width"
  export CAPTURE_PIXEL_HEIGHT="$pixel_height"
  export CAPTURE_RUNTIME_IDENTIFIER="$runtime_identifier"
  export CAPTURE_DEVICE_TYPE_IDENTIFIER="$selected_device_type"
  export CAPTURE_DEVICE_MODEL="$selected_device_model"
  export CAPTURE_SIMULATOR_UDID="$simulator_id"
  /usr/bin/ruby -rjson -rtime -e '
    metadata = {
      schemaVersion: 1,
      status: "unapproved-debug-simulator-capture-evidence",
      uploadApproved: false,
      platform: ENV.fetch("CAPTURE_PLATFORM"),
      locale: ENV.fetch("CAPTURE_LOCALE"),
      captureSelector: ENV.fetch("CAPTURE_FRAME_SELECTOR"),
      plannedFile: ENV.fetch("CAPTURE_PLANNED_FILE"),
      screenshotFile: ENV.fetch("CAPTURE_SCREENSHOT_FILE"),
      screenshotSha256: ENV.fetch("CAPTURE_SCREENSHOT_SHA256"),
      pixels: [
        Integer(ENV.fetch("CAPTURE_PIXEL_WIDTH"), 10),
        Integer(ENV.fetch("CAPTURE_PIXEL_HEIGHT"), 10)
      ],
      capturedAtUtc: Time.now.utc.iso8601,
      selectedSimulator: {
        runtimeIdentifier: ENV.fetch("CAPTURE_RUNTIME_IDENTIFIER"),
        deviceTypeIdentifier: ENV.fetch("CAPTURE_DEVICE_TYPE_IDENTIFIER"),
        deviceModel: ENV.fetch("CAPTURE_DEVICE_MODEL"),
        udid: ENV.fetch("CAPTURE_SIMULATOR_UDID")
      }
    }
    File.write(ARGV.fetch(0), JSON.pretty_generate(metadata) + "\n", mode: "wx")
  ' "$provenance_output"
  echo "Recorded unapproved capture provenance: $provenance_output"
fi

if [ "$keep_simulator" = "1" ]; then
  echo "Preserved simulator: $simulator_id"
fi
