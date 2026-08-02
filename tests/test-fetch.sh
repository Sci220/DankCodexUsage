#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir "$TMPDIR_TEST/bin" "$TMPDIR_TEST/cache"
ln -s "$ROOT/tests/fake-codex.sh" "$TMPDIR_TEST/bin/codex"
REQUEST_LOG=$TMPDIR_TEST/requests.jsonl

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

CODEX_USAGE_CACHE_DIR=$TMPDIR_TEST/cache \
CODEX_USAGE_CODEX_BIN=/definitely/missing \
CODEX_USAGE_NOW=1785686700 \
sh "$ROOT/fetch-usage.sh" || fail "fresh cache did not no-op"
assert_jq '.captured_at == 1785686600'

printf 'FETCH TESTS PASSED\n'
