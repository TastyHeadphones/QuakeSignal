#!/bin/bash

# Send TERM to every live child together, wait at most two seconds, then use
# KILL before reaping. This keeps EXIT/signal cleanup bounded even if
# CoreSimulator ignores a graceful termination request.
quakesignal_stop_processes() {
  local process_id
  local any_live=0
  local attempt=0

  for process_id in "$@"; do
    if [ -n "$process_id" ] && kill -0 "$process_id" >/dev/null 2>&1; then
      kill -TERM "$process_id" >/dev/null 2>&1 || true
    fi
  done

  while [ "$attempt" -lt 2 ]; do
    any_live=0
    for process_id in "$@"; do
      if [ -n "$process_id" ] && kill -0 "$process_id" >/dev/null 2>&1; then
        any_live=1
        break
      fi
    done
    [ "$any_live" -eq 0 ] && break
    sleep 1
    attempt=$((attempt + 1))
  done

  for process_id in "$@"; do
    if [ -n "$process_id" ] && kill -0 "$process_id" >/dev/null 2>&1; then
      kill -KILL "$process_id" >/dev/null 2>&1 || true
    fi
  done
  for process_id in "$@"; do
    if [ -n "$process_id" ]; then
      wait "$process_id" >/dev/null 2>&1 || true
    fi
  done
}

# Stop one child with the same bound while preserving wait's status. Only a
# signal this helper successfully sends is normalized to success; a child that
# already failed with 137/143 remains a failure.
quakesignal_stop_process_with_status() {
  local process_id="$1"
  local attempt=0
  local stopped_by_guard=0
  local process_status=0

  if [ -z "$process_id" ]; then
    return 0
  fi
  if kill -0 "$process_id" >/dev/null 2>&1; then
    if kill -TERM "$process_id" >/dev/null 2>&1; then
      stopped_by_guard=1
    fi
  fi
  while kill -0 "$process_id" >/dev/null 2>&1 && [ "$attempt" -lt 2 ]; do
    sleep 1
    attempt=$((attempt + 1))
  done
  if kill -0 "$process_id" >/dev/null 2>&1; then
    if kill -KILL "$process_id" >/dev/null 2>&1; then
      stopped_by_guard=1
    fi
  fi
  if wait "$process_id"; then
    process_status=0
  else
    process_status=$?
  fi
  if [ "$stopped_by_guard" -eq 1 ]; then
    case "$process_status" in
      137|143) return 0 ;;
    esac
  fi
  return "$process_status"
}

# A signal trap can run after an external child starts but before Bash assigns
# $!, leaving EXIT cleanup without the child's PID. Defer only across that
# two-command critical section, restore the caller's exact traps, then apply
# its 130/143 exit semantics after the tracked PID is populated.
quakesignal_defer_tracked_spawn_signals() {
  quakesignal_saved_int_trap="$(trap -p INT)"
  quakesignal_saved_term_trap="$(trap -p TERM)"
  quakesignal_deferred_spawn_signal=""
  trap 'quakesignal_deferred_spawn_signal=INT' INT
  trap 'quakesignal_deferred_spawn_signal=TERM' TERM
}

quakesignal_restore_tracked_spawn_signals() {
  if [ -n "$quakesignal_saved_int_trap" ]; then
    eval "$quakesignal_saved_int_trap"
  else
    trap - INT
  fi
  if [ -n "$quakesignal_saved_term_trap" ]; then
    eval "$quakesignal_saved_term_trap"
  else
    trap - TERM
  fi

  case "$quakesignal_deferred_spawn_signal" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
  esac
}

