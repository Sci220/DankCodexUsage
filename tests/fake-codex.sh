#!/bin/sh
set -eu
[ "${1:-}" = "app-server" ] || exit 64
requests=$(mktemp)
trap 'rm -f "$requests"' EXIT HUP INT TERM
cat >"$requests" & reader=$!
case "${FAKE_CODEX_MODE:-success}" in
  hang) wait "$reader"; sleep 300 ;;
  *)
    fixture="${FAKE_CODEX_FIXTURE_DIR:?}/${FAKE_CODEX_MODE:-success}.jsonl"
    [ -f "$fixture" ] || exit 65
    cat "$fixture"
    ;;
esac
wait "$reader" || true
if [ -n "${FAKE_CODEX_REQUEST_LOG:-}" ]; then cp "$requests" "$FAKE_CODEX_REQUEST_LOG"; fi
