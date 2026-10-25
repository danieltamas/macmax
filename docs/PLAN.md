# MacMax plan

Status: U0 is done on branch `u0-skeleton` (2026-10-25); start at U1. D9 (icon) is still open: the palette and `Brand/icon-app.svg` are provisional.
Open decisions (bottom of this file) are asked when the unit that needs them starts.

## What it is

MacMax is an open source macOS menu bar app (MIT) that tells you why your Mac is slow, in one
verdict, and shows what each app costs: CPU, memory, disk, network traffic in and out. It runs
a deterministic audit on a schedule (the rules of `mac-audit.sh`, as data), keeps a local
history, shows your public IP and whether your VPN (Outline, Tailscale, any Network Extension
VPN) is up and actually carrying traffic, and offers only safe, reversible fixes. A Claude
agent can query it directly through a local MCP server (`macmax mcp`), read-only.

Companion specs (each is part of this plan; where they disagree, this file wins):

| File | Holds |
|------|-------|
| `docs/LESSONS.md` | What Bton taught: rhythm, plumbing, CPU, UI glitches, Settings structure, About, release, defect classes |
| `docs/ARCHITECTURE.md` | Targets, collectors and their data sources, store, sampler, CLI |
| `docs/RULES.md` | The audit rule set, thresholds, rule schema, cleanup rules |
| `docs/NETWORK.md` | Per-app traffic, connections, public IP, VPN state, leak check |
| `docs/AGENT-API.md` | `macmax mcp` tools, schemas, CLI JSON output |
| `docs/DESIGN.md` | The UI standard: panel, tabs, tokens, rules every view follows |
| `docs/RELEASE.md` | Versioning, signing, release ceremony, installer, updater, CI, rollback |
| `docs/SCREENSHOTS.md` | How README images are rendered from synthetic data |
| `SECURITY.md` | Threat model and trust boundaries for users |

## Complete when

A person on a Mac that never had MacMax runs the README install line, and within two minutes
the menu bar shows MacMax with a verdict; the panel lists apps by CPU, memory and network,
shows the public IP and the VPN state; `claude mcp add macmax -- ~/.local/bin/macmax mcp`
lets a Claude Code session call `snapshot` and `run_audit`; and v0.1.0 is published on
github.com/danieltamas/macmax with a reproducible zip and `SHA256SUMS`.

## Measured by

`scripts/acceptance.sh` exits 0. It runs, in order, failing on the first error:
1. `scripts/check.sh` (build, full test suite, file-size and ASCII lint).
2. The live suite (`MACMAX_LIVE=1`, collectors against this Mac, outside the Claude Code sandbox).
3. `scripts/perf.sh` (sampler and idle CPU budgets below, 10 minutes).
4. An MCP smoke test: `macmax mcp` over stdin answers `initialize`, `tools/list`, `snapshot`,
   `run_audit` with valid JSON-RPC within the latency budget.
5. `scripts/release.sh <version> --verify` on the release tag (byte-identical rebuild).
6. `MACMAX_VERSION=<version> ./install.sh` installs the published release; the installed
   `CFBundleShortVersionString` equals `<version>`.

Plus one manual check recorded in the release notes: the first install on a second Mac (a
different user, no Homebrew in `/opt/homebrew`, no developer tools), per `docs/RELEASE.md`.

## Non-goals (v1)

- Memory per Chrome tab. Nothing outside Chrome can attribute memory to a tab on stable
  Chrome; MacMax shows Chrome's total and its heaviest renderers, and says so.
- Blocking traffic (Little Snitch, LuLu territory). It needs a Network Extension.
- The Mac App Store (App Sandbox forbids reading other processes), Windows, Linux.
- Root helpers, kernel or system extensions, `sudo`, `powermetrics`.
- Any network call besides the public IP check and the update check.
- Write actions over MCP.

## Layout

Each unit is one session, one PR, acceptance tests by Codex before or alongside the code, a
Codex review of the diff, P0-P2 fixed and re-reviewed. Units on the same row of "depends on"
can run in parallel in separate worktrees.

