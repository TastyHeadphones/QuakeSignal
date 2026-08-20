#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
test_temp_parent="${QUAKESIGNAL_TEST_TEMP_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
if [ ! -d "$test_temp_parent" ]; then
  echo "error: screenshot test temporary parent is not an existing directory: $test_temp_parent" >&2
  exit 64
fi
test_temp_parent="$(cd "$test_temp_parent" && pwd -P)"
test_root="$(mktemp -d "$test_temp_parent/quakesignal-ios-validator-test.XXXXXX")"

cleanup() { rm -rf "$test_root"; }
trap cleanup EXIT

/usr/bin/ruby -e '
  source = File.read(ARGV.fetch(0))
  abort "validator must snapshot the image path exactly once" unless
    source.scan("Data(contentsOf: imageURL)").length == 1
  abort "CGImage decode must consume the immutable snapshot" unless
    source.include?("CGImageSourceCreateWithData(data as CFData") &&
    !source.include?("CGImageSourceCreateWithURL")
  abort "Vision OCR must consume the immutable snapshot" unless
    source.include?("VNImageRequestHandler(data: imageData)") &&
    !source.include?("VNImageRequestHandler(url:")
' "$script_dir/ios-screenshot-content-validator.swift"

validator="$test_root/validator"
fixture="$test_root/fixture"
xcrun swiftc -O "$script_dir/ios-screenshot-content-validator.swift" -o "$validator"
xcrun swiftc -O "$script_dir/ios-screenshot-content-validator-fixture.swift" -o "$fixture"

expect_status() {
  local expected="$1"
  shift
  set +e
  "$@" >"$test_root/stdout" 2>"$test_root/stderr"
  local actual="$?"
  set -e
  if [ "$actual" -ne "$expected" ]; then
    echo "error: expected status $expected, received $actual: $*" >&2
    /bin/cat "$test_root/stdout" "$test_root/stderr" >&2
    exit 1
  fi
}

selectors=(home reports map guide alert-preferences)
modes=(home reports map guide settings)
for index in 0 1 2 3 4; do
  selector="ios-iphone-6.5-${selectors[$index]}"
  mode="${modes[$index]}"
  image="$test_root/$mode.png"
  evidence="$test_root/$mode.json"
  "$fixture" iphone "$mode" "$image"
  expect_status 0 "$validator" "$selector" "$image" "$evidence"
done

"$fixture" ipad home "$test_root/ipad-home.png"
expect_status 0 "$validator" ios-ipad-13-home "$test_root/ipad-home.png" "$test_root/ipad-home.json"

"$fixture" iphone blank "$test_root/blank.png"
expect_status 65 "$validator" ios-iphone-6.5-home "$test_root/blank.png" "$test_root/blank.json"
"$fixture" iphone placeholder "$test_root/placeholder.png"
expect_status 65 "$validator" ios-iphone-6.5-home "$test_root/placeholder.png" "$test_root/placeholder.json"
"$fixture" iphone map-placeholder "$test_root/map-placeholder.png"
expect_status 65 "$validator" ios-iphone-6.5-map "$test_root/map-placeholder.png" "$test_root/map-placeholder.json"
"$fixture" iphone permission "$test_root/permission.png"
expect_status 65 "$validator" ios-iphone-6.5-home "$test_root/permission.png" "$test_root/permission.json"
expect_status 65 "$validator" ios-iphone-6.5-map "$test_root/home.png" "$test_root/wrong-route.json"

printf 'not an image\n' >"$test_root/invalid.png"
expect_status 70 "$validator" ios-iphone-6.5-home "$test_root/invalid.png" "$test_root/invalid.json"
expect_status 64 "$validator" ios-iphone-unreviewed "$test_root/home.png" "$test_root/unreviewed.json"

for evidence in blank placeholder map-placeholder permission wrong-route; do
  /usr/bin/ruby -rjson -e '
    record = JSON.parse(File.read(ARGV.fetch(0)))
    abort "semantic reject did not emit evidence" unless record["status"] == "rejected" && !record["reasons"].empty?
  ' "$test_root/$evidence.json"
done
if [ -e "$test_root/invalid.json" ] || [ -e "$test_root/unreviewed.json" ]; then
  echo "error: operational/usage failure unexpectedly emitted semantic evidence" >&2
  exit 1
fi

echo "iOS/iPadOS screenshot content validator tests passed"
