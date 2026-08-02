#!/bin/sh
set -eu
[ "${1:-}" = "app-server" ] || exit 64
requests=$(mktemp)
trap 'rm -f "$requests"' EXIT HUP INT TERM
for request_number in 1 2 3 4; do
  IFS= read -r request || exit 66
  printf '%s\n' "$request" >>"$requests"
done
if [ -n "${FAKE_CODEX_REQUEST_LOG:-}" ]; then cp "$requests" "$FAKE_CODEX_REQUEST_LOG"; fi
case "${FAKE_CODEX_MODE:-success}" in
  hang) sleep 300 ;;
  *)
    fixture="${FAKE_CODEX_FIXTURE_DIR:?}/${FAKE_CODEX_MODE:-success}.jsonl"
    [ -f "$fixture" ] || exit 65
    cat "$fixture"
    ;;
esac
