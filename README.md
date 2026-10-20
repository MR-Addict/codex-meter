# Codex Meter

A small native macOS menu bar app for your existing Codex account. The menu bar shows a native terminal icon and the **lowest remaining percentage** across the core Codex allowance windows. Click it for a compact usage panel with a progress ring, per-window allowance bars, reset countdowns, credit information, and refresh controls. The panel closes on an outside click (configurable) or Escape, and behaves the same on every Mac.

## Requirements

- macOS 13 or later, Apple Silicon or Intel.
- Swift 6+ and Apple Command Line Tools (`xcode-select --install`). Full Xcode is not required.
- [Codex CLI](https://developers.openai.com/codex/cli) installed and signed in with **ChatGPT**. Run `codex login` and check with `codex login status`. An API-key-only login does not provide ChatGPT subscription allowances.

## Build and run

```sh
git clone https://github.com/MR-Addict/codex-meter.git
cd codex-meter
./scripts/build.sh
open "dist/Codex Meter.app"
```

The script builds for your current Mac and creates an ad-hoc-signed app at `dist/Codex Meter.app`. It needs no third-party libraries or Apple Developer account. This is a local build, not a Developer ID-signed or notarized download.

For regular use, quit the app, move it to `/Applications` or `~/Applications`, and launch that copy. Open the gear menu and enable **Launch at Login** only from that stable location. macOS may require approval in System Settings → General → Login Items. Disable Launch at Login before moving or removing the app. Keep only one running copy.

## How it works

The app runs one `codex app-server` subprocess and uses its [documented account interface](https://learn.chatgpt.com/docs/app-server). It initializes the connection, checks the CLI account, and reads `account/rateLimits/read`. It never creates a thread or starts a model task.

Authentication is handled by Codex using its existing local login. The app does not read credential files or copy tokens. Current usage still requires internet access. Desktop-app login alone does not guarantee the CLI has a usable login.

Usage refreshes on startup, every minute in the background, every 20 seconds while the panel is open, on wake, on session reactivation, when the panel opens, and when you click the refresh icon. A failed request schedules an automatic retry (5, 10, 20, 40, then 60-second backoff; 60 seconds for a missing CLI and 2 minutes for sign-in or version problems), so a slow login or a not-yet-installed CLI recovers without a manual refresh. There is a 20-second timeout per request and at most two reconnect retries after a timeout or closed connection. Requests never overlap. After failure, the last successful values stay visible with a warning and the time of their last update. A passed reset time does not imply that an allowance has replenished; refresh confirms it.

While no usage has loaded yet, the panel shows a dedicated connecting state and, if setup is required, a plain-language explanation with **Choose CLI…**, **Copy Login Command**, and **Try Again** actions instead of a bare error string.

The main percentage uses `rateLimitsByLimitId.codex`, falling back to `rateLimits`. All returned allowance buckets appear directly in the panel, without a disclosure section. Labels derive from window durations. Remaining percentages are rounded down and clamped to 0–100. Purchased/workspace credits and earned reset counts are separate from allowances; absent fields are unavailable, not zero. No purchase or reset-redemption controls are included.

Only the selected CLI path, the close-on-outside-click preference, and the macOS login-item state persist. Usage is held in memory. The app discards subprocess stderr and does not log tokens, account responses, or balances.

## Troubleshooting

- **CLI missing:** Install Codex or use **gear menu → Codex CLI → Choose Executable…**. Automatic discovery checks `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, and the app's inherited PATH. Finder-launched apps may not inherit your shell PATH. Select the actual executable, not an alias or shell function.
- **Login needed:** Run `codex login` in Terminal, sign in with ChatGPT, then refresh. The app uses the same `CODEX_HOME` and environment it inherits; a shell-only custom `CODEX_HOME` is not automatically inherited by Finder launches.
- **Connection or timeout:** Check internet connectivity, run `codex login status`, and refresh. Update the CLI if the account interface is unsupported.
- **Launch at Login fails:** Move the app to Applications, relaunch it there, and check Login Items in System Settings. Rebuilding or moving an ad-hoc-signed app can require registration again.
- **Swift cache permission errors:** Run the build from a normal Terminal with access to your user compiler caches.

## Tests

```sh
./scripts/test.sh
# Optional: read the current account's usage, without generating a model response:
CODEX_METER_LIVE_TEST=1 ./scripts/test.sh --filter RPCTests/testLiveUsageWhenExplicitlyEnabled
```

Tests require Swift 6+; this Mac’s Swift Testing framework requires macOS 14+ to run tests (the app itself targets macOS 13). The test script handles the Command Line Tools macro-plugin discovery workaround automatically.

Unit tests cover parsing, bucket selection, missing fields, credits, countdowns, stale state, request matching, fragmented messages, initialization, connection reuse, bounded timeout retries, exit recovery, and login/version failures. The live test intentionally prints no account details.

Manual release checks: launch the built app, open its menu, verify refresh and Quit, disconnect networking to check stale state, choose an invalid/missing CLI to check setup guidance, sleep/wake the Mac, and test Launch at Login from an installed copy. Actual login behavior requires logging out/in; CI/unit tests cannot prove that behavior.
