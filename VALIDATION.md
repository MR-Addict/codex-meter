# 0.2.0 audit status — 2026-10-23

Baseline: aeba40ded5a6bb6c43948b47f4d68483fc2e14f1.
See [REVIEW-0.2.0.md](REVIEW-0.2.0.md) for findings, regression definitions and the pending macOS acceptance matrix.

- Source review and regression additions completed locally.
- `git diff --check`: passed.
- New Swift tests/build: NOT RUN successfully (Linux host lacks Swift/xcrun; test script exits 127).
- 25 test definitions now exist, including one opt-in live test; this is not a passing-test count.
- New macOS CI workflow prepared, not triggered.
- AppKit events, sleep/wake, login registration, live account, signatures and architecture compatibility: NOT VERIFIED for 0.2.0.

The following record is historical and does not validate the October UI/refresh changes.

---

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
