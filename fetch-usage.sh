#!/bin/sh
set -u

PLUGIN_VERSION=0.1.0
SCHEMA_VERSION=1
REFRESH_SECONDS=300
TIMEOUT_SECONDS=${CODEX_USAGE_TIMEOUT_SECONDS:-30}
ERROR_DETAIL_MAX=120
CACHE_DIR=${CODEX_USAGE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/DankCodexUsage}
CACHE_FILE=$CACHE_DIR/usage.json
ERROR_FILE=$CACHE_DIR/error.json
LOCK_FILE=$CACHE_DIR/lock
CODEX_BIN=${CODEX_USAGE_CODEX_BIN:-codex}
NOW=${CODEX_USAGE_NOW:-$(date +%s)}

WORK_DIR=
APP_PID=
READER_PID=
WATCHDOG_PID=
CACHE_TEMP=

cleanup() {
  trap - EXIT HUP INT TERM
  if [ -n "${WATCHDOG_PID:-}" ]; then
    kill -TERM "-$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
  fi
  if [ -n "${APP_PID:-}" ]; then
    kill -TERM "-$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  [ -n "${READER_PID:-}" ] && wait "$READER_PID" 2>/dev/null || true
  [ -n "${CACHE_TEMP:-}" ] && rm -f "$CACHE_TEMP"
  [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR"
}

trap cleanup EXIT HUP INT TERM

write_error() {
  category=$1
  detail=$2
  detail=$(printf '%.*s' "$ERROR_DETAIL_MAX" "$detail")
  error_temp=$(mktemp "$CACHE_DIR/error.json.XXXXXX" 2>/dev/null || printf '%s/error.json.tmp.%s' "$CACHE_DIR" "$$") || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg category "$category" --argjson occurred_at "$NOW" --arg detail "$detail" \
      '{version: 1, category: $category, occurred_at: $occurred_at, detail: $detail}' >"$error_temp" || return 1
  else
    printf '{"version":1,"category":"dependency_missing","occurred_at":%s,"detail":"required helper dependency is unavailable"}\n' "$NOW" >"$error_temp" || return 1
  fi
  chmod 600 "$error_temp" || return 1
  mv "$error_temp" "$ERROR_FILE" || return 1
}

fail() {
  category=$1
  detail=$2
  write_error "$category" "$detail" || true
  printf '%s\n' "$detail" >&2
  exit 1
}

mkdir -p "$CACHE_DIR" || { printf '%s\n' "cannot create cache directory" >&2; exit 1; }
chmod 700 "$CACHE_DIR" || { printf '%s\n' "cannot secure cache directory" >&2; exit 1; }

case $NOW in
  ''|*[!0-9]*) fail refresh_failed 'invalid current time' ;;
esac

for dependency in jq flock; do
  command -v "$dependency" >/dev/null 2>&1 || fail dependency_missing 'required helper dependency is unavailable'
done

exec 9>"$LOCK_FILE" || fail dependency_missing 'cannot acquire helper lock'
flock 9 || fail dependency_missing 'cannot acquire helper lock'

if [ "${CODEX_USAGE_FORCE:-}" != 1 ] && [ -f "$CACHE_FILE" ]; then
  captured_at=$(jq -r '.captured_at // empty' "$CACHE_FILE" 2>/dev/null || true)
  case $captured_at in
    ''|*[!0-9]*) ;;
    *)
      age=$((NOW - captured_at))
      [ "$age" -lt "$REFRESH_SECONDS" ] && exit 0
      ;;
  esac
fi

for dependency in setsid mktemp; do
  command -v "$dependency" >/dev/null 2>&1 || fail dependency_missing 'required helper dependency is unavailable'
done
command -v "$CODEX_BIN" >/dev/null 2>&1 || fail codex_missing 'Codex executable is unavailable'

WORK_DIR=$(mktemp -d) || fail refresh_failed 'cannot create refresh workspace'
INPUT_FIFO=$WORK_DIR/input
OUTPUT_FIFO=$WORK_DIR/output
RESPONSES=$WORK_DIR/responses.jsonl
BUCKET=$WORK_DIR/bucket.json
TIMEOUT_MARKER=$WORK_DIR/timed-out
READER_DONE=$WORK_DIR/reader-done
mkfifo "$INPUT_FIFO" "$OUTPUT_FIFO" || fail refresh_failed 'cannot create app-server pipes'

# Keep a read/write endpoint open long enough for the server to attach to stdin.
exec 7<>"$INPUT_FIFO"
(cat "$OUTPUT_FIFO" >"$RESPONSES"; : >"$READER_DONE") &
READER_PID=$!
setsid "$CODEX_BIN" app-server <&7 >"$OUTPUT_FIFO" &
APP_PID=$!

setsid sh -c 'sleep "$1"; : > "$2"; kill -TERM "-$3" 2>/dev/null || true' sh \
  "$TIMEOUT_SECONDS" "$TIMEOUT_MARKER" "$APP_PID" &
WATCHDOG_PID=$!

if [ -n "${CODEX_USAGE_TEST_PRE_REQUEST_DELAY_SECONDS:-}" ]; then
  sleep "$CODEX_USAGE_TEST_PRE_REQUEST_DELAY_SECONDS"
