#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir "$TMPDIR_TEST/bin" "$TMPDIR_TEST/cache"
ln -s "$ROOT/tests/fake-codex.sh" "$TMPDIR_TEST/bin/codex"
REQUEST_LOG=$TMPDIR_TEST/requests.jsonl
INVOCATION_LOG=$TMPDIR_TEST/invocations.log

run_mode() {
  mode=$1
  now=$2
  rm -f "$TMPDIR_TEST/cache/usage.json" "$REQUEST_LOG"
  FAKE_CODEX_MODE=$mode \
  FAKE_CODEX_FIXTURE_DIR=$ROOT/fixtures \
  FAKE_CODEX_REQUEST_LOG=$REQUEST_LOG \
  CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
  CODEX_USAGE_CODEX_BIN=$TMPDIR_TEST/bin/codex \
  CODEX_USAGE_NOW=$now \
  CODEX_USAGE_FORCE=1 \
  sh "$ROOT/fetch-usage.sh" || fail "fetch failed for $mode"
}

assert_jq() {
  jq -e "$1" "$TMPDIR_TEST/cache/usage.json" >/dev/null || fail "usage assertion: $1"
}

assert_error() {
  category=$1
  jq -e --arg category "$category" '
    .version == 1 and
    .category == $category and
    (.occurred_at | type == "number") and
    ((.detail? // "") | test("(sk-|token|secret)"; "i") | not)
  ' "$TMPDIR_TEST/cache/error.json" >/dev/null || fail "error assertion: $category"
}

seed_cache() {
  run_mode success 1785686400
  checksum=$(cksum "$TMPDIR_TEST/cache/usage.json" | awk '{print $1 ":" $2}')
}

assert_cache_preserved() {
  current_checksum=$(cksum "$TMPDIR_TEST/cache/usage.json" | awk '{print $1 ":" $2}')
  [ "$current_checksum" = "$checksum" ] || fail "failure replaced usage cache"
}

run_failure_mode() {
  failure_mode=$1
  category=$2
  seed_cache
  set +e
  FAKE_CODEX_MODE=$failure_mode \
  FAKE_CODEX_FIXTURE_DIR=$ROOT/fixtures \
  FAKE_CODEX_INVOCATION_LOG=$INVOCATION_LOG \
  CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
  CODEX_USAGE_CODEX_BIN=$TMPDIR_TEST/bin/codex \
  CODEX_USAGE_NOW=1785686800 \
  CODEX_USAGE_FORCE=1 \
  sh "$ROOT/fetch-usage.sh" >/dev/null 2>&1
  exit_status=$?
  set -e
  [ "$exit_status" -ne 0 ] || fail "$failure_mode unexpectedly succeeded"
  assert_cache_preserved
  assert_error "$category"
}

run_mode success 1785686400
assert_jq '.version == 1 and .captured_at == 1785686400'
assert_jq '.primary == {"used_percentage":25,"window_minutes":300,"resets_at":1785690000}'
assert_jq '.secondary == {"used_percentage":8,"window_minutes":10080,"resets_at":1786291200}'
jq -s -e '
  .[0].id == 1 and .[0].method == "initialize" and
  .[0].params.clientInfo.name == "DankCodexUsage" and
  .[0].params.clientInfo.version == "0.1.0" and
  .[1].method == "initialized" and
  .[2].id == 2 and .[2].method == "account/read" and
  .[3].id == 3 and .[3].method == "account/rateLimits/read"
' "$REQUEST_LOG" >/dev/null || fail "handshake"

run_mode multi-bucket 1785686500
assert_jq '.primary.used_percentage == 25'

run_mode no-secondary 1785686600
assert_jq '.secondary == null'

rm -f "$INVOCATION_LOG"
run_mode unknown-fields 1785686650
assert_jq '.captured_at == 1785686650 and .primary.used_percentage == 25'

run_failure_mode signed-out chatgpt_sign_in_required
run_failure_mode api-key api_key_unsupported
run_failure_mode non-codex-only rate_limits_unavailable
run_failure_mode method-not-found codex_version_unsupported
run_failure_mode malformed refresh_failed

run_mode no-secondary 1785686600

CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
CODEX_USAGE_CODEX_BIN=/definitely/missing \
CODEX_USAGE_NOW=1785686700 \
sh "$ROOT/fetch-usage.sh" || fail "fresh cache did not no-op"
assert_jq '.captured_at == 1785686600'

rm -f "$TMPDIR_TEST/cache/usage.json" "$REQUEST_LOG"
set +e
FAKE_CODEX_MODE=exit-before-read \
FAKE_CODEX_FIXTURE_DIR=$ROOT/fixtures \
CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
CODEX_USAGE_CODEX_BIN=$TMPDIR_TEST/bin/codex \
CODEX_USAGE_NOW=1785686800 \
CODEX_USAGE_FORCE=1 \
CODEX_USAGE_TIMEOUT_SECONDS=1 \
CODEX_USAGE_TEST_PRE_REQUEST_DELAY_SECONDS=1 \
timeout 4 sh "$ROOT/fetch-usage.sh" >/dev/null 2>&1
exit_status=$?
set -e
[ "$exit_status" -ne 124 ] || fail "early app-server exit stalled FIFO delivery"
[ "$exit_status" -ne 0 ] || fail "early app-server exit unexpectedly succeeded"

rm -f "$TMPDIR_TEST/cache/usage.json" "$REQUEST_LOG"
set +e
FAKE_CODEX_MODE=success \
FAKE_CODEX_FIXTURE_DIR=$ROOT/fixtures \
FAKE_CODEX_REQUEST_LOG=$REQUEST_LOG \
CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
CODEX_USAGE_CODEX_BIN=$TMPDIR_TEST/bin/codex \
CODEX_USAGE_NOW=1785686900 \
CODEX_USAGE_FORCE=1 \
CODEX_USAGE_TEST_MUTATE_CACHE=invalid-primary \
sh "$ROOT/fetch-usage.sh" >/dev/null 2>&1
exit_status=$?
set -e
[ "$exit_status" -ne 0 ] || fail "malformed nested cache window was accepted"
[ ! -e "$TMPDIR_TEST/cache/usage.json" ] || fail "malformed cache replaced usage file"

seed_cache
set +e
CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
CODEX_USAGE_CODEX_BIN=/definitely/missing \
CODEX_USAGE_NOW=1785686800 \
CODEX_USAGE_FORCE=1 \
sh "$ROOT/fetch-usage.sh" >/dev/null 2>&1
exit_status=$?
set -e
[ "$exit_status" -ne 0 ] || fail "missing Codex executable unexpectedly succeeded"
assert_cache_preserved
assert_error codex_missing

make_path_without() {
  missing=$1
  path_dir=$TMPDIR_TEST/path-without-$missing
  rm -rf "$path_dir"
  mkdir "$path_dir"
  for command_name in awk cat chmod cksum date dirname flock jq kill mkdir mkfifo mktemp mv printf rm setsid sh sleep; do
    [ "$command_name" = "$missing" ] && continue
    command_path=$(command -v "$command_name" || true)
    [ -n "$command_path" ] && ln -s "$command_path" "$path_dir/$command_name"
  done
  printf '%s\n' "$path_dir"
}

for missing_dependency in flock setsid jq; do
  seed_cache
  path_without=$(make_path_without "$missing_dependency")
  set +e
  PATH=$path_without \
  CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
  CODEX_USAGE_CODEX_BIN=$TMPDIR_TEST/bin/codex \
  CODEX_USAGE_NOW=1785686800 \
  CODEX_USAGE_FORCE=1 \
  sh "$ROOT/fetch-usage.sh" >/dev/null 2>&1
  exit_status=$?
  set -e
  [ "$exit_status" -ne 0 ] || fail "missing $missing_dependency unexpectedly succeeded"
  assert_cache_preserved
  assert_error dependency_missing
done

seed_cache
path_with_broken_flock=$(make_path_without flock)
ln -s "$(command -v false)" "$path_with_broken_flock/flock"
rm -f "$INVOCATION_LOG"
set +e
PATH=$path_with_broken_flock \
FAKE_CODEX_MODE=success \
FAKE_CODEX_FIXTURE_DIR=$ROOT/fixtures \
FAKE_CODEX_INVOCATION_LOG=$INVOCATION_LOG \
CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
CODEX_USAGE_CODEX_BIN=$TMPDIR_TEST/bin/codex \
CODEX_USAGE_NOW=1785686800 \
CODEX_USAGE_FORCE=1 \
sh "$ROOT/fetch-usage.sh" >/dev/null 2>&1
exit_status=$?
set -e
[ "$exit_status" -ne 0 ] || fail "broken flock unexpectedly succeeded"
[ ! -e "$INVOCATION_LOG" ] || fail "broken flock proceeded to Codex"
assert_cache_preserved
assert_error dependency_missing

seed_cache
PID_FILE=$TMPDIR_TEST/pids
start_time=$(date +%s)
set +e
FAKE_CODEX_MODE=hang \
FAKE_CODEX_FIXTURE_DIR=$ROOT/fixtures \
FAKE_CODEX_PID_FILE=$PID_FILE \
CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
CODEX_USAGE_CODEX_BIN=$TMPDIR_TEST/bin/codex \
CODEX_USAGE_NOW=1785686800 \
CODEX_USAGE_FORCE=1 \
CODEX_USAGE_TIMEOUT_SECONDS=1 \
sh "$ROOT/fetch-usage.sh" >/dev/null 2>&1
exit_status=$?
set -e
elapsed=$(( $(date +%s) - start_time ))
[ "$exit_status" -ne 0 ] || fail "hang unexpectedly succeeded"
[ "$elapsed" -lt 5 ] || fail "timeout took too long"
assert_cache_preserved
assert_error timeout
for process_id in $(cat "$PID_FILE"); do
  if kill -0 "$process_id" 2>/dev/null; then
    fail "timeout left process $process_id running"
  fi
done

rm -f "$INVOCATION_LOG"
run_mode success 1785686501
FAKE_CODEX_MODE=success \
FAKE_CODEX_FIXTURE_DIR=$ROOT/fixtures \
FAKE_CODEX_INVOCATION_LOG=$INVOCATION_LOG \
CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
CODEX_USAGE_CODEX_BIN=$TMPDIR_TEST/bin/codex \
CODEX_USAGE_NOW=1785686800 \
sh "$ROOT/fetch-usage.sh" || fail "299-second cache unexpectedly refreshed"
[ ! -e "$INVOCATION_LOG" ] || fail "299-second cache invoked Codex"
FAKE_CODEX_MODE=success \
FAKE_CODEX_FIXTURE_DIR=$ROOT/fixtures \
FAKE_CODEX_INVOCATION_LOG=$INVOCATION_LOG \
CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
CODEX_USAGE_CODEX_BIN=$TMPDIR_TEST/bin/codex \
CODEX_USAGE_NOW=1785686801 \
sh "$ROOT/fetch-usage.sh" || fail "300-second cache did not refresh"
[ "$(wc -l < "$INVOCATION_LOG")" -eq 1 ] || fail "300-second cache did not invoke Codex once"
rm -f "$INVOCATION_LOG"
FAKE_CODEX_MODE=success \
FAKE_CODEX_FIXTURE_DIR=$ROOT/fixtures \
FAKE_CODEX_INVOCATION_LOG=$INVOCATION_LOG \
CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
CODEX_USAGE_CODEX_BIN=$TMPDIR_TEST/bin/codex \
CODEX_USAGE_NOW=1785686801 \
CODEX_USAGE_FORCE=1 \
sh "$ROOT/fetch-usage.sh" || fail "forced refresh failed"
[ "$(wc -l < "$INVOCATION_LOG")" -eq 1 ] || fail "forced refresh did not invoke Codex"

rm -f "$TMPDIR_TEST/cache/usage.json" "$INVOCATION_LOG"
for worker in 1 2; do
  FAKE_CODEX_MODE=success \
  FAKE_CODEX_FIXTURE_DIR=$ROOT/fixtures \
  FAKE_CODEX_INVOCATION_LOG=$INVOCATION_LOG \
  CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
  CODEX_USAGE_CODEX_BIN=$TMPDIR_TEST/bin/codex \
  CODEX_USAGE_NOW=1785686900 \
  sh "$ROOT/fetch-usage.sh" >"$TMPDIR_TEST/worker-$worker.out" 2>&1 &
  worker_pid=$!
  if [ "$worker" = 1 ]; then first_worker_pid=$worker_pid; else second_worker_pid=$worker_pid; fi
done
wait "$first_worker_pid" || fail "first concurrent refresh failed"
wait "$second_worker_pid" || fail "second concurrent refresh failed"
[ "$(wc -l < "$INVOCATION_LOG")" -eq 1 ] || fail "concurrent refresh exchanged more than once"

rm -f "$TMPDIR_TEST/cache/usage.json" "$INVOCATION_LOG"
sh -c '
  exec 9>"$1"
  flock 9
  exec sleep 30
' sh "$TMPDIR_TEST/cache/lock" &
holder_pid=$!
while flock -n "$TMPDIR_TEST/cache/lock" true 2>/dev/null; do sleep 1; done
kill -TERM "$holder_pid"
wait "$holder_pid" 2>/dev/null || true
FAKE_CODEX_MODE=success \
FAKE_CODEX_FIXTURE_DIR=$ROOT/fixtures \
FAKE_CODEX_INVOCATION_LOG=$INVOCATION_LOG \
CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
CODEX_USAGE_CODEX_BIN=$TMPDIR_TEST/bin/codex \
CODEX_USAGE_NOW=1785686900 \
sh "$ROOT/fetch-usage.sh" || fail "refresh could not recover from dead lock holder"
[ "$(wc -l < "$INVOCATION_LOG")" -eq 1 ] || fail "dead-holder recovery did not refresh"

printf 'FETCH TESTS PASSED\n'
