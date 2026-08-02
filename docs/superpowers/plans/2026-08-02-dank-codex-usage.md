# DankCodexUsage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a zero-configuration DankMaterialShell widget that shows the primary and secondary ChatGPT Codex usage windows through the documented local Codex app-server protocol.

**Architecture:** A POSIX shell helper owns the JSONL app-server exchange, validation, locking, timeout, and atomic cache/error files. A plugin-local Quickshell singleton watches those files and schedules refreshes, while a separate widget and reusable ring component render DMS-native bar pills and a read-only popout.

**Tech Stack:** POSIX shell, `jq`, `flock`, `setsid`, OpenAI Codex CLI app-server JSONL, Qt 6 QML, Quickshell/DankMaterialShell plugin APIs, shell fixture tests.

## Global Constraints

- Minimum supported Codex CLI: `0.133.0`.
- Minimum DMS plugin API: `>=0.1.0`.
- Refresh interval: 300 seconds.
- Hard app-server timeout: 30 seconds.
- State directory: `${XDG_CACHE_HOME:-$HOME/.cache}/DankCodexUsage/`.
- Cache schema version: `1`.
- The helper must never read `~/.codex/auth.json`, print raw app-server responses, or mutate account state.
- Only the main `codex` bucket is valid; never guess from another `rateLimitsByLimitId` entry.
- A failed refresh must leave `usage.json` byte-for-byte unchanged.
- The DMS bar ships rings-only in version 1; there is no settings component.

## File Structure

- `plugin.json`: DMS widget manifest, dependency and permission declaration.
- `qmldir`: registers `CodexUsageData` as a plugin-local singleton.
- `fetch-usage.sh`: app-server client, response normalization, lock, timeout, and atomic state writes.
- `CodexUsageData.qml`: shared cache/error model, refresh scheduling, countdown formatting, and expired-window refresh.
- `UsageRing.qml`: presentation-only circular progress gauge.
- `CodexUsageWidget.qml`: DMS horizontal/vertical pills and popout.
- `fixtures/*.jsonl`: deterministic fake app-server response streams.
- `tests/fake-codex.sh`: protocol-aware Codex substitute driven by a fixture mode.
- `tests/test-fetch.sh`: helper contract, normalization, failure, concurrency, and cleanup tests.
- `tests/test-manifest.sh`: manifest, local module, and referenced-file checks.
- `tests/test-qml-contract.sh`: static QML boundary checks that do not require a running shell.
- `README.md`: installation, requirements, behavior, troubleshooting, and privacy documentation.
- `.gitignore`: excludes generated runtime/test artifacts.
- `LICENSE`: MIT license.

---

### Task 1: Establish the DMS plugin contract and fixture harness

**Files:**
- Create: `plugin.json`
- Create: `qmldir`
- Create: `.gitignore`
- Create: `fixtures/success.jsonl`
- Create: `fixtures/multi-bucket.jsonl`
- Create: `fixtures/no-secondary.jsonl`
- Create: `tests/fake-codex.sh`
- Create: `tests/test-manifest.sh`

**Interfaces:**
- Consumes: DMS manifest schema and Codex app-server request IDs `1` (`initialize`), `2` (`account/read`), and `3` (`account/rateLimits/read`).
- Produces: plugin ID `codexUsage`; widget component path `./CodexUsageWidget.qml`; executable fake Codex selected by `FAKE_CODEX_MODE`; singleton type `CodexUsageData 1.0`.

- [ ] **Step 1: Write the failing manifest test**

Create `tests/test-manifest.sh` with assertions for JSON validity, all required keys, exact ID/type/capability/component, semantic version `0.1.0`, process permission, dependencies `jq`, `flock`, `setsid`, and `codex`, no settings field, referenced files, and the singleton declaration:

```sh
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
grep -Fx 'singleton CodexUsageData 1.0 CodexUsageData.qml' "$ROOT/qmldir" >/dev/null || fail "singleton registration"
printf 'MANIFEST TESTS PASSED\n'
```

