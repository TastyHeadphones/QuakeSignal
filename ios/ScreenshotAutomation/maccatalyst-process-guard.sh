#!/bin/bash

# Stop each exact child PID with a bounded TERM/KILL/reap sequence. Callers keep
# the PID globals in their EXIT cleanup so a direct INT/TERM sent to the harness
# cannot orphan an in-flight compiler, build, window observer, capture, sleep,
# validator, or launched app.
quakesignal_maccatalyst_process_tree() {
  local process_id="$1"
  local child_id
  for child_id in $(/usr/bin/pgrep -P "$process_id" 2>/dev/null || true); do
    quakesignal_maccatalyst_process_tree "$child_id"
  done
  printf '%s\n' "$process_id"
}

quakesignal_maccatalyst_stop_processes() {
  local process_id
  local any_live=0
  local attempt=0
  local requested_id
  # The empty sentinel keeps Bash 3.2 + `set -u` from treating an empty local
  # array as unbound; every action below already ignores empty PIDs.
  local process_ids=("")

  for requested_id in "$@"; do
    if [ -n "$requested_id" ] && kill -0 "$requested_id" >/dev/null 2>&1; then
      while IFS= read -r process_id; do
        process_ids+=("$process_id")
      done < <(quakesignal_maccatalyst_process_tree "$requested_id")
    elif [ -n "$requested_id" ]; then
      process_ids+=("$requested_id")
    fi
  done

  for process_id in "${process_ids[@]}"; do
    if [ -n "$process_id" ] && kill -0 "$process_id" >/dev/null 2>&1; then
      kill -TERM "$process_id" >/dev/null 2>&1 || true
    fi
  done
  while [ "$attempt" -lt 20 ]; do
    any_live=0
    for process_id in "${process_ids[@]}"; do
      if [ -n "$process_id" ] && kill -0 "$process_id" >/dev/null 2>&1; then
        any_live=1
        break
      fi
    done
    [ "$any_live" -eq 0 ] && break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  for process_id in "${process_ids[@]}"; do
    if [ -n "$process_id" ] && kill -0 "$process_id" >/dev/null 2>&1; then
      kill -KILL "$process_id" >/dev/null 2>&1 || true
    fi
  done
  for process_id in "${process_ids[@]}"; do
    if [ -n "$process_id" ]; then
      wait "$process_id" >/dev/null 2>&1 || true
    fi
  done
}

# Defer INT/TERM only across the asynchronous-spawn/$! assignment critical
# section. The original traps are restored before waiting for the child.
quakesignal_maccatalyst_defer_spawn_signals() {
  quakesignal_maccatalyst_saved_int_trap="$(trap -p INT)"
  quakesignal_maccatalyst_saved_term_trap="$(trap -p TERM)"
  quakesignal_maccatalyst_deferred_signal=""
  trap 'quakesignal_maccatalyst_deferred_signal=INT' INT
  trap 'quakesignal_maccatalyst_deferred_signal=TERM' TERM
}

quakesignal_maccatalyst_restore_spawn_signals() {
  if [ -n "$quakesignal_maccatalyst_saved_int_trap" ]; then
    eval "$quakesignal_maccatalyst_saved_int_trap"
  else
    trap - INT
  fi
  if [ -n "$quakesignal_maccatalyst_saved_term_trap" ]; then
    eval "$quakesignal_maccatalyst_saved_term_trap"
  else
    trap - TERM
  fi
  case "$quakesignal_maccatalyst_deferred_signal" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
  esac
}

# Run one foreground operation as an explicitly tracked asynchronous child,
# preserving its exact exit status for the caller.
quakesignal_maccatalyst_run_tracked() {
  if [ "$#" -eq 0 ]; then
    return 64
  fi
  local spawned_pid
  local child_status=0

  quakesignal_maccatalyst_defer_spawn_signals
  "$@" &
  spawned_pid=$!
  if [ "${QUAKESIGNAL_TEST_HOLD_CATALYST_PID_ASSIGNMENT:-0}" = "1" ]; then
    sleep 1 || true
  fi
  maccatalyst_active_child_pid="$spawned_pid"
  quakesignal_maccatalyst_restore_spawn_signals

  if wait "$maccatalyst_active_child_pid"; then
    child_status=0
  else
    child_status=$?
  fi
  maccatalyst_active_child_pid=""
  return "$child_status"
}
