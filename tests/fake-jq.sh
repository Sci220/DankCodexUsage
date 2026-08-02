#!/bin/sh
set -u

"${FAKE_JQ_REAL_BIN:?}" "$@"
status=$?
if [ "$status" -ne 0 ] && [ -n "${FAKE_JQ_SIGNAL_FILE:-}" ] && [ ! -e "$FAKE_JQ_SIGNAL_FILE" ]; then
  : >"$FAKE_JQ_SIGNAL_FILE"
  sleep "${FAKE_JQ_POST_SIGNAL_DELAY_SECONDS:-1}"
fi
exit "$status"