# Captures a Watch screenshot while periodically restarting the fixture app.
# The caller initializes global screenshot_pid/watch_reactivation_pid values so
# its EXIT trap can stop the exact external children if interrupted. Production
# uses xcrun; the executable override exists solely for the credential-free
# process-supervisor test.
quakesignal_capture_watch_screenshot() {
  if [ "$#" -ne 7 ]; then
    echo "error: Watch capture guard expects simulator, bundle, output, locale, Apple locale, timeout, and interval" >&2
    return 64
  fi

  local simulator_id="$1"
  local bundle_id="$2"
  local candidate="$3"
  local locale="$4"
  local apple_locale="$5"
  local timeout_seconds="$6"
  local reactivation_interval_seconds="$7"
  local xcrun_executable="${QUAKESIGNAL_XCRUN_EXECUTABLE:-xcrun}"
  case "$timeout_seconds" in
    ""|0|0*|*[!0-9]*)
      echo "error: Watch capture timeout must be one canonical positive integer" >&2
      return 64
      ;;
    *) ;;
  esac
  case "$reactivation_interval_seconds" in
    ""|0|0*|*[!0-9]*)
      echo "error: Watch reactivation interval must be one canonical positive integer" >&2
      return 64
      ;;
    *) ;;
  esac
  if [ "$reactivation_interval_seconds" -ge "$timeout_seconds" ]; then
    echo "error: Watch reactivation interval must be shorter than its capture timeout" >&2
    return 64
  fi

  local started_at_seconds="$SECONDS"
  local elapsed_seconds=0
  local next_reactivation_seconds="$reactivation_interval_seconds"
  local reactivation_status=0
  local screenshot_status=0
  local spawned_pid=""

  quakesignal_defer_tracked_spawn_signals
  "$xcrun_executable" simctl io \
    "$simulator_id" screenshot --type=png --mask=black "$candidate" &
  spawned_pid=$!
  if [ "${QUAKESIGNAL_TEST_HOLD_PID_ASSIGNMENT:-0}" = "1" ]; then
    sleep 1 || true
  fi
  screenshot_pid="$spawned_pid"
  quakesignal_restore_tracked_spawn_signals

  while kill -0 "$screenshot_pid" >/dev/null 2>&1; do
    sleep 1
    elapsed_seconds=$((SECONDS - started_at_seconds))

    if [ "$elapsed_seconds" -ge "$timeout_seconds" ]; then
      quakesignal_stop_processes "$screenshot_pid" "$watch_reactivation_pid"
      screenshot_pid=""
      watch_reactivation_pid=""
      echo "error: Watch screenshot exceeded the ${timeout_seconds}s hard timeout" >&2
      return 124
    fi

    # Harvest a completed restart before accepting a screenshot that finished
    # in the same polling tick. Otherwise its nonzero status could be lost by
    # the post-capture child cleanup.
    if [ -n "$watch_reactivation_pid" ] && \
        ! kill -0 "$watch_reactivation_pid" >/dev/null 2>&1; then
      if wait "$watch_reactivation_pid"; then
        reactivation_status=0
      else
        reactivation_status=$?
      fi
      watch_reactivation_pid=""
      if [ "$reactivation_status" -ne 0 ]; then
        quakesignal_stop_processes "$screenshot_pid"
        screenshot_pid=""
        echo "error: deterministic Watch foreground restart failed with status $reactivation_status" >&2
        return 70
      fi
    fi

    if ! kill -0 "$screenshot_pid" >/dev/null 2>&1; then
      break
    fi

    if [ -z "$watch_reactivation_pid" ] && \
        [ "$elapsed_seconds" -ge "$next_reactivation_seconds" ]; then
      echo "Watch screenshot still pending after ${elapsed_seconds}s; restarting QuakeSignal in foreground"
      # Spawn the external command directly. Backgrounding a shell function
      # here would make $! identify a wrapper and could orphan its xcrun child.
      quakesignal_defer_tracked_spawn_signals
      SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_AUTOMATION=1 \
      SIMCTL_CHILD_AppleLanguages="($locale)" \
      SIMCTL_CHILD_AppleLocale="$apple_locale" \
      SIMCTL_CHILD_TZ=UTC \
        "$xcrun_executable" simctl launch --terminate-running-process \
          "$simulator_id" "$bundle_id" \
          --quakesignal-screenshot-automation >/dev/null &
      spawned_pid=$!
      if [ "${QUAKESIGNAL_TEST_HOLD_PID_ASSIGNMENT:-0}" = "1" ]; then
        sleep 1 || true
      fi
      watch_reactivation_pid="$spawned_pid"
      quakesignal_restore_tracked_spawn_signals
      next_reactivation_seconds=$((elapsed_seconds + reactivation_interval_seconds))
    fi
  done

  if quakesignal_stop_process_with_status "$watch_reactivation_pid"; then
    reactivation_status=0
  else
    reactivation_status=$?
  fi
  watch_reactivation_pid=""
  if wait "$screenshot_pid"; then
    screenshot_status=0
  else
    screenshot_status=$?
  fi
  screenshot_pid=""

  if [ "$screenshot_status" -ne 0 ]; then
    echo "error: Watch screenshot command failed with status $screenshot_status" >&2
    return 70
  fi
  if [ "$reactivation_status" -ne 0 ]; then
    echo "error: deterministic Watch foreground restart failed with status $reactivation_status" >&2
    return 70
  fi
}
