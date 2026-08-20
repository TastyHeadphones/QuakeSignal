#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
source "$script_dir/watch-capture-guard.sh"
source "$script_dir/vision-map-capture-guard.sh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/quakesignal-vision-guard-test.XXXXXX")"
watch_reactivation_pid=""
screenshot_pid=""
signal_supervisor_pid=""
export QUAKESIGNAL_XCRUN_EXECUTABLE="$script_dir/watch-capture-guard-xcrun-stub.rb"
export QUAKESIGNAL_TEST_EXPECTED_FRAME=visionos-home
export QUAKESIGNAL_TEST_CAPTURE_DELAY=0
export QUAKESIGNAL_TEST_CAPTURE_STATUS=0
export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$test_root/capture.pid"
export QUAKESIGNAL_TEST_CAPTURE_RELEASE_FILE=""
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=0
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$test_root/reactivation.pid"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$test_root/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_RELEASE_FILE=""
export QUAKESIGNAL_TEST_IGNORE_TERM=0

cleanup() {
  quakesignal_stop_processes \
    "$signal_supervisor_pid" "$screenshot_pid" "$watch_reactivation_pid"
  rm -rf "$test_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

expect_status() {
  local expected_status="$1"
  shift
  local actual_status=0
  if "$@"; then
    actual_status=0
  else
    actual_status=$?
  fi
  if [ "$actual_status" -ne "$expected_status" ]; then
    echo "error: expected status $expected_status, got $actual_status from $*" >&2
    exit 1
  fi
}

assert_file_content() {
  local file_path="$1"
  local expected_content="$2"
  local label="$3"
  if [ ! -f "$file_path" ] || [ "$(<"$file_path")" != "$expected_content" ]; then
    echo "error: $label did not contain the expected test payload" >&2
    exit 1
  fi
}

assert_recorded_process_stopped() {
  local pid_file="$1"
  local label="$2"
  if [ ! -s "$pid_file" ]; then
    echo "error: $label did not record its child PID" >&2
    exit 1
  fi
  local recorded_pid
  recorded_pid="$(sed -n '1p' "$pid_file")"
  if kill -0 "$recorded_pid" >/dev/null 2>&1; then
    echo "error: $label child $recorded_pid survived bounded cleanup" >&2
    exit 1
  fi
}

capture_vision() {
  local directory="$1"
  local validator="$2"
  local settle_seconds="${3:-0}"
  local frame_selector="${4:-visionos-home}"
  export QUAKESIGNAL_TEST_EXPECTED_FRAME="$frame_selector"
  quakesignal_capture_validated_vision_screenshot \
    fake-vision fake.bundle "$directory/candidate.png" en en_US \
    "$frame_selector" "$directory" 3840 2160 "$validator" "$settle_seconds" \
    "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby
}

reviewed_frames=(
  visionos-home
  visionos-reports
  visionos-map
  visionos-guide
  visionos-alert-preferences
)

expect_status 64 quakesignal_capture_validated_vision_screenshot

mkdir "$test_root/invalid-selector"
expect_status 64 quakesignal_capture_validated_vision_screenshot \
  fake-vision fake.bundle "$test_root/invalid-selector/candidate.png" en en_US \
  visionos-emergency-history "$test_root/invalid-selector" 3840 2160 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby

mkdir "$test_root/invalid-settle"
for invalid_settle in "" 00 01 -1 1x; do
  expect_status 64 quakesignal_capture_validated_vision_screenshot \
    fake-vision fake.bundle "$test_root/invalid-settle/candidate.png" en en_US \
    visionos-map "$test_root/invalid-settle" 3840 2160 \
    "$QUAKESIGNAL_XCRUN_EXECUTABLE" "$invalid_settle" \
    "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby
done

mkdir "$test_root/real-root"
ln -s "$test_root/real-root" "$test_root/root-symlink"
expect_status 64 quakesignal_capture_validated_vision_screenshot \
  fake-vision fake.bundle "$test_root/root-symlink/candidate.png" en en_US \
  visionos-map "$test_root/root-symlink" 3840 2160 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby

mkdir "$test_root/outside-root"
expect_status 64 quakesignal_capture_validated_vision_screenshot \
  fake-vision fake.bundle "$test_root/outside-root/candidate.png" en en_US \
  visionos-map "$test_root/real-root" 3840 2160 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby

ln -s "$QUAKESIGNAL_XCRUN_EXECUTABLE" "$test_root/validator-symlink.rb"
expect_status 64 quakesignal_capture_validated_vision_screenshot \
  fake-vision fake.bundle "$test_root/real-root/candidate.png" en en_US \
  visionos-map "$test_root/real-root" 3840 2160 \
  "$test_root/validator-symlink.rb" 0 "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby

existing_candidate_directory="$test_root/existing-candidate"
mkdir "$existing_candidate_directory"
touch "$existing_candidate_directory/candidate.png"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$existing_candidate_directory/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$existing_candidate_directory/reactivated"
expect_status 73 capture_vision "$existing_candidate_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE"
if [ -e "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" ] ||
    [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ]; then
  echo "error: existing Vision candidate still captured or relaunched" >&2
  exit 1
fi

candidate_symlink_directory="$test_root/candidate-symlink"
mkdir "$candidate_symlink_directory"
ln -s "$candidate_symlink_directory/missing.png" "$candidate_symlink_directory/candidate.png"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$candidate_symlink_directory/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$candidate_symlink_directory/reactivated"
expect_status 73 capture_vision "$candidate_symlink_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE"

existing_bitmap_directory="$test_root/existing-bitmap"
mkdir "$existing_bitmap_directory"
touch "$existing_bitmap_directory/vision-validation-1.bmp"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$existing_bitmap_directory/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$existing_bitmap_directory/reactivated"
expect_status 73 capture_vision "$existing_bitmap_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE"
if [ -e "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" ] ||
    [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ]; then
  echo "error: existing Vision validation bitmap still captured or relaunched" >&2
  exit 1
fi

bitmap_symlink_directory="$test_root/bitmap-symlink"
mkdir "$bitmap_symlink_directory"
ln -s "$bitmap_symlink_directory/missing.bmp" \
  "$bitmap_symlink_directory/vision-validation-1.bmp"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$bitmap_symlink_directory/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$bitmap_symlink_directory/reactivated"
expect_status 73 capture_vision "$bitmap_symlink_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE"
if [ -e "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" ] ||
    [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ]; then
  echo "error: symlinked Vision validation bitmap still captured or relaunched" >&2
  exit 1
fi

for reviewed_frame in "${reviewed_frames[@]}"; do
  pass_directory="$test_root/pass-first-$reviewed_frame"
  mkdir "$pass_directory"
  export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="valid"
  export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$pass_directory/capture-count"
  export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$pass_directory/reactivated"
  expect_status 0 capture_vision \
    "$pass_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 "$reviewed_frame"
  assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 1 \
    "pass-first $reviewed_frame capture count"
  assert_file_content "$pass_directory/candidate.png" valid \
    "pass-first $reviewed_frame candidate"
  if [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ] ||
      [ -e "$pass_directory/rejected-vision-attempt-1.png" ]; then
    echo "error: pass-first $reviewed_frame validation retried or quarantined a valid raster" >&2
    exit 1
  fi

  retry_directory="$test_root/reject-pass-$reviewed_frame"
  mkdir "$retry_directory"
  export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="invalid|valid"
  export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$retry_directory/capture-count"
  export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$retry_directory/reactivated"
  expect_status 0 capture_vision \
    "$retry_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 "$reviewed_frame"
  assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 2 \
    "retry $reviewed_frame capture count"
  assert_file_content "$retry_directory/rejected-vision-attempt-1.png" invalid \
    "quarantined $reviewed_frame raster"
  assert_file_content "$retry_directory/candidate.png" valid \
    "accepted $reviewed_frame retry raster"
  assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 1 \
    "reject-pass $reviewed_frame exact-frame relaunch count"
done

reject_directory="$test_root/reject-reject"
mkdir "$reject_directory"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="invalid|invalid|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$reject_directory/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$reject_directory/reactivated"
expect_status 65 capture_vision "$reject_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE"
assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 2 "reject-twice capture count"
assert_file_content "$reject_directory/rejected-vision-attempt-1.png" invalid \
  "first rejected Vision raster"
assert_file_content "$reject_directory/rejected-vision-attempt-2.png" invalid \
  "second rejected Vision raster"
assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 1 \
  "reject-twice exact-frame relaunch count"
if [ -e "$reject_directory/candidate.png" ]; then
  echo "error: reject-twice Vision validation left a publishable candidate" >&2
  exit 1
fi
if [ -e "$reject_directory/final.png" ] ||
    [ -e "$reject_directory/capture-provenance.json" ]; then
  echo "error: reject-twice Vision validation published an artifact or provenance" >&2
  exit 1
fi

quarantine_directory="$test_root/quarantine-refusal"
mkdir "$quarantine_directory"
touch "$quarantine_directory/rejected-vision-attempt-1.png"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="invalid|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$quarantine_directory/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$quarantine_directory/reactivated"
expect_status 73 capture_vision "$quarantine_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE"
if [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ]; then
  echo "error: quarantine refusal still relaunched the Vision fixture" >&2
  exit 1
fi

conversion_directory="$test_root/conversion-failure"
mkdir "$conversion_directory"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$conversion_directory/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$conversion_directory/reactivated"
expect_status 70 quakesignal_capture_validated_vision_screenshot \
  fake-vision fake.bundle "$conversion_directory/candidate.png" en en_US \
  visionos-home "$conversion_directory" 3840 2160 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 /usr/bin/false /usr/bin/ruby
if [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ]; then
  echo "error: conversion failure must not relaunch the Vision fixture" >&2
  exit 1
fi

validator_failure_directory="$test_root/validator-operational-failure"
mkdir "$validator_failure_directory"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="operational|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validator_failure_directory/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validator_failure_directory/reactivated"
export QUAKESIGNAL_TEST_VALIDATOR_OPERATIONAL_STATUS=70
expect_status 70 capture_vision "$validator_failure_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE"
assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 1 \
  "validator-operational-failure capture count"
if [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ] ||
    [ -e "$validator_failure_directory/rejected-vision-attempt-1.png" ]; then
  echo "error: validator operational failure retried or quarantined the Vision frame" >&2
  exit 1
fi

validator_usage_directory="$test_root/validator-usage-failure"
mkdir "$validator_usage_directory"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="operational|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validator_usage_directory/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validator_usage_directory/reactivated"
export QUAKESIGNAL_TEST_VALIDATOR_OPERATIONAL_STATUS=64
expect_status 70 capture_vision "$validator_usage_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE"
assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 1 \
  "validator-usage-failure capture count"
if [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ] ||
    [ -e "$validator_usage_directory/rejected-vision-attempt-1.png" ]; then
  echo "error: validator usage failure retried or quarantined the Vision frame" >&2
  exit 1
fi
export QUAKESIGNAL_TEST_VALIDATOR_OPERATIONAL_STATUS=70

relaunch_directory="$test_root/relaunch-failure"
mkdir "$relaunch_directory"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="invalid|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$relaunch_directory/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$relaunch_directory/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=29
expect_status 70 capture_vision "$relaunch_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE"
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=0
assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 1 "relaunch-failure capture count"

capture_failure_directory="$test_root/capture-failure"
mkdir "$capture_failure_directory"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$capture_failure_directory/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$capture_failure_directory/reactivated"
export QUAKESIGNAL_TEST_CAPTURE_STATUS=23
expect_status 70 capture_vision "$capture_failure_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE"
export QUAKESIGNAL_TEST_CAPTURE_STATUS=0

sleep_failure_directory="$test_root/sleep-failure"
mkdir "$sleep_failure_directory"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="invalid|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$sleep_failure_directory/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$sleep_failure_directory/reactivated"
expect_status 70 bash -c '
  source "$1/watch-capture-guard.sh"
  source "$1/vision-map-capture-guard.sh"
  screenshot_pid=""
  watch_reactivation_pid=""
  export QUAKESIGNAL_TEST_EXPECTED_FRAME=visionos-home
  sleep() { return 23; }
  quakesignal_capture_validated_vision_screenshot \
    fake-vision fake.bundle "$2/candidate.png" en en_US visionos-home \
    "$2" 3840 2160 "$3" 5 "$3" /usr/bin/ruby
' bash "$script_dir" "$sleep_failure_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE"
assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 1 \
  "sleep-failure capture count"
assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 1 \
  "sleep-failure exact-frame relaunch count"
if [ -e "$sleep_failure_directory/candidate.png" ]; then
  echo "error: interrupted Vision retry settle left a publishable candidate" >&2
  exit 1
fi

signal_directory="$test_root/relaunch-signal"
mkdir "$signal_directory"
signal_reactivation_pid_file="$signal_directory/reactivation.pid"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="invalid|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$signal_directory/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$signal_directory/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$signal_reactivation_pid_file"
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=5
export QUAKESIGNAL_TEST_SIGNAL_PARENT_MODE=launch
export QUAKESIGNAL_TEST_SIGNAL_PARENT=TERM
export QUAKESIGNAL_TEST_HOLD_PID_ASSIGNMENT=1
(
  watch_reactivation_pid=""
  signal_cleanup() {
    quakesignal_stop_processes "$watch_reactivation_pid"
  }
  trap signal_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  capture_vision "$signal_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE"
) &
signal_supervisor_pid=$!
signal_status=0
if wait "$signal_supervisor_pid"; then
  signal_status=0
else
  signal_status=$?
fi
signal_supervisor_pid=""
if [ "$signal_status" -ne 143 ]; then
  echo "error: TERM during Vision relaunch tracking returned $signal_status instead of 143" >&2
  exit 1
fi
assert_recorded_process_stopped "$signal_reactivation_pid_file" "Vision relaunch"
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_SIGNAL_PARENT_MODE=""
export QUAKESIGNAL_TEST_HOLD_PID_ASSIGNMENT=0
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$test_root/reactivation.pid"

capture_signal_directory="$test_root/capture-signal"
mkdir "$capture_signal_directory"
capture_signal_pid_file="$capture_signal_directory/capture.pid"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$capture_signal_directory/capture-count"
export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$capture_signal_pid_file"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$capture_signal_directory/reactivated"
export QUAKESIGNAL_TEST_CAPTURE_DELAY=5
export QUAKESIGNAL_TEST_SIGNAL_PARENT_MODE=io
export QUAKESIGNAL_TEST_SIGNAL_PARENT=TERM
export QUAKESIGNAL_TEST_HOLD_PID_ASSIGNMENT=1
(
  screenshot_pid=""
  watch_reactivation_pid=""
  signal_cleanup() {
    quakesignal_stop_processes "$screenshot_pid" "$watch_reactivation_pid"
  }
  trap signal_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  capture_vision "$capture_signal_directory" "$QUAKESIGNAL_XCRUN_EXECUTABLE"
) &
signal_supervisor_pid=$!
capture_signal_status=0
if wait "$signal_supervisor_pid"; then
  capture_signal_status=0
else
  capture_signal_status=$?
fi
signal_supervisor_pid=""
if [ "$capture_signal_status" -ne 143 ]; then
  echo "error: TERM during Vision screenshot tracking returned $capture_signal_status instead of 143" >&2
  exit 1
fi
assert_recorded_process_stopped "$capture_signal_pid_file" "Vision screenshot"
export QUAKESIGNAL_TEST_CAPTURE_DELAY=0
export QUAKESIGNAL_TEST_SIGNAL_PARENT_MODE=""
export QUAKESIGNAL_TEST_HOLD_PID_ASSIGNMENT=0
export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$test_root/capture.pid"

echo "Vision capture guard tests passed"
