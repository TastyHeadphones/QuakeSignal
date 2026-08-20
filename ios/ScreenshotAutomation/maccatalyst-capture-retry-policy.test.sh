#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=maccatalyst-capture-retry-policy.sh
. "$script_dir/maccatalyst-capture-retry-policy.sh"

assert_decision() {
  local expected="$1"
  local attempt="$2"
  local status="$3"
  local actual
  actual="$(quakesignal_maccatalyst_capture_retry_decision "$attempt" "$status")"
  if [ "$actual" != "$expected" ]; then
    echo "error: attempt $attempt/status $status expected $expected, received $actual" >&2
    exit 1
  fi
}

assert_decision accept 1 0
assert_decision accept 2 0
assert_decision retry 1 65
assert_decision semantic-failure 2 65
assert_decision operational-failure 1 70
assert_decision operational-failure 2 70
assert_decision operational-failure 1 64

set +e
quakesignal_maccatalyst_capture_retry_decision 0 65 >/dev/null
invalid_attempt_status="$?"
quakesignal_maccatalyst_capture_retry_decision 1 >/dev/null
invalid_arity_status="$?"
set -e
if [ "$invalid_attempt_status" -ne 64 ] || [ "$invalid_arity_status" -ne 64 ]; then
  echo "error: invalid retry-policy inputs must fail with usage status 64" >&2
  exit 1
fi

echo "Mac Catalyst capture retry policy tests passed"
