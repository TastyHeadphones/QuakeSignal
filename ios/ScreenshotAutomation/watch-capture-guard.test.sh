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
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$test_root/reactivation.pid"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$test_root/reactivated"
export QUAKESIGNAL_TEST_REACTIVATION_RELEASE_FILE=""
export QUAKESIGNAL_TEST_RELEASE_TIMEOUT=20
export QUAKESIGNAL_TEST_IGNORE_TERM=0
export QUAKESIGNAL_TEST_EXPECTED_FRAME=watchos-headline

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
"$QUAKESIGNAL_XCRUN_EXECUTABLE" simctl launch --terminate-running-process \
  fake-watch fake.bundle --quakesignal-screenshot-automation >/dev/null &
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
"$QUAKESIGNAL_XCRUN_EXECUTABLE" simctl launch --terminate-running-process \
  fake-watch fake.bundle --quakesignal-screenshot-automation >/dev/null &
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
"$QUAKESIGNAL_XCRUN_EXECUTABLE" simctl launch --terminate-running-process \
  fake-watch fake.bundle --quakesignal-screenshot-automation >/dev/null &
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