In the `/goal` lines, `$SCRATCH/review-out.md` is Codex's review of the unit's final diff, re-run
after the last fix (never an earlier round), and the review prompt requires every finding on its
own line starting with its severity (`P0`..`P3`). So "prints 0" means the last review of the code
being committed found no P0, P1 or P2.

| Unit | What | Depends on | Touches |
|------|------|------------|---------|
| U0 | Skeleton, scripts, process helper, theme, CI | none | Package, Support, scripts, Sources (3 targets), Tests, CI |
| U1 | System collectors | U0 | Core collectors, tests |
| U2 | Process collector and app grouping, argv redaction | U0 | Core collectors, redaction, tests |
| U3 | Per-app network traffic | U0 | Core network, tests |
| U4 | Network identity: VPN, public IP, ISP IP, leak check | U0 | Core network, tests |
| U5 | Store and sampler | U1, U2, U3 | Core store (SQLite), sampler, tests |
| U6 | Audit engine and rules | U1, U2, U3, U4 | Core rules, scheduler, notifications glue, tests |
| U7 | Panel UI: Overview, Apps, Network, Findings; menu bar icon; Settings | U5, U6 | App target, DemoShots |
| U8 | History charts | U5, U7 | App target |
| U9 | Actions and cleanup | U2, U6, U7 | Core actions, App target, tests |
| U10 | CLI and MCP server | U5, U6 | CLI target, Core API, tests |
| U11 | Updater, About, login item, notifications | U0, U7 | App target, Core release |
| U12 | Release: signing, installer, README media, first public release | all | scripts, README, docs, SECURITY |

## Units

### U0. Skeleton
- SwiftPM, Swift 6 language mode, macOS 14, no third-party packages. Targets `MacMaxCore`
  (no SwiftUI or AppKit imports), `MacMax` (SwiftUI app), `MacMaxCLI` (installed as
  `macmax`), `MacMaxCoreTests`. Bundle id `ro.danieltamas.macmax`, `LSUIElement`.
- Copy and rename from Bton's current `main` (github.com/danieltamas/bton), not from older
  snapshots: `ProcessRunner` and `Executables`, `Theme`, `Looks` (three looks), `Components`,
  the Settings parts, `LoginItem`,
  `bundle.sh`, `install-from-source.sh`, `make-signing-identity.sh`, `render-icons.sh`.
  Rename every `Bton`, `bton`, `BTON_` literal. Drop Bton's domain colour maps.
- `MacMaxHome`: `~/.macmax` (or `$MACMAX_HOME`), mode 0700 even when it exists.
- `scripts/check.sh`: build with an explicit scratch path, run the suite, fail on any Swift
  file over 500 lines, fail on non-ASCII punctuation in `README.md`, `docs/`, `Sources/`
  user-facing strings (en and em dashes, curly quotes, the ellipsis character, NBSP).
- `--render-screenshots <dir>` flag stub that renders an empty panel (see `docs/SCREENSHOTS.md`).
- Icons (decision D9): `Brand/icon-app.svg` (the app icon) and `Brand/icon-menubar.svg` (a
  single-color template glyph that reads at 18 points), rendered by `scripts/render-icons.sh` to
  `Support/AppIcon.icns` and `Support/MenuBarIcon.pdf` (committed). The MacMax palette's brand
  hues are taken from the app icon, so the icon comes before the theme tokens.
- GitHub Actions: build and test on every PR, actions pinned by SHA, Xcode pinned to
  `Support/toolchain`.

Acceptance:
- `swift build` produces three products; `MacMaxCore` imports neither SwiftUI nor AppKit (a
  test greps the sources).
- `ProcessRunner`: a child that ignores SIGTERM is killed by the group KILL after the
  timeout; a grandchild holding the pipe does not hang the read; a child that exits 0 after
  its timeout is reported as a timeout failure.
- `MacMaxHome` creates the directory with mode 0700 and corrects a wider mode on an existing one.
- `scripts/check.sh` fails on a 501-line Swift file and on an en dash in `README.md`.
- `scripts/render-icons.sh` run twice produces byte-identical `AppIcon.icns` and
  `MenuBarIcon.pdf`; the bundled app shows the icon, the menu bar glyph is a template image.

