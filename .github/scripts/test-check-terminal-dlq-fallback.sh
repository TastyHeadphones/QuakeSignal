#!/usr/bin/env bash

# Lightweight offline contract tests for the production Queue-metrics probe.
# The mock returns only aggregate metrics; no Queue message API is exposed.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
monitor_script="$repo_root/.github/scripts/check-terminal-dlq-fallback.sh"

fail() {
  printf 'test failure: %s\n' "$1" >&2
  exit 1
}

run_case() {
  local scenario="$1"
  local expected_status="$2"
  local expected_alert="${3:-}"
  local tmp_dir
  local server_pid
  local server_log
  local port
  local status

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/quakesignal-terminal-dlq-test.XXXXXX")"
  server_log="$tmp_dir/server.log"
  PORT_FILE="$tmp_dir/port" SCENARIO="$scenario" node --input-type=module - <<'NODE' > /dev/null 2> "$server_log" &
import http from "node:http";
import { writeFileSync } from "node:fs";

const queueId = "0123456789abcdef0123456789abcdef";
const scenario = process.env.SCENARIO;
const portFile = process.env.PORT_FILE;
if (!portFile) throw new Error("PORT_FILE is required");
const queues = (() => {
  if (scenario === "missing") return [];
  if (scenario === "duplicate") {
    return [
      { queue_name: "quakesignal-alert-delivery-dlq-fallback", queue_id: queueId },
      { queue_name: "quakesignal-alert-delivery-dlq-fallback", queue_id: "abcdef0123456789abcdef0123456789" },
    ];
  }
  return [{ queue_name: "quakesignal-alert-delivery-dlq-fallback", queue_id: queueId }];
})();

const metrics = scenario === "backlog"
  ? { backlog_count: 2, oldest_message_timestamp_ms: 1 }
  : { backlog_count: 0, oldest_message_timestamp_ms: 0 };

const server = http.createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  response.setHeader("content-type", "application/json");
  if (url.pathname.endsWith("/queues")) {
    response.end(JSON.stringify({ success: true, result: queues, result_info: { total_pages: 1 } }));
    return;
  }
  if (url.pathname.endsWith(`/queues/${queueId}/metrics`)) {
    response.end(JSON.stringify({ success: true, result: metrics }));
    return;
  }
  response.statusCode = 404;
  response.end(JSON.stringify({ success: false }));
});

server.listen(0, "127.0.0.1", () => {
  writeFileSync(portFile, String(server.address().port));
});
NODE
  server_pid=$!

  for ((attempt = 0; attempt < 100; attempt += 1)); do
    if [[ -s "$tmp_dir/port" ]]; then
      break
    fi
    sleep 0.05
  done
  [[ -s "$tmp_dir/port" ]] || {
    [[ -s "$server_log" ]] && cat "$server_log" >&2
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    rm -rf "$tmp_dir"
    fail "mock API did not start"
  }
  port="$(<"$tmp_dir/port")"
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || {
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    rm -rf "$tmp_dir"
    fail "mock API returned an invalid port"
  }

  set +e
  GITHUB_OUTPUT="$tmp_dir/output" \
    CLOUDFLARE_API_BASE="http://127.0.0.1:${port}/client/v4" \
    CLOUDFLARE_MONITOR_API_TOKEN="test-token" \
    CLOUDFLARE_ACCOUNT_ID="0123456789abcdef0123456789abcdef" \
    bash "$monitor_script" > "$tmp_dir/stdout" 2> "$tmp_dir/stderr"
  status=$?
  set -e

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true

  if [[ "$expected_status" == "success" ]]; then
    [[ "$status" == 0 ]] || {
      cat "$tmp_dir/stderr" >&2
      rm -rf "$tmp_dir"
      fail "${scenario} unexpectedly failed"
    }
    grep -Fx "alert=${expected_alert}" "$tmp_dir/output" >/dev/null || {
      rm -rf "$tmp_dir"
      fail "${scenario} returned the wrong alert state"
    }
  else
    [[ "$status" != 0 ]] || {
      rm -rf "$tmp_dir"
      fail "${scenario} unexpectedly succeeded"
    }
  fi

  rm -rf "$tmp_dir"
}

run_case healthy success false
run_case backlog success true
run_case missing failure
run_case duplicate failure

printf 'terminal DLQ fallback monitor tests passed\n'
