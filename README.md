# DankCodexUsage

DankCodexUsage is a read-only [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) bar widget for ChatGPT-authenticated Codex usage limits. It renders compact primary and secondary usage rings in horizontal and vertical bars. Clicking the widget opens a popout with each window's used percentage, duration, reset countdown, cache age, refresh state, and any refresh error.

The rings follow the active DMS theme. Usage below 70% uses the theme primary color, 70–89% uses the warning color, and 90% or higher uses the error color. A missing window is shown as unavailable; it is never represented as 0%.

## Requirements

- DankMaterialShell 0.1.0 or newer with plugin support
- Codex CLI 0.133.0 or newer
- a ChatGPT account active in Codex via `codex login`
- `jq`, `flock`, and `setsid`

API-key sessions do not expose ChatGPT subscription rate limits and are not supported by this plugin.

## Install

Obtain a repository checkout (for example, clone it from its published remote once one is available), enter the DankCodexUsage repository root, and link that checkout into the DMS plugin directory:

```sh
mkdir -p "$HOME/.config/DankMaterialShell/plugins"
ln -s "$(pwd)" "$HOME/.config/DankMaterialShell/plugins/codexUsage"
```

Then open **DMS Settings → Plugins**, select **Scan**, and enable **Codex Usage**. Add Codex Usage to the desired horizontal or vertical section under the DankBar layout settings. DMS owns the bar placement; installing the plugin does not change the layout automatically.

## How it works

The local helper starts `codex app-server`, performs its JSONL initialization handshake, and calls the read-only `account/read` and `account/rateLimits/read` methods. It selects the main `codex` rate-limit bucket and stores only normalized percentages, window durations, reset times, and capture time.

The shared DMS data singleton checks for fresh data every five minutes. Multiple bars and monitors share the same cache and `flock` lock. A cache younger than five minutes suppresses another request, including rapid clicks on the manual refresh action. After 60 minutes the popout marks retained data as stale. When a displayed window reaches its reset time, the widget marks it as resetting and requests an early refresh.

A successful refresh atomically replaces `usage.json` and clears the previous error. A failed refresh writes `error.json` without replacing the last-good usage, so previously valid rings stay visible alongside a concise error.

## Local data and privacy

State is stored under `${XDG_CACHE_HOME:-$HOME/.cache}/DankCodexUsage/`:

- `usage.json` contains the normalized, last-good display data.
- `error.json` contains the latest sanitized error category and detail.
- `lock` coordinates refreshes with `flock`.

Codex itself owns authentication and upstream communication. The plugin does not read `~/.codex/auth.json`, environment API keys, or any other credential store. Its long-lived cache files contain only normalized display data and sanitized errors. During a refresh, the helper writes raw JSONL only inside a private `mktemp` workspace; normal cleanup removes that workspace on regular exit and handled signals. An uncatchable `SIGKILL` cannot run shell cleanup traps, so forcibly terminated temporary data may require operating-system cleanup. The plugin does not log in, log out, purchase credits, consume reset credits, or otherwise change account state.

## Troubleshooting

- **Codex CLI is not installed:** ensure `codex` is on `PATH` and `codex --version` reports at least 0.133.0.
- **Sign in to Codex with ChatGPT:** run `codex login` and choose ChatGPT authentication.
- **API-key sessions do not expose ChatGPT limits:** sign in with ChatGPT instead of an API key.
- **Installed Codex is unsupported:** update Codex if `account/read` or `account/rateLimits/read` is unavailable.
- **`rate_limits_unavailable`:** the authenticated account returned no main `codex` bucket. Update Codex and retry, then check whether usage limits are available for the active account. The helper does not guess another bucket.
- **A dependency is missing:** install `jq`, `flock`, and `setsid` through the operating system package manager.
- **Refresh timed out or failed:** retry after checking local connectivity. Valid cached usage remains intact.
- **Widget is not listed:** confirm the directory is exactly `~/.config/DankMaterialShell/plugins/codexUsage`, then scan again in DMS Settings → Plugins.

To request a refresh from the shell while preserving the normal cache location:

```sh
CODEX_USAGE_FORCE=1 sh ./fetch-usage.sh
```

## Development and verification

The fixture suite uses a fake Codex app-server and requires no account or network access:

```sh
sh tests/test-fetch.sh
sh tests/test-manifest.sh
sh tests/test-qml-contract.sh
sh -n fetch-usage.sh tests/*.sh
git diff --check
```

Run the native validators when installed:

```sh
shellcheck fetch-usage.sh tests/*.sh
qmllint UsageRing.qml CodexUsageData.qml CodexUsageWidget.qml
```

## License

DankCodexUsage is available under the MIT License. See [LICENSE](LICENSE).