`/goal scripts/check.sh exits 0 with the U0 acceptance tests (written by Codex) passing, grep -cE "^(P0|P1|P2)" $SCRATCH/review-out.md prints 0, or stop after 40 turns`

### U1. System collectors
- CPU (total, user, system, idle, per core), load averages, core count, uptime and boot time.
- Memory: physical, used, wired, compressed, compressor share of RAM, swap used, swap-ins and
  swap-outs per second over a window, `kern.memorystatus_level`, memory pressure.
- Disk: free space (important-usage capacity) and IO bytes and operations per second on the
  boot disk. Thermal state and CPU speed limit. GPU utilization. Battery state and power source.
- Every reading carries its source and a status: `ok`, `unavailable` (with reason), or
  `failed` (with reason). Sources and their verification state are in `docs/ARCHITECTURE.md`.

Acceptance:
- Parsers are pure functions tested on captured fixtures: `vm_stat`, `sysctl vm.swapusage`,
  `pmset -g therm`, `top -l` header lines, `iostat` lines. Malformed or truncated input gives
  `failed`, never zeros.
- Rates (swap-ins per second, disk bytes per second) come from two readings and a monotonic
  clock; a counter that went backwards yields `failed` for that interval, not a negative rate.
- Live suite: on this Mac every collector returns `ok` or `unavailable` with a reason;
  used memory is between 0 and physical memory; CPU shares sum to 100 plus or minus 1.

`/goal scripts/check.sh exits 0, MACMAX_LIVE=1 swift test --filter SystemCollector passes outside the sandbox, grep -cE "^(P0|P1|P2)" $SCRATCH/review-out.md prints 0, or stop after 40 turns`

### U2. Process collector, app grouping, argv redaction
- Every process of every user it can read: pid, parent, start time, user, name, path, CPU %
  (from CPU time deltas), memory footprint (the number Activity Monitor shows), disk bytes read
  and written, whether it runs under Rosetta, cwd, tty, argv.
- Identity is (pid, start time), never pid alone.
- App grouping: a process belongs to the outermost `.app` bundle in its path, else to its
  nearest ancestor that has one, else stands alone. Known families get one label: Chrome
  helpers, Electron helpers, Claude Code sessions with their MCP sidecars, Docker's VM.
- Argv redaction before anything is stored, shown or returned: values after flags and keys
  that look like secrets (`--token`, `--api-key`, `--password`, `Authorization`, `Bearer`,
  `*_KEY=`, `*_TOKEN=`, `*_SECRET=`, URLs with credentials, long high-entropy strings) become
  `[redacted]`. The rule list lives in one file with tests.

Acceptance:
- Grouping on fixtures: a Chrome renderer path groups under Google Chrome; a node process whose
  parent is a Claude Code session groups under that session; a `/usr/libexec` daemon stands alone.
- Redaction fixtures: a Bearer header value, an `--api-key=...` flag, `GITHUB_TOKEN=...`, a URL
  with `user:pass@`, and a 40-character random string are redacted; `--model opus` and a file
  path are not.
- CPU % for a busy-loop child spawned by the test is above 80 on a 2-second window.
- A pid reused by a new process (same pid, new start time) is a new identity.

`/goal scripts/check.sh exits 0, MACMAX_LIVE=1 swift test --filter ProcessCollector passes outside the sandbox, grep -cE "^(P0|P1|P2)" $SCRATCH/review-out.md prints 0, or stop after 40 turns`

### U3. Per-app network traffic
- Bytes in and out per process per interval from macOS's network statistics (the source
  behind `nettop`), grouped by app like U2. Interface totals per interval. Connections of one
  process on demand (remote address, port, state), never on every sample.
- Details and the verified source are in `docs/NETWORK.md`.

Acceptance:
- The `nettop` CSV parser on fixtures: process names with spaces and dots, truncated names
  resolved through the pid, the header line, a line with missing fields (skipped and counted,
  never read as zero traffic).
- Deltas: two cumulative readings give per-interval bytes; a process that restarted (new start
  time) restarts its counter.