- [ ] **Step 2: Run the manifest test to verify it fails**

Run: `sh tests/test-manifest.sh`

Expected: `FAIL: plugin.json is not valid JSON` because the manifest does not exist.

- [ ] **Step 3: Add the minimal manifest and local module declaration**

Create `plugin.json`:

```json
{
  "id": "codexUsage",
  "name": "Codex Usage",
  "description": "OpenAI Codex primary and secondary subscription limits in the bar.",
  "version": "0.1.0",
  "author": "Eduards",
  "type": "widget",
  "capabilities": ["dankbar-widget"],
  "component": "./CodexUsageWidget.qml",
  "icon": "speed",
  "requires_dms": ">=0.1.0",
  "requires": ["codex", "jq", "flock", "setsid"],
  "permissions": ["process"]
}
```

Create `qmldir`:

```text
module DankCodexUsage
singleton CodexUsageData 1.0 CodexUsageData.qml
```

Create temporary skeletal QML/helper files only to satisfy reference checks; each must be syntactically valid and will be replaced test-first in later tasks:

```qml
// CodexUsageData.qml
pragma Singleton
import QtQuick
QtObject {}
```

```qml
// CodexUsageWidget.qml
import QtQuick
Item {}
```

```sh
#!/bin/sh
exit 1
```

Create `.gitignore`:

```gitignore
*.tmp
tests/.tmp/
```

- [ ] **Step 4: Add deterministic app-server fixtures and fake executable**

Each JSONL fixture contains the response messages the fake server emits. `success.jsonl` must contain ChatGPT auth and one `codex` bucket with primary `25/300/1785690000` and secondary `8/10080/1786291200`. `multi-bucket.jsonl` must place a non-Codex bucket first and the valid `codex` bucket under `rateLimitsByLimitId`. `no-secondary.jsonl` must set `secondary` to null.

Create `tests/fake-codex.sh` to reject commands other than `app-server`, record stdin when `FAKE_CODEX_REQUEST_LOG` is set, emit the fixture selected by `FAKE_CODEX_MODE`, and support `hang` mode:

```sh
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
```

- [ ] **Step 5: Run the manifest test and inspect fixture JSON**

Run: `chmod +x fetch-usage.sh tests/fake-codex.sh tests/test-manifest.sh && sh tests/test-manifest.sh && for f in fixtures/*.jsonl; do while IFS= read -r line; do printf '%s\n' "$line" | jq -e . >/dev/null || exit 1; done <"$f"; done`

Expected: `MANIFEST TESTS PASSED`; every fixture line parses successfully.

- [ ] **Step 6: Commit the plugin contract**

```bash
git add .gitignore plugin.json qmldir CodexUsageData.qml CodexUsageWidget.qml fetch-usage.sh fixtures tests/fake-codex.sh tests/test-manifest.sh
git commit -m "chore: establish DMS plugin contract"
```

---

### Task 2: Implement successful app-server collection and normalization

**Files:**
- Modify: `fetch-usage.sh`
- Create: `tests/test-fetch.sh`
- Modify: `tests/fake-codex.sh`
- Modify: `fixtures/success.jsonl`
- Modify: `fixtures/multi-bucket.jsonl`
- Modify: `fixtures/no-secondary.jsonl`

**Interfaces:**
- Consumes: `codex app-server`, newline-delimited JSON, environment overrides `CODEX_USAGE_CACHE_DIR`, `CODEX_USAGE_CODEX_BIN`, `CODEX_USAGE_NOW`, `CODEX_USAGE_FORCE`, `FAKE_CODEX_*`.
- Produces: `${CODEX_USAGE_CACHE_DIR}/usage.json` schema `{version:1,captured_at,primary,secondary}` and exit code `0` on success or a fresh-cache no-op.

- [ ] **Step 1: Write successful-path tests**

Create `tests/test-fetch.sh` with a private temp directory, a `codex` symlink to `tests/fake-codex.sh`, fixture exports, `run_mode()` and `assert_jq()` helpers, then assert:

