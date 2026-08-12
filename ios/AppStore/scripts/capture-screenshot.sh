#!/usr/bin/env bash
# Capture the currently visible iOS Simulator screen as an App Store-ready JPEG.
# The caller must first navigate the app to the frame specified in
# ../screenshot-manifest.json. This script deliberately does not automate
# product-page content or overwrite an approved asset.

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_STORE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  capture-screenshot.sh [--device <UDID|booted>] [--class <6.9|6.3>] <locale> <frame>

Examples:
  capture-screenshot.sh --device booted --class 6.9 en-US 01-home
  capture-screenshot.sh --class 6.3 ja 04-guide

Locales: en-US, ja, zh-Hans
Frames:  01-home, 02-reports, 03-map, 04-guide, 05-alert-preferences

The simulator must already show the intended localized app screen. Output is
written as ios/AppStore/screenshots/<locale>/iphone-<class>/<frame>.jpg.
EOF
}

device="booted"
display_class="6.9"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      device="$2"
      shift 2
      ;;
    --class)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      display_class="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -eq 2 ]] || { usage >&2; exit 2; }
locale="$1"
frame="$2"

case "$locale" in
  en-US|ja|zh-Hans) ;;
  *)
    printf 'Unsupported locale: %s\n' "$locale" >&2
    exit 2
    ;;
esac

case "$frame" in
  01-home|02-reports|03-map|04-guide|05-alert-preferences) ;;
  *)
    printf 'Unsupported frame: %s\n' "$frame" >&2
    exit 2
    ;;
esac

case "$display_class" in
  6.9|6.3) ;;
  *)
    printf 'Unsupported display class: %s\n' "$display_class" >&2
    exit 2
    ;;
esac

readonly output_dir="${APP_STORE_DIR}/screenshots/${locale}/iphone-${display_class}"
readonly output_file="${output_dir}/${frame}.jpg"

if [[ -e "$output_file" ]]; then
  printf 'Refusing to overwrite existing asset: %s\n' "$output_file" >&2
  exit 1
fi

readonly temporary_dir="$(mktemp -d -t quakesignal-screenshot)"
readonly raw_file="${temporary_dir}/capture.png"
trap 'rm -rf "$temporary_dir"' EXIT

mkdir -p "$output_dir"

# --mask=black removes the simulated device-corner transparency. JPEG output
# below guarantees no alpha channel, as required by App Store Connect.
xcrun simctl io "$device" screenshot --type=png --mask=black "$raw_file"
sips -s format jpeg -s formatOptions 100 "$raw_file" --out "$output_file" >/dev/null

width="$(sips -g pixelWidth "$output_file" | awk '/pixelWidth/ { print $2 }')"
height="$(sips -g pixelHeight "$output_file" | awk '/pixelHeight/ { print $2 }')"

case "${display_class}:${width}x${height}" in
  6.9:1260x2736|6.9:1290x2796|6.9:1320x2868|6.3:1179x2556|6.3:1206x2622) ;;
  *)
    printf 'Unexpected %s screenshot dimensions: %sx%s\n' "$display_class" "$width" "$height" >&2
    printf 'The file was kept for diagnosis: %s\n' "$output_file" >&2
    exit 1
    ;;
esac

format="$(sips -g format "$output_file" | awk '/format/ { print tolower($2) }')"
if [[ "$format" != "jpeg" ]]; then
  printf 'Expected JPEG output, received: %s\n' "$format" >&2
  exit 1
fi

printf 'Captured %s (%sx%s)\n' "$output_file" "$width" "$height"