- Live: a test downloads 5 MB from a local `python3 -m http.server`-style listener it starts;
  the test process's bytes in over that interval are at least 5 MB.
- The long-lived collector child is supervised: killed with the app, restarted with backoff if
  it dies, and its death marks network readings `failed` until it is back.

`/goal scripts/check.sh exits 0, MACMAX_LIVE=1 swift test --filter NetworkTraffic passes outside the sandbox, grep -cE "^(P0|P1|P2)" $SCRATCH/review-out.md prints 0, or stop after 40 turns`

### U4. Network identity
- VPN services and their state from the system's network connection list (name, bundle id,
  connected or not). The primary interface and whether the default route goes through a tunnel.
- Public IP as the internet sees it (default route) and the ISP IP (forced onto the physical
  interface, bypassing a tunnel), with country, from one configurable endpoint. On launch, on
  every network path change, and every 5 minutes.
- Leak verdict, first match wins (full table in `docs/NETWORK.md`): `off` (check turned off),
  `unknown` (any lookup failed), `no_vpn`, `leak` (VPN connected but the two IPs match),
  `split_tunnel` (VPN connected, default route outside the tunnel, IPs differ), `tunnel_ok`.
  `unknown` is never shown as OK.

Acceptance:
- The `scutil --nc list` parser on fixtures: Connected, Disconnected, Connecting, names with
  quotes and spaces, three services at once.
- Leak verdict table test covering every combination of (VPN state, route via tunnel, public
  IP, ISP IP, lookup failure).
- The IP endpoint client: timeout, non-200, malformed body and a non-IP `ip=` value all give
  `failed`; IPv4 and IPv6 both parse.
- Live: with a VPN connected, `public_ip` and `isp_ip` are both present; the test prints them
  only as hashes.

`/goal scripts/check.sh exits 0, MACMAX_LIVE=1 swift test --filter NetworkIdentity passes outside the sandbox, grep -cE "^(P0|P1|P2)" $SCRATCH/review-out.md prints 0, or stop after 40 turns`

### U5. Store and sampler
- SQLite through the system library (`import SQLite3`), one database in `~/.macmax/macmax.db`,
  WAL mode, one writer actor. Schema in `docs/ARCHITECTURE.md`.
- Sampler every 10 seconds (setting: 5, 10, 30, 60): one system row, rows for the top 40 apps
  by any of CPU, memory, disk or network, process rows for the top 30 processes.
- Rollups: raw kept 48 hours, 1-minute rows 14 days, 1-hour rows 365 days. Retention runs
  hourly and is bounded in time per run.

Acceptance:
- Schema migrations are versioned and idempotent; opening a newer schema read-only works,
  writing to it refuses.
- Rollup correctness on synthetic data: averages, maxima and byte sums over known inputs.
- Retention deletes only rows older than each cut.
- A reader (the CLI) and the writer run at once without `SQLITE_BUSY` failures surfacing
  (busy timeout, retries bounded).
- Size budget: 90 days of synthetic samples at the default cadence stay under 250 MB.

`/goal scripts/check.sh exits 0 with the U5 acceptance tests passing, swift test --filter StoreBudget proves the 250 MB bound, grep -cE "^(P0|P1|P2)" $SCRATCH/review-out.md prints 0, or stop after 40 turns`

### U6. Audit engine and rules
- The rules of `~/agent-os/skills/mac-audit/bin/mac-audit.sh` ported one to one as data, same
  ids, same thresholds, same severities, plus the new rules in `docs/RULES.md` (Intel
  Homebrew under Rosetta, translated processes, VPN leak, IP changed).
- An audit evaluates one immutable snapshot; the same snapshot always gives the same findings
  in the same order. Verdict = the highest severity present.
- Scheduled every 4 hours (setting), on demand, and when memory pressure enters the critical
  band. Notifications only for a finding that is new or got worse since the last audit.

Acceptance:
- Golden tests: fixture snapshots in, the exact findings list out (ids, severities, evidence).
- Parity (method in `docs/RULES.md`): `scripts/parity.sh` runs `mac-audit.sh --json-summary` and
  `macmax audit --json` within the same minute, maps the script's verdict lines to rule ids by
  message prefix, and fails when MacMax misses a (rule, severity) the script reports, except
  values within 5 percent of a threshold.
