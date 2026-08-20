#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
test_temp_root="${QUAKESIGNAL_TEST_TEMP_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
if [ ! -d "$test_temp_root" ] || [ -L "$test_temp_root" ]; then
  echo "error: screenshot test temp root must be an existing plain directory" >&2
  exit 64
fi
test_temp_root="$(cd "$test_temp_root" && pwd -P)"
test_root="$(mktemp -d "$test_temp_root/quakesignal-maccatalyst-validator-test.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}
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
' "$script_dir/maccatalyst-validate-content.swift"

validator="$test_root/validator"
fixture="$test_root/fixture"
xcrun swiftc -O "$script_dir/maccatalyst-validate-content.swift" -o "$validator"
xcrun swiftc -O "$script_dir/maccatalyst-content-validator-fixture.swift" -o "$fixture"

expect_status() {
  local expected="$1"
  shift
  set +e
  "$@" >"$test_root/stdout" 2>"$test_root/stderr"
  local actual="$?"
  set -e
  if [ "$actual" -ne "$expected" ]; then
    echo "error: expected status $expected, received $actual: $*" >&2
    cat "$test_root/stdout" >&2
    cat "$test_root/stderr" >&2
    exit 1
  fi
}

selectors=(
  maccatalyst-home
  maccatalyst-reports
  maccatalyst-map
  maccatalyst-guide
  maccatalyst-alert-preferences
)
modes=(home reports map guide settings)
for index in 0 1 2 3 4; do
  selector="${selectors[$index]}"
  mode="${modes[$index]}"
  image="$test_root/$mode.png"
  evidence="$test_root/$mode.json"
  "$fixture" "$mode" "$image"
  expect_status 0 "$validator" "$selector" "$image" "$evidence"
  /usr/bin/ruby -rjson -rdigest -e '
    record = JSON.parse(File.read(ARGV.fetch(0)))
    abort "valid fixture was not accepted" unless record["status"] == "accepted" && record["reasons"] == []
    abort "valid semantic evidence is not bound to its PNG" unless
      record["imageFormat"] == "png" && record["imageSha256"] == Digest::SHA256.file(ARGV.fetch(1)).hexdigest
  ' "$evidence" "$image"
done

"$fixture" blank "$test_root/blank.png"
expect_status 65 "$validator" maccatalyst-home \
  "$test_root/blank.png" "$test_root/blank.json"
"$fixture" placeholder "$test_root/placeholder.png"
expect_status 65 "$validator" maccatalyst-home \
  "$test_root/placeholder.png" "$test_root/placeholder.json"
"$fixture" map-placeholder "$test_root/map-placeholder.png"
expect_status 65 "$validator" maccatalyst-map \
  "$test_root/map-placeholder.png" "$test_root/map-placeholder.json"
"$fixture" permission "$test_root/permission.png"
expect_status 65 "$validator" maccatalyst-home \
  "$test_root/permission.png" "$test_root/permission.json"
expect_status 65 "$validator" maccatalyst-map \
  "$test_root/home.png" "$test_root/wrong-route.json"

printf 'not an image\n' >"$test_root/invalid.png"
expect_status 70 "$validator" maccatalyst-home \
  "$test_root/invalid.png" "$test_root/invalid.json"
expect_status 64 "$validator" maccatalyst-unreviewed \
  "$test_root/home.png" "$test_root/unreviewed.json"

for evidence in blank placeholder map-placeholder permission wrong-route; do
  case "$evidence" in
    wrong-route) evidence_image="$test_root/home.png" ;;
    *) evidence_image="$test_root/$evidence.png" ;;
  esac
  /usr/bin/ruby -rjson -rdigest -e '
    record = JSON.parse(File.read(ARGV.fetch(0)))
    abort "semantic reject did not emit evidence" unless record["status"] == "rejected" && !record["reasons"].empty?
    abort "rejected semantic evidence is not bound to its PNG" unless
      record["imageFormat"] == "png" && record["imageSha256"] == Digest::SHA256.file(ARGV.fetch(1)).hexdigest
  ' "$test_root/$evidence.json" "$evidence_image"
done
if [ -e "$test_root/invalid.json" ] || [ -e "$test_root/unreviewed.json" ]; then
  echo "error: operational/usage failure unexpectedly emitted semantic evidence" >&2
  exit 1
fi

echo "Mac Catalyst content validator tests passed"
