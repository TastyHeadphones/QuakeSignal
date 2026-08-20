#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
test_temp_root="${QUAKESIGNAL_TEST_TEMP_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
if [ ! -d "$test_temp_root" ] || [ -L "$test_temp_root" ]; then
  echo "error: screenshot test temp root must be an existing plain directory" >&2
  exit 64
fi
test_temp_root="$(cd "$test_temp_root" && pwd -P)"
test_root="$(mktemp -d "$test_temp_root/quakesignal-maccatalyst-process-guard-test.XXXXXX")"
supervisor_pid=""

cleanup() {
  quakesignal_maccatalyst_stop_processes "$supervisor_pid"
  rm -rf "$test_root"
}
# shellcheck source=maccatalyst-process-guard.sh
. "$script_dir/maccatalyst-process-guard.sh"
trap cleanup EXIT

wait_for_file() {
  local path="$1"
  local attempt=0
  while [ ! -s "$path" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  [ -s "$path" ] || {
    echo "error: timed out waiting for tracked child PID" >&2
    exit 1
  }
}

assert_stopped() {
  local path="$1"
  local process_id
  process_id="$(cat "$path")"
  if kill -0 "$process_id" >/dev/null 2>&1; then
    echo "error: tracked child $process_id survived signal cleanup" >&2
    exit 1
  fi
}

run_signal_test() {
  local signal="$1"
  local expected_status="$2"
  local mode="$3"
  local pid_file="$test_root/$signal-$mode.pid"
  local output="$test_root/$signal-$mode-published"
  local supervisor_status=0

  /usr/bin/ruby -e \
    'signal = ARGV.shift; Signal.trap(signal, "DEFAULT"); exec(*ARGV)' \
    "$signal" /bin/bash -c '
      set -euo pipefail
      source "$1"
      maccatalyst_active_child_pid=""
      cleanup() {
        quakesignal_maccatalyst_stop_processes "$maccatalyst_active_child_pid"
      }
      trap cleanup EXIT
      trap "exit 130" INT
      trap "exit 143" TERM
      if [ "$5" = "race" ]; then
        export QUAKESIGNAL_TEST_HOLD_CATALYST_PID_ASSIGNMENT=1
      fi
      quakesignal_maccatalyst_run_tracked /bin/bash -c '\''
        printf "%s\\n" "$$" >"$1"
        /bin/sleep 30 &
        descendant_pid=$!
        printf "%s\\n" "$descendant_pid" >"$1.descendant"
        if [ "$3" = "race" ]; then
          kill -"$2" "$PPID"
        fi
        wait "$descendant_pid"
      '\'' tracked-child "$2" "$3" "$5"
      mkdir "$4"
    ' maccatalyst-process-supervisor \
    "$script_dir/maccatalyst-process-guard.sh" "$pid_file" "$signal" "$output" "$mode" &
  supervisor_pid=$!
  wait_for_file "$pid_file"
  wait_for_file "$pid_file.descendant"
  if [ "$mode" = "normal" ]; then
    kill -"$signal" "$supervisor_pid"
  fi
  if wait "$supervisor_pid"; then
    supervisor_status=0
  else
    supervisor_status=$?
  fi
  supervisor_pid=""
  if [ "$supervisor_status" -ne "$expected_status" ]; then
    echo "error: $signal/$mode expected $expected_status, received $supervisor_status" >&2
    exit 1
  fi
  assert_stopped "$pid_file"
  assert_stopped "$pid_file.descendant"
  if [ -e "$output" ] || [ -L "$output" ]; then
    echo "error: $signal/$mode published output after interruption" >&2
    exit 1
  fi
}

run_signal_test TERM 143 normal
run_signal_test INT 130 normal
run_signal_test TERM 143 race
run_signal_test INT 130 race

echo "Mac Catalyst tracked-process signal tests passed"
