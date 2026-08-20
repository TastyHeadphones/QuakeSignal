#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
test_temp_parent="${QUAKESIGNAL_TEST_TEMP_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
if [ ! -d "$test_temp_parent" ]; then
  echo "error: screenshot test temporary parent is not an existing directory: $test_temp_parent" >&2
  exit 64
fi
test_temp_parent="$(cd "$test_temp_parent" && pwd -P)"
test_root="$(mktemp -d "$test_temp_parent/quakesignal-screenshot-process-guard.XXXXXX")"
supervisor_pid=""

# shellcheck source=screenshot-process-guard.sh
. "$script_dir/screenshot-process-guard.sh"
cleanup() {
  quakesignal_screenshot_stop_processes "$supervisor_pid"
  rm -rf "$test_root"
}
trap cleanup EXIT

/usr/bin/ruby -e '
  source = File.read(ARGV.fetch(0))
  abort "publication must use Darwin fd-relative renameatx_np" unless
    source.include?("renameatx_np") && source.include?("openat") &&
    source.include?("rename_exclusive_nofollow = 0x4 | 0x10")
  abort "publication must bind payload and payload-parent inodes" unless
    source.include?("expected_payload_identity") &&
    source.include?("expected_payload_parent_identity")
  abort "cleanup must require an exact bound target inode" unless
    source.include?("expected_target_identity") &&
    source.include?("bound cleanup target identity changed before removal")
' "$script_dir/screenshot-process-guard.sh"

