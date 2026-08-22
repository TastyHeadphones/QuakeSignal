#!/bin/bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: capture-maccatalyst-screenshot-set.sh <absolute-output-directory>

Captures all five reviewed English Mac Catalyst selectors from one exact clean
Git commit. Each direct @2x live-UIWindow hierarchy render and its request,
raw, window, and build evidence is validated before the complete unapproved
set is published atomically.

Optional environment:
  QUAKESIGNAL_CATALYST_SCREENSHOT_DERIVED_DATA=/absolute/cache/directory
USAGE
}

if [ "$#" -ne 1 ]; then
  usage >&2
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
debug_local_override="$repo_root/ios/QuakeSignal/Supporting/Debug.local.xcconfig"
# shellcheck source=maccatalyst-process-guard.sh
. "$script_dir/maccatalyst-process-guard.sh"
output_parent="$(dirname "$requested_output")"
mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd -P)"
output="$output_parent/$(basename "$requested_output")"
case "$output" in
  "$repo_root"|"$repo_root"/*)
    echo "error: capture output must be outside the repository: $repo_root" >&2
    exit 64
    ;;
esac
if [ -e "$output" ] || [ -L "$output" ]; then
  echo "error: refusing to overwrite existing capture directory: $output" >&2
  exit 73
fi

source_commit="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}')"
if [[ ! "$source_commit" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || \
   [ -n "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]; then
  echo "error: Mac Catalyst screenshot sets require an exact clean source commit" >&2
  exit 65
fi
if [ -e "$debug_local_override" ] || [ -L "$debug_local_override" ]; then
  echo "error: ignored Debug.local.xcconfig is forbidden for exact screenshot sets" >&2
  exit 65
fi

temporary_root="$(mktemp -d "$output_parent/.quakesignal-maccatalyst-set.XXXXXX")"
payload="$temporary_root/payload"
plan_tsv="$temporary_root/plan.tsv"
maccatalyst_active_child_pid=""
mkdir -p "$payload"
for directory in \
  app-logs \
  build-logs \
  capture-request-evidence \
  en-US \
  frame-capture-evidence \
  geometry-evidence \
  native-capture-evidence \
  raw-window-captures \
  semantic-evidence \
  semantic-rejections \
  transformation-evidence \
  window-observations; do
  mkdir -p "$payload/$directory"
done

cleanup() {
  quakesignal_maccatalyst_stop_processes "$maccatalyst_active_child_pid"
  maccatalyst_active_child_pid=""
  rm -rf "$temporary_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/ruby "$script_dir/maccatalyst-screenshot-plan.rb" --tsv >"$plan_tsv"
if [ ! -s "$plan_tsv" ]; then
  echo "error: reviewed Mac Catalyst screenshot plan is empty" >&2
  exit 65
fi
if [ "$(wc -l <"$plan_tsv" | tr -d ' ')" != "5" ]; then
  echo "error: reviewed Mac Catalyst screenshot plan must contain exactly five frames" >&2
  exit 65
fi

if [ -n "${QUAKESIGNAL_CATALYST_SCREENSHOT_DERIVED_DATA:-}" ]; then
  shared_derived_data="$QUAKESIGNAL_CATALYST_SCREENSHOT_DERIVED_DATA"
else
  shared_derived_data="$temporary_root/DerivedData"
fi

while IFS=$'\t' read -r selector planned_file width height; do
  if [ "$width" != "2560" ] || [ "$height" != "1600" ]; then
    echo "error: plan contains a non-native Mac Catalyst pixel size" >&2
    exit 65
  fi
  single_package="$temporary_root/single-$selector"
  quakesignal_maccatalyst_run_tracked env \
    QUAKESIGNAL_CATALYST_SCREENSHOT_DERIVED_DATA="$shared_derived_data" \
      "$script_dir/capture-maccatalyst-screenshot.sh" "$selector" "$single_package"

  /usr/bin/ruby -rpathname -e '
    root = Pathname.new(ARGV.fetch(0)).realpath
    selector = ARGV.fetch(1)
    planned_file = ARGV.fetch(2)
    expected_directories = %w[app-logs build-logs capture-request-evidence en-US frame-capture-evidence geometry-evidence native-capture-evidence raw-window-captures semantic-evidence semantic-rejections transformation-evidence window-observations]
    expected_files = [
      planned_file,
      "app-logs/#{selector}.log",
      "build-logs/#{selector}.log",
      "capture-request-evidence/#{selector}.json",
      "frame-capture-evidence/#{selector}.json",
      "geometry-evidence/#{selector}.json",
      "native-capture-evidence/#{selector}.json",
      "raw-window-captures/#{selector}.png",
      "semantic-evidence/#{selector}.json",
      "transformation-evidence/#{selector}.json",
      "window-observations/#{selector}-after.json",
      "window-observations/#{selector}-before.json",
    ].sort
    rejection = "semantic-rejections/#{selector}-attempt-1.json"
    rejection_image = "semantic-rejections/#{selector}-attempt-1.png"
    if root.join(rejection).file? && !root.join(rejection).symlink? &&
       root.join(rejection_image).file? && !root.join(rejection_image).symlink?
      expected_files.concat([rejection, rejection_image])
    elsif root.join(rejection).exist? || root.join(rejection).symlink? ||
          root.join(rejection_image).exist? || root.join(rejection_image).symlink?
      abort "semantic rejection JSON/PNG pair is incomplete or unsafe"
    end
    expected_files.sort!
    directories = []
    files = []
    visit = lambda do |directory|
      directory.children.sort_by(&:to_s).each do |entry|
        relative = entry.relative_path_from(root).to_s
        stat = entry.lstat
        if stat.directory?
          directories << relative
          visit.call(entry)
        elsif stat.file?
          files << relative
        else
          abort "single capture contains a symlink or special file"
        end
      end
    end
    visit.call(root)
    abort "single capture inventory differs" unless directories.sort == expected_directories && files.sort == expected_files
  ' "$single_package" "$selector" "$planned_file"

  mv "$single_package/$planned_file" "$payload/$planned_file"
  mv "$single_package/app-logs/$selector.log" "$payload/app-logs/$selector.log"
  mv "$single_package/build-logs/$selector.log" "$payload/build-logs/$selector.log"
  mv "$single_package/capture-request-evidence/$selector.json" "$payload/capture-request-evidence/$selector.json"
  mv "$single_package/frame-capture-evidence/$selector.json" "$payload/frame-capture-evidence/$selector.json"
  mv "$single_package/geometry-evidence/$selector.json" "$payload/geometry-evidence/$selector.json"
  mv "$single_package/native-capture-evidence/$selector.json" "$payload/native-capture-evidence/$selector.json"
  mv "$single_package/raw-window-captures/$selector.png" "$payload/raw-window-captures/$selector.png"
  mv "$single_package/semantic-evidence/$selector.json" "$payload/semantic-evidence/$selector.json"
  rejection_file="$single_package/semantic-rejections/$selector-attempt-1.json"
  rejection_image="$single_package/semantic-rejections/$selector-attempt-1.png"
  if [ -f "$rejection_file" ] && [ ! -L "$rejection_file" ]; then
    if [ ! -f "$rejection_image" ] || [ -L "$rejection_image" ]; then
      echo "error: semantic rejection JSON is missing its retained rejected PNG" >&2
      exit 65
    fi
    mv "$rejection_file" "$payload/semantic-rejections/$selector-attempt-1.json"
    mv "$rejection_image" "$payload/semantic-rejections/$selector-attempt-1.png"
  elif [ -e "$rejection_image" ] || [ -L "$rejection_image" ]; then
    echo "error: retained rejected PNG exists without semantic rejection JSON" >&2
    exit 65
  fi
  mv "$single_package/transformation-evidence/$selector.json" "$payload/transformation-evidence/$selector.json"
  mv "$single_package/window-observations/$selector-before.json" "$payload/window-observations/$selector-before.json"
  mv "$single_package/window-observations/$selector-after.json" "$payload/window-observations/$selector-after.json"
done <"$plan_tsv"

quakesignal_maccatalyst_run_tracked \
  /usr/bin/ruby "$script_dir/assemble-maccatalyst-screenshot-provenance.rb" \
  "$payload" "$payload/capture-provenance.json"
if [ ! -s "$payload/capture-provenance.json" ]; then
  echo "error: aggregate Mac Catalyst provenance was not assembled" >&2
  exit 65
fi
quakesignal_maccatalyst_run_tracked \
  /usr/bin/ruby "$script_dir/seal-screenshot-capture-package.rb" \
  maccatalyst "$source_commit" "$payload" "$payload/capture-package-manifest.json"
if [ "$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}')" != "$source_commit" ] || \
   [ -n "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]; then
  echo "error: source commit/tree changed during capture set" >&2
  exit 65
fi
if [ -e "$debug_local_override" ] || [ -L "$debug_local_override" ]; then
  echo "error: ignored Debug.local.xcconfig appeared during Catalyst capture set" >&2
  exit 65
fi
if [ -e "$output" ] || [ -L "$output" ]; then
  echo "error: output appeared during publication; refusing to overwrite" >&2
  exit 73
fi
mv "$payload" "$output"
echo "Captured exact unapproved Mac Catalyst screenshot set: $output"
echo "No screenshot in this directory is approved for upload."
