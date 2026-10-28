# Lessons carried over from Bton

Bton (github.com/danieltamas/bton) is the owner's first menu bar app, built 2026-10-19..25 from
v0.1 to v0.5.3 on the same stack MacMax uses. Every lesson below cost at least one owner
correction, one Codex P0-P2 finding or one broken release. They are rules for MacMax from the
first commit, not ideas for later. Where a rule names a Bton file, copy the current version from
Bton's `main` and rename it; do not rewrite it from memory.

How to use this file: read it once before U0; re-read the section for the unit you work on; put
the "UI glitch" list and the defect classes into every Codex review prompt.

## 1. Working rhythm

- One change = spec (the unit's Acceptance lines) -> Codex writes the acceptance tests -> implement
  -> build and the full suite -> Codex reviews the diff -> fix P0, P1, P2 -> Codex re-reviews the
  fixes (fixes introduced new findings several times) -> commit -> install from source -> tell the
  owner in one or two lines what to try. The owner tests the real app.
- Commit messages say what the user gets, not what the code does: "a quit app's traffic stays in
  the hour view until the hour ends", not "refactor NetworkStore".
- Keep `docs/PLAN.md`, `README.md` and the screenshots in step with every change, in the same commit.
- Commit and push only as the owner authorized. In Bton the owner authorized every finished
  change; get that said again for MacMax rather than assuming it.
- Releases happen only when the owner picks one; the version number is the owner's call (they
  took a minor bump over a proposed patch once).
- Decisions go to the owner as choices with a recommendation, never as open questions. Do not stop
  for confirmations the plan already covers.