- Determinism: evaluating one snapshot 100 times yields byte-identical JSON.
- A collector that `failed` makes its rules report `unknown` with the reason, never `ok`.
- Notification diffing: first audit after install notifies only CRIT; an unchanged finding
  never notifies twice.

`/goal scripts/check.sh exits 0, scripts/parity.sh exits 0 outside the sandbox, grep -cE "^(P0|P1|P2)" $SCRATCH/review-out.md prints 0, or stop after 50 turns`

### U7. Panel UI
- The panel, tabs and Settings in `docs/DESIGN.md`: Overview (verdict, vitals tiles, identity
  card), Apps (sortable by CPU, memory, disk, network; expand to processes), Network (per-app
  traffic now, 1 hour, 24 hours; interface totals; identity), Findings (each with evidence,
  why it matters and its action). Menu bar icon tinted by verdict, optional live text.
- The Settings window with every pane in `docs/DESIGN.md`, structured per `docs/LESSONS.md`
  section 5 (sidebar, `PaneHeader`, `SettingsCard`s, sheets, Restart and Quit), and the three looks.
- Demo store and `--render-screenshots` for every tab and pane from day one.

Acceptance (offscreen renders checked by Codex against `docs/DESIGN.md`, plus pure tests):
- Sorting and filtering are pure functions on the store's snapshot with tests.
- Every tab has a loading state that says what it waits for, an empty state, and an error
  state that names the failed collector.
- Renders at the panel width show no wrapped or truncated labels with the longest synthetic
  app names and 5-digit values (`--stress`), in all three looks.
- Every glitch in `docs/LESSONS.md` section 4 is checked on the renders and absent.
- Settings: a malformed `config.json` is never overwritten and shows a problem in the pane; every
  number is bounded on load.
- Idle CPU with the panel closed stays within the budget in Quality criteria (perf.sh).

`/goal scripts/check.sh exits 0, MacMax --render-screenshots $TMPDIR/shots writes every shot in docs/SCREENSHOTS.md, Codex reviewed the renders and the diff and grep -cE "^(P0|P1|P2)" $SCRATCH/review-out.md prints 0, or stop after 50 turns`

### U8. History
- Swift Charts (system framework): CPU, memory pressure, swap, disk IO, network in and out for
  1 hour, 24 hours, 7 days, 90 days; per-app lines for the top 5; tap a spike to see the apps
  that held the resource then.

Acceptance:
- Query functions return points aligned to the chosen step with gaps where the app was not
  running (never interpolated across a gap).
- "Who held it then" for a time window returns the top 5 apps from stored rows, tested on
  synthetic data.

`/goal scripts/check.sh exits 0, renders of the History tab for 1h and 7d exist, grep -cE "^(P0|P1|P2)" $SCRATCH/review-out.md prints 0, or stop after 30 turns`

### U9. Actions and cleanup
- Quit app (graceful terminate request), end process (SIGTERM after re-checking pid and start
  time, same user only, a second press for SIGKILL), end a stale Claude Code session (the
  session process; its sidecars end with it), stop a Docker container (`docker stop <id>`).
- Cleanup from the cache rules in `docs/RULES.md`: scan, preview with sizes, Move to Trash
  only, protected paths never touched, re-check each path right before moving it.
- Every action is logged to the store with what it targeted and the result.

Acceptance:
- End process refuses when the start time changed since the snapshot (a reused pid) and when
  the target belongs to another user or is a system process.
- Cleanup never touches a protected path, including through a symlink, and never deletes
  permanently (a test asserts every removal goes through the Trash API).
- A path that changed between scan and move (replaced by a symlink, grew past its previewed
  size by more than 10 percent) is skipped and reported.
- No action exists outside the app: the CLI has no command that quits, kills, stops or moves
  anything, and the MCP server has no such tool (a test lists both command sets).

