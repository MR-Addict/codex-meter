# Validation — 2026-09-16

Environment: Apple Silicon, macOS 26.6.2, Swift 6.4 Command Line Tools, Codex CLI 0.154.0.

Verified:

- Release build through `./scripts/build.sh`.
- Ad-hoc signature passes `codesign --verify --strict`.
- 13 automated tests pass; the opt-in live test is skipped by default.
- The separately enabled live test reads the existing ChatGPT account successfully, without starting a thread or model turn or printing account data.
- App bundle launches and spawns its Codex child process.
- Terminating the test app leaves neither the app nor its Codex child running.
- Final release app relaunched after verification.

Not verified interactively:

- Actual menu appearance, Refresh/Quit button interactions, and setup-guidance presentation.
- Real sleep/wake refresh.
- Launch at Login registration from an installed Applications copy, or behavior after logging in.
- macOS 13 / Intel runtime compatibility (the source targets macOS 13; this build is arm64).

The UI automation tool timed out selecting this background menu bar app; the fallback desktop screenshot was blank. Unit tests cover stale snapshots, errors, parsing, connection shutdown, and retry behavior, but do not replace these manual checks. Launch at Login remains off by default and was not enabled during validation.
