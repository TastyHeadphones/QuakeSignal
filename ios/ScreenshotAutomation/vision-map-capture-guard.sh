#!/bin/bash

# Capture an exact reviewed Vision route and reject the gray launch placeholder
# that CoreSimulator can return before SwiftUI commits meaningful app content.
# A first semantic rejection is quarantined and receives one exact-route
# relaunch/retry; a second rejection fails before the caller can publish the
# candidate or write provenance. The validator applies stricter map-specific
# evidence when the selected route is visionos-map.
quakesignal_capture_validated_vision_screenshot() {
  if [ "$#" -ne 13 ]; then
    echo "error: validated Vision capture expects 13 arguments" >&2
    return 64
  fi

  local simulator_id="$1"
  local bundle_id="$2"
  local candidate="$3"
  local locale="$4"
  local apple_locale="$5"
  local frame_selector="$6"
  local validation_root="$7"
  local expected_width="$8"
  local expected_height="$9"
  local validator_path="${10}"
  local retry_settle_seconds="${11}"
  local sips_executable="${12}"
  local ruby_executable="${13}"
  local xcrun_executable="${QUAKESIGNAL_XCRUN_EXECUTABLE:-xcrun}"
  local candidate_parent=""
  local capture_attempt=1
  local maximum_attempts=2
  local validation_bitmap=""
  local rejected_candidate=""
  local capture_status=0
  local relaunch_status=0
  local validator_status=0
  local spawned_pid=""
  local sleep_status=0

  case "$frame_selector" in
    visionos-home|visionos-reports|visionos-map|visionos-guide|visionos-alert-preferences) ;;
    *)
      echo "error: Vision semantic capture requires an exact reviewed selector" >&2
      return 64
      ;;
  esac
  if ! [[ "$retry_settle_seconds" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "error: Vision retry settle time must be a canonical nonnegative integer" >&2
    return 64
  fi
  if [ ! -d "$validation_root" ] || [ -L "$validation_root" ]; then
    echo "error: Vision validation root must be a real directory" >&2
    return 64
  fi
  validation_root="$(cd "$validation_root" && pwd -P)" || return 64
  candidate_parent="$(cd "$(dirname "$candidate")" && pwd -P)" || return 64
  if [ "$candidate_parent" != "$validation_root" ]; then
    echo "error: Vision candidate must remain inside its validation root" >&2
    return 64
  fi
  if [ ! -f "$validator_path" ] || [ -L "$validator_path" ]; then
    echo "error: Vision validator must be a regular non-symlink file" >&2
    return 64
  fi
  if ! command -v "$xcrun_executable" >/dev/null 2>&1 ||
      ! command -v "$sips_executable" >/dev/null 2>&1 ||
      ! command -v "$ruby_executable" >/dev/null 2>&1; then
    echo "error: Vision validation executables are unavailable" >&2
    return 69
  fi

  while [ "$capture_attempt" -le "$maximum_attempts" ]; do
    validation_bitmap="$validation_root/vision-validation-$capture_attempt.bmp"
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
      echo "error: refusing to overwrite an existing Vision candidate" >&2
      return 73
    fi
    if [ -e "$validation_bitmap" ] || [ -L "$validation_bitmap" ]; then
      echo "error: refusing to overwrite an existing Vision validation bitmap" >&2
      return 73
    fi
    capture_status=0
    quakesignal_defer_tracked_spawn_signals
    "$xcrun_executable" simctl io "$simulator_id" screenshot \
      --type=png --mask=black "$candidate" &
    spawned_pid=$!
    if [ "${QUAKESIGNAL_TEST_HOLD_PID_ASSIGNMENT:-0}" = "1" ]; then
      sleep 1 || true
    fi
    screenshot_pid="$spawned_pid"
    quakesignal_restore_tracked_spawn_signals
    if wait "$screenshot_pid"; then
      capture_status=0
    else
      capture_status=$?
    fi
    screenshot_pid=""
    if [ "$capture_status" -ne 0 ]; then
      echo "error: Vision screenshot command failed with status $capture_status" >&2
      return 70
    fi
    if [ ! -f "$candidate" ] || [ -L "$candidate" ]; then
      echo "error: Vision screenshot command did not create a regular candidate" >&2
      return 70
    fi

    # Recheck immediately before conversion as well as before capture. The
    # validation root is private, but this also fails closed if another local
    # process races a path into it while CoreSimulator is taking the frame.
    if [ -e "$validation_bitmap" ] || [ -L "$validation_bitmap" ]; then
      echo "error: refusing to overwrite an existing Vision validation bitmap" >&2
      return 73
    fi
    if ! "$sips_executable" -s format bmp "$candidate" --out "$validation_bitmap" >/dev/null; then
      echo "error: could not create the temporary Vision validation bitmap" >&2
      return 70
    fi
    if [ ! -f "$validation_bitmap" ] || [ -L "$validation_bitmap" ]; then
      echo "error: Vision conversion did not create a regular validation bitmap" >&2
      return 70
    fi
    validator_status=0
    "$ruby_executable" "$validator_path" \
      "$validation_bitmap" "$expected_width" "$expected_height" "$frame_selector" || \
      validator_status=$?
    if [ "$validator_status" -eq 0 ]; then
      return 0
    fi
    if [ "$validator_status" -ne 65 ]; then
      echo "error: Vision validator failed operationally with status $validator_status; refusing retry" >&2
      return 70
    fi
    rejected_candidate="$validation_root/rejected-vision-attempt-$capture_attempt.png"
    if [ -e "$rejected_candidate" ] || [ -L "$rejected_candidate" ]; then
      echo "error: refusing to overwrite a quarantined Vision capture" >&2
      return 73
    fi
    if ! mv "$candidate" "$rejected_candidate"; then
      echo "error: could not quarantine the rejected Vision capture" >&2
      return 73
    fi
    if [ "$capture_attempt" -ge "$maximum_attempts" ]; then
      echo "error: Vision screenshot failed semantic validation after $maximum_attempts attempts" >&2
      return 65
    fi

    echo "Vision screenshot failed semantic validation; relaunching the exact frame for one bounded retry" >&2
    relaunch_status=0
    quakesignal_defer_tracked_spawn_signals
    /usr/bin/env \
      SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_AUTOMATION=1 \
      SIMCTL_CHILD_QUAKESIGNAL_SCREENSHOT_FRAME="$frame_selector" \
      "SIMCTL_CHILD_AppleLanguages=($locale)" \
      "SIMCTL_CHILD_AppleLocale=$apple_locale" \
      SIMCTL_CHILD_TZ=UTC \
      "$xcrun_executable" simctl launch --terminate-running-process \
        "$simulator_id" "$bundle_id" \
        --quakesignal-screenshot-automation \
        "--quakesignal-screenshot-frame=$frame_selector" >/dev/null &
    spawned_pid=$!
    if [ "${QUAKESIGNAL_TEST_HOLD_PID_ASSIGNMENT:-0}" = "1" ]; then
      sleep 1 || true
    fi
    watch_reactivation_pid="$spawned_pid"
    quakesignal_restore_tracked_spawn_signals
    if wait "$watch_reactivation_pid"; then
      relaunch_status=0
    else
      relaunch_status=$?
    fi
    watch_reactivation_pid=""
    if [ "$relaunch_status" -ne 0 ]; then
      echo "error: exact-frame Vision relaunch failed with status $relaunch_status" >&2
      return 70
    fi

    sleep_status=0
    sleep "$retry_settle_seconds" || sleep_status=$?
    if [ "$sleep_status" -ne 0 ]; then
      echo "error: Vision retry settle was interrupted with status $sleep_status" >&2
      return 70
    fi
    capture_attempt=$((capture_attempt + 1))
  done

  return 65
}