`/goal scripts/check.sh exits 0 with the U9 acceptance tests passing, grep -cE "^(P0|P1|P2)" $SCRATCH/review-out.md prints 0 (the review prompt names defect classes 1, 4 and 5), or stop after 40 turns`

### U10. CLI and MCP
- `macmax snapshot|apps|network|ip|audit|findings|history|mcp` with `--json`. The CLI reads
  the store read-only and runs collectors itself when the app is not running.
- `macmax mcp`: MCP over stdio, the tools in `docs/AGENT-API.md`, read-only, outputs labelled
  as machine data, argv already redacted.

Acceptance:
- JSON-RPC conformance on recorded requests: `initialize`, `tools/list`, each tool's schema
  validates its sample output, unknown tool and bad arguments give JSON-RPC errors.
- No tool can kill, quit, delete or write (a test lists tools and asserts the read-only set).
- Latency: `history` over 7 days at the default cadence answers within 200 ms on this Mac.
- The CLI exits 0 on success, 2 on CRIT findings for `audit` (as `mac-audit.sh` does), 1 on WARN.

`/goal scripts/check.sh exits 0, the MCP smoke test in scripts/acceptance.sh passes, grep -cE "^(P0|P1|P2)" $SCRATCH/review-out.md prints 0, or stop after 40 turns`

### U11. Updater, About, login item, notifications
- Update check by itself at launch and every 24 hours against GitHub's latest release, no
  `gh` needed. A newer release shows an arrow in the panel header and a notification once per
  version. Update installs on a press; "Install updates automatically" is a setting, off.
- About: who makes it, the repo, this build's version and source describe, standing against
  the latest release, Update. Login item only from an installed location (`/Applications` or
  `~/Applications`, see `docs/RELEASE.md`, install.sh).

Acceptance:
- Version standing (behind, latest, ahead, unknown) on a table of version and tag pairs,
  dirty and post-tag builds included.
- Update is offered only when running from exactly `/Applications/MacMax.app` or
  `~/Applications/MacMax.app` and behind a valid tag; the installer replaces the copy that is running.
- Update pressed twice starts one installer (the in-flight state lives in the store).
- The update log is opened with no-follow and refuses a symlink.

`/goal scripts/check.sh exits 0 with the U11 acceptance tests passing, grep -cE "^(P0|P1|P2)" $SCRATCH/review-out.md prints 0, or stop after 30 turns`

### U12. Release
- Everything in `docs/RELEASE.md`: `release.sh` with `--verify`, `install.sh`, signing per D1,
  `SHA256SUMS`, README with rendered media, `SECURITY.md` final, CI release-verify job, the
  first install on a second Mac (including a non-admin user, which installs to
  `~/Applications`), v0.1.0 published by the owner's choice.
- Public-repo hygiene before v0.1.0: branch protection on `main` (PRs, required CI), GitHub
  private vulnerability reporting on, a `gitleaks` scan of the whole history with no findings,
  `CONTRIBUTING.md` (build, the Codex-tests rule for maintainers, ASCII rule, no real data),
  issue and PR templates.

Acceptance: `scripts/acceptance.sh` exits 0 (see Measured by).

`/goal scripts/acceptance.sh exits 0 on tag v0.1.0 and the second-Mac install is recorded in the release notes, or stop after 40 turns`

## Quality criteria

**Code**
- Swift 6 strict concurrency; `MacMaxCore` has no UI imports; one `ProcessRunner` for every
  external command (argv only, own process group, TERM then KILL, timeout is failure, logged).
- No third-party packages. System frameworks only (Foundation, SwiftUI, AppKit, Charts,
  Network, SystemConfiguration, IOKit, SQLite3, ServiceManagement, UserNotifications).
- Files 500 lines or fewer; English identifiers, comments and logs; camelCase Swift, snake_case
  JSON and SQL; comments say why.
- Background loops start in the app's init, in-flight state lives in the store (skill invariants 1, 5).

**Tests**
- Codex writes the acceptance tests from this plan's Acceptance lines, before or alongside
  the code; the implementer never edits them. Hash them after Codex writes them and re-check
  before each commit. A red test is fixed in `Sources/`.