```sh
run_mode success 1785686400
assert_jq '.version == 1 and .captured_at == 1785686400'
assert_jq '.primary == {"used_percentage":25,"window_minutes":300,"resets_at":1785690000}'
assert_jq '.secondary == {"used_percentage":8,"window_minutes":10080,"resets_at":1786291200}'

run_mode multi-bucket 1785686500
assert_jq '.primary.used_percentage == 25'

run_mode no-secondary 1785686600
assert_jq '.secondary == null'
```

Capture requests and assert exact methods, IDs, and client metadata:

```sh
jq -s -e '
  .[0].id == 1 and .[0].method == "initialize" and
  .[0].params.clientInfo.name == "DankCodexUsage" and
  .[0].params.clientInfo.version == "0.1.0" and
  .[1].method == "initialized" and
  .[2].id == 2 and .[2].method == "account/read" and
  .[3].id == 3 and .[3].method == "account/rateLimits/read"
' "$REQUEST_LOG" >/dev/null || fail "handshake"
```

- [ ] **Step 2: Run successful-path tests to verify they fail**

Run: `sh tests/test-fetch.sh`

Expected: FAIL because the skeletal helper exits 1 and does not write `usage.json`.

- [ ] **Step 3: Implement paths, dependency checks, locking, and freshness guard**

In `fetch-usage.sh`, define the public test seam and fixed constants:

```sh
#!/bin/sh
set -u
PLUGIN_VERSION=0.1.0
SCHEMA_VERSION=1
REFRESH_SECONDS=300
TIMEOUT_SECONDS=${CODEX_USAGE_TIMEOUT_SECONDS:-30}
CACHE_DIR=${CODEX_USAGE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/DankCodexUsage}
CACHE_FILE=$CACHE_DIR/usage.json
ERROR_FILE=$CACHE_DIR/error.json
LOCK_FILE=$CACHE_DIR/lock
CODEX_BIN=${CODEX_USAGE_CODEX_BIN:-codex}
NOW=${CODEX_USAGE_NOW:-$(date +%s)}
```

Create the cache directory with mode `0700`, open file descriptor 9 on `lock`, acquire `flock 9`, then re-read `.captured_at`. Exit 0 when age is below 300 seconds unless `CODEX_USAGE_FORCE=1`.

- [ ] **Step 4: Implement the JSONL exchange and response selection**

Use a private `mktemp -d` work directory and an EXIT trap. Start `setsid "$CODEX_BIN" app-server` with named stdin/stdout FIFOs, store its PID/PGID, write the four fixed request lines, and read until responses with IDs `1`, `2`, and `3` are present. A 30-second watchdog terminates the negative process group.

Select auth mode from response ID 2. Select the main bucket with this exact jq rule:

```jq
def response($id): map(select(.id == $id)) | last;
def main_bucket:
  if .rateLimits.limitId == "codex" then .rateLimits
  elif (.rateLimitsByLimitId.codex? != null) then .rateLimitsByLimitId.codex
  else null end;
```

Unknown response fields are ignored. Do not select the first map entry.

- [ ] **Step 5: Implement validation and atomic cache replacement**

Normalize with jq only after auth and main-bucket checks:

```jq
def valid_window:
  type == "object" and
  (.usedPercent | type == "number" and . >= 0 and . <= 100) and
  (.windowDurationMins | type == "number" and . > 0) and
  (.resetsAt | type == "number" and . > 0);
def norm:
  if . == null then null
  elif valid_window then {
    used_percentage: (.usedPercent | floor),
    window_minutes: (.windowDurationMins | floor),
    resets_at: (.resetsAt | floor)
  }
  else error("invalid rate-limit window") end;
{
  version: 1,
  captured_at: $now,
  primary: ($bucket.primary | norm),
  secondary: ($bucket.secondary | norm)
}
```

Require at least one non-null window. Write to a temp file inside `$CACHE_DIR`, set mode `0600`, validate it again, then `mv` it over `usage.json`. Remove `error.json` only after the move succeeds.

