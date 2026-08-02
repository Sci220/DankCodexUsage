# DankCodexUsage Design

## Summary

DankCodexUsage is a DankMaterialShell (DMS) bar widget that displays the primary and secondary usage windows for a ChatGPT-authenticated OpenAI Codex account. It follows the interaction model of [DankClaudeUsage](https://github.com/bogdan-velicu/DankClaudeUsage), but retrieves data through Codex's documented local app-server protocol rather than reading or forwarding stored OAuth credentials.

Version 1 is intentionally small: two theme-colored usage rings in the bar and a detailed read-only popout. It does not include a numeric bar style, per-limit visibility settings, extra metered buckets, credit purchases, or rate-limit reset consumption.

## Goals

- Work without separate API keys or manual endpoint configuration when Codex CLI is installed and signed in with ChatGPT.
- Display the main Codex bucket's primary and secondary rate-limit windows.
- Show usage percentage, a human-readable window label, reset countdown, and cache age.
- Match the active DMS theme and shift ring colors as usage increases.
- Avoid direct access to `~/.codex/auth.json` and never persist credentials.
- Preserve the last valid reading when a refresh fails.
- Behave correctly on multi-monitor DMS setups without multiplying upstream requests.

## Non-goals

- Supporting API-key billing or OpenAI Platform project spend.
- Displaying every entry in `rateLimitsByLimitId`.
- Purchasing credits, consuming reset credits, or changing account state.
- Running a persistent daemon.
- Reproducing every DankClaudeUsage setting in the initial release.

## User Experience

The bar widget renders two compact progress rings. The first represents the main Codex bucket's `primary` window and the second its `secondary` window. Each ring contains its rounded used percentage. Rings use the active DMS palette and move from primary to warning to error colors at named thresholds.

Clicking the widget opens a popout with one row per window. Each row shows:

- a duration-derived label, such as `5 hour` or `weekly`;
- used percentage;
- a live `resets in …` countdown; and
- an unavailable state when that window is absent.

The footer shows `updated … ago`, current refresh status, and a manual refresh action. A failed refresh leaves the last valid rings visible while the popout reports the failure. If no valid cache exists, the bar renders an unavailable state rather than a fabricated zero.

There are no user-facing display settings in version 1. Refresh interval, stale threshold, and color thresholds are named constants so they can be promoted to settings later.

## Architecture

### `fetch-usage.sh`

The helper is the only component that communicates with Codex. It:

1. Checks that `codex` and `jq` are available.
2. Acquires a short freshness lock so simultaneous widgets and monitors share one refresh.
3. Starts `codex app-server` over its default JSONL stdio transport.
4. Sends the required `initialize` request and `initialized` notification.
5. Sends `account/read` to distinguish ChatGPT auth from unsupported API-key auth.
6. Sends `account/rateLimits/read`.
7. Selects the backward-compatible `rateLimits` object when its `limitId` is `codex`; otherwise it selects the `codex` entry from `rateLimitsByLimitId`.
8. Normalizes the primary and secondary windows into a small cache document.
9. Validates the normalized output and atomically replaces the cache.
10. Terminates the app-server process and releases the lock.

The helper has a hard timeout. It never sources, parses, prints, or copies Codex credential files. Diagnostic output is sanitized and must not contain app-server payloads that could include account details.

### `CodexUsageData.qml`

This singleton-like data component owns cache loading and refresh timing. It exposes normalized primary and secondary values, cache age, stale state, refresh state, and a concise error category. It invokes the helper at startup, every five minutes, and on manual refresh. Countdown updates happen in QML and do not trigger network calls.

The component tolerates partially written or malformed cache input by retaining its last in-memory valid model. Atomic writes should prevent partial reads during normal operation.

### `CodexUsageWidget.qml`

This component binds DMS bar and popout UI to `CodexUsageData`. It contains no process execution or response parsing. It chooses duration-derived labels and exposes loading, unavailable, stale, and error states without hiding last-known-good usage.

### `UsageRing.qml`

This focused visual component accepts percentage, label/accessibility text, availability, and theme colors. It clamps display values to `0–100` and contains no data-fetching logic.

### `plugin.json`

The DMS manifest registers the widget, declares the minimum compatible DMS plugin API version, and provides project metadata. No configuration page is registered in version 1.

## Data Contract

The cache file is stored below the user's cache directory and contains only display data:

```json
{
  "captured_at": 1785686400,
  "primary": {
    "used_percentage": 25,
    "window_minutes": 300,
    "resets_at": 1785690000
  },
  "secondary": {
    "used_percentage": 8,
    "window_minutes": 10080,
    "resets_at": 1786291200
  }
}
```

`captured_at` and `resets_at` are Unix epoch seconds. `primary` and `secondary` may be `null` when Codex does not return a window. For present windows, all three fields are required numeric values. Percentages are clamped only for rendering; clearly malformed values cause validation failure instead of silently replacing the cache.

Window labels are derived from `window_minutes`. Known friendly cases include hours, days, and a seven-day `weekly` label. Unknown durations remain explicit, for example `90 minute`, so the UI remains truthful if OpenAI changes quota windows.

## Error Handling

The helper maps failures into stable categories that QML can present:

- `codex_missing`: Codex CLI is not on `PATH`.
- `dependency_missing`: a required local utility is unavailable.
- `chatgpt_sign_in_required`: no ChatGPT-managed account is active.
- `api_key_unsupported`: Codex uses API-key authentication, for which ChatGPT subscription limits do not apply.
- `rate_limits_unavailable`: authentication succeeds but no main Codex rate-limit bucket is returned.
- `timeout`: the local app-server or upstream request did not finish in time.
- `refresh_failed`: protocol, parsing, or other connection failure.

Errors are written separately from the last-good cache so a failed refresh cannot destroy valid readings. User-visible messages remain concise; development diagnostics go to stderr without tokens or full account responses.

## Security and Privacy

- The plugin communicates only with the locally installed `codex` executable.
- Codex owns authentication, token refresh, and upstream communication.
- The plugin never reads `~/.codex/auth.json` or environment API keys.
- Cache contents include only timestamps, durations, and percentages.
- Temporary files are created with restrictive permissions and atomically renamed.
- The helper performs read-only account and rate-limit calls. It does not call login, logout, credit purchase, email, or reset-credit methods.

## Testing

Shell tests use a fake `codex` executable that implements the app-server JSONL exchange. They require no network and cover:

- successful handshake and primary/secondary normalization;
- selection of the main `codex` bucket;
- absent secondary window;
- missing Codex and missing dependency errors;
- ChatGPT sign-in and unsupported API-key states;
- malformed JSON and protocol errors;
- timeout behavior;
- percentage and timestamp validation;
- atomic last-good cache preservation; and
- freshness-lock behavior across concurrent invocations.

Manifest tests validate required DMS metadata and referenced files. `shellcheck`, `jq`, and `qmllint` are run when available. Final verification loads the plugin in DMS, checks both rings and the popout against the active theme, triggers a manual refresh, and confirms correct stale/error behavior by substituting the fake app-server.

## Repository Layout

```text
DankCodexUsage/
├── docs/superpowers/specs/2026-08-02-dank-codex-usage-design.md
├── fixtures/
├── tests/
├── CodexUsageData.qml
├── CodexUsageWidget.qml
├── UsageRing.qml
├── fetch-usage.sh
├── plugin.json
├── README.md
├── LICENSE
└── .gitignore
```

## Delivery Criteria

Version 1 is complete when a ChatGPT-authenticated Codex user can clone the repository into the DMS plugin directory, enable the widget, and see accurate primary and secondary usage rings without configuring credentials. Automated fixture tests must pass without network access, native validation must pass where available, and a failed refresh must demonstrably preserve the last valid reading.
