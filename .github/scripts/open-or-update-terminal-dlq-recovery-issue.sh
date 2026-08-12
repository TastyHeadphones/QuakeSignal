#!/usr/bin/env bash
#
# Open or refresh one incident issue from already-sanitized Queue metrics.
# Do not add Queue message bodies, provider credentials, or API responses here.

set -euo pipefail

readonly LABEL="quakesignal-terminal-dlq-fallback"
readonly ISSUE_MARKER="<!-- quakesignal-terminal-dlq-fallback-monitor -->"
readonly ISSUE_TITLE="[Emergency] Recover terminal DLQ fallback backlog"
readonly GITHUB_API_BASE="${GITHUB_API_URL:-https://api.github.com}"

fail() {
  printf '%s\n' "::error title=Terminal DLQ fallback issue::$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command is unavailable: $1"
}

require_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "Required environment value is missing: $name"
}

github_api() {
  local method="$1"
  local path="$2"
  local output_file="$3"
  local payload_file="${4:-}"
  local status
  local -a curl_args=(
    --silent
    --output "$output_file"
    --write-out '%{http_code}'
    --connect-timeout 10
    --max-time 30
    --request "$method"
    --header "Authorization: Bearer ${GITHUB_TOKEN}"
    --header 'Accept: application/vnd.github+json'
    --header 'X-GitHub-Api-Version: 2022-11-28'
  )

  if [[ -n "$payload_file" ]]; then
    curl_args+=(--header 'Content-Type: application/json' --data-binary "@$payload_file")
  fi

  # Retrying a POST/PATCH after an ambiguous network failure could create a
  # duplicate issue or overwrite a newer operator update. GET requests are
  # safe to retry; later scheduled monitor runs provide recovery for a failed
  # write without turning a single incident into a stream of new issues.
  if [[ "$method" == "GET" ]]; then
    curl_args+=(--retry 2)
  fi

  if ! status="$(curl "${curl_args[@]}" "${GITHUB_API_BASE%/}${path}")"; then
    fail "GitHub issue API request failed. Check the workflow's issues permission."
  fi

  printf '%s' "$status"
}

require_command curl
require_command jq
require_value GITHUB_TOKEN
require_value GITHUB_REPOSITORY
require_value QUEUE_NAME
require_value BACKLOG_COUNT
require_value OLDEST_MESSAGE_TIMESTAMP_MS
require_value OLDEST_MESSAGE_AGE_SECONDS

[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
  fail "GITHUB_REPOSITORY has an unexpected format."
[[ "$QUEUE_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || \
  fail "QUEUE_NAME has an unexpected format."
[[ "$BACKLOG_COUNT" =~ ^[0-9]+$ ]] || fail "BACKLOG_COUNT has an unexpected format."
[[ "$OLDEST_MESSAGE_TIMESTAMP_MS" =~ ^[0-9]+$ ]] || \
  fail "OLDEST_MESSAGE_TIMESTAMP_MS has an unexpected format."
[[ "$OLDEST_MESSAGE_AGE_SECONDS" =~ ^([0-9]+|unknown|clock-skew-or-future)$ ]] || \
  fail "OLDEST_MESSAGE_AGE_SECONDS has an unexpected format."

tmp_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/quakesignal-terminal-dlq-issue.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

label_response="$tmp_dir/label.json"
label_status="$(github_api GET "/repos/${GITHUB_REPOSITORY}/labels/${LABEL}" "$label_response")"
case "$label_status" in
  200) ;;
  404)
    label_payload="$tmp_dir/label-payload.json"
    jq -n \
      --arg name "$LABEL" \
      --arg description "Production terminal DLQ fallback recovery required" \
      '{name: $name, color: "B60205", description: $description}' > "$label_payload"
    label_status="$(github_api POST "/repos/${GITHUB_REPOSITORY}/labels" "$label_response" "$label_payload")"
    [[ "$label_status" =~ ^2[0-9][0-9]$ ]] || \
      fail "Could not create the terminal DLQ fallback issue label."
    ;;
  *) fail "Could not read the terminal DLQ fallback issue label." ;;
esac

