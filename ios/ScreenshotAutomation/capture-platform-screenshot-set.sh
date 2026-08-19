#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: capture-platform-screenshot-set.sh <tvos|watchos|visionos> <absolute-output-directory>

Captures the exact English (U.S.) frame inventory in the checked-in platform
manifest. The output directory is created atomically only after every native
PNG and every unapproved Debug Simulator provenance record validates.
USAGE
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 64
fi

platform="$1"
requested_output="$2"
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
ios_root="$(cd "$script_dir/.." && pwd -P)"
repo_root="$(cd "$ios_root/.." && pwd -P)"

case "$platform" in
  tvos|watchos|visionos) ;;
  *)
    echo "error: unsupported platform '$platform'" >&2
    usage >&2
    exit 64
    ;;
esac
if [ "${QUAKESIGNAL_SCREENSHOT_LOCALE:-en}" != "en" ]; then
  echo "error: the reviewed platform set currently contains English (U.S.) only" >&2
  exit 64
fi
if [[ "$requested_output" != /* ]]; then
  echo "error: output directory must be an absolute path" >&2
  exit 64
fi

output_parent="$(dirname "$requested_output")"
output_name="$(basename "$requested_output")"
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd -P)"
output="$output_parent/$output_name"
case "$output" in
  "$repo_root"|"$repo_root"/*)
    echo "error: screenshot output must be outside the repository: $repo_root" >&2
    exit 64
    ;;
esac
if [ -e "$output" ] || [ -L "$output" ]; then
  echo "error: refusing to overwrite existing artifact directory: $output" >&2
  exit 73
fi

temporary_root="$(mktemp -d "$output_parent/.quakesignal-$platform-set.XXXXXX")"
payload="$temporary_root/payload"
plan_tsv="$temporary_root/plan.tsv"
mkdir -p "$payload/en-US" "$payload/frame-capture-evidence"

cleanup() {
  rm -rf "$temporary_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/ruby "$script_dir/platform-screenshot-plan.rb" "$platform" --tsv > "$plan_tsv"
if [ ! -s "$plan_tsv" ]; then
  echo "error: reviewed platform screenshot plan is empty" >&2
  exit 65
fi

if [ -n "${QUAKESIGNAL_SCREENSHOT_DERIVED_DATA:-}" ]; then
  shared_derived_data="$QUAKESIGNAL_SCREENSHOT_DERIVED_DATA"
else
  shared_derived_data="$temporary_root/DerivedData"
fi

while IFS=$'\t' read -r frame_selector relative_file _width _height; do
  screenshot_output="$payload/$relative_file"
  capture_evidence="$payload/frame-capture-evidence/$frame_selector.json"
  QUAKESIGNAL_SCREENSHOT_LOCALE=en \
  QUAKESIGNAL_SCREENSHOT_DERIVED_DATA="$shared_derived_data" \
  QUAKESIGNAL_SCREENSHOT_PROVENANCE_OUTPUT="$capture_evidence" \
    "$script_dir/capture-platform-screenshot.sh" \
      "$platform" "$frame_selector" "$screenshot_output"
done < "$plan_tsv"

/usr/bin/ruby "$script_dir/assemble-platform-screenshot-provenance.rb" \
  "$platform" "$payload" "$payload/capture-provenance.json"
test -s "$payload/capture-provenance.json"

if [ -e "$output" ] || [ -L "$output" ]; then
  echo "error: artifact directory appeared during capture; refusing to overwrite: $output" >&2
  exit 73
fi
mv "$payload" "$output"
echo "Captured exact unapproved $platform screenshot set: $output"
echo "No screenshot in this directory is approved for upload."