- [ ] **Step 6: Run successful-path tests**

Run: `sh tests/test-fetch.sh`

Expected: all successful normalization and handshake assertions pass.

- [ ] **Step 7: Commit successful collection**

```bash
git add fetch-usage.sh tests/test-fetch.sh tests/fake-codex.sh fixtures
git commit -m "feat: collect Codex rate limits"
```

---

### Task 3: Complete helper failures, timeout cleanup, and concurrency safety

**Files:**
- Modify: `fetch-usage.sh`
- Modify: `tests/test-fetch.sh`
- Modify: `tests/fake-codex.sh`
- Create: `fixtures/signed-out.jsonl`
- Create: `fixtures/api-key.jsonl`
- Create: `fixtures/non-codex-only.jsonl`
- Create: `fixtures/method-not-found.jsonl`
- Create: `fixtures/malformed.jsonl`
- Create: `fixtures/unknown-fields.jsonl`

**Interfaces:**
- Consumes: helper seams from Task 2 plus `CODEX_USAGE_TIMEOUT_SECONDS` for fast timeout tests.
- Produces: `${CACHE_DIR}/error.json` schema `{version:1,category,occurred_at,detail?}`; non-zero failures; sanitized stderr; no orphan app-server process.

- [ ] **Step 1: Add failing error-category and preservation tests**

Seed a known cache, record its checksum, invoke each fixture, assert non-zero status and these categories:

```text
signed-out       -> chatgpt_sign_in_required
api-key          -> api_key_unsupported
non-codex-only   -> rate_limits_unavailable
method-not-found -> codex_version_unsupported
malformed        -> refresh_failed
```

For every case assert `usage.json` retains the original checksum and `error.json` has `version == 1`, numeric `occurred_at`, and no token-like text. Add an `unknown-fields` fixture that succeeds to prove forward compatibility.

Add command-availability cases by overriding `CODEX_USAGE_CODEX_BIN` with a nonexistent absolute path (`codex_missing`) and by running with a test `PATH` that selectively omits `flock` or `setsid` (`dependency_missing`). Because `jq` is needed to parse and atomically construct normal output, implement its missing-dependency error document with fixed `printf` fields rather than calling the missing program; assert that this case also produces valid `error.json`.

- [ ] **Step 2: Add failing timeout and process-group cleanup test**

Run hang mode with `CODEX_USAGE_TIMEOUT_SECONDS=1`. Have the fake server write its PID and a spawned child PID to `FAKE_CODEX_PID_FILE`; after the helper exits, use `kill -0` to assert neither remains. Assert category `timeout`, non-zero exit, and elapsed time below five seconds.

- [ ] **Step 3: Add failing freshness and concurrent-lock tests**

Add tests for:

- a 299-second-old cache causes no fake Codex invocation;
- a 300-second-old cache refreshes;
- `CODEX_USAGE_FORCE=1` refreshes a fresh cache;
- two concurrent normal invocations against a stale cache result in one exchange because the second rechecks freshness after acquiring `flock`;
- killing a lock holder allows a later invocation to acquire the lock, proving kernel auto-release.

Use append-only `FAKE_CODEX_INVOCATION_LOG` and assert its line count rather than depending on timing alone.

- [ ] **Step 4: Implement stable error writing**

Add `write_error category detail` that constructs JSON with `jq -n`, truncates detail to a short allowlisted message generated by the helper, writes mode `0600` to a temp file in `$CACHE_DIR`, and atomically renames it. Route dependency, auth, bucket, protocol, timeout, and generic failures through this function. Never include captured stdout in `detail`.

- [ ] **Step 5: Implement robust EXIT cleanup and timeout mapping**

The EXIT trap must follow this behavior:

```sh
cleanup() {
  trap - EXIT HUP INT TERM
  if [ -n "${APP_PID:-}" ]; then
    kill -TERM "-$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM
```

