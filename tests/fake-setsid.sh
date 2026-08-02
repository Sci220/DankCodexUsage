#!/bin/sh
set -eu

if [ "${FAKE_SETSID_SKIP_WATCHDOG:-}" = 1 ] && [ "${1:-}" = sh ] && [ "${2:-}" = -c ]; then
  exit 0
fi
exec "${FAKE_SETSID_REAL_BIN:?}" "$@"
