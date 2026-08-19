#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/quakesignal-platform-interface-test.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

expect_status() {
  local expected_status="$1"
  shift
  local actual_status=0
  if "$@" >/dev/null 2>&1; then
    actual_status=0
  else
    actual_status=$?
  fi
  if [ "$actual_status" -ne "$expected_status" ]; then
    echo "error: expected status $expected_status, got $actual_status from $*" >&2
    exit 1
  fi
}

expect_status 64 "$script_dir/capture-platform-screenshot.sh"
expect_status 64 "$script_dir/capture-platform-screenshot.sh" \
  tvos tvos-unreviewed "$test_root/unreviewed.png"
expect_status 64 "$script_dir/capture-platform-screenshot.sh" \
  tvos tvos-dashboard relative.png
expect_status 64 env QUAKESIGNAL_SCREENSHOT_DERIVED_DATA=relative-cache \
  "$script_dir/capture-platform-screenshot.sh" \
  tvos tvos-dashboard "$test_root/relative-cache.png"

expect_status 64 "$script_dir/capture-platform-screenshot-set.sh"
expect_status 64 "$script_dir/capture-platform-screenshot-set.sh" \
  unreviewed "$test_root/unreviewed-set"
expect_status 64 env QUAKESIGNAL_SCREENSHOT_LOCALE=ja \
  "$script_dir/capture-platform-screenshot-set.sh" \
  tvos "$test_root/non-english-set"

mkdir "$test_root/existing-set"
expect_status 73 "$script_dir/capture-platform-screenshot-set.sh" \
  tvos "$test_root/existing-set"

ln -s "$test_root/missing-single-target.png" "$test_root/dangling-single.png"
expect_status 73 "$script_dir/capture-platform-screenshot.sh" \
  tvos tvos-dashboard "$test_root/dangling-single.png"

ln -s "$test_root/missing-provenance-target.json" "$test_root/dangling-provenance.json"
expect_status 73 env \
  QUAKESIGNAL_SCREENSHOT_PROVENANCE_OUTPUT="$test_root/dangling-provenance.json" \
  "$script_dir/capture-platform-screenshot.sh" \
  tvos tvos-dashboard "$test_root/provenance-guard.png"

ln -s "$test_root/missing-set-target" "$test_root/dangling-set"
expect_status 73 "$script_dir/capture-platform-screenshot-set.sh" \
  tvos "$test_root/dangling-set"

for forbidden_path in \
  "$script_dir/forbidden-single.png" \
  "$script_dir/forbidden-set"; do
  if [ -e "$forbidden_path" ]; then
    echo "error: interface test fixture unexpectedly exists: $forbidden_path" >&2
    exit 1
  fi
done
expect_status 64 "$script_dir/capture-platform-screenshot.sh" \
  tvos tvos-dashboard "$script_dir/forbidden-single.png"
expect_status 64 "$script_dir/capture-platform-screenshot-set.sh" \
  tvos "$script_dir/forbidden-set"

if find "$test_root" -type f -name '*.png' -print -quit | grep -q .; then
  echo "error: rejected interface input emitted a screenshot" >&2
  exit 1
fi

# Both foreground-only detail screens share a `%@` localization template.
# Passing a Double directly to that object placeholder crashes Foundation's
# vararg formatter before SwiftUI commits the frame, leaving a Watch clock or
# TV system raster. Require an explicitly formatted String argument in each
# platform-local source so this contract cannot regress unnoticed.
for detail_source in \
  "$script_dir/../QuakeSignalWatch/WatchDashboardView.swift" \
  "$script_dir/../QuakeSignalTV/TVDashboardView.swift"; do
  if grep -Fq 'L("quake.depth.label", depth)' "$detail_source"; then
    echo "error: detail depth must not pass a Double to the %@ localization placeholder: $detail_source" >&2
    exit 1
  fi
  grep -Fq 'Label(localizedDepthLabel(depth), systemImage: "arrow.down")' "$detail_source" || {
    echo "error: detail screen does not use the reviewed localized depth helper: $detail_source" >&2
    exit 1
  }
  grep -Fq 'locale: Locale(identifier: "en_US_POSIX")' "$detail_source" || {
    echo "error: detail depth helper lost its deterministic numeric locale: $detail_source" >&2
    exit 1
  }
  grep -Fq 'return L("quake.depth.label", depthText)' "$detail_source" || {
    echo "error: detail depth helper must pass formatted text to the %@ placeholder: $detail_source" >&2
    exit 1
  }
done

ruby - "$script_dir/../QuakeSignalWatch/WatchDashboardView.swift" <<'RUBY'
source = File.read(ARGV.fetch(0))
detail = source[/private struct WatchEventDetailView: View \{.*?(?=\nprivate func localizedDepthLabel)/m]
abort "error: Watch detail view block is missing" unless detail

checks = {
  "use a ScrollView as its first body container" =>
    /var body: some View \{\s*ScrollView \{/m,
  "place the foreground banner before the first metric row" =>
    /ScrollView \{\s*VStack\(alignment: \.leading, spacing: 10\) \{\s*foregroundBadge\s*HStack/m,
  "show localized depth beside magnitude in the first-baseline row" =>
    /HStack\(alignment: \.firstTextBaseline, spacing: 8\) \{\s*Text\(event\.magnitudeText\).*?Label\(localizedDepthLabel\(depth\), systemImage: "arrow\.down"\)/m,
  "reserve inline navigation-title space above its foreground banner" =>
    /\.navigationTitle\("detail\.title"\)\s*\.navigationBarTitleDisplayMode\(\.inline\)/m
}

checks.each do |requirement, pattern|
  abort "error: Watch detail must #{requirement}" unless detail.match?(pattern)
end
RUBY

echo "Platform screenshot interface tests passed"
