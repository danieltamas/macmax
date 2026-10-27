# MacMax: instructions for agents

MacMax is an open source (MIT) macOS menu bar app: why the Mac is slow, per-app CPU, memory, disk
and network, a scheduled deterministic audit, public IP and VPN state, safe cleanup, and a read-only
MCP server for coding agents. Owner: Daniel Tamas. Repo: github.com/danieltamas/macmax.

## Start here

1. Read `docs/PLAN.md` (the spec, units U0..U12, acceptance, quality criteria, open decisions).
2. Read `docs/LESSONS.md` (what Bton, the owner's first menu bar app, taught; these are rules).
3. Read the companion doc for your unit (`docs/ARCHITECTURE.md`, `RULES.md`, `NETWORK.md`,
   `AGENT-API.md`, `DESIGN.md`, `RELEASE.md`, `SCREENSHOTS.md`).
4. Take the first unit whose dependencies are done, in PLAN.md's layout table. Nothing is built yet:
   start at U0. Each unit ends in a `/goal` line: run the unit under it.
5. If the owner keeps the macos-menubar-app skill on this machine
   (`~/agent-os/skills/macos-menubar-app/`), load it: it holds Bton's script and Swift snapshots and
   the longer form of every lesson. Bton's current `main` (github.com/danieltamas/bton) is the
   source to copy from; the skill's snapshots may be older.

## Stack

SwiftPM only (no Xcode project), Swift 6 language mode with strict concurrency, macOS 13 minimum
(`@Observable` and the other macOS 14 APIs are replaced or gated, LESSONS.md section 2), no
third-party packages. Targets: `MacMaxCore` (no SwiftUI or AppKit imports), `MacMax` (the app),
`MacMaxCLI` (installed as `macmax`; never a target named `macmax`, it collides with `MacMax` on a
case-insensitive disk), `MacMaxCoreTests` (Swift Testing). Bundle id `ro.danieltamas.macmax`.
App home `~/.macmax` (or `$MACMAX_HOME`), mode 0700.

## Build and test

Always an explicit scratch path outside the repo (a stale `.build/build.db` once made SwiftPM run
an old test binary). In Claude Code, `swift`, `gh`, `codesign` and `codex` need the Bash sandbox
off; `open` and `osascript` are blocked: hand the owner the command.

```
SCRATCH=$HOME/.cache/macmax-build
swift build --build-tests --scratch-path "$SCRATCH"
swift test --skip-build --scratch-path "$SCRATCH" [--filter Topic]
MACMAX_LIVE=1 swift test --skip-build --scratch-path "$SCRATCH" --filter Live   # real collectors
scripts/check.sh                 # build, tests, 500-line limit, ASCII punctuation lint
scripts/install-from-source.sh   # bundle and install to /Applications, CLI to ~/.local/bin
```

Check the test count grows when tests are added. Check the installed build is the checkout:
`PlistBuddy -c 'Print MacMaxSource'` on the installed Info.plist equals `git describe --tags
--always --dirty`. Live tests need a real Mac outside the sandbox (processes, nettop, scutil).

## How a unit gets done

1. **Acceptance tests by Codex, not by you.** Give Codex the unit's Acceptance lines from PLAN.md
   and the relevant doc; it writes `Tests/MacMaxCoreTests/<Topic>AcceptanceTests.swift`. Hash the
   files (`shasum -a 256 ... > "$SCRATCH/<topic>.sha"`) and re-check the hash before every commit.
   You never edit those tests; a red test is fixed in `Sources/`. A test you believe is wrong goes
   back to Codex with the evidence.
   ```
   codex exec --sandbox workspace-write --skip-git-repo-check -C . --add-dir "$SCRATCH" \
     -o "$SCRATCH/codex-tests.md" - < "$SCRATCH/tests-prompt.md"
   ```
   Always give `codex exec` its stdin (`- < file` or `< /dev/null`), or it waits forever. Write
   prompt files with the Write tool, not heredocs.
2. **Implement** the smallest change that meets the spec, matching the file's idiom.
3. **Build and run the whole suite** (and the live suite when the unit touches collectors).
4. **Codex reviews the diff**: `git diff > "$SCRATCH/x.diff"`, a prompt with the diff, the unit's
   spec, `docs/LESSONS.md` section 9 (defect classes) and, for UI, section 4 (glitches) plus the
   renders; ask for P0-P3 with file:line and a failure scenario, every finding on its own line
   starting with its severity (`P0: ...`), so the `/goal` check
   `grep -cE "^(P0|P1|P2)" "$SCRATCH/review-out.md"` reads the last review.
   ```
   codex exec --sandbox read-only --skip-git-repo-check -C . --add-dir "$SCRATCH" \
     -o "$SCRATCH/review-out.md" - < "$SCRATCH/review.md"
   ```
   Fix every P0, P1 and P2, send the fixes back for re-review, repeat until none are open. Dismiss a
   finding only with a reason checked against the code, and say so in the report.
5. **UI units**: render (`MacMax --render-screenshots "$SCRATCH/shots" --all-looks --stress`),
   look at every PNG, have Codex review them against `docs/DESIGN.md`. Then install and look at the
   live panel, or report "UI not exercised live".
6. **Update docs, README and screenshots in the same commit** when behavior or UI changed.
7. **Commit** only as the owner authorized (ask once at the start of the build whether finished
   units may be committed and pushed as they land).
8. **Install from source** and tell the owner in one or two lines what to try.

## Git

- Author `Daniel Tamas <hello@danieltamas.ro>`. Conventional Commits whose subject says what the
  user gets ("feat: the Network tab shows each app's traffic for the last hour"), not what the code
  does. Never a `Co-Authored-By` or any co-author or tool trailer.
- Branch per unit from `main` (`u3-network-traffic`), PR into `main`, merge after review. Never
  force-push `main`.
- Never commit `dist/`, `.build/`, scratch files, real captures, or anything from `~/.macmax`.

## Rules that are easy to break

- **Fail closed** on every read that feeds a decision: present, absent and failed are three states;
  failed or unknown never permits an action and never displays as healthy.
- **No action over MCP or the CLI.** Quit, kill, stop and cleanup exist only behind a press in the app.
- **Redact before storing, showing or returning** any command line or process text.
- **The app must stay light**: no perpetual SwiftUI animation, pause when the panel is hidden,
  relative times redraw once a minute (LESSONS.md section 3). `scripts/perf.sh` budgets are hard.
- **Anything MacMax does on this Mac shows progress** while it runs (`OperationProgress`: a bar that fills when the amount is
  known, the system's moving bar when not), and a press never looks like nothing happened.
- **Every setting lives in the app** (Settings window structure in LESSONS.md section 5).
- **No real data in fixtures or screenshots**: no user names, hostnames, paths, tokens; IPs only
  from RFC 5737 ranges.
- **Plain ASCII punctuation** in every user-facing string and doc (`-`, `"`, `'`, `...`); no en or em
  dashes, curly quotes, ellipsis character or invisible characters.
- **No vendor or AI attribution** in the app, README or release notes. Naming apps MacMax measures
  (Claude Code, Docker) is identification and fine.
- **Files 500 lines or fewer**; English identifiers and comments; comments say why.
- **Warn the owner before anything that prompts them** (admin password, keychain, TCC dialogs) and
  never run `sudo`, `sfltool` or `screencapture`.
- **Decisions are the owner's**: PLAN.md's open decisions (D1 signing, D3 IP endpoint, D4 cleanup,
  D7 Homebrew, D8 public docs, D10 vendoring mac-audit.sh) are asked as choices with the recommendation first, never assumed.
  Do not create the GitHub repo, push, tag or publish a release without the owner's go.
