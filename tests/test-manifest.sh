#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
M="$ROOT/plugin.json"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

jq -e . "$M" >/dev/null 2>&1 || fail "plugin.json is not valid JSON"
for key in id name description version author type capabilities component icon requires_dms requires permissions; do
  jq -e "has(\"$key\")" "$M" >/dev/null || fail "missing key: $key"
done
jq -e '.id == "codexUsage" and .type == "widget"' "$M" >/dev/null || fail "identity"
jq -e '.capabilities == ["dankbar-widget"]' "$M" >/dev/null || fail "capability"
jq -e '.component == "./CodexUsageWidget.qml" and (has("settings") | not)' "$M" >/dev/null || fail "surface"
jq -e '.version == "0.1.0" and .requires_dms == ">=0.1.0"' "$M" >/dev/null || fail "versions"
jq -e '(.permissions | index("process")) != null' "$M" >/dev/null || fail "process permission"
for dep in jq flock setsid codex; do
  jq -e --arg dep "$dep" '(.requires | index($dep)) != null' "$M" >/dev/null || fail "dependency: $dep"
done
[ -f "$ROOT/CodexUsageWidget.qml" ] || fail "missing widget"
[ -f "$ROOT/CodexUsageData.qml" ] || fail "missing data singleton"
[ -f "$ROOT/fetch-usage.sh" ] || fail "missing helper"
[ -f "$ROOT/README.md" ] || fail "missing README"
[ -f "$ROOT/LICENSE" ] || fail "missing license"
for text in \
  'Codex CLI 0.133.0' \
  'codex login' \
  'account/rateLimits/read' \
  '~/.config/DankMaterialShell/plugins/codexUsage' \
  'API-key sessions'; do
  grep -F "$text" "$ROOT/README.md" >/dev/null || fail "README mention: $text"
done
grep -E 'does not read[^`]*`?~/.codex/auth\.json`?' "$ROOT/README.md" >/dev/null \
  || fail "README must say the plugin does not read ~/.codex/auth.json"
grep -Fx 'singleton CodexUsageData 1.0 CodexUsageData.qml' "$ROOT/qmldir" >/dev/null || fail "singleton registration"
printf 'MANIFEST TESTS PASSED\n'
