# Codex Meter

A small macOS menu bar app for checking your Codex usage, remaining allowances, and reset times. Uses your existing Codex CLI login and refreshes automatically.

<img src="assets/screenshot.png" alt="Codex Meter menu bar and usage panel showing remaining allowance, reset time, and credits" width="382">

## Requirements

- macOS 13+
- Swift 6+ and Command Line Tools (`xcode-select --install`)
- [Codex CLI](https://developers.openai.com/codex/cli), signed in with a ChatGPT account (`codex login`)

## Build and install

```sh
git clone https://github.com/MR-Addict/codex-meter.git
cd codex-meter
./scripts/build.sh
mkdir -p ~/Applications
cp -R "dist/Codex Meter.app" ~/Applications/
open ~/Applications/"Codex Meter.app"
```

The build script creates a locally signed app for your Mac. Click its menu bar icon to view usage; use the gear menu to choose the CLI or enable **Launch at Login**.

To update, quit the app, pull the latest code, then repeat the build and install steps.
