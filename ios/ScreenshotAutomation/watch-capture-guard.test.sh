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
export QUAKESIGNAL_XCRUN_EXECUTABLE="$script_dir/watch-capture-guard-xcrun-stub.rb"
export QUAKESIGNAL_TEST_CAPTURE_DELAY=0
export QUAKESIGNAL_TEST_CAPTURE_STATUS=0
export QUAKESIGNAL_TEST_CAPTURE_PID_FILE="$test_root/capture.pid"
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=0
export QUAKESIGNAL_TEST_REACTIVATION_PID_FILE="$test_root/reactivation.pid"
export QUAKESIGNAL_TEST_REACTIVATION_MARKER="$test_root/reactivated"
export QUAKESIGNAL_TEST_IGNORE_TERM=0

cleanup() {
  quakesignal_stop_processes \
    "$signal_supervisor_pid" "$spawn_race_supervisor_pid" "$helper_test_pid" \
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

for invalid_timeout in "" 0 00 01 -1 1:2 12x; do
  expect_status 64 quakesignal_capture_watch_screenshot \
    fake-watch fake.bundle "$test_root/invalid-timeout.png" en en_US \
    "$invalid_timeout" 1
done
for invalid_interval in "" 0 00 01 -1 1:2 12x; do
  expect_status 64 quakesignal_capture_watch_screenshot \
    fake-watch fake.bundle "$test_root/invalid-interval.png" en en_US \
    2 "$invalid_interval"
done
expect_status 64 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/invalid-order.png" en en_US 2 2

export QUAKESIGNAL_TEST_CAPTURE_DELAY=0
expect_status 0 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/quick.png" en en_US 4 1
if [ -e "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ]; then
  echo "error: quick Watch capture performed an unnecessary restart" >&2
  exit 1
fi

export QUAKESIGNAL_TEST_CAPTURE_DELAY=3
expect_status 0 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/slow.png" en en_US 6 1
if [ ! -s "$QUAKESIGNAL_TEST_REACTIVATION_MARKER" ]; then
  echo "error: Watch capture guard did not restart during a slow screenshot" >&2
  exit 1
fi

export QUAKESIGNAL_TEST_CAPTURE_DELAY=0
export QUAKESIGNAL_TEST_CAPTURE_STATUS=23
expect_status 70 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/capture-failure.png" en en_US 4 1
export QUAKESIGNAL_TEST_CAPTURE_STATUS=0

export QUAKESIGNAL_TEST_CAPTURE_DELAY=4
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=29
rm -f "$QUAKESIGNAL_TEST_CAPTURE_PID_FILE"
expect_status 70 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/restart-failure.png" en en_US 6 1
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=0
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_CAPTURE_PID_FILE" "screenshot"

export QUAKESIGNAL_TEST_CAPTURE_DELAY=2
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=1
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=29
expect_status 70 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/same-tick-restart-failure.png" en en_US 6 1
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=0

export QUAKESIGNAL_TEST_CAPTURE_DELAY=2
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=1
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=143
expect_status 70 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/same-tick-natural-sigterm.png" en en_US 6 1
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=0

export QUAKESIGNAL_TEST_CAPTURE_DELAY=10
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=10
export QUAKESIGNAL_TEST_IGNORE_TERM=1
rm -f \
  "$QUAKESIGNAL_TEST_CAPTURE_PID_FILE" \
  "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE"
expect_status 124 quakesignal_capture_watch_screenshot \
  fake-watch fake.bundle "$test_root/timeout.png" en en_US 2 1
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_CAPTURE_PID_FILE" "screenshot"
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" "reactivation"
export QUAKESIGNAL_TEST_IGNORE_TERM=0

export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=143
"$QUAKESIGNAL_XCRUN_EXECUTABLE" simctl launch --terminate-running-process \
  fake-watch fake.bundle --quakesignal-screenshot-automation >/dev/null &
helper_test_pid=$!
sleep 1
expect_status 143 quakesignal_stop_process_with_status "$helper_test_pid"
helper_test_pid=""

export QUAKESIGNAL_TEST_REACTIVATION_DELAY=30
export QUAKESIGNAL_TEST_REACTIVATION_STATUS=0
rm -f "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE"
"$QUAKESIGNAL_XCRUN_EXECUTABLE" simctl launch --terminate-running-process \
  fake-watch fake.bundle --quakesignal-screenshot-automation >/dev/null &
helper_test_pid=$!
sleep 1
expect_status 0 quakesignal_stop_process_with_status "$helper_test_pid"
assert_recorded_process_stopped "$QUAKESIGNAL_TEST_REACTIVATION_PID_FILE" \
  "intentional-stop reactivation"
helper_test_pid=""
export QUAKESIGNAL_TEST_REACTIVATION_DELAY=0

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
    fake-watch fake.bundle "$test_root/signal.png" en en_US 20 5
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
  local signal="$2"
  local expected_status="$3"
  local iteration="$4"
  local race_capture_pid_file="$test_root/$mode-$iteration-capture.pid"
  local race_reactivation_pid_file="$test_root/$mode-$iteration-reactivation.pid"
  local race_status=0
  local restore_job_control=0

  # Non-interactive Bash starts asynchronous subshells with SIGINT ignored
  # unless job control is enabled. Turn it on only for the INT race so the
  # child-triggered signal exercises the installed 130 trap on Bash 3.2.
  if [ "$signal" = "INT" ]; then
    case "$-" in
      *m*) ;;
      *)
        set -m
        restore_job_control=1
        ;;
    esac
  fi

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
    export QUAKESIGNAL_TEST_SIGNAL_PARENT="$signal"
    export QUAKESIGNAL_TEST_HOLD_PID_ASSIGNMENT=1

    race_cleanup() {
      quakesignal_stop_processes "$screenshot_pid" "$watch_reactivation_pid"
    }
    trap race_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    quakesignal_capture_watch_screenshot \
      fake-watch fake.bundle "$test_root/$mode-$iteration.png" en en_US 20 1
  ) &
  spawn_race_supervisor_pid=$!
  if wait "$spawn_race_supervisor_pid"; then
    race_status=0
  else
    race_status=$?
  fi
  spawn_race_supervisor_pid=""
  if [ "$restore_job_control" -eq 1 ]; then
    set +m
  fi
  if [ "$race_status" -ne "$expected_status" ]; then
    echo "error: $mode spawn-race test $iteration expected $expected_status, got $race_status" >&2
    exit 1
  fi
  assert_recorded_process_stopped "$race_capture_pid_file" \
    "$mode spawn-race screenshot"
  if [ "$mode" = "launch" ]; then
    assert_recorded_process_stopped "$race_reactivation_pid_file" \
      "$mode spawn-race reactivation"
  fi
}

for race_iteration in 1 2 3; do
  run_spawn_assignment_signal_test io TERM 143 "$race_iteration"
  run_spawn_assignment_signal_test launch INT 130 "$race_iteration"
done

if [ -n "$screenshot_pid" ] || [ -n "$watch_reactivation_pid" ]; then
  echo "error: Watch capture guard leaked a tracked child PID" >&2
  exit 1
fi

echo "Watch capture guard tests passed"
