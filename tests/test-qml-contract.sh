#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DATA="$ROOT/CodexUsageData.qml"
WIDGET="$ROOT/CodexUsageWidget.qml"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -Fx 'pragma Singleton' "$DATA" >/dev/null || fail "singleton pragma"
for module in Quickshell Quickshell.Io qs.Common; do
  grep -F "import $module" "$DATA" >/dev/null || fail "import: $module"
done
for symbol in \
  'property var primary' \
  'property var secondary' \
  'property int capturedAt' \
  'property string errorCategory' \
  'property string errorDetail' \
  'property bool refreshing' \
  'property bool hasData' \
  'property int now' \
  'function refresh(force)' \
  'function countdown(resetEpoch)' \
  'function windowLabel(minutes)' \
  'function minutesOld()'; do
  grep -F "$symbol" "$DATA" >/dev/null || fail "$symbol"
done

grep -F 'readonly property int refreshSeconds: 300' "$DATA" >/dev/null || fail "refresh interval"
grep -F 'interval: 60000' "$DATA" >/dev/null || fail "display tick"
grep -F 'id: cacheFile' "$DATA" >/dev/null || fail "usage cache watcher"
grep -F 'id: errorFile' "$DATA" >/dev/null || fail "error cache watcher"
grep -F 'watchChanges: true' "$DATA" >/dev/null || fail "file watching"
if grep -F 'CodexUsageData {' "$WIDGET" >/dev/null; then
  fail "widget instantiates singleton"
fi

printf 'QML CONTRACT TESTS PASSED\n'
