#!/bin/sh
set -u

PLUGIN_VERSION=0.1.0
SCHEMA_VERSION=1
REFRESH_SECONDS=300
TIMEOUT_SECONDS=${CODEX_USAGE_TIMEOUT_SECONDS:-30}
CACHE_DIR=${CODEX_USAGE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/DankCodexUsage}
CACHE_FILE=$CACHE_DIR/usage.json
ERROR_FILE=$CACHE_DIR/error.json
LOCK_FILE=$CACHE_DIR/lock
CODEX_BIN=${CODEX_USAGE_CODEX_BIN:-codex}
NOW=${CODEX_USAGE_NOW:-$(date +%s)}

WORK_DIR=
SERVER_PID=
SERVER_PGID=
READER_PID=
WATCHDOG_PID=
CACHE_TEMP=

cleanup() {
  if [ -n "$WATCHDOG_PID" ]; then
    kill -TERM "-$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
  fi
  if [ -n "$SERVER_PGID" ]; then
    kill -TERM "-$SERVER_PGID" 2>/dev/null || true
  fi
  if [ -n "$SERVER_PID" ]; then
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  [ -n "$CACHE_TEMP" ] && rm -f "$CACHE_TEMP"
  if [ -n "$READER_PID" ]; then
    kill "$READER_PID" 2>/dev/null || true
    wait "$READER_PID" 2>/dev/null || true
  fi
  [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

for dependency in jq flock; do
  command -v "$dependency" >/dev/null 2>&1 || fail "missing dependency: $dependency"
done

case $NOW in
  ''|*[!0-9]*) fail 'CODEX_USAGE_NOW must be an epoch timestamp' ;;
esac

mkdir -p "$CACHE_DIR" || fail "cannot create cache directory: $CACHE_DIR"
chmod 700 "$CACHE_DIR" || fail "cannot secure cache directory: $CACHE_DIR"
exec 9>"$LOCK_FILE"
flock 9

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
  command -v "$dependency" >/dev/null 2>&1 || fail "missing dependency: $dependency"
done
command -v "$CODEX_BIN" >/dev/null 2>&1 || fail "missing Codex executable: $CODEX_BIN"

WORK_DIR=$(mktemp -d) || fail 'cannot create work directory'
trap cleanup EXIT HUP INT TERM
INPUT_FIFO=$WORK_DIR/input
OUTPUT_FIFO=$WORK_DIR/output
RESPONSES=$WORK_DIR/responses.jsonl
BUCKET=$WORK_DIR/bucket.json
mkfifo "$INPUT_FIFO" "$OUTPUT_FIFO" || fail 'cannot create app-server pipes'

# Keep a read/write endpoint open long enough for the server to attach to stdin.
exec 7<>"$INPUT_FIFO"
cat "$OUTPUT_FIFO" >"$RESPONSES" &
READER_PID=$!
setsid "$CODEX_BIN" app-server <&7 >"$OUTPUT_FIFO" &
SERVER_PID=$!
SERVER_PGID=$SERVER_PID
exec 7>&-

setsid sh -c 'sleep "$1"; kill -TERM "-$2" 2>/dev/null || true' sh \
  "$TIMEOUT_SECONDS" "$SERVER_PGID" &
WATCHDOG_PID=$!

exec 8>"$INPUT_FIFO"
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"DankCodexUsage","version":"0.1.0"}}}' \
  '{"jsonrpc":"2.0","method":"initialized","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"account/read","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"account/rateLimits/read","params":{}}' >&8
exec 8>&-

elapsed=0
while ! jq -s -e '
  ([.[] | select(.id == 1 or .id == 2 or .id == 3) | .id] | unique | length == 3)
' "$RESPONSES" >/dev/null 2>&1; do
  [ "$elapsed" -ge "$TIMEOUT_SECONDS" ] && fail 'timed out waiting for Codex app-server'
  sleep 1
  elapsed=$((elapsed + 1))
done

kill -TERM "-$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
WATCHDOG_PID=

auth_mode=$(jq -s -r '
  def response($id): map(select(.id == $id)) | last;
  response(2).result.account.type // empty
' "$RESPONSES")
[ -n "$auth_mode" ] || fail 'Codex account response has no auth mode'

jq -s -e '
  def response($id): map(select(.id == $id)) | last;
  def main_bucket:
    if .rateLimits.limitId == "codex" then .rateLimits
    elif (.rateLimitsByLimitId.codex? != null) then .rateLimitsByLimitId.codex
    else null end;
  response(3).result | main_bucket
' "$RESPONSES" >"$BUCKET" || fail 'Codex response has no codex rate-limit bucket'

CACHE_TEMP=$(mktemp "$CACHE_DIR/usage.json.XXXXXX") || fail 'cannot create cache file'
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
' "$BUCKET" >"$CACHE_TEMP" || fail 'Codex response has no valid rate-limit window'
chmod 600 "$CACHE_TEMP" || fail 'cannot secure cache file'
jq -e '
  .version == 1 and
  (.captured_at | type == "number") and
  (.primary == null or type == "object") and
  (.secondary == null or type == "object")
' "$CACHE_TEMP" >/dev/null || fail 'generated cache failed validation'
mv "$CACHE_TEMP" "$CACHE_FILE" || fail 'cannot replace cache file'
CACHE_TEMP=
rm -f "$ERROR_FILE"
