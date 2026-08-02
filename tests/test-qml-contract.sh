#!/bin/sh
set -eu

ROOT=${DANK_CODEX_USAGE_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
DATA="$ROOT/CodexUsageData.qml"
WIDGET="$ROOT/CodexUsageWidget.qml"
RING="$ROOT/UsageRing.qml"
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
grep -F 'if (value.primary === null && value.secondary === null)' "$DATA" >/dev/null || fail "all-null usage rejection"

# FileView must keep the default preload: with preload disabled, quickshell
# 0.3.0 never pushes `path` to the backend until text()/data() is called, so
# reload() is a silent no-op and loaded/loadFailed never fire.
grep -E 'preload[[:space:]]*:' "$DATA" >/dev/null && fail "FileView must not disable preload"
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

[ -f "$RING" ] || fail "missing usage ring"
for symbol in \
  'property int percentage' \
  'property color ringColor' \
  'property int diameter' \
  'property real thickness' \
  'property bool available' \
  'property string accessibleName'; do
  grep -F "$symbol" "$RING" >/dev/null || fail "ring $symbol"
done
grep -F 'readonly property real fraction: available ? Math.max(0, Math.min(1, percentage / 100)) : 0' "$RING" >/dev/null || fail "ring fraction clamp"
grep -F 'function onPercentageChanged() { canvas.requestPaint() }' "$RING" >/dev/null || fail "ring percentage repaint"
grep -F 'function onRingColorChanged() { canvas.requestPaint() }' "$RING" >/dev/null || fail "ring color repaint"
grep -F 'function onAvailableChanged() { canvas.requestPaint() }' "$RING" >/dev/null || fail "ring availability repaint"
grep -F 'Accessible.name: accessibleName' "$RING" >/dev/null || fail "ring accessibility name"
grep -F 'Accessible.role: Accessible.Indicator' "$RING" >/dev/null || fail "ring accessibility role"

grep -F 'PluginComponent {' "$WIDGET" >/dev/null || fail "widget component"
grep -F 'pluginId: "codexUsage"' "$WIDGET" >/dev/null || fail "widget plugin id"
# DMS loads plugin components by file URL, so the plugin directory is never on
# the QML import path; the singleton resolves through the implicit directory
# import and its qmldir declaration. A module import would fail to load.
grep -F 'import DankCodexUsage' "$WIDGET" >/dev/null && fail "widget must not use module import"
grep -Fx 'singleton CodexUsageData 1.0 CodexUsageData.qml' "$ROOT/qmldir" >/dev/null || fail "qmldir singleton declaration"
grep -F 'module ' "$ROOT/qmldir" >/dev/null && fail "qmldir must not declare a module"
grep -F 'horizontalBarPill: Component {' "$WIDGET" >/dev/null || fail "horizontal pill"
grep -F 'verticalBarPill: Component {' "$WIDGET" >/dev/null || fail "vertical pill"
grep -F 'readonly property int warnPct: 70' "$WIDGET" >/dev/null || fail "warning threshold"
grep -F 'readonly property int critPct: 90' "$WIDGET" >/dev/null || fail "critical threshold"
refresh_action=$(awk '/headerActions: Component \{/{inside=1} inside{print} inside && /^                }$/{exit}' "$WIDGET")
printf '%s\n' "$refresh_action" | grep -F 'DankActionButton {' >/dev/null || fail "manual refresh action"
printf '%s\n' "$refresh_action" | grep -F 'enabled: !CodexUsageData.refreshing' >/dev/null || fail "manual refresh disabled while busy"
printf '%s\n' "$refresh_action" | grep -F 'opacity: enabled ? 1.0 : 0.5' >/dev/null || fail "manual refresh busy affordance"
printf '%s\n' "$refresh_action" | grep -F 'Accessible.name: "Refresh Codex usage"' >/dev/null || fail "manual refresh accessible name"
printf '%s\n' "$refresh_action" | grep -F 'tooltipText: "Refresh Codex usage"' >/dev/null || fail "manual refresh tooltip"
if printf '%s\n' "$refresh_action" | grep -F 'Theme.cornerRadiusSmall' >/dev/null; then
  fail "manual refresh tooltip uses nonexistent Theme.cornerRadiusSmall"
fi
printf '%s\n' "$refresh_action" | grep -Fx '                    onClicked: CodexUsageData.refresh(true)' >/dev/null || fail "manual refresh handler"
grep -F 'id: refreshStatus' "$WIDGET" >/dev/null || fail "refresh status footer"
grep -F 'visible: CodexUsageData.refreshing' "$WIDGET" >/dev/null || fail "refresh status visibility"
grep -F 'text: root.hasData ? "Refreshing…" : "Loading…"' "$WIDGET" >/dev/null || fail "loading and refreshing status copy"
grep -F 'PopoutComponent {' "$WIDGET" >/dev/null || fail "popout"
# Pills must stay bare rows/columns sized by the bar-aware helpers so the
# widget matches the dimensions of built-in and reference bar widgets; the
# DankBar draws the pill capsule itself.
grep -F 'StyledRect' "$WIDGET" >/dev/null && fail "pills must not draw their own background"
diameter_count=$(grep -F 'diameter: root.iconSize' "$WIDGET" | wc -l | tr -d ' ')
[ "$diameter_count" -eq 2 ] || fail "pill ring diameters use bar-aware iconSize"
bartext_count=$(grep -F 'Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)' "$WIDGET" | wc -l | tr -d ' ')
[ "$bartext_count" -eq 4 ] || fail "pill text uses bar-aware barTextSize"
grep -F 'return limit.value === null' "$WIDGET" >/dev/null || fail "unavailable accessible branch"
grep -F 'root.label(limit) + ", usage unavailable"' "$WIDGET" >/dev/null || fail "unavailable accessible copy"
accessible_count=$(grep -F 'accessibleName: root.accessibleLimitName(modelData)' "$WIDGET" | wc -l | tr -d ' ')
[ "$accessible_count" -eq 3 ] || fail "ring accessibility uses unavailable copy"
if grep -E 'displayStyle|displayMode|pluginData|settings' "$WIDGET" >/dev/null; then
  fail "widget exposes settings or display mode"
fi

printf 'QML CONTRACT TESTS PASSED\n'