fi
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"DankCodexUsage","version":"0.1.0"}}}' \
  '{"jsonrpc":"2.0","method":"initialized","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"account/read","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"account/rateLimits/read","params":{}}' >&7 || fail refresh_failed 'cannot write app-server request'
exec 7>&-

responses_complete() {
  jq -s -e '
    ([.[] | select(.id == 1 or .id == 2 or .id == 3) | .id] | unique | length == 3)
  ' "$RESPONSES" >/dev/null 2>&1
}

elapsed=0
while ! responses_complete; do
  [ -f "$TIMEOUT_MARKER" ] && fail timeout 'Codex refresh timed out'
  if [ -f "$READER_DONE" ]; then
    responses_complete && break
    fail refresh_failed 'Codex app-server ended before a complete response'
  fi
  [ "$elapsed" -ge "$TIMEOUT_SECONDS" ] && fail timeout 'Codex refresh timed out'
  sleep 1
  elapsed=$((elapsed + 1))
done

kill -TERM "-$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
WATCHDOG_PID=

rpc_status=$(jq -s -r '
  def response($id): map(select(.id == $id)) | last;
  [response(1), response(2), response(3)] as $responses |
  if any($responses[]; (type != "object") or ((.result? == null) and (.error? == null))) then "failed"
  elif any($responses[]; .error? != null) then
    if any($responses[]; .error? != null and
      (.error.code == -32601 or ((.error.message? // "") | test("method not found"; "i"))))
    then "unsupported" else "failed" end
  else "ok" end
' "$RESPONSES") || fail refresh_failed 'invalid initialize response'
case $rpc_status in
  ok) ;;
  unsupported) fail codex_version_unsupported 'installed Codex does not support usage refresh' ;;
  *) fail refresh_failed 'Codex RPC request failed' ;;
esac

auth_mode=$(jq -s -r '
  def response($id): map(select(.id == $id)) | last;
  response(2).result.account.type // empty
' "$RESPONSES") || fail refresh_failed 'invalid account response'
case $auth_mode in
  chatgpt) ;;
  apiKey|api_key|api-key|apikey|api) fail api_key_unsupported 'API-key authentication does not provide usage limits' ;;
  *) fail chatgpt_sign_in_required 'sign in to ChatGPT in Codex' ;;
esac

jq -s -e '
  def response($id): map(select(.id == $id)) | last;
  def main_bucket:
    if .rateLimits.limitId == "codex" then .rateLimits
    elif (.rateLimitsByLimitId.codex? != null) then .rateLimitsByLimitId.codex
    else null end;
  response(3).result | main_bucket
' "$RESPONSES" >"$BUCKET" || fail rate_limits_unavailable 'Codex has no usage limits for this account'

CACHE_TEMP=$(mktemp "$CACHE_DIR/usage.json.XXXXXX") || fail refresh_failed 'cannot create cache file'
jq -e --argjson now "$NOW" '
  def valid_window:
    type == "object" and
    (.usedPercent | type == "number" and . >= 0 and . <= 100) and
    (.windowDurationMins | type == "number" and . > 0) and
    (.resetsAt | type == "number" and . > 0);
  def norm:
    if . == null then null
    elif valid_window then {
      used_percentage: (.usedPercent | floor),
      window_minutes: (.windowDurationMins | floor),
      resets_at: (.resetsAt | floor)
    }
    else error("invalid rate-limit window") end;
  {
    version: 1,
    captured_at: $now,
    primary: (.primary | norm),
    secondary: (.secondary | norm)
  }
  | select(.primary != null or .secondary != null)
' "$BUCKET" >"$CACHE_TEMP" || fail refresh_failed 'Codex returned invalid usage limits'
if [ "${CODEX_USAGE_TEST_MUTATE_CACHE:-}" = invalid-primary ]; then
  jq '.primary.used_percentage = "invalid"' "$CACHE_TEMP" >"$CACHE_TEMP.mutated" || \
    fail refresh_failed 'cannot validate generated cache'
  mv "$CACHE_TEMP.mutated" "$CACHE_TEMP" || fail refresh_failed 'cannot validate generated cache'
fi
chmod 600 "$CACHE_TEMP" || fail refresh_failed 'cannot secure cache file'
jq -e '
  def valid_window:
    type == "object" and
    (.used_percentage | type == "number" and . >= 0 and . <= 100 and floor == .) and
    (.window_minutes | type == "number" and . > 0 and floor == .) and
    (.resets_at | type == "number" and . > 0 and floor == .);
  def valid_or_null: . == null or valid_window;
  type == "object" and
  .version == 1 and
  (.captured_at | type == "number" and . >= 0 and floor == .) and
  (.primary | valid_or_null) and
  (.secondary | valid_or_null) and
  (.primary != null or .secondary != null)
' "$CACHE_TEMP" >/dev/null || fail refresh_failed 'generated cache failed validation'
mv "$CACHE_TEMP" "$CACHE_FILE" || fail refresh_failed 'cannot replace cache file'
CACHE_TEMP=
rm -f "$ERROR_FILE"
