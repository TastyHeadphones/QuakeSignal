#!/usr/bin/env bash

# Offline contract test for the one-issue recovery writer. It proves a second
# alert updates the existing marker-owned issue instead of opening a duplicate.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
issue_script="$repo_root/.github/scripts/open-or-update-terminal-dlq-recovery-issue.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/quakesignal-terminal-dlq-issue-test.XXXXXX")"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

fail() {
  printf 'test failure: %s\n' "$1" >&2
  exit 1
}

node --input-type=module - <<'NODE' > "$tmp_dir/port" &
import http from "node:http";

const label = "quakesignal-terminal-dlq-fallback";
const marker = "<!-- quakesignal-terminal-dlq-fallback-monitor -->";
const state = { labelExists: false, issues: [], updates: 0 };

function reply(response, status, payload) {
  response.statusCode = status;
  response.setHeader("content-type", "application/json");
  response.end(JSON.stringify(payload));
}

function readJSON(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (error) {
        reject(error);
      }
    });
  });
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  if (request.method === "GET" && url.pathname === "/state") {
    reply(response, 200, state);
    return;
  }
  if (url.pathname === `/repos/owner/repo/labels/${label}` && request.method === "GET") {
    if (state.labelExists) {
      reply(response, 200, { name: label });
    } else {
      reply(response, 404, { message: "Not Found" });
    }
    return;
  }
  if (url.pathname === "/repos/owner/repo/labels" && request.method === "POST") {
    state.labelExists = true;
    reply(response, 201, { name: label });
    return;
  }
  if (url.pathname === "/repos/owner/repo/issues" && request.method === "GET") {
    reply(response, 200, state.issues);
    return;
  }
  if (url.pathname === "/repos/owner/repo/issues" && request.method === "POST") {
    const payload = await readJSON(request);
    if (!payload.body?.includes(marker)) {
      reply(response, 400, { message: "marker missing" });
      return;
    }
    const issue = { number: 7, title: payload.title, body: payload.body, labels: payload.labels };
    state.issues.push(issue);
    reply(response, 201, issue);
    return;
  }
  if (url.pathname === "/repos/owner/repo/issues/7" && request.method === "PATCH") {
    const payload = await readJSON(request);
    state.issues[0] = { ...state.issues[0], title: payload.title, body: payload.body, labels: payload.labels };
    state.updates += 1;
    reply(response, 200, state.issues[0]);
    return;
  }
  reply(response, 404, { message: "Not Found" });
});

server.listen(0, "127.0.0.1", () => process.stdout.write(String(server.address().port)));
NODE
server_pid=$!

for _ in $(seq 1 50); do
  [[ -s "$tmp_dir/port" ]] && break
  sleep 0.05
done
[[ -s "$tmp_dir/port" ]] || fail "mock GitHub API did not start"
port="$(<"$tmp_dir/port")"
api_url="http://127.0.0.1:${port}"

run_writer() {
  local backlog_count="$1"
  GITHUB_API_URL="$api_url" \
    GITHUB_TOKEN="test-token" \
    GITHUB_REPOSITORY="owner/repo" \
    QUEUE_NAME="quakesignal-alert-delivery-dlq-fallback" \
    BACKLOG_COUNT="$backlog_count" \
    OLDEST_MESSAGE_TIMESTAMP_MS="1" \
    OLDEST_MESSAGE_AGE_SECONDS="2" \
    bash "$issue_script" > /dev/null
}

run_writer 2
run_writer 3

state="$(curl --silent --fail "$api_url/state")"
[[ "$(jq -r '.issues | length' <<< "$state")" == "1" ]] || fail "writer created more than one issue"
[[ "$(jq -r '.updates' <<< "$state")" == "1" ]] || fail "writer did not update the existing issue"
jq -e '.issues[0].body | contains("`3`")' <<< "$state" >/dev/null || \
  fail "writer did not refresh the aggregate metric"

printf 'terminal DLQ fallback recovery issue tests passed\n'