- Root cause before fixing, checked against the owner's evidence (the screenshot, the log, the
  actual state). Claims made without checking were wrong several times ("codex is the Superset
  copy", "there is a second Mac", "login items are matched by signature").
- Never answer a bug with "turn the feature off". When antivirus software broke Bton's worktrees,
  "disable the antivirus" was rejected: the fix was to detect and route around the quarantined file.
- Re-read the owner's earlier requests before recommending. A recommendation that contradicts a
  decision the owner already made is a defect.
- Warn before anything that prompts the owner: an admin password (`sudo`, `sfltool`), a keychain
  dialog, a TCC prompt (Full Disk Access, notifications, Apple Events). An unannounced password
  prompt from an agent running `sfltool dumpbtm` was a real complaint.
- Treat the owner's credential stores as read-only. A keychain search-list "restore" once broke
  `gh`'s token.
- Test on someone else's Mac early. The first teammate install of Bton found, in one hour, what the
  owner's Mac hid: a tool in a custom Homebrew prefix, an installer that checked the shell's PATH
  instead of the app's, an nvm-installed CLI whose `#!/usr/bin/env node` found no node, a CLI that
  crashed instead of printing a sentence. For MacMax: test on a Mac with no developer tools, no
  `/opt/homebrew`, no Docker, no VPN, and a non-admin user.

## 2. Plumbing that must be right from U0

- **Background work starts in `App.init()`**, never in a view's `.task`. A panel's content exists
  only while it is open: Bton's loop first started when the user clicked the icon.
- **`MenuBarExtra` with `.menuBarExtraStyle(.window)`** (a SwiftUI panel, not an NSMenu), and a
  `Settings` scene opened with `@Environment(\.openSettings)` after `NSApp.activate()`. A `Window`
  scene may open by itself at launch; `Settings` never does and gives Cmd-, for free.
- **Panel size**: 404 points wide; height `min(780, visibleFrame.height - 40)` of the screen under
  the menu bar. A fixed 780 was cut off on a 13-inch screen.
- **One `@MainActor ObservableObject` store (`@Observable` is macOS 14).** Anything that must survive closing the panel or switching
  tab lives in it: in-flight flags, the open tab, the open sheet, a running update. Views hold only
  ephemeral layout state.
- **Never name the CLI target like the app in another case** (`macmax` vs `MacMax`): the
  case-insensitive filesystem collides. The target is `MacMaxCLI`; the installer names it `macmax`.
- **A Finder-launched app has almost no PATH.** Resolve every external tool through one
  `Executables` helper: inherited PATH plus `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`,
  `/usr/bin`, `/bin`. Prefer absolute system paths (`/usr/bin/nettop`, `/usr/sbin/scutil`) for
  stock tools. Docker is optional: absent means "Docker not installed", never an error.
- **One `ProcessRunner` for every external command**: argv array (never a shell string), stdin
  `/dev/null`, stdout and stderr drained concurrently (a full 64 KB pipe blocks the child forever),
  child is its own process-group leader and the group is signalled (grandchildren die too, even
  after the leader is reaped), watchdog TERM then KILL after 2 s, a fired deadline makes the result
  a failure even if the child then exits 0, task cancellation kills the group. Log the command and
  its timeout before running it, and name the stuck command in the timeout error.
- **Long-lived children** (MacMax's `nettop` stream) are supervised: started by the store, killed
  with the app, restarted with backoff, and their death is shown as a failed collector.
- **App home** `~/.macmax` (or `$MACMAX_HOME`), mode 0700 even when it already exists. A second
  instance with another home shares nothing (used by tests).
- **Bundle-only APIs** (`UNUserNotificationCenter`, `SMAppService`) trap under `swift run`: guard
  with `Bundle.main.bundleIdentifier != nil`.
- **Login item** only from an installed copy (`/Applications/` or, for MacMax, `~/Applications/`), registered once; set the "registered" default only on
  success, so a user who turns it off in System Settings stays off.
- **Notifications** by diffing the previous state with the new one; nothing on the first tick after
  launch; stable identifiers and a dedupe set.
- **Relaunch** (Restart in the footer): spawn `/bin/sh -c 'while kill -0 "$0"; do sleep 0.2; done;
  /usr/bin/open "$1"' <pid> <bundle>` then `NSApp.terminate(nil)`. `open` while the app still runs
  only brings the old copy forward. Guard that the bundle ends in `.app`, else beep.
- **Pick the bundle id before anyone else installs**: `ro.danieltamas.macmax`. Bton changed its id
  after the first installs and every user got a second, orphan login item and a second
  notification-permission prompt; the app cannot remove another id's login item.
- **Swift 6.2.3 compiler crash** (signal 6): a `@MainActor` method passed point-free as a closure,
  e.g. `Binding(get:set: setX)`. Wrap it: `set: { setX($0) }`.
- **macOS 13 availability**: check every API. `@Observable`, `@Bindable`, `openSettings`, the two-value
  `onChange`, `plotFrame` and the `.isToggle` trait are macOS 14: the models are `ObservableObject`, views
  take them as `@ObservedObject`, and a macOS 14 API lives behind `#available` with the macOS 13 path
  beside it. `Decimal.formatted(notation:)` and `pointerStyle` are macOS 15 (see the cursor glitch below).

## 3. CPU and lag: MacMax must not be the thing slowing the Mac

Bton idled at 23-40 percent CPU with nothing running; the owner felt lag before anyone measured.
A performance app that costs performance is dead on arrival, so these are hard rules:
- **No perpetual SwiftUI animation.** A `repeatForever` pulse redraws the whole panel at the
  display's rate for as long as it exists. Pulses run in Core Animation (an `NSViewRepresentable`
  over a `CAAnimationGroup`), added only while something is live and the panel is visible.
- **Pause when hidden.** Observe `NSWindow.didChangeOcclusionStateNotification` and publish
  `occlusionState.contains(.visible)` as an environment value (`panelVisible`), deferred with
  `DispatchQueue.main.async` since AppKit may move the view mid-layout. Live charts, pulses and
  per-second redraws stop while the panel is hidden. The sampler keeps sampling; the UI does not.
- **Relative times redraw once a minute**: `Text(date, style: .relative)` redraws every second under
  an hour. Use a `TimelineView(.everyMinute)` label; for live counters `Text(start, style: .timer)`.
- **The menu bar icon is a still image.** SwiftUI animations never run in the status item. Draw
  frames into a 22x22 `NSImage` in an `ObservableObject` icon model; a template image at rest. Never a
  perpetual icon animation (it re-renders on every display every frame). A live readout in the
  menu bar ("CPU 34%") updates at most once per sampler tick and only when its text changes.
- **Heavy work off the main actor**: parsing, SQLite reads for charts, rollups. Never build a
  file-touching object inside a view body.
- **Measure before and after** with `top -pid`, `sample <pid> 5`, and `scripts/perf.sh`; the budgets
  are in PLAN.md's Quality criteria. Look for strays the app spawned (a `nettop` left behind by a
  crash) before blaming SwiftUI.

## 4. UI glitches Bton shipped, and the rule each one set

Every item here reached the owner's screen. Check each one on the offscreen renders in every UI
review (paste this list into the review prompt).