observed_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
issue_body="${ISSUE_MARKER}
## Terminal fallback backlog detected

The scheduled production monitor found retained work in the intentionally
consumerless terminal Queue. This is an urgent recovery event: the normal DLQ
could not persist an incident in either D1 or the Durable Object fallback.

- Queue: \`${QUEUE_NAME}\`
- Backlog count: \`${BACKLOG_COUNT}\`
- Oldest message timestamp (ms): \`${OLDEST_MESSAGE_TIMESTAMP_MS}\`
- Oldest message age (seconds): \`${OLDEST_MESSAGE_AGE_SECONDS}\`
- Observed (UTC): \`${observed_at}\`

Only aggregate metrics are published here. Do **not** paste Queue message
contents, device data, APNs credentials, Cloudflare tokens, or API responses
into this issue.

## Required recovery

1. Page the designated production responder and follow the terminal-DLQ
   runbook in \`docs/CLOUDFLARE_PRODUCTION.md#terminal-dlq-fallback-recovery\`.
2. Preserve the terminal Queue: do not attach a Worker consumer, purge it, or
   acknowledge messages before D1 and the Durable Object are demonstrably
   healthy.
3. Investigate and restore the D1/Durable Object failure. Perform any manual
   replay only with the approved break-glass Queue procedure; the monitoring
   token must never pull, acknowledge, retry, purge, or redrive messages.
4. Verify the Queue metrics return to zero, record the incident outcome, and
   manually close this issue only after the retained evidence is safely
   recovered or deliberately dispositioned.
"

issues_response="$tmp_dir/issues.json"
issues_status="$(github_api GET "/repos/${GITHUB_REPOSITORY}/issues?state=open&labels=${LABEL}&per_page=100" "$issues_response")"
[[ "$issues_status" =~ ^2[0-9][0-9]$ ]] || \
  fail "Could not list existing terminal DLQ fallback issues."

jq -e 'type == "array"' "$issues_response" >/dev/null 2>&1 || \
  fail "GitHub returned an invalid issue list."

matching_issue_numbers=()
while IFS= read -r issue_number; do
  [[ -n "$issue_number" ]] || continue
  matching_issue_numbers+=("$issue_number")
done < <(
  jq -r --arg marker "$ISSUE_MARKER" '
    .[]
    | select(.pull_request | not)
    | select((.body // "") | contains($marker))
    | .number
  ' "$issues_response"
)

issue_payload="$tmp_dir/issue-payload.json"
jq -n \
  --arg title "$ISSUE_TITLE" \
  --arg body "$issue_body" \
  --arg label "$LABEL" \
  '{title: $title, body: $body, labels: [$label]}' > "$issue_payload"

if (( ${#matching_issue_numbers[@]} == 0 )); then
  issue_response="$tmp_dir/issue.json"
  issue_status="$(github_api POST "/repos/${GITHUB_REPOSITORY}/issues" "$issue_response" "$issue_payload")"
  [[ "$issue_status" =~ ^2[0-9][0-9]$ ]] || \
    fail "Could not open the terminal DLQ fallback recovery issue."
  printf '%s\n' "Opened terminal DLQ fallback recovery issue."
else
  # The marker lets us update only monitor-owned issues. If a human manually
  # created duplicates, update the oldest one rather than creating more.
  issue_number="$(printf '%s\n' "${matching_issue_numbers[@]}" | sort -n | sed -n '1p')"
  [[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || \
    fail "GitHub returned an invalid issue number."
  issue_response="$tmp_dir/issue.json"
  issue_status="$(github_api PATCH "/repos/${GITHUB_REPOSITORY}/issues/${issue_number}" "$issue_response" "$issue_payload")"
  [[ "$issue_status" =~ ^2[0-9][0-9]$ ]] || \
    fail "Could not update the terminal DLQ fallback recovery issue."
  if (( ${#matching_issue_numbers[@]} > 1 )); then
    printf '%s\n' "::warning title=Terminal DLQ fallback issue::Multiple monitor-owned issues exist; updated the oldest and did not create another."
  fi
  printf '%s\n' "Updated terminal DLQ fallback recovery issue #${issue_number}."
fi