- Fixtures are synthetic or scrubbed captures: no real user names, hostnames, IPs (use
  RFC 5737 ranges 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24), tokens or paths.
- Live suites are gated by `MACMAX_LIVE=1` and run outside the Claude Code sandbox.

**Speed** (measured by `scripts/perf.sh`, 10 minutes, on an Apple Silicon Mac)
- Sampler at the 10 s default: average CPU of the app under 1 percent of one core with the
  panel closed, under 3 percent with the panel open and idle.
- Resident memory of the app under 150 MB after 24 hours of sampling.
- A full audit under 5 seconds (the shell script takes 30 to 50).
- MCP `snapshot` under 500 ms and `history` (7 days) under 200 ms while the app runs (database
  reads); with the app not running, `snapshot` under 3 s (it takes a 2-second network sample).

**UI**: every rule in `docs/DESIGN.md`, checked on offscreen renders in every review.

**Security**: trust boundaries, each with its check (full model in `SECURITY.md`):
1. Process argv, window titles, paths and names are untrusted text: redacted before storage,
   display or MCP output; MCP results are labelled data, never instructions.
2. Acting on another process: same user only, identity (pid, start time) re-checked right
   before the signal, confirmation in the UI, logged.
3. Deleting files: Trash only, protected list, symlinks resolved, re-checked before each move.
4. Network egress: only the IP endpoint and the GitHub releases API, each with connect and
   total timeouts; a failed lookup is `unknown`, never OK.
5. Updater: checksum from `SHA256SUMS`, and with Developer ID (D1) the new app's Team ID must
   equal the running app's before the swap; only for the installed copy in `/Applications` or
   `~/Applications`; log opened no-follow.
6. MCP and CLI: stdio only, no listening socket anywhere in MacMax, no write tools.
7. Privacy: no telemetry, no analytics; `~/.macmax` is 0700; the IP check can be turned off.

## Open decisions

| # | Decision | Options | Recommendation | Decided |
|---|----------|---------|----------------|---------|
| D1 | Signing | Ad hoc (like Bton) or Developer ID + notarization ($99/year) | Developer ID. MacMax asks for Full Disk Access; with ad hoc signing every update is a new app to TCC and the grant is lost, and the updater cannot check the Team ID. Keep publishing the reproducible ad hoc zip beside the signed one. | open (owner) |
| D2 | License | MIT, Apache-2.0, GPL-3.0 | MIT, like Bton. Mole (GPL-3.0) may be read for ideas, never copied. | MIT, owner 2026-10-25 |
| D3 | IP endpoint | Cloudflare `https://1.1.1.1/cdn-cgi/trace`, a self-hosted echo, off | Cloudflare by default (no account, plain text, IPv4 and IPv6), endpoint editable, a switch to turn the check off. README says what it sends. | open (owner) |
| D4 | Cleanup in v1 | Trash-only cache rules; or none | Trash-only with preview and protected list (U9). | open (owner) |
| D5 | Full Disk Access | Ask at first run; ask only when a feature needs it; never | Only when a feature needs it (sizing protected folders). Everything else works without it. | recommended |
| D6 | Minimum macOS | 14 or 15 | 14, like Bton. | recommended |
| D7 | Homebrew cask | Own tap now, later, never | After v0.1.0, in `danieltamas/homebrew-tap`. | open (owner) |
| D8 | Planning docs in the public repo | Publish all of `docs/`; keep PLAN, LESSONS and ARCHITECTURE local like Bton | Publish all: they are the contributor guide and hold nothing private (no client names, no real IPs). The GitHub repo already exists and is public, so the first push publishes them, and a README whose images do not exist until U7 (its status line says nothing is released). | open (owner) |
| D9 | App icon | The implementing agent draws `Brand/*.svg`; the owner supplies or commissions one | The owner supplies it or approves one of three SVG drafts the agent renders in U0, since the palette derives from it. | open (owner) |
| D10 | `mac-audit.sh` in this repo | Vendor it into `scripts/` (the owner's own work, MIT); keep it private | Vendor it, so parity runs for anyone and the port is verifiable. | open (owner) |
