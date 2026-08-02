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
grep -F '}, 35, 35000)' "$DATA" >/dev/null || fail "helper debounce and timeout"
grep -F 'const wallClock = Math.floor(Date.now() / 1000)' "$DATA" >/dev/null || fail "refresh wall clock"
grep -F 'capturedAt <= wallClock' "$DATA" >/dev/null || fail "future cache guard"
grep -F 'wallClock - capturedAt < refreshSeconds' "$DATA" >/dev/null || fail "cache age guard"

component_block=$(awk '/Component.onCompleted:/{inside=1} inside{print} inside && /^    }/{exit}' "$DATA")
printf '%s\n' "$component_block" | grep -F 'cacheFile.reload()' >/dev/null || fail "startup usage reload"
printf '%s\n' "$component_block" | grep -F 'errorFile.reload()' >/dev/null || fail "startup error reload"
if printf '%s\n' "$component_block" | grep -F 'refresh(false)' >/dev/null; then
  fail "startup refresh before cache load"
fi
cache_block=$(awk '/id: cacheFile/{inside=1} inside{print} inside && /^    }/{exit}' "$DATA")
printf '%s\n' "$cache_block" | grep -F 'root.finishInitialUsageLoad()' >/dev/null || fail "cache completion refresh gate"
error_block=$(awk '/id: errorFile/{inside=1} inside{print} inside && /^    }/{exit}' "$DATA")
printf '%s\n' "$error_block" | grep -F 'function(error)' >/dev/null || fail "error load failure handler"
printf '%s\n' "$error_block" | grep -F 'error === FileViewError.FileNotFound' >/dev/null || fail "error file-not-found clear"
if printf '%s\n' "$error_block" | grep -F 'root.errorCategory = ""' >/dev/null \
    && ! printf '%s\n' "$error_block" | grep -F 'if (error === FileViewError.FileNotFound)' >/dev/null; then
  fail "error state cleared for all load failures"
fi
if grep -F 'CodexUsageData {' "$WIDGET" >/dev/null; then
  fail "widget instantiates singleton"
fi

printf 'QML CONTRACT TESTS PASSED\n'