Start app-server with `setsid` so `$APP_PID` is its process-group ID. The watchdog writes a private timeout marker before killing the group, allowing the main path to map this specific failure to `timeout`.

- [ ] **Step 6: Run the full helper suite**

Run: `sh tests/test-fetch.sh`

Expected: success, failure mapping, cache preservation, timeout cleanup, freshness, concurrency, and dead-holder recovery all pass.

- [ ] **Step 7: Run shell quality checks**

Run: `sh -n fetch-usage.sh tests/fake-codex.sh tests/test-fetch.sh tests/test-manifest.sh`

Run when installed: `shellcheck fetch-usage.sh tests/*.sh`

Expected: no syntax errors; no ShellCheck findings.

- [ ] **Step 8: Commit hardened helper behavior**

```bash
git add fetch-usage.sh tests/test-fetch.sh tests/fake-codex.sh fixtures
git commit -m "test: harden usage refresh failures"
```

---

### Task 4: Implement the Quickshell data singleton

**Files:**
- Modify: `CodexUsageData.qml`
- Create: `tests/test-qml-contract.sh`

**Interfaces:**
- Consumes: `usage.json`, `error.json`, `fetch-usage.sh`, Quickshell `FileView`, and DMS `Proc.runCommand`.
- Produces: singleton properties `primary`, `secondary`, `capturedAt`, `errorCategory`, `errorDetail`, `refreshing`, `hasData`, `now`; functions `refresh(force)`, `countdown(resetEpoch)`, `windowLabel(minutes)`, `minutesOld()`.

- [ ] **Step 1: Write failing static singleton contract tests**

Create `tests/test-qml-contract.sh` to assert `pragma Singleton`, imports for `Quickshell`, `Quickshell.Io`, and `qs.Common`, exact public property/function names, 60-second display tick, 300-second refresh interval, cache/error `FileView` watchers, and absence of `CodexUsageData {` in the widget:

```sh
grep -Fx 'pragma Singleton' "$ROOT/CodexUsageData.qml" >/dev/null || fail "singleton pragma"
grep -F 'readonly property int refreshSeconds: 300' "$ROOT/CodexUsageData.qml" >/dev/null || fail "refresh interval"
for symbol in 'property var primary' 'property var secondary' 'function refresh(force)' 'function countdown(resetEpoch)' 'function windowLabel(minutes)' 'function minutesOld()'; do
  grep -F "$symbol" "$ROOT/CodexUsageData.qml" >/dev/null || fail "$symbol"
done
if grep -F 'CodexUsageData {' "$ROOT/CodexUsageWidget.qml" >/dev/null; then fail "widget instantiates singleton"; fi
```

- [ ] **Step 2: Run the QML contract test to verify it fails**

Run: `sh tests/test-qml-contract.sh`

Expected: FAIL on the first missing property/function.

- [ ] **Step 3: Implement state parsing and formatting**

Replace the skeleton with a Quickshell `Singleton` that:

- computes `cacheDir` from `XDG_CACHE_HOME` or `HOME/.cache`;
- watches `usage.json` and `error.json` with separate `FileView` objects;
- accepts only `version === 1` and well-shaped window objects;
- retains current in-memory values when parsing fails;
- formats countdowns at minute granularity;
- maps `10080` to `Weekly`, whole-day durations to `N day`, whole-hour durations to `N hour`, and all others to `N minute`;
- exposes `hasData` when either window exists.

- [ ] **Step 4: Implement cache-age-gated refresh scheduling**

`refresh(force)` returns without spawning when `refreshing` is true or `force` is false and cache age is below 300 seconds. Otherwise call:

```qml
Proc.runCommand("codexUsage.fetch", ["sh", scriptPath], function(stdout, exitCode) {
    root.refreshing = false
    cacheFile.reload()
    errorFile.reload()
}, 35)
```

At `Component.onCompleted`, load both files then call `refresh(false)`. Use a five-minute repeating refresh timer and a 60-second display timer. When a present window crosses `resets_at`, mark it as resetting and perform one early forced refresh per reset epoch.

