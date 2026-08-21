#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
source "$script_dir/watch-capture-guard.sh"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/quakesignal-watch-guard-test.XXXXXX")"
screenshot_pid=""
watch_reactivation_pid=""
signal_supervisor_pid=""
helper_test_pid=""
spawn_race_supervisor_pid=""
gated_test_supervisor_pid=""
export QUAKESIGNAL_XCRUN_EXECUTABLE="$script_dir/watch-capture-guard-xcrun-stub.rb"
export QUAKESIGNAL_TEST_CAPTURE_DELAY=0
export QUAKESIGNAL_TEST_CAPTURE_STATUS=0
export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$test_root/capture.pid"
export QUAKESIGNAL_TEST_CAPTURE_RELEASE_FILE=""
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=0
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES=""
export QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE=""
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$test_root/reactivation.pid"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$test_root/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_RELEASE_FILE=""
export QUAKESIGNAL_TEST_RELEASE_TIMEOUT=20
export QUAKESIGNAL_TEST_IGNORE_TERM=0
export QUAKESIGNAL_TEST_EXPECTED_FRAME=watchos-headline
export QUAKESIGNAL_TEST_VALIDATOR_OPERATIONAL_STATUS=70

cleanup() {
  quakesignal_stop_processes \
    "$signal_supervisor_pid" "$spawn_race_supervisor_pid" \
    "$gated_test_supervisor_pid" "$helper_test_pid" \
    "$screenshot_pid" "$watch_reactivation_pid"
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

assert_recorded_process_stopped() {
  local pid_file="$1"
  local label="$2"
  if [ ! -s "$pid_file" ]; then
    echo "error: $label did not record its real child PID" >&2
    exit 1
  fi
  local recorded_pid
  recorded_pid="$(sed -n '1p' "$pid_file")"
  if kill -0 "$recorded_pid" >/dev/null 2>&1; then
    echo "error: $label child $recorded_pid survived bounded cleanup" >&2
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

capture_and_publish_validated_watch() {
  local directory="$1"
  local capture_status=0

  quakesignal_capture_validated_watch_screenshot \
    fake-watch fake.bundle "$directory/candidate.png" en en_US \
    watchos-headline 4 1 "$directory" 410 502 \
    "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 \
    "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby || \
    capture_status=$?
  if [ "$capture_status" -ne 0 ]; then
    return "$capture_status"
  fi
  mv "$directory/candidate.png" "$directory/accepted-candidate.png"
}

launch_and_publish_initial_watch() {
  local directory="$1"
  local launch_status=0

  quakesignal_launch_exact_watch_frame \
    fake-watch fake.bundle en en_US watchos-headline || launch_status=$?
  if [ "$launch_status" -ne 0 ]; then
    return "$launch_status"
  fi
  printf 'accepted\n' > "$directory/accepted-candidate.png"
  printf '{}\n' > "$directory/capture-provenance.json"
}

wait_for_nonempty_file() {
  local file="$1"
  local label="$2"
  local attempt=0
  while [ ! -s "$file" ] && [ "$attempt" -lt 200 ]; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  if [ ! -s "$file" ]; then
    echo "error: timed out waiting for $label marker" >&2
    exit 1
  fi
}

wait_for_file_content() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local attempt=0
  while { [ ! -f "$file" ] || [ "$(<"$file")" != "$expected" ]; } && \
      [ "$attempt" -lt 400 ]; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  if [ ! -f "$file" ] || [ "$(<"$file")" != "$expected" ]; then
    echo "error: timed out waiting for $label content" >&2
    exit 1
  fi
}

wait_for_recorded_process_stopped() {
  local pid_file="$1"
  local label="$2"
  local recorded_pid
  local attempt=0

  wait_for_nonempty_file "$pid_file" "$label PID"
  recorded_pid="$(sed -n '1p' "$pid_file")"
  while kill -0 "$recorded_pid" >/dev/null 2>&1 && \
      [ "$attempt" -lt 200 ]; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  if kill -0 "$recorded_pid" >/dev/null 2>&1; then
    echo "error: timed out waiting for $label child $recorded_pid to stop" >&2
    exit 1
  fi
}

run_same_poll_completion_test() {
  local reactivation_status="$1"
  local label="$2"
  local capture_pid_file="$test_root/$label-capture.pid"
  local reactivation_pid_file="$test_root/$label-reactivation.pid"
  local capture_release_file="$test_root/$label-capture.release"
  local reactivation_release_file="$test_root/$label-reactivation.release"
  local guard_status=0

  rm -f \
    "$capture_pid_file" "$reactivation_pid_file" \
    "$capture_release_file" "$reactivation_release_file"
  export QUAKESIGNAL_TEST_CAPTURE_DELAY=0
  export QUAKESIGNAL_TEST_CAPTURE_STATUS=0
  export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$capture_pid_file"
  export QUAKESIGNAL_TEST_CAPTURE_RELEASE_FILE="$capture_release_file"
  export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
  export QUAKESIGNAL_TEST_REACTIVATION_STATUS="$reactivation_status"
  export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$reactivation_pid_file"
  export QUAKESIGNAL_TEST_REACTIVATION_RELEASE_FILE="$reactivation_release_file"

  (
    screenshot_pid=""
    watch_reactivation_pid=""

    gated_cleanup() {
      quakesignal_stop_processes "$screenshot_pid" "$watch_reactivation_pid"
    }
    trap gated_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    quakesignal_capture_watch_screenshot \
      fake-watch fake.bundle "$test_root/$label.png" en en_US \
      watchos-headline 300 1
  ) &
  gated_test_supervisor_pid=$!

  # Both external children are now blocked on distinct release files. Complete
  # the restart first, then release the screenshot in the same controller
  # cycle. The outcome no longer depends on two equal-duration sleeps or on
  # which child the scheduler happens to run first.
  wait_for_nonempty_file "$capture_pid_file" "$label screenshot PID"
  wait_for_nonempty_file "$reactivation_pid_file" "$label reactivation PID"
  touch "$reactivation_release_file"
  wait_for_recorded_process_stopped "$reactivation_pid_file" \
    "$label reactivation"
  touch "$capture_release_file"

  if wait "$gated_test_supervisor_pid"; then
    guard_status=0
  else
    guard_status=$?
  fi
  gated_test_supervisor_pid=""
  if [ "$guard_status" -ne 70 ]; then
    echo "error: $label expected status 70, got $guard_status" >&2
    exit 1
  fi
  assert_recorded_process_stopped "$capture_pid_file" "$label screenshot"
  assert_recorded_process_stopped "$reactivation_pid_file" "$label reactivation"

  export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$test_root/capture.pid"
  export QUAKESIGNAL_TEST_CAPTURE_RELEASE_FILE=""
  export QUAKESIGNAL_TEST_REACTIVATION_STATUS=0
  export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$test_root/reactivation.pid"
  export QUAKESIGNAL_TEST_REACTIVATION_RELEASE_FILE=""
}

for invalid_timeout in "" 0 00 01 -1 1:2 12x; do
  expect_status 64 quakesignal_capture_watch_screenshot \
    fake-watch fake.bundle "$test_root/invalid-timeout.png" en en_US \
    watchos-headline "$invalid_timeout" 1
done
for invalid_interval in "" 0 00 01 -1 1:2 12x; do
  expect_status 64 quakesignal_capture_watch_screenshot \
    fake-watch fake.bundle "$test_root/invalid-interval.png" en en_US \
    watchos-headline 2 "$invalid_interval"
done
expect_status 64 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/invalid-order.png" en en_US \
  watchos-headline 2 2
expect_status 64 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/invalid-frame.png" en en_US \
  watchos-unreviewed 4 1

export QUAKESIGNAL_TEST_CAPTURE_DELAY=0
expect_status 0 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/quick.png" en en_US \
  watchos-headline 4 1
if [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ]; then
  echo "error: quick Watch capture performed an unnecessary restart" >&2
  exit 1
fi

# The first exact-frame Watch launch uses the same bounded helper as semantic
# recovery. A transient FBS code 4 recovers once; two code-4 failures map to
# operational status 70 before capture/publication; TERM during the backoff
# preserves signal status and also publishes nothing.
initial_launch_recovery_dir="$test_root/initial-launch-recovery"
mkdir "$initial_launch_recovery_dir"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$initial_launch_recovery_dir/launched"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES="4|0"
export QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE="$initial_launch_recovery_dir/statuses"
expect_status 0 launch_and_publish_initial_watch "$initial_launch_recovery_dir"
assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 2 \
  "initial launch recovery count"
assert_file_content "$QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE" $'4\n0' \
  "initial launch recovery statuses"
assert_file_content "$initial_launch_recovery_dir/accepted-candidate.png" accepted \
  "initial launch recovery candidate"
assert_file_content "$initial_launch_recovery_dir/capture-provenance.json" '{}' \
  "initial launch recovery provenance"

initial_launch_failure_dir="$test_root/initial-launch-failure"
mkdir "$initial_launch_failure_dir"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$initial_launch_failure_dir/launched"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES="4|4"
export QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE="$initial_launch_failure_dir/statuses"
expect_status 70 launch_and_publish_initial_watch "$initial_launch_failure_dir"
assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 2 \
  "initial launch failure count"
assert_file_content "$QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE" $'4\n4' \
  "initial launch failure statuses"
if [ -e "$initial_launch_failure_dir/accepted-candidate.png" ] || \
    [ -e "$initial_launch_failure_dir/capture-provenance.json" ]; then
  echo "error: exhausted initial Watch launch published a candidate or provenance" >&2
  exit 1
fi

initial_launch_nontransient_dir="$test_root/initial-launch-nontransient"
mkdir "$initial_launch_nontransient_dir"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$initial_launch_nontransient_dir/launched"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES="29|0"
export QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE="$initial_launch_nontransient_dir/statuses"
expect_status 70 launch_and_publish_initial_watch "$initial_launch_nontransient_dir"
assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 1 \
  "initial launch nontransient count"
assert_file_content "$QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE" 29 \
  "initial launch nontransient status"
if [ -e "$initial_launch_nontransient_dir/accepted-candidate.png" ] || \
    [ -e "$initial_launch_nontransient_dir/capture-provenance.json" ]; then
  echo "error: nontransient initial Watch launch published a candidate or provenance" >&2
  exit 1
fi

initial_launch_signal_dir="$test_root/initial-launch-signal"
mkdir "$initial_launch_signal_dir"
initial_launch_signal_pid_file="$initial_launch_signal_dir/launch.pid"
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$initial_launch_signal_pid_file"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$initial_launch_signal_dir/launched"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES="4|0"
export QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE="$initial_launch_signal_dir/statuses"
(
  screenshot_pid=""
  watch_reactivation_pid=""

  initial_launch_signal_cleanup() {
    quakesignal_stop_processes "$screenshot_pid" "$watch_reactivation_pid"
  }
  trap initial_launch_signal_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  launch_and_publish_initial_watch "$initial_launch_signal_dir"
) &
gated_test_supervisor_pid=$!
wait_for_recorded_process_stopped "$initial_launch_signal_pid_file" \
  "initial Watch launch before backoff"
kill -TERM "$gated_test_supervisor_pid"
initial_launch_signal_status=0
if wait "$gated_test_supervisor_pid"; then
  initial_launch_signal_status=0
else
  initial_launch_signal_status=$?
fi
gated_test_supervisor_pid=""
if [ "$initial_launch_signal_status" -ne 143 ]; then
  echo "error: TERM during initial Watch launch backoff expected 143, got $initial_launch_signal_status" >&2
  exit 1
fi
assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 1 \
  "initial launch signal count"
assert_file_content "$QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE" 4 \
  "initial launch signal status"
assert_recorded_process_stopped "$initial_launch_signal_pid_file" \
  "initial Watch launch signal"
if [ -e "$initial_launch_signal_dir/accepted-candidate.png" ] || \
    [ -e "$initial_launch_signal_dir/capture-provenance.json" ]; then
  echo "error: interrupted initial Watch launch published a candidate or provenance" >&2
  exit 1
fi

export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$test_root/reactivation.pid"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$test_root/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES=""
export QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE=""

# Exercise the complete semantic retry orchestration with the same xcrun stub
# used by the process-supervisor tests. The stub also acts as sips and as the
# Ruby validator for these bounded text-payload fixtures.
for invalid_settle in "" 00 01 -1 1x; do
  expect_status 64 quakesignal_capture_validated_watch_screenshot \
    fake-watch fake.bundle "$test_root/invalid-settle.png" en en_US \
    watchos-headline 4 1 "$test_root" 410 502 \
    "$QUAKESIGNAL_XCRUN_EXECUTABLE" "$invalid_settle" \
    "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby
done

ln -s "$test_root" "$test_root/validation-root-symlink"
expect_status 64 quakesignal_capture_validated_watch_screenshot \
  fake-watch fake.bundle "$test_root/symlink-root.png" en en_US \
  watchos-headline 4 1 "$test_root/validation-root-symlink" 410 502 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby

mkdir "$test_root/other-validation-root"
expect_status 64 quakesignal_capture_validated_watch_screenshot \
  fake-watch fake.bundle "$test_root/outside-root.png" en en_US \
  watchos-headline 4 1 "$test_root/other-validation-root" 410 502 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby

ln -s "$QUAKESIGNAL_XCRUN_EXECUTABLE" "$test_root/validator-symlink.rb"
expect_status 64 quakesignal_capture_validated_watch_screenshot \
  fake-watch fake.bundle "$test_root/symlink-validator.png" en en_US \
  watchos-headline 4 1 "$test_root" 410 502 \
  "$test_root/validator-symlink.rb" 0 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby

validated_pass_dir="$test_root/validated-pass-first"
mkdir "$validated_pass_dir"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validated_pass_dir/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validated_pass_dir/reactivated"
expect_status 0 quakesignal_capture_validated_watch_screenshot \
  fake-watch fake.bundle "$validated_pass_dir/candidate.png" en en_US \
  watchos-headline 4 1 "$validated_pass_dir" 410 502 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby
assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 1 "pass-first capture count"
assert_file_content "$validated_pass_dir/candidate.png" valid "pass-first candidate"
if [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ] || \
    [ -e "$validated_pass_dir/rejected-watch-attempt-1.png" ]; then
  echo "error: pass-first Watch validation retried or quarantined a valid raster" >&2
  exit 1
fi

validated_retry_dir="$test_root/validated-reject-pass"
mkdir "$validated_retry_dir"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="invalid|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validated_retry_dir/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validated_retry_dir/reactivated"
expect_status 0 quakesignal_capture_validated_watch_screenshot \
  fake-watch fake.bundle "$validated_retry_dir/candidate.png" en en_US \
  watchos-headline 4 1 "$validated_retry_dir" 410 502 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby
assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 2 "retry capture count"
assert_file_content "$validated_retry_dir/rejected-watch-attempt-1.png" invalid \
  "quarantined Watch raster"
assert_file_content "$validated_retry_dir/candidate.png" valid "accepted retry raster"
if [ ! -s "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ]; then
  echo "error: rejected Watch raster did not trigger an exact-frame relaunch" >&2
  exit 1
fi

validated_validator_70_dir="$test_root/validated-validator-70"
mkdir "$validated_validator_70_dir"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="operational|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validated_validator_70_dir/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validated_validator_70_dir/reactivated"
export QUAKESIGNAL_TEST_VALIDATOR_OPERATIONAL_STATUS=70
expect_status 70 capture_and_publish_validated_watch "$validated_validator_70_dir"
assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 1 \
  "validator-70 capture count"
if [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ] || \
    [ -e "$validated_validator_70_dir/rejected-watch-attempt-1.png" ] || \
    [ -e "$validated_validator_70_dir/accepted-candidate.png" ]; then
  echo "error: Watch validator status 70 retried, quarantined, or published its candidate" >&2
  exit 1
fi

validated_validator_64_dir="$test_root/validated-validator-64"
mkdir "$validated_validator_64_dir"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="operational|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validated_validator_64_dir/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validated_validator_64_dir/reactivated"
export QUAKESIGNAL_TEST_VALIDATOR_OPERATIONAL_STATUS=64
expect_status 70 capture_and_publish_validated_watch "$validated_validator_64_dir"
assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 1 \
  "validator-64 capture count"
if [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ] || \
    [ -e "$validated_validator_64_dir/rejected-watch-attempt-1.png" ] || \
    [ -e "$validated_validator_64_dir/accepted-candidate.png" ]; then
  echo "error: Watch validator status 64 retried, quarantined, or published its candidate" >&2
  exit 1
fi
export QUAKESIGNAL_TEST_VALIDATOR_OPERATIONAL_STATUS=70

validated_reject_dir="$test_root/validated-reject-reject"
mkdir "$validated_reject_dir"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="invalid|invalid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validated_reject_dir/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validated_reject_dir/reactivated"
expect_status 65 quakesignal_capture_validated_watch_screenshot \
  fake-watch fake.bundle "$validated_reject_dir/candidate.png" en en_US \
  watchos-headline 4 1 "$validated_reject_dir" 410 502 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby
assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 2 "reject-twice capture count"
assert_file_content "$validated_reject_dir/rejected-watch-attempt-1.png" invalid \
  "first rejected Watch raster"
assert_file_content "$validated_reject_dir/candidate.png" invalid \
  "second rejected Watch raster"
if [ -e "$validated_reject_dir/final.png" ] || \
    [ -e "$validated_reject_dir/capture-provenance.json" ]; then
  echo "error: reject-twice Watch validation published an artifact" >&2
  exit 1
fi

validated_sips_dir="$test_root/validated-sips-failure"
mkdir "$validated_sips_dir"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validated_sips_dir/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validated_sips_dir/reactivated"
expect_status 70 quakesignal_capture_validated_watch_screenshot \
  fake-watch fake.bundle "$validated_sips_dir/candidate.png" en en_US \
  watchos-headline 4 1 "$validated_sips_dir" 410 502 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 /usr/bin/false /usr/bin/ruby

validated_quarantine_dir="$test_root/validated-quarantine-failure"
mkdir "$validated_quarantine_dir"
touch "$validated_quarantine_dir/rejected-watch-attempt-1.png"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="invalid|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validated_quarantine_dir/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validated_quarantine_dir/reactivated"
expect_status 73 quakesignal_capture_validated_watch_screenshot \
  fake-watch fake.bundle "$validated_quarantine_dir/candidate.png" en en_US \
  watchos-headline 4 1 "$validated_quarantine_dir" 410 502 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby
if [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ]; then
  echo "error: quarantine refusal still relaunched the Watch fixture" >&2
  exit 1
fi

validated_relaunch_recovery_dir="$test_root/validated-relaunch-recovery"
mkdir "$validated_relaunch_recovery_dir"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="invalid|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validated_relaunch_recovery_dir/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validated_relaunch_recovery_dir/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES="4|0"
expect_status 0 quakesignal_capture_validated_watch_screenshot \
  fake-watch fake.bundle "$validated_relaunch_recovery_dir/candidate.png" en en_US \
  watchos-headline 12 1 "$validated_relaunch_recovery_dir" 410 502 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby
assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 2 \
  "relaunch-recovery capture count"
assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 2 \
  "relaunch-recovery launch count"
assert_file_content "$validated_relaunch_recovery_dir/rejected-watch-attempt-1.png" invalid \
  "relaunch-recovery quarantined raster"
assert_file_content "$validated_relaunch_recovery_dir/candidate.png" valid \
  "relaunch-recovery accepted raster"

validated_relaunch_failure_dir="$test_root/validated-relaunch-failure"
mkdir "$validated_relaunch_failure_dir"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="invalid|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validated_relaunch_failure_dir/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validated_relaunch_failure_dir/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES="4|4"
expect_status 70 capture_and_publish_validated_watch "$validated_relaunch_failure_dir"
assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 1 \
  "relaunch-failure capture count"
assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 2 \
  "relaunch-failure launch count"
assert_file_content "$validated_relaunch_failure_dir/rejected-watch-attempt-1.png" invalid \
  "relaunch-failure quarantined raster"
if [ -e "$validated_relaunch_failure_dir/candidate.png" ] || \
    [ -e "$validated_relaunch_failure_dir/accepted-candidate.png" ]; then
  echo "error: exhausted Watch relaunch attempts published a candidate" >&2
  exit 1
fi

validated_backoff_signal_dir="$test_root/validated-backoff-signal"
mkdir "$validated_backoff_signal_dir"
backoff_signal_capture_pid_file="$validated_backoff_signal_dir/capture.pid"
backoff_signal_reactivation_pid_file="$validated_backoff_signal_dir/reactivation.pid"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="invalid|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validated_backoff_signal_dir/capture-count"
export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$backoff_signal_capture_pid_file"
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$backoff_signal_reactivation_pid_file"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validated_backoff_signal_dir/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES="4|0"
(
  screenshot_pid=""
  watch_reactivation_pid=""

  backoff_signal_cleanup() {
    quakesignal_stop_processes "$screenshot_pid" "$watch_reactivation_pid"
  }
  trap backoff_signal_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  quakesignal_capture_validated_watch_screenshot \
    fake-watch fake.bundle "$validated_backoff_signal_dir/candidate.png" en en_US \
    watchos-headline 20 5 "$validated_backoff_signal_dir" 410 502 \
    "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 \
    "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby
) &
gated_test_supervisor_pid=$!
wait_for_recorded_process_stopped "$backoff_signal_reactivation_pid_file" \
  "semantic-retry backoff first relaunch"
kill -TERM "$gated_test_supervisor_pid"
backoff_signal_status=0
if wait "$gated_test_supervisor_pid"; then
  backoff_signal_status=0
else
  backoff_signal_status=$?
fi
gated_test_supervisor_pid=""
if [ "$backoff_signal_status" -ne 143 ]; then
  echo "error: TERM during Watch relaunch backoff expected 143, got $backoff_signal_status" >&2
  exit 1
fi
assert_file_content "$QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE" 1 \
  "backoff-signal capture count"
assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 1 \
  "backoff-signal launch count"
assert_recorded_process_stopped "$backoff_signal_capture_pid_file" \
  "backoff-signal screenshot"
assert_recorded_process_stopped "$backoff_signal_reactivation_pid_file" \
  "backoff-signal relaunch"

export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$test_root/capture.pid"
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$test_root/reactivation.pid"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES=""

validated_capture_failure_dir="$test_root/validated-capture-failure"
mkdir "$validated_capture_failure_dir"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validated_capture_failure_dir/capture-count"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validated_capture_failure_dir/reactivated"
export QUAKESIGNAL_TEST_CAPTURE_STATUS=23
expect_status 70 quakesignal_capture_validated_watch_screenshot \
  fake-watch fake.bundle "$validated_capture_failure_dir/candidate.png" en en_US \
  watchos-headline 4 1 "$validated_capture_failure_dir" 410 502 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby
export QUAKESIGNAL_TEST_CAPTURE_STATUS=0

validated_retry_signal_dir="$test_root/validated-retry-signal"
mkdir "$validated_retry_signal_dir"
retry_signal_capture_pid_file="$validated_retry_signal_dir/capture.pid"
retry_signal_reactivation_pid_file="$validated_retry_signal_dir/reactivation.pid"
export QUAKESIGNAL_TEST_CAPTURE_PAYLOADS="invalid|valid"
export QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE="$validated_retry_signal_dir/capture-count"
export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$retry_signal_capture_pid_file"
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$retry_signal_reactivation_pid_file"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$validated_retry_signal_dir/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=30
export QUAKESIGNAL_TEST_SIGNAL_PARENT_MODE=launch
export QUAKESIGNAL_TEST_SIGNAL_PARENT=TERM
export QUAKESIGNAL_TEST_HOLD_PID_ASSIGNMENT=1
(
  screenshot_pid=""
  watch_reactivation_pid=""

  retry_signal_cleanup() {
    quakesignal_stop_processes "$screenshot_pid" "$watch_reactivation_pid"
  }
  trap retry_signal_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  quakesignal_capture_validated_watch_screenshot \
    fake-watch fake.bundle "$validated_retry_signal_dir/candidate.png" en en_US \
    watchos-headline 20 5 "$validated_retry_signal_dir" 410 502 \
    "$QUAKESIGNAL_XCRUN_EXECUTABLE" 0 \
    "$QUAKESIGNAL_XCRUN_EXECUTABLE" /usr/bin/ruby
) &
spawn_race_supervisor_pid=$!
validated_retry_signal_status=0
if wait "$spawn_race_supervisor_pid"; then
  validated_retry_signal_status=0
else
  validated_retry_signal_status=$?
fi
spawn_race_supervisor_pid=""
if [ "$validated_retry_signal_status" -ne 143 ]; then
  echo "error: semantic-retry relaunch signal race expected 143, got $validated_retry_signal_status" >&2
  exit 1
fi
assert_recorded_process_stopped "$retry_signal_capture_pid_file" \
  "semantic-retry screenshot"
assert_recorded_process_stopped "$retry_signal_reactivation_pid_file" \
  "semantic-retry relaunch"

export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$test_root/capture.pid"
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$test_root/reactivation.pid"
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_SIGNAL_PARENT_MODE=""
export QUAKESIGNAL_TEST_SIGNAL_PARENT=""
export QUAKESIGNAL_TEST_HOLD_PID_ASSIGNMENT=0
unset QUAKESIGNAL_TEST_CAPTURE_PAYLOADS QUAKESIGNAL_TEST_CAPTURE_COUNT_FILE
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$test_root/reactivated"

# Periodic foreground keeping uses the same narrowly classified recovery as
# the hosted failure: one FBS status-4 result may retry after five seconds.
# The retry remains a directly tracked xcrun child, and every other outcome
# fails closed without waiting for the screenshot command to publish.
periodic_recovery_dir="$test_root/periodic-restart-recovery"
mkdir "$periodic_recovery_dir"
periodic_recovery_release_file="$periodic_recovery_dir/capture.release"
export QUAKESIGNAL_TEST_CAPTURE_DELAY=0
export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$periodic_recovery_dir/capture.pid"
export QUAKESIGNAL_TEST_CAPTURE_RELEASE_FILE="$periodic_recovery_release_file"
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$periodic_recovery_dir/reactivation.pid"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$periodic_recovery_dir/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES="4|0"
export QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE="$periodic_recovery_dir/statuses"
(
  screenshot_pid=""
  watch_reactivation_pid=""

  periodic_recovery_cleanup() {
    quakesignal_stop_processes "$screenshot_pid" "$watch_reactivation_pid"
  }
  trap periodic_recovery_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  quakesignal_capture_watch_screenshot \
    fake-watch fake.bundle "$periodic_recovery_dir/candidate.png" en en_US \
    watchos-headline 20 1
) &
gated_test_supervisor_pid=$!
wait_for_nonempty_file "$QUAKESIGNAL_TEST_CAPTURE_PID_FILE" \
  "periodic restart recovery screenshot PID"
wait_for_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 2 \
  "periodic restart recovery launch count"
wait_for_recorded_process_stopped "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "periodic restart recovery launch"
touch "$periodic_recovery_release_file"
periodic_recovery_status=0
if wait "$gated_test_supervisor_pid"; then
  periodic_recovery_status=0
else
  periodic_recovery_status=$?
fi
gated_test_supervisor_pid=""
if [ "$periodic_recovery_status" -ne 0 ]; then
  echo "error: periodic restart recovery expected status 0, got $periodic_recovery_status" >&2
  exit 1
fi
assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 2 \
  "periodic restart recovery count"
assert_file_content "$QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE" $'4\n0' \
  "periodic restart recovery statuses"
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_CAPTURE_PID_FILE" \
  "periodic restart recovery screenshot"
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "periodic restart recovery launch"
export QUAKESIGNAL_TEST_CAPTURE_RELEASE_FILE=""

periodic_exhaustion_dir="$test_root/periodic-restart-exhaustion"
mkdir "$periodic_exhaustion_dir"
export QUAKESIGNAL_TEST_CAPTURE_DELAY=15
export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$periodic_exhaustion_dir/capture.pid"
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$periodic_exhaustion_dir/reactivation.pid"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$periodic_exhaustion_dir/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES="4|4"
export QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE="$periodic_exhaustion_dir/statuses"
expect_status 70 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$periodic_exhaustion_dir/candidate.png" en en_US \
  watchos-headline 20 1
assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 2 \
  "periodic restart exhaustion count"
assert_file_content "$QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE" $'4\n4' \
  "periodic restart exhaustion statuses"
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_CAPTURE_PID_FILE" \
  "periodic restart exhaustion screenshot"
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "periodic restart exhaustion launch"

periodic_nontransient_dir="$test_root/periodic-restart-nontransient"
mkdir "$periodic_nontransient_dir"
export QUAKESIGNAL_TEST_CAPTURE_DELAY=8
export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$periodic_nontransient_dir/capture.pid"
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$periodic_nontransient_dir/reactivation.pid"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$periodic_nontransient_dir/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES="29|0"
export QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE="$periodic_nontransient_dir/statuses"
expect_status 70 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$periodic_nontransient_dir/candidate.png" en en_US \
  watchos-headline 12 1
assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 1 \
  "periodic nontransient failure count"
assert_file_content "$QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE" 29 \
  "periodic nontransient failure status"
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_CAPTURE_PID_FILE" \
  "periodic nontransient screenshot"
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "periodic nontransient launch"

periodic_backoff_signal_dir="$test_root/periodic-restart-backoff-signal"
mkdir "$periodic_backoff_signal_dir"
export QUAKESIGNAL_TEST_CAPTURE_DELAY=30
export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$periodic_backoff_signal_dir/capture.pid"
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$periodic_backoff_signal_dir/reactivation.pid"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$periodic_backoff_signal_dir/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES="4|0"
export QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE="$periodic_backoff_signal_dir/statuses"
(
  screenshot_pid=""
  watch_reactivation_pid=""

  periodic_backoff_cleanup() {
    quakesignal_stop_processes "$screenshot_pid" "$watch_reactivation_pid"
  }
  trap periodic_backoff_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  quakesignal_capture_watch_screenshot \
    fake-watch fake.bundle "$periodic_backoff_signal_dir/candidate.png" en en_US \
    watchos-headline 20 1
) &
gated_test_supervisor_pid=$!
wait_for_recorded_process_stopped "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "periodic restart before backoff"
sleep 2
kill -TERM "$gated_test_supervisor_pid"
periodic_backoff_signal_status=0
if wait "$gated_test_supervisor_pid"; then
  periodic_backoff_signal_status=0
else
  periodic_backoff_signal_status=$?
fi
gated_test_supervisor_pid=""
if [ "$periodic_backoff_signal_status" -ne 143 ]; then
  echo "error: TERM during periodic restart backoff expected 143, got $periodic_backoff_signal_status" >&2
  exit 1
fi
assert_file_content "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" 1 \
  "periodic backoff signal launch count"
assert_file_content "$QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE" 4 \
  "periodic backoff signal status"
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_CAPTURE_PID_FILE" \
  "periodic backoff signal screenshot"
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "periodic backoff signal launch"

export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$test_root/capture.pid"
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$test_root/reactivation.pid"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$test_root/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_STATUSES=""
export QUAKESIGNAL_TEST_LAUNCH_STATUS_TRACE_FILE=""

export QUAKESIGNAL_TEST_CAPTURE_DELAY=3
expect_status 0 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/slow.png" en en_US \
  watchos-headline 6 1
if [ ! -s "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ]; then
  echo "error: Watch capture guard did not restart during a slow screenshot" >&2
  exit 1
fi

export QUAKESIGNAL_TEST_CAPTURE_DELAY=0
export QUAKESIGNAL_TEST_CAPTURE_STATUS=23
expect_status 70 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/capture-failure.png" en en_US \
  watchos-headline 4 1
export QUAKESIGNAL_TEST_CAPTURE_STATUS=0

export QUAKESIGNAL_TEST_CAPTURE_DELAY=4
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=29
rm -f "$QUAKESIGNAL_TEST_CAPTURE_PID_FILE"
expect_status 70 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/restart-failure.png" en en_US \
  watchos-headline 6 1
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=0
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_CAPTURE_PID_FILE" "screenshot"

run_same_poll_completion_test 29 same-poll-restart-failure
run_same_poll_completion_test 143 same-poll-natural-sigterm
run_same_poll_completion_test 4 same-poll-transient-restart-failure

timeout_capture_release_file="$test_root/timeout-capture.release"
timeout_reactivation_release_file="$test_root/timeout-reactivation.release"
export QUAKESIGNAL_TEST_CAPTURE_DELAY=0
export QUAKESIGNAL_TEST_CAPTURE_RELEASE_FILE="$timeout_capture_release_file"
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_REACTIVATION_RELEASE_FILE="$timeout_reactivation_release_file"
export QUAKESIGNAL_TEST_IGNORE_TERM=1
rm -f \
  "$QUAKESIGNAL_TEST_CAPTURE_PID_FILE" \
  "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "$timeout_capture_release_file" \
  "$timeout_reactivation_release_file"
expect_status 124 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/timeout.png" en en_US \
  watchos-headline 2 1
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_CAPTURE_PID_FILE" "screenshot"
# Timeout is checked before the reactivation deadline. A heavily scheduled
# runner can legitimately cross both deadlines in one poll, so only assert on
# the restart child when the production guard actually spawned one.
if [ -s "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" ]; then
  assert_recorded_process_stopped "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
    "timeout reactivation"
fi
export QUAKESIGNAL_TEST_IGNORE_TERM=0
export QUAKESIGNAL_TEST_CAPTURE_RELEASE_FILE=""
export QUAKESIGNAL_TEST_REACTIVATION_RELEASE_FILE=""

export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=143
rm -f "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE"
SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_AUTOMATION=1 \
SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_FRAME=watchos-headline \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" simctl launch --terminate-running-process \
    fake-watch fake.bundle --quakesignal-screenshot-automation \
    --quakesignal-screenshot-frame=watchos-headline >/dev/null &
helper_test_pid=$!
wait_for_nonempty_file "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "natural-sigterm reactivation PID"
wait_for_recorded_process_stopped "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "natural-sigterm reactivation"
expect_status 143 quakesignal_stop_process_with_status "$helper_test_pid"
helper_test_pid=""

intentional_stop_release_file="$test_root/intentional-stop.release"
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=0
export QUAKESIGNAL_TEST_REACTIVATION_RELEASE_FILE="$intentional_stop_release_file"
rm -f \
  "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "$intentional_stop_release_file"
SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_AUTOMATION=1 \
SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_FRAME=watchos-headline \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" simctl launch --terminate-running-process \
    fake-watch fake.bundle --quakesignal-screenshot-automation \
    --quakesignal-screenshot-frame=watchos-headline >/dev/null &
helper_test_pid=$!
wait_for_nonempty_file "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "intentional-stop reactivation PID"
expect_status 0 quakesignal_stop_process_with_status "$helper_test_pid"
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "intentional-stop reactivation"
helper_test_pid=""
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_REACTIVATION_RELEASE_FILE=""

stubborn_release_file="$test_root/stubborn.release"
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_REACTIVATION_RELEASE_FILE="$stubborn_release_file"
export QUAKESIGNAL_TEST_IGNORE_TERM=1
rm -f \
  "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "$stubborn_release_file"
SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_AUTOMATION=1 \
SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_FRAME=watchos-headline \
  "$QUAKESIGNAL_XCRUN_EXECUTABLE" simctl launch --terminate-running-process \
    fake-watch fake.bundle --quakesignal-screenshot-automation \
    --quakesignal-screenshot-frame=watchos-headline >/dev/null &
helper_test_pid=$!
wait_for_nonempty_file "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "stubborn reactivation PID"
quakesignal_stop_processes "$helper_test_pid"
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "stubborn reactivation"
helper_test_pid=""
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_REACTIVATION_RELEASE_FILE=""
export QUAKESIGNAL_TEST_IGNORE_TERM=0

signal_capture_pid_file="$test_root/signal-capture.pid"
(
  screenshot_pid=""
  watch_reactivation_pid=""
  export QUAKESIGNAL_TEST_CAPTURE_DELAY=30
  export QUAKESIGNAL_TEST_CAPTURE_STATUS=0
  export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$signal_capture_pid_file"
  export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
  export QUAKESIGNAL_TEST_REACTIVATION_STATUS=0

  signal_cleanup() {
    quakesignal_stop_processes "$screenshot_pid" "$watch_reactivation_pid"
  }
  trap signal_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  quakesignal_capture_watch_screenshot \
    fake-watch fake.bundle "$test_root/signal.png" en en_US \
    watchos-headline 20 5
) &
signal_supervisor_pid=$!

signal_wait_attempt=0
while [ ! -s "$signal_capture_pid_file" ] && \
    kill -0 "$signal_supervisor_pid" >/dev/null 2>&1 && \
    [ "$signal_wait_attempt" -lt 5 ]; do
  sleep 1
  signal_wait_attempt=$((signal_wait_attempt + 1))
done
if [ ! -s "$signal_capture_pid_file" ]; then
  echo "error: TERM test did not observe the real screenshot child PID" >&2
  exit 1
fi
# The child can write its PID before the supervisor records $!; one loop tick
# makes that assignment race impossible before delivering TERM.
sleep 1
kill -TERM "$signal_supervisor_pid"
signal_status=0
if wait "$signal_supervisor_pid"; then
  signal_status=0
else
  signal_status=$?
fi
signal_supervisor_pid=""
if [ "$signal_status" -ne 143 ]; then
  echo "error: TERM test expected status 143, got $signal_status" >&2
  exit 1
fi
assert_recorded_process_stopped "$signal_capture_pid_file" "signal-test screenshot"

run_spawn_assignment_signal_test() {
  local mode="$1"
  local iteration="$2"
  local race_capture_pid_file="$test_root/$mode-$iteration-capture.pid"
  local race_reactivation_pid_file="$test_root/$mode-$iteration-reactivation.pid"
  local race_status=0

  (
    screenshot_pid=""
    watch_reactivation_pid=""
    export QUAKESIGNAL_TEST_CAPTURE_DELAY=30
    export QUAKESIGNAL_TEST_CAPTURE_STATUS=0
    export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$race_capture_pid_file"
    export QUAKESIGNAL_TEST_REACTIVATION_DELAY=30
    export QUAKESIGNAL_TEST_REACTIVATION_STATUS=0
    export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$race_reactivation_pid_file"
    export QUAKESIGNAL_TEST_SIGNAL_PARENT_MODE="$mode"
    export QUAKESIGNAL_TEST_SIGNAL_PARENT=TERM
    export QUAKESIGNAL_TEST_HOLD_PID_ASSIGNMENT=1

    race_cleanup() {
      quakesignal_stop_processes "$screenshot_pid" "$watch_reactivation_pid"
    }
    trap race_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    quakesignal_capture_watch_screenshot \
      fake-watch fake.bundle "$test_root/$mode-$iteration.png" en en_US \
      watchos-headline 20 1
  ) &
  spawn_race_supervisor_pid=$!
  if wait "$spawn_race_supervisor_pid"; then
    race_status=0
  else
    race_status=$?
  fi
  spawn_race_supervisor_pid=""
  if [ "$race_status" -ne 143 ]; then
    echo "error: $mode spawn-race test $iteration expected 143, got $race_status" >&2
    exit 1
  fi
  assert_recorded_process_stopped "$race_capture_pid_file" \
    "$mode spawn-race screenshot"
  if [ "$mode" = "launch" ]; then
    assert_recorded_process_stopped "$race_reactivation_pid_file" \
      "$mode spawn-race reactivation"
  fi
}

run_deferred_signal_restore_test() {
  local signal="$1"
  local expected_status="$2"

  # A Bash script launched as another shell's asynchronous job inherits an
  # ignored SIGINT, which Bash cannot later trap. Reset the selected signal in
  # a tiny foreground Ruby exec wrapper so this helper has the same default
  # disposition in direct and concurrent test invocations.
  expect_status "$expected_status" /usr/bin/ruby -e \
    'signal = ARGV.shift; Signal.trap(signal, "DEFAULT"); exec(*ARGV)' \
    "$signal" /bin/bash -c '
      set -euo pipefail
      source "$1"
      trap '\''exit 130'\'' INT
      trap '\''exit 143'\'' TERM
      quakesignal_defer_tracked_spawn_signals
      kill -"$2" "$$"
      if [ "$quakesignal_deferred_spawn_signal" != "$2" ]; then
        echo "error: deferred-signal helper did not record $2" >&2
        exit 65
      fi
      quakesignal_restore_tracked_spawn_signals
      exit 66
    ' quakesignal-deferred-signal-helper \
    "$script_dir/watch-capture-guard.sh" "$signal"
}

run_deferred_signal_restore_test INT 130
run_deferred_signal_restore_test TERM 143

for race_iteration in 1 2 3; do
  run_spawn_assignment_signal_test io "$race_iteration"
  run_spawn_assignment_signal_test launch "$race_iteration"
done

if [ -n "$screenshot_pid" ] || [ -n "$watch_reactivation_pid" ]; then
  echo "error: Watch capture guard leaked a tracked child PID" >&2
  exit 1
fi

echo "Watch capture guard tests passed"