wait_for_file() {
  local path="$1"
  local attempt=0
  while [ ! -s "$path" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  [ -s "$path" ] || {
    echo "error: timed out waiting for tracked process evidence" >&2
    exit 1
  }
}

assert_stopped() {
  local process_id
  process_id="$(<"$1")"
  if kill -0 "$process_id" >/dev/null 2>&1; then
    echo "error: tracked process $process_id survived signal cleanup" >&2
    exit 1
  fi
}

run_signal_test() {
  local signal="$1"
  local expected_status="$2"
  local mode="$3"
  local pid_file="$test_root/$signal-$mode.pid"
  local simulator_trace="$test_root/$signal-$mode.simulators"
  local output="$test_root/$signal-$mode-published"
  local status=0

  /usr/bin/ruby -e \
    'signal = ARGV.shift; Signal.trap(signal, "DEFAULT"); exec(*ARGV)' \
    "$signal" /bin/bash -c '
      set -euo pipefail
      guard_file="$1"
      pid_file="$2"
      simulator_trace="$3"
      output="$4"
      mode="$5"
      signal="$6"
      source "$guard_file"
      quakesignal_screenshot_active_child_pid=""
      cleanup() {
        quakesignal_screenshot_stop_processes "$quakesignal_screenshot_active_child_pid"
        printf "shutdown iphone-device\ndelete iphone-device\nshutdown ipad-device\ndelete ipad-device\n" >"$simulator_trace"
      }
      trap cleanup EXIT
      trap "exit 130" INT
      trap "exit 143" TERM
      if [ "$mode" = "race" ]; then
        export QUAKESIGNAL_TEST_HOLD_SCREENSHOT_PID_ASSIGNMENT=1
      fi
      quakesignal_screenshot_run_tracked /bin/bash -c '\''
        printf "%s\n" "$$" >"$1"
        /bin/sleep 30 &
        descendant=$!
        printf "%s\n" "$descendant" >"$1.descendant"
        if [ "$3" = "race" ]; then kill -"$2" "$PPID"; fi
        wait "$descendant"
      '\'' tracked "$pid_file" "$signal" "$mode"
      mkdir "$output"
    ' screenshot-supervisor \
    "$script_dir/screenshot-process-guard.sh" "$pid_file" "$simulator_trace" "$output" "$mode" "$signal" &
  supervisor_pid=$!
  wait_for_file "$pid_file"
  wait_for_file "$pid_file.descendant"
  if [ "$mode" = "normal" ]; then kill -"$signal" "$supervisor_pid"; fi
  if wait "$supervisor_pid"; then status=0; else status=$?; fi
  supervisor_pid=""
  if [ "$status" -ne "$expected_status" ]; then
    echo "error: $signal/$mode expected $expected_status, received $status" >&2
    exit 1
  fi
  assert_stopped "$pid_file"
  assert_stopped "$pid_file.descendant"
  if [ -e "$output" ] || [ -L "$output" ]; then
    echo "error: $signal/$mode published output after interruption" >&2
    exit 1
  fi
  if [ "$(<"$simulator_trace")" != $'shutdown iphone-device\ndelete iphone-device\nshutdown ipad-device\ndelete ipad-device' ]; then
    echo "error: $signal/$mode did not clean both disposable simulators" >&2
    exit 1
  fi
}

successful_parent="$test_root/publication-parent"
mkdir -p "$successful_parent/stage/payload"
successful_payload="$successful_parent/stage/payload"
successful_output="$successful_parent/published"
successful_identity="$(quakesignal_screenshot_capture_parent_identity "$successful_parent")"
successful_payload_parent_identity="$(quakesignal_screenshot_capture_directory_identity "$successful_parent/stage")"
successful_payload_identity="$(quakesignal_screenshot_capture_directory_identity "$successful_payload")"
quakesignal_screenshot_publish_directory \
  "$successful_payload" "$successful_output" "$successful_identity" \
  "$successful_payload_parent_identity" "$successful_payload_identity"
if [ ! -d "$successful_output" ] || [ -L "$successful_output" ] || [ -e "$successful_payload" ]; then
  echo "error: bound-parent publication did not atomically publish one plain directory" >&2
  exit 1
fi
successful_cleanup="$successful_parent/cleanup"
mkdir "$successful_cleanup"
successful_cleanup_identity="$(quakesignal_screenshot_capture_directory_identity "$successful_cleanup")"
quakesignal_screenshot_remove_bound_tree \
  "$successful_cleanup" "$successful_parent" "$successful_identity" "$successful_cleanup_identity"
if [ -e "$successful_cleanup" ] || [ -L "$successful_cleanup" ]; then
  echo "error: exact identity-bound cleanup did not remove its own directory" >&2
  exit 1
fi

swapped_parent="$test_root/swapped-parent"
original_parent="$test_root/swapped-parent-original"
attacker_parent="$test_root/swapped-parent-attacker"
mkdir -p "$swapped_parent/stage/payload" "$swapped_parent/recovery-temp" "$attacker_parent/recovery-temp"
printf '%s\n' recovery >"$swapped_parent/recovery-temp/simulator-lease.json"
printf '%s\n' attacker >"$attacker_parent/recovery-temp/attacker-marker"
swapped_payload="$swapped_parent/stage/payload"
swapped_output="$swapped_parent/published"
swapped_identity="$(quakesignal_screenshot_capture_parent_identity "$swapped_parent")"
swapped_payload_parent_identity="$(quakesignal_screenshot_capture_directory_identity "$swapped_parent/stage")"
swapped_payload_identity="$(quakesignal_screenshot_capture_directory_identity "$swapped_payload")"
swapped_cleanup_identity="$(quakesignal_screenshot_capture_directory_identity "$swapped_parent/recovery-temp")"
mv "$swapped_parent" "$original_parent"
ln -s "$attacker_parent" "$swapped_parent"
if quakesignal_screenshot_publish_directory \
  "$swapped_payload" "$swapped_output" "$swapped_identity" \
  "$swapped_payload_parent_identity" "$swapped_payload_identity" >/dev/null 2>&1; then
  echo "error: publication accepted a symlink-rebound parent" >&2
  exit 1
fi
if [ -e "$attacker_parent/published" ] || [ -L "$attacker_parent/published" ] || \
   [ ! -d "$original_parent/stage/payload" ]; then
  echo "error: parent-swap rejection published or lost the staged payload" >&2
  exit 1
fi
if quakesignal_screenshot_remove_bound_tree \
  "$swapped_parent/recovery-temp" "$swapped_parent" "$swapped_identity" \
  "$swapped_cleanup_identity" >/dev/null 2>&1; then
  echo "error: cleanup accepted a symlink-rebound parent" >&2
  exit 1
fi

payload_race_parent="$test_root/payload-race-parent"
mkdir -p "$payload_race_parent/stage/payload"
printf '%s\n' original >"$payload_race_parent/stage/payload/original-marker"
payload_race_hook="$test_root/payload-race-hook"
/usr/bin/ruby -e '
  File.write(ARGV.fetch(0), %q{#!/bin/bash
set -euo pipefail
mv "$1" "$1-original"
mkdir "$1"
printf "%s\n" replacement >"$1/replacement-marker"
}, mode: "wx")
' "$payload_race_hook"
chmod +x "$payload_race_hook"
payload_race_payload="$payload_race_parent/stage/payload"
payload_race_output="$payload_race_parent/published"
payload_race_parent_identity="$(quakesignal_screenshot_capture_parent_identity "$payload_race_parent")"
payload_race_stage_identity="$(quakesignal_screenshot_capture_directory_identity "$payload_race_parent/stage")"
payload_race_identity="$(quakesignal_screenshot_capture_directory_identity "$payload_race_payload")"
if QUAKESIGNAL_SCREENSHOT_TEST_HOOKS=1 \
   QUAKESIGNAL_TEST_SCREENSHOT_PUBLISH_HOOK="$payload_race_hook" \
   quakesignal_screenshot_publish_directory \
     "$payload_race_payload" "$payload_race_output" "$payload_race_parent_identity" \
     "$payload_race_stage_identity" "$payload_race_identity" >/dev/null 2>&1; then
  echo "error: publication accepted a same-parent payload inode swap" >&2
  exit 1
fi
if [ -e "$payload_race_output" ] || [ -L "$payload_race_output" ] || \
   [ "$(<"$payload_race_parent/stage/payload-original/original-marker")" != "original" ] || \
   [ "$(<"$payload_race_parent/stage/payload/replacement-marker")" != "replacement" ]; then
  echo "error: payload-swap rejection published bytes or failed to restore the raced entry" >&2
  exit 1
fi

target_race_parent="$test_root/target-race-parent"
mkdir -p "$target_race_parent/stage/payload"
target_race_hook="$test_root/target-race-hook"
/usr/bin/ruby -e '
  File.write(ARGV.fetch(0), %q{#!/bin/bash
set -euo pipefail
mkdir "$2"
printf "%s\n" attacker >"$2/attacker-marker"
}, mode: "wx")
' "$target_race_hook"
chmod +x "$target_race_hook"
target_race_payload="$target_race_parent/stage/payload"
target_race_output="$target_race_parent/published"
target_race_parent_identity="$(quakesignal_screenshot_capture_parent_identity "$target_race_parent")"
target_race_stage_identity="$(quakesignal_screenshot_capture_directory_identity "$target_race_parent/stage")"
target_race_payload_identity="$(quakesignal_screenshot_capture_directory_identity "$target_race_payload")"
if QUAKESIGNAL_SCREENSHOT_TEST_HOOKS=1 \
   QUAKESIGNAL_TEST_SCREENSHOT_PUBLISH_HOOK="$target_race_hook" \
   quakesignal_screenshot_publish_directory \
     "$target_race_payload" "$target_race_output" "$target_race_parent_identity" \
     "$target_race_stage_identity" "$target_race_payload_identity" >/dev/null 2>&1; then
  echo "error: publication replaced a target created during the rename race" >&2
  exit 1
fi
if [ ! -d "$target_race_payload" ] || [ -L "$target_race_payload" ] || \
   [ "$(<"$target_race_output/attacker-marker")" != "attacker" ]; then
  echo "error: exclusive target-race rejection lost payload or changed attacker content" >&2
  exit 1
fi

cleanup_race_parent="$test_root/cleanup-race-parent"
mkdir -p "$cleanup_race_parent/bound" "$cleanup_race_parent/replacement"
printf '%s\n' original >"$cleanup_race_parent/bound/original-marker"
printf '%s\n' replacement >"$cleanup_race_parent/replacement/replacement-marker"
cleanup_race_parent_identity="$(quakesignal_screenshot_capture_parent_identity "$cleanup_race_parent")"
cleanup_race_bound_identity="$(quakesignal_screenshot_capture_directory_identity "$cleanup_race_parent/bound")"
mv "$cleanup_race_parent/bound" "$cleanup_race_parent/bound-original"
mv "$cleanup_race_parent/replacement" "$cleanup_race_parent/bound"
if quakesignal_screenshot_remove_bound_tree \
  "$cleanup_race_parent/bound" "$cleanup_race_parent" "$cleanup_race_parent_identity" \
  "$cleanup_race_bound_identity" >/dev/null 2>&1; then
  echo "error: identity-bound cleanup accepted a same-parent target swap" >&2
  exit 1
fi
if [ "$(<"$cleanup_race_parent/bound-original/original-marker")" != "original" ] || \
   [ "$(<"$cleanup_race_parent/bound/replacement-marker")" != "replacement" ]; then
  echo "error: identity-bound cleanup touched a swapped target" >&2
  exit 1
fi
if [ ! -f "$original_parent/recovery-temp/simulator-lease.json" ] || \
   [ "$(<"$attacker_parent/recovery-temp/attacker-marker")" != "attacker" ]; then
  echo "error: parent-rebind cleanup lost recovery evidence or touched attacker content" >&2
  exit 1
fi

run_signal_test TERM 143 normal
run_signal_test INT 130 normal
run_signal_test HUP 129 normal
run_signal_test TERM 143 race
run_signal_test INT 130 race
run_signal_test HUP 129 race

echo "Screenshot tracked-process/simulator signal tests passed"
