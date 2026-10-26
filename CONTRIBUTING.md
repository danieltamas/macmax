# Contributing to MacMax

Thanks for looking. MacMax is a small macOS menu bar app (SwiftPM, Swift 6, macOS 14+, no
third-party packages). Start with [`docs/PLAN.md`](docs/PLAN.md) and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Build and test

```bash
SCRATCH=$HOME/.cache/macmax-build
swift build --build-tests --scratch-path "$SCRATCH"
swift test --skip-build --scratch-path "$SCRATCH"
scripts/check.sh                 # build, tests, 500-line limit, ASCII punctuation, README links
scripts/install-from-source.sh   # bundle and install this checkout
```

Use a scratch path outside the repo: a stale `.build` once made SwiftPM run an old test binary.
Tests marked live (`MACMAX_LIVE=1`) need a real Mac and are not run in CI.

## Rules a change must follow

- **Fail closed.** A read that feeds a decision is present, absent or failed; failed or unknown
  never permits an action and never shows as healthy.
- **No action over MCP or the CLI.** Quit, kill, stop and cleanup exist only behind a press in the app.
- **Redact before storing, showing or returning** any command line or process text.
- **Keep the app light:** no perpetual animation, pause when the panel is hidden.
- **Files stay under 500 lines.** English identifiers and comments; comments say why.
- **Plain ASCII punctuation** in every user-facing string and doc: `-`, `"`, `'`, `...`.
- **No real data** in fixtures or screenshots: no user names, hostnames, paths or tokens; IPs only
  from the documentation ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24).
- **Update the README and screenshots in the same change** as the behavior or UI they show
  (`docs/SCREENSHOTS.md`).

## Tests

A bug fix comes with a test that fails without it. For new behavior, write the acceptance test from
the spec first. A maintainer's acceptance tests are written by someone other than the author of the
code they judge; if you change a test, say what in the spec makes it wrong.

## Pull requests

Conventional Commits whose subject says what the user gets ("feat: the Network tab shows each
app's traffic for the last hour"). One concern per pull request. Say what you ran and what you
could not run (for example, UI you did not look at live).

Security problems: see [`SECURITY.md`](SECURITY.md), not a public issue.
