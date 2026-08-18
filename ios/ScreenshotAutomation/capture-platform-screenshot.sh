#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: capture-platform-screenshot.sh <tvos|watchos|visionos> <absolute-output.png>

Builds a Debug simulator app, launches it with QuakeSignal's deterministic
screenshot fixture, and captures an unmodified native PNG. The requested
platform runtime must already be installed. Captures inside the repository are
rejected so review candidates remain CI/manual artifacts until approved.

Optional environment:
  QUAKESIGNAL_SCREENSHOT_LOCALE=en|ja|zh-Hans  (default: en)
  QUAKESIGNAL_SCREENSHOT_KEEP_SIMULATOR=1      (preserve disposable simulator)
USAGE
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 64
fi

platform="$1"
requested_output="$2"
locale="${QUAKESIGNAL_SCREENSHOT_LOCALE:-en}"
keep_simulator="${QUAKESIGNAL_SCREENSHOT_KEEP_SIMULATOR:-0}"

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
if [ -e "$output" ]; then
  echo "error: refusing to overwrite existing artifact: $output" >&2
  exit 73
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
    expected_width=0
    expected_height=0
    device_types=(
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-2-49mm
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-49mm
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-3-49mm
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-10-46mm
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-9-45mm
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-8-45mm
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-7-45mm
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-SE-3-44mm
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-6-44mm
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-SE-44mm-2nd-generation
      com.apple.CoreSimulator.SimDeviceType.Apple-Watch-SE-44mm
    )
    ;;
  *)
    echo "error: unsupported platform '$platform'" >&2
    usage >&2
    exit 64
    ;;
esac

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

cleanup() {
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
trap cleanup EXIT INT TERM

available_device_types="$(xcrun simctl list devicetypes -j)"
selected_device_type=""
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
    break
  fi
done

if [ -z "$simulator_id" ]; then
  echo "error: the installed $runtime_name runtime supports none of the accepted screenshot devices" >&2
  exit 69
fi

if [ "$platform" = "watchos" ]; then
  case "$selected_device_type" in
    *Apple-Watch-Ultra-3-49mm) expected_width=422; expected_height=514 ;;
    *Apple-Watch-Ultra-2-49mm|*Apple-Watch-Ultra-49mm) expected_width=410; expected_height=502 ;;
    *Apple-Watch-Series-11-46mm|*Apple-Watch-Series-10-46mm) expected_width=416; expected_height=496 ;;
    *Apple-Watch-Series-9-45mm|*Apple-Watch-Series-8-45mm|*Apple-Watch-Series-7-45mm)
      expected_width=396; expected_height=484
      ;;
    *) expected_width=368; expected_height=448 ;;
  esac
fi

echo "Using runtime: $runtime_identifier"
echo "Using device:  $selected_device_type"
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

derived_data="$temporary_root/DerivedData"
destination="platform=$destination_platform,id=$simulator_id"

xcodebuild build \
  -project "$ios_root/QuakeSignal.xcodeproj" \
  -scheme "$scheme" \
  -configuration Debug \
  -destination "$destination" \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO

build_settings="$temporary_root/build-settings.txt"
xcodebuild -showBuildSettings \
  -project "$ios_root/QuakeSignal.xcodeproj" \
  -scheme "$scheme" \
  -configuration Debug \
  -destination "$destination" \
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

/usr/bin/env \
  SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_AUTOMATION=1 \
  "SIMCTL_CHILD_AppleLanguages=($locale)" \
  "SIMCTL_CHILD_AppleLocale=$apple_locale" \
  SIMCTL_CHILD_TZ=UTC \
  xcrun simctl launch --terminate-running-process \
    "$simulator_id" \
    "$bundle_id" \
    --quakesignal-screenshot-automation

# SwiftUI needs a short, bounded settling period after the process becomes
# launchable. The fixture does not issue network or permission requests.
sleep 5

candidate="$temporary_root/$platform-$locale.png"
# Simulator's black device mask preserves native pixels while avoiding a
# transparent corner channel on rounded Watch captures.
xcrun simctl io "$simulator_id" screenshot --type=png --mask=black "$candidate"

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

mv "$candidate" "$output"
shasum -a 256 "$output"
echo "Captured native review candidate: $output (${pixel_width}x${pixel_height})"
echo "This artifact still requires named visual review before any metadata upload."

if [ "$keep_simulator" = "1" ]; then
  echo "Preserved simulator: $simulator_id"
fi
