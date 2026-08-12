#!/usr/bin/env bash
#
# Read only the terminal alert-delivery fallback Queue's aggregate metrics.
# This monitor never pulls, acknowledges, retries, purges, or logs Queue
# messages. A nonzero result is an operator-recovery event, not a redrive.

set -euo pipefail

readonly DEFAULT_QUEUE_NAME="quakesignal-alert-delivery-dlq-fallback"
readonly CLOUDFLARE_API_BASE="${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}"
readonly TERMINAL_DLQ_FALLBACK_QUEUE_NAME="${TERMINAL_DLQ_FALLBACK_QUEUE_NAME:-$DEFAULT_QUEUE_NAME}"

fail() {
  printf '%s\n' "::error title=Terminal DLQ fallback monitor::$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command is unavailable: $1"
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "Required environment value is missing: $name"
}

write_output() {
  local key="$1"
  local value="$2"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$key" "$value"
  fi
}

api_get() {
  local path="$1"
  local output_file="$2"
  local status

  # Keep the bearer token in a request header and discard API response bodies
  # on errors. Cloudflare Queue messages are never requested by this monitor.
  if ! status="$(curl \
    --silent \
    --output "$output_file" \
    --write-out '%{http_code}' \
    --connect-timeout 10 \
    --max-time 30 \
    --retry 2 \
    --header "Authorization: Bearer ${CLOUDFLARE_MONITOR_API_TOKEN}" \
    --header 'Accept: application/json' \
    "${CLOUDFLARE_API_BASE%/}${path}")"; then
    fail "Cloudflare Queue API request failed. Check the protected monitor token and account access."
  fi

  [[ "$status" =~ ^2[0-9][0-9]$ ]] || \
    fail "Cloudflare Queue API returned an unexpected status. Check the protected monitor token and account access."

  jq -e '.success == true' "$output_file" >/dev/null 2>&1 || \
    fail "Cloudflare Queue API returned an invalid response. Check the protected monitor token and account access."
}

require_command curl
require_command jq
require_value CLOUDFLARE_MONITOR_API_TOKEN
require_value CLOUDFLARE_ACCOUNT_ID

[[ "$CLOUDFLARE_ACCOUNT_ID" =~ ^[A-Za-z0-9]{1,64}$ ]] || \
  fail "CLOUDFLARE_ACCOUNT_ID has an unexpected format."
[[ "$TERMINAL_DLQ_FALLBACK_QUEUE_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || \
  fail "TERMINAL_DLQ_FALLBACK_QUEUE_NAME has an unexpected format."

tmp_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/quakesignal-terminal-dlq-monitor.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

queue_ids=()
page=1
total_pages=1

while (( page <= total_pages )); do
  list_file="$tmp_dir/queues-$page.json"
  api_get "/accounts/${CLOUDFLARE_ACCOUNT_ID}/queues?page=${page}&per_page=100" "$list_file"

  jq -e '(.result | type) == "array"' "$list_file" >/dev/null 2>&1 || \
    fail "Cloudflare Queue API did not return a Queue list."

  while IFS= read -r queue_id; do
    [[ -n "$queue_id" ]] || continue
    [[ "$queue_id" =~ ^[A-Za-z0-9]{1,64}$ ]] || \
      fail "Cloudflare Queue API returned an invalid Queue identifier."
    queue_ids+=("$queue_id")
  done < <(
    jq -r --arg queue_name "$TERMINAL_DLQ_FALLBACK_QUEUE_NAME" \
      '.result[] | select(.queue_name == $queue_name) | .queue_id // empty' \
      "$list_file"
  )

  total_pages="$(jq -er '.result_info.total_pages // 1' "$list_file" 2>/dev/null)" || \
    fail "Cloudflare Queue API returned invalid pagination metadata."
  [[ "$total_pages" =~ ^[1-9][0-9]*$ ]] && (( total_pages <= 1000 )) || \
    fail "Cloudflare Queue API returned invalid pagination metadata."
  ((page += 1))
done

(( ${#queue_ids[@]} == 1 )) || \
  fail "Expected exactly one terminal fallback Queue named ${TERMINAL_DLQ_FALLBACK_QUEUE_NAME}; found ${#queue_ids[@]}."

metrics_file="$tmp_dir/metrics.json"
api_get "/accounts/${CLOUDFLARE_ACCOUNT_ID}/queues/${queue_ids[0]}/metrics" "$metrics_file"

backlog_count="$(jq -er '
  .result.backlog_count as $value
  | if ($value | type) == "number" and $value >= 0 and ($value | floor) == $value
    then ($value | tostring)
    else error("invalid backlog count")
    end
' "$metrics_file" 2>/dev/null)" || fail "Cloudflare Queue metrics did not include a valid backlog count."

oldest_message_timestamp_ms="$(jq -er '
  .result.oldest_message_timestamp_ms as $value
  | if ($value | type) == "number" and $value >= 0 and ($value | floor) == $value
    then ($value | tostring)
    else error("invalid oldest timestamp")
    end
' "$metrics_file" 2>/dev/null)" || fail "Cloudflare Queue metrics did not include a valid oldest-message timestamp."

oldest_message_age_seconds="unknown"
if (( oldest_message_timestamp_ms > 0 )); then
  now_ms="$(date +%s%3N)"
  if (( oldest_message_timestamp_ms <= now_ms )); then
    oldest_message_age_seconds="$(((now_ms - oldest_message_timestamp_ms) / 1000))"
  else
    oldest_message_age_seconds="clock-skew-or-future"
  fi
fi

alert=false
if (( backlog_count > 0 || oldest_message_timestamp_ms > 0 )); then
  alert=true
fi

# All outputs are aggregate, token-free metrics suitable for a GitHub issue.
write_output "alert" "$alert"
write_output "queue_name" "$TERMINAL_DLQ_FALLBACK_QUEUE_NAME"
write_output "backlog_count" "$backlog_count"
write_output "oldest_message_timestamp_ms" "$oldest_message_timestamp_ms"
write_output "oldest_message_age_seconds" "$oldest_message_age_seconds"