- [ ] **Step 5: Run static and native QML validation**

Run: `sh tests/test-qml-contract.sh`

Run when installed and import paths are available: `qmllint CodexUsageData.qml`

Expected: contract passes; `qmllint` reports no errors. If DMS imports are unavailable to standalone `qmllint`, record that limitation and validate through DMS in Task 6 rather than suppressing real QML errors.

- [ ] **Step 6: Commit the shared data model**

```bash
git add CodexUsageData.qml tests/test-qml-contract.sh
git commit -m "feat: add shared Codex usage model"
```

---

### Task 5: Build rings-only DMS bar and popout UI

**Files:**
- Create: `UsageRing.qml`
- Modify: `CodexUsageWidget.qml`
- Modify: `tests/test-qml-contract.sh`

**Interfaces:**
- Consumes: `CodexUsageData` singleton and DMS `PluginComponent`, `PopoutComponent`, `StyledRect`, `StyledText`, and `Theme`.
- Produces: horizontal and vertical bar pills, 320px popout, `UsageRing` inputs `percentage`, `ringColor`, `diameter`, `thickness`, `available`, and `accessibleName`.

- [ ] **Step 1: Extend QML contract tests for the visual boundary**

Assert that `UsageRing.qml` contains all six public properties, clamps percentage, requests repaint on percentage/color/availability changes, and that `CodexUsageWidget.qml`:

- is a `PluginComponent` with `pluginId: "codexUsage"`;
- imports `DankCodexUsage 1.0`;
- defines both `horizontalBarPill` and `verticalBarPill`;
- uses warning threshold 70 and critical threshold 90;
- exposes a manual refresh action;
- has no numeric display-mode branch or settings access.

- [ ] **Step 2: Run the extended contract test to verify it fails**

Run: `sh tests/test-qml-contract.sh`

Expected: FAIL because `UsageRing.qml` and DMS widget surfaces are absent.

- [ ] **Step 3: Implement the presentation-only ring**

Create `UsageRing.qml` using a `Canvas`. Draw the neutral track first and the colored clockwise arc from 12 o'clock only when available. Use:

```qml
readonly property real fraction: available ? Math.max(0, Math.min(1, percentage / 100)) : 0
Accessible.name: accessibleName
Accessible.role: Accessible.Indicator
```

Do not import or access `CodexUsageData` from this component.

- [ ] **Step 4: Implement widget models and theme behavior**

Use `PluginComponent`, `pluginId: "codexUsage"`, and singleton access only. Define:

```qml
readonly property int warnPct: 70
readonly property int critPct: 90
readonly property int staleMinutes: 60
function color(pct) {
    return pct >= critPct ? Theme.error : pct >= warnPct ? Theme.warning : Theme.primary
}
function limits() {
    return [
        { key: "primary", value: CodexUsageData.primary },
        { key: "secondary", value: CodexUsageData.secondary }
    ]
}
```

Keep both rows present even when one value is null. Use an unavailable ring and `--` percentage for null values.

- [ ] **Step 5: Implement horizontal and vertical pills**

Follow current DMS patterns from `PluginComponent`: `StyledRect`, theme spacing/radius, one ring plus adjacent percent per available window, and `✳ --` only when neither window exists. Both orientations must fit `parent.widgetThickness` and derive ring diameter from available thickness.

- [ ] **Step 6: Implement popout states and manual refresh**

Build a `PopoutComponent` with header `Codex Usage`, two stable rows, duration labels, percentage, minute-granularity countdown, resetting state, updated/stale footer, categorized error copy, and a header refresh action. Disable the action while `CodexUsageData.refreshing`; manual refresh calls `CodexUsageData.refresh(true)`.

Use concise category copy:

```text
codex_missing              Codex CLI is not installed.
dependency_missing         A required local dependency is missing.
chatgpt_sign_in_required   Sign in to Codex with ChatGPT.
api_key_unsupported        API-key sessions do not expose ChatGPT limits.
rate_limits_unavailable    Codex rate limits are unavailable.
codex_version_unsupported  Update Codex CLI to version 0.133.0 or newer.
timeout                    Codex usage refresh timed out.
refresh_failed             Codex usage refresh failed.
```

