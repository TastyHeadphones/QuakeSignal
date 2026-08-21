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

assert_sanitized_rejection_summary() {
  /usr/bin/ruby -rjson -e '
    stderr_path, evidence_path = ARGV
    lines = File.readlines(stderr_path, chomp: true).reject(&:empty?)
    summary_lines = lines.select { |line| line.start_with?("{") }
    abort "semantic reject must emit exactly one JSON summary line" unless summary_lines.length == 1
    summary = JSON.parse(summary_lines.first)
    abort "semantic reject summary keys drifted" unless summary.keys.sort == %w[counts metrics reasons]
    counts = summary.fetch("counts")
    abort "semantic reject count keys drifted" unless counts.keys.sort == %w[
      matchedForbiddenSystemPromptGroups matchedRequiredTermGroups
      recognizedText requiredTermGroups sampledPixels
    ].sort
    metrics = summary.fetch("metrics")
    abort "semantic reject metric keys drifted" unless metrics.keys.sort == %w[
      brightFraction chromaticFraction horizontalEdgeFraction
      luminanceStandardDeviation nonBlackFraction
    ].sort
    abort "semantic reject counts must contain only nonnegative integers" unless
      counts.values.all? { |value| value.is_a?(Integer) && value >= 0 }
    abort "semantic reject metrics must contain only finite numbers" unless
      metrics.values.all? { |value| value.is_a?(Numeric) && value.finite? }
    allowed_reasons = [
      "committed-view luminance variation is too low",
      "committed-view non-black coverage is too low",
      "committed-view bright-detail coverage is too low",
      "committed-view edge detail is too low",
      "committed-view recognized text inventory is too small",
      "requested route terms are missing",
      "a system permission dialog is visible",
      "map chromatic content is too low",
    ]
    reasons = summary.fetch("reasons")
    abort "semantic reject summary requires only fixed reasons" unless
      reasons.is_a?(Array) && !reasons.empty? && reasons.all? { |reason| allowed_reasons.include?(reason) }

    evidence = JSON.parse(File.read(evidence_path))
    checks = evidence.fetch("checks")
    committed = checks.fetch("committedView")
    metrics.each do |key, value|
      abort "semantic reject summary metric mismatch: #{key}" unless value == committed.fetch(key)
    end
    expected_counts = {
      "matchedForbiddenSystemPromptGroups" => checks.fetch("matchedForbiddenSystemPromptGroups").length,
      "matchedRequiredTermGroups" => checks.fetch("matchedRequiredTermGroups").length,
      "recognizedText" => checks.fetch("recognizedText").length,
      "requiredTermGroups" => 3,
      "sampledPixels" => committed.fetch("sampledPixels"),
    }
    abort "semantic reject summary count mismatch" unless counts == expected_counts
    abort "semantic reject summary reason mismatch" unless reasons == evidence.fetch("reasons")
  ' "$test_root/stderr" "$1"
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

"$fixture" ipad sparse-reports "$test_root/ipad-sparse-reports.png"
expect_status 0 "$validator" ios-ipad-13-reports \
  "$test_root/ipad-sparse-reports.png" "$test_root/ipad-sparse-reports.json"
/usr/bin/ruby -rjson -e '
  record = JSON.parse(File.read(ARGV.fetch(0)))
  metrics = record.fetch("checks").fetch("committedView")
  abort "sparse iPad Reports fixture did not exercise the calibrated band" unless
    metrics.fetch("nonBlackFraction") >= 0.004 && metrics.fetch("nonBlackFraction") < 0.12
  abort "sparse iPad Reports fixture bypassed an independent committed-view gate" unless
    metrics.fetch("luminanceStandardDeviation") >= 12 &&
    metrics.fetch("brightFraction") >= 0.004 &&
    metrics.fetch("horizontalEdgeFraction") >= 0.004 &&
    record.fetch("checks").fetch("recognizedText").length >= 5 &&
    record.fetch("checks").fetch("matchedRequiredTermGroups").length == 3
' "$test_root/ipad-sparse-reports.json"
expect_status 65 "$validator" ios-ipad-13-home \
  "$test_root/ipad-sparse-reports.png" "$test_root/ipad-sparse-wrong-route.json"
assert_sanitized_rejection_summary "$test_root/ipad-sparse-wrong-route.json"
/usr/bin/ruby -rjson -e '
  record = JSON.parse(File.read(ARGV.fetch(0)))
  abort "ordinary iPad selector accepted sparse Reports coverage" unless
    record.fetch("reasons").include?("committed-view non-black coverage is too low")
' "$test_root/ipad-sparse-wrong-route.json"

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

for evidence in blank placeholder map-placeholder permission wrong-route ipad-sparse-wrong-route; do
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
