#!/bin/sh
set -eu
[ "${1:-}" = "app-server" ] || exit 64
if [ "${FAKE_CODEX_MODE:-success}" = exit-before-read ]; then
  exit 0
fi
if [ -n "${FAKE_CODEX_INVOCATION_LOG:-}" ]; then
  printf '%s\n' "$$" >>"$FAKE_CODEX_INVOCATION_LOG"
fi
requests=$(mktemp)
trap 'rm -f "$requests"' EXIT HUP INT TERM
for request_number in 1 2 3 4; do
  IFS= read -r request || exit 66
  printf '%s\n' "$request" >>"$requests"
done
if [ -n "${FAKE_CODEX_REQUEST_LOG:-}" ]; then cp "$requests" "$FAKE_CODEX_REQUEST_LOG"; fi
case "${FAKE_CODEX_MODE:-success}" in
  hang)
    sleep 300 &
    child_pid=$!
    if [ -n "${FAKE_CODEX_PID_FILE:-}" ]; then
      printf '%s\n%s\n' "$$" "$child_pid" >"$FAKE_CODEX_PID_FILE"
    fi
    wait "$child_pid"
    ;;
  *)
    fixture="${FAKE_CODEX_FIXTURE_DIR:?}/${FAKE_CODEX_MODE:-success}.jsonl"
    [ -f "$fixture" ] || exit 65
    cat "$fixture"
    ;;
esac