- [ ] **Step 7: Run QML contract and native validation**

Run: `sh tests/test-qml-contract.sh && sh tests/test-manifest.sh`

Run when available: `qmllint UsageRing.qml CodexUsageData.qml CodexUsageWidget.qml`

Expected: contract and manifest pass; no QML syntax errors.

- [ ] **Step 8: Commit the DMS interface**

```bash
git add UsageRing.qml CodexUsageWidget.qml tests/test-qml-contract.sh
git commit -m "feat: render Codex usage rings"
```

---

### Task 6: Document, license, and verify the complete plugin

**Files:**
- Create: `README.md`
- Create: `LICENSE`
- Modify: `tests/test-manifest.sh`

**Interfaces:**
- Consumes: all completed plugin behavior and commands.
- Produces: clone-and-enable installation instructions and a release-ready `0.1.0` repository.

- [ ] **Step 1: Add failing documentation assertions**

Extend `tests/test-manifest.sh` to require `README.md` and `LICENSE`, and assert README mentions:

```text
Codex CLI 0.133.0
codex login
account/rateLimits/read
~/.config/DankMaterialShell/plugins/codexUsage
API-key sessions
~/.codex/auth.json
```

The auth-file mention must explicitly say the plugin does not read it.

- [ ] **Step 2: Run the manifest test to verify it fails**

Run: `sh tests/test-manifest.sh`

Expected: FAIL because README and LICENSE do not exist.

- [ ] **Step 3: Write README and MIT license**

Document the rings and popout, requirements, install path, DMS scan/enable steps, refresh/stale behavior, cache files, API-key limitation, troubleshooting, privacy model, read-only methods, and test commands. Use the standard MIT text with copyright year `2026` and author `Eduards`.

- [ ] **Step 4: Run the full automated verification suite**

Run:

```bash
sh tests/test-fetch.sh
sh tests/test-manifest.sh
sh tests/test-qml-contract.sh
sh -n fetch-usage.sh tests/*.sh
git diff --check
```

Run when available:

```bash
shellcheck fetch-usage.sh tests/*.sh
qmllint UsageRing.qml CodexUsageData.qml CodexUsageWidget.qml
```

Expected: every installed check passes. Missing optional validators must be reported, not installed without approval.

- [ ] **Step 5: Verify against the real local Codex account**

Use an isolated temporary cache directory so normal user cache is untouched:

```bash
verify_dir=$(mktemp -d)
CODEX_USAGE_CACHE_DIR="$verify_dir" CODEX_USAGE_FORCE=1 sh ./fetch-usage.sh
jq -e '.version == 1 and (.primary != null or .secondary != null)' "$verify_dir/usage.json"
```

Expected: exit 0 and a valid schema. Inspect only normalized `usage.json`; do not print or inspect Codex credentials. Remove the explicit temporary directory after recording the result.

- [ ] **Step 6: Load and inspect in DMS**

Clone or symlink the repository into `~/.config/DankMaterialShell/plugins/codexUsage`, then use DMS Settings → Plugins → Scan, enable Codex Usage, and add it to a DankBar section. Verify horizontal and vertical layouts; percentages against Codex `/status` semantics; popout labels/countdowns; manual refresh debounce; active theme and 70/90 color transitions using fixture cache values; and last-good preservation after a forced failure.

Do not edit the user's permanent DMS bar layout without explicit approval; manual loading is sufficient if layout mutation is not authorized.

- [ ] **Step 7: Commit documentation and release readiness**

```bash
git add README.md LICENSE tests/test-manifest.sh
git commit -m "docs: prepare DankCodexUsage 0.1.0"
```

- [ ] **Step 8: Final clean-tree verification**

Run: `git status --short --branch && git log --oneline --decorate -6`

Expected: `## main` with no changed files and a concise sequence of task commits.
