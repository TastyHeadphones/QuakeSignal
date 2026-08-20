#!/bin/bash

# Pure policy for the bounded Mac Catalyst semantic retry. The caller owns
# process cleanup and publication; this function only classifies a completed
# validator attempt.
quakesignal_maccatalyst_capture_retry_decision() {
  if [ "$#" -ne 2 ]; then
    return 64
  fi

  local attempt="$1"
  local validator_status="$2"
  case "$attempt" in
    1|2) ;;
    *) return 64 ;;
  esac
  case "$validator_status" in
    0)
      printf '%s\n' accept
      ;;
    65)
      if [ "$attempt" -eq 1 ]; then
        printf '%s\n' retry
      else
        printf '%s\n' semantic-failure
      fi
      ;;
    *)
      printf '%s\n' operational-failure
      ;;
  esac
}