| Glitch in Bton | Rule for MacMax |
|----------------|-----------------|
| Labels wrapped mid-word: "Canc el", "Merge d" | Every label and button title is `.lineLimit(1)` with `.fixedSize()`; the content around it yields. Check at the panel width with the longest synthetic names. |
| Cost "$1234.56" overflowed its tile; tiles sized for a day broke at week totals | Numbers get room for their largest realistic value; compact them by hand ("1.2K", "3.4 GB", "812 KB/s"); tiles sized for the 90-day maximum. |
| Tabs were hard to see; the active tab did not read at a glance | Tabs in a floating island with a matched-geometry active capsule (accent fill and ring). When counts no longer fit, `ViewThatFits` falls back to showing only the open tab's count. |
| The active tab's stroked outline showed a gap in its bottom edge in the live panel (not in renders) | Draw thin outlines as a filled even-odd ring (Bton's `CapsuleRing`), never `strokeBorder` on a capsule at fractional widths. |
| The hand cursor flickered back to the arrow over buttons on macOS 15 | `pointingHandCursor()` uses `pointerStyle(.link)` on macOS 15 and later, and the `onContinuousHover` fallback only on 14. Set it once in the shared press style and card, never per view. |
| Cards that open something on click showed the arrow cursor and did not lift | Everything clickable shows the hand and gives hover feedback: `HoverCard` lifts and shows an accent edge. Static content never does. |
| A pill button disabled by its parent's `.disabled` still looked enabled | Components read `@Environment(\.isEnabled)` and dim themselves. |
| A failure reason squeezed the row's title and author into a sliver | Long secondary text (a reason, a path, a command line) runs the card's full width on its own line under the row. |
| Pressing Merge, Run now or Update showed nothing until the next refresh | Every press shows state at once: "Quitting...", "Moving to Trash...", "Checking...", a saved chip. The in-flight flag lives in the store. |
| Switching tabs reset an in-flight button; Update pressed twice ran two installers | In-flight state lives in the store, keyed by a stable identity, never in a view. The idempotent operation is guarded, not just the button. |
| Start buttons stayed visible on a row an agent was already working; a second press started it again | No second start while something works. Button visibility uses the same predicate the engine uses to act. |
| A pill that looked pressable only opened a web page | A thing that looks pressable acts in the app. A link looks like a link (an arrow-up-right glyph). |
| "Nothing here" showed before the first read finished | Every list says what it waits for ("Reading network usage..."), then shows what it has as soon as it has it. An empty state is a glyph, one line, one hint. |
| "Your move:" on a card confused the owner | Label things by what the user does next, in plain words ("Quit to free 2.1 GB"), never internal jargon. |
| A badge counted "the 30 we fetched" | Counts mean something: "3 new since this morning", not "the rows we happened to load". |
| Lists in fetch order; merged items oldest first | Newest or largest first, stable sort, paginated in pages of 25 with "Show N more", searchable. |
| A popover acted on data that had changed since the last refresh | Re-read right before any action from a popover or confirmation, and say so if it changed ("This process has ended; nothing was done"). |
| A per-second relative time and a perpetual pulse made the panel lag | Section 3. |
| `ImageRenderer` screenshots showed placeholder text fields | Offscreen renders use `NSHostingView` in a never-shown window and `cacheDisplay` (`docs/SCREENSHOTS.md`). |
| Renders looked right but the live panel did not (the tab ring gap) | Renders check layout only. Install the build and look at the live panel before calling a UI change done; say "UI not exercised live" when that did not happen. |

## 5. Settings: structure and rules

The owner rejected "open the config file" on day one: every setting is editable in the app, saved
as it changes, and the app re-reads its config file before every write (a hand edit is never lost;
a file that does not parse fails closed with a visible problem, never a silent reset).

Settings is a separate window (the `Settings` scene), structured like Bton's:
- **Window** minimum 760 x 540, the app's backdrop, the theme's color scheme.
- **Sidebar** 196 points wide on a darker canvas: an eyebrow "Settings", then one row per pane
  (a 24-point glyph tile tinted in the pane's own hue when selected, the pane's name, the selected
  row on a core-colored rounded card with a hairline). At the bottom of the sidebar: Restart and
  Quit (a menu bar app has no Dock menu, so they must be in the footer of the panel and here).
- **Content** scrolls (indicators hidden), padding 28, keyed by the selected pane so it cross-fades
  on switch with the app's spring. The selected pane lives in the store, so the panel can open
  Settings straight to a pane ("Turn on in Settings" opens Network).
- **Every pane** starts with a `PaneHeader` (an eyebrow in the pane's hue, a title, one line on what
  the pane does) followed by `SettingsCard`s: the setting's name and one line on why it matters,
  the control below. Choices among a few values are `SegmentChip`s, text is a `GlassField`, a menu
  is a `MenuField`, a problem is a `ProblemText` under the control. Toggles say what happens when on.
- **"New X" and edits are sheets** (a modal), never a separate screen; quick actions from the
  panel open in place in the panel, never by jumping to Settings.
- **Defaults are generic and conservative**; anything that suits only the owner is off by default,
  and the owner's names, paths, IPs and VPN names never appear in code, fixtures or screenshots.

MacMax's panes are listed in `docs/DESIGN.md`.

## 6. About and updates

- About shows who makes the app and why, the repo and "Report an issue", the owner's links, this
  build's version line (`v0.3.1 + 2 commits (abc1234), built from source, uncommitted changes`,
  selectable), and its standing against the latest release (latest, behind with "Update to vX",
  ahead, unknown with the reason), plus "Check again".
- One release check shared by About and the panel header (the header shows an arrow when a newer
  release is out), asking GitHub at most every 15 minutes, never on every view appearance.
- Update only from the installed copy (`/Applications/MacMax.app` or `~/Applications/MacMax.app`), only when behind a valid tag. The updater is a
  store-level singleton. Its log opens with no-follow and refuses a symlink.
- The bundled installer must stop the app that launched it: Bton's `pkill` skipped its own ancestor
  and Update never restarted the app. The installer waits until the old app is gone, then opens the
  new one.
- Details in `docs/RELEASE.md`.

## 7. Themes

Bton ended with three looks chosen under General: its own dark double-bezel look, Solid Glass
(neutral grey panes lit at the edge, near-white ink for what asks to be pressed) and Solid Glass
Light. A color means the same thing in every look. MacMax ships the same structure from U0 (copy
`Looks.swift`, `Theme.swift`, `Components.swift`): `Look` enum, one `Palette` per look, a `Finish`
(bezel or pane), and semantic color maps used everywhere a meaning appears. Every look is rendered
for the README check, and every new view is checked in all three.

## 8. Build, release and install

- Always build with an explicit `--scratch-path` outside the repo. After another agent ran `swift
  test` in its own sandbox, `.build/build.db` went read-only and SwiftPM silently ran a stale test
  binary. Check that the test count grew after adding tests.
- `swift`, `gh`, `codesign` and `codex` fail inside the Claude Code Bash sandbox: run them with the
  sandbox off. `open` and `osascript` are blocked there: give the owner the command.
- Releases are reproducible: pinned Xcode (`Support/toolchain`), `git archive` build, fixed
  timestamps, sorted zip entries, `--verify` builds twice and compares. That holds for the ad hoc
  zip only: a certificate signature carries its signing time, so the signed zip users install is
  the ad hoc build re-signed with the pinned certificate (MacMax 0.4.1). The build number came from
  clone depth once; a shallow clone is refused. Toolchain rpaths are stripped.
- `release.sh` takes minutes: never behind a button with a 120-second timeout.
- The README's one-line install works only once the repo is public and the release has its zip and
  `SHA256SUMS`: after publishing, run the public path once.
- `install.sh`: everything in functions and `main "$@"` on the last line (a truncated download
  runs nothing); every `curl` has `--connect-timeout 20 --speed-limit 1024 --speed-time 60` (a
  stalled download hung Update forever); exactly one valid checksum line; a lock that survives a
  crashed installer; swap through `.new` and `.old` with restore on failure.
- The agent session's hook blocks `curl | bash`: run the repo's `./install.sh` (same file).

## 9. Defect classes to check in every review

Twelve mechanisms produced most of Bton's P0-P2 findings; a first fix usually closed the named case
and missed its sibling path (the CLI path, the helper path). When fixing one, grep for its siblings.
1. **Fail-open on error, unknown or partial read.** Every read has three outcomes: present, absent,
   failed. Only a confirmed state may permit an action; failed or unknown skips it and says so.
   Display may keep the last good value, marked stale; no action may rely on it.
2. **Ownership released while work still runs.** (MacMax: a supervised child marked stopped while
   its process group lives.)
3. **Timeouts that do not kill the child tree.**
4. **TOCTOU: the checked state is not bound to the action.** (MacMax: a pid ended by signal must
   still have the start time the user saw; a path moved to Trash must be the file that was scanned.)
5. **Double start and races**: in-flight flags in the store, one serial writer per file.
6. **UI state lost on navigation or reload**: rows resolve by stable key, never by index.
7. **Hardening by denylist**: allowlist what the MCP server and the cleanup may do.
8. **Untrusted text trusted as data or authority**: process names, argv, window titles and paths
   are attacker-controllable; strip terminal escapes and invisible characters before display;
   redact secrets before storage.
9. **File-write safety**: `O_CREAT|O_EXCL|O_NOFOLLOW` in a 0700 directory, stage then rename.
10. **Destructive operations without proof of state** (MacMax: cleanup).
11. **Persistence order and crash loss**: write intent, act, mark done.
12. **Numeric and input validation**: bound every setting before arithmetic (Bton crashed on
    `60 * timeoutMinutes`), total parsers, no force-indexing, exact threshold comparisons.
Also: docs that promise more than the code enforces (fix the claim or the code).

## 10. What Bton still gets wrong (do not copy)

From Bton's reconciled audit at v0.5.3: identity by pid alone (store start time; MacMax must),
hand-edited config decoded without range validation (validate on load), a fixed-rate GitHub poll
with no backoff on 403/429 (MacMax's update check backs off), events that start and end within one
refresh never notify (diff by event, not by state), logs and caches that grow without limit
(MacMax bounds its database and logs from U5), no UI tests (offscreen renders reviewed every
change, plus pure tests for every sort, filter and label function).
