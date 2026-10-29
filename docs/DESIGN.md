# MacMax design standard

Set before any view is written (Bton's first UI was called "rudimentary" and its standard was set
after the fact; see `docs/LESSONS.md` section 4). Every UI review checks the offscreen renders
against this file and the glitch list in LESSONS.md.

## Foundations (copied from Bton, renamed)

- `Theme.swift`, `Looks.swift`, `Components.swift` from Bton's current `main`. Keep `Backdrop`,
  `Bezel`, `HoverCard`, `RowStack`, `EmptyState`, `Eyebrow`, `GlyphDisc`, `Chip`, `PillButton`,
  `PressStyle`, `PulseDot` (Core Animation), `RelativeTime`, `CapsuleRing`, `AppControls`,
  `pointingHandCursor()`, and the Settings parts (`PaneHeader`, `SettingsCard`, `SegmentChip`,
  `GlassField`, `GlassEditor`, `MenuField`, `FieldLabel`, `ProblemText`).
- Three looks under Settings > General: **MacMax** (the default, dark double bezel, hues from the
  app icon), **Solid Glass**, **Solid Glass Light**. Each look is a `Palette` plus a `Finish`.
- Type scale: eyebrow 9.5 semibold uppercase tracking 1.4; row title 13 medium; meta 11; stat 26
  rounded; numbers in tables `.monospacedDigit()`.
- Motion: springs only (`spring 0.42/0.82`, `snappy 0.28/0.86`, `gentle 0.7/0.9`). Nothing linear,
  nothing perpetual in SwiftUI.
- Custom glyphs and SF Symbols, never emoji. App icons of the apps in lists come from
  `NSWorkspace.shared.icon(forFile:)`, cached per bundle path.

## One hue per meaning

Semantic maps live in `Theme` and are used everywhere the meaning appears (tiles, rows, charts,
the menu bar icon, notifications). Values are set per palette; names are fixed:

| Meaning | Token | Used for |
|---------|-------|----------|
| Healthy | `ok` | Verdict OK, tunnel OK, a rule that passed |
| Warning | `warn` | Verdict WARN, a finding at WARN |
| Critical | `crit` | Verdict CRIT, leak, a finding at CRIT |
| Unknown | `unknown` | A failed collector, an unknown verdict; never green |
| CPU | `cpu` | CPU tiles, chart lines, the CPU sort |
| Memory | `memory` | Memory, swap, compressor, pressure |
| Disk | `disk` | Disk free, IO |
| Download | `netIn` | Bytes in |
| Upload | `netOut` | Bytes out |
| Brand | `brand` | Accent, the active tab, selection. In the MacMax look the solid hue is `teal` and the gradient runs teal to green (the other looks set their own neutral values). The icon's amber appears only as the backdrop light (`dialLight`), never in the gradient, on a control or on a status, where it would read as WARN |

A verdict color is never used for a resource, and a resource color never signals health.

## The panel (MenuBarExtra, `.window`)

404 points wide; height `min(780, visibleFrame.height - 40)`. Structure top to bottom:
1. **Header**: the app glyph, "MacMax", the verdict chip (OK, WARN, CRIT, unknown), the time of the
   last audit (once a minute), an update arrow when a newer release is out, a gear that opens Settings.
2. **Tab island** (floating, matched-geometry active capsule with a `CapsuleRing` outline):
   Overview, Apps, Network, Findings, History. Badges: Findings shows its count in the verdict hue;
   when counts do not fit, only the open tab's count shows.
3. **Content** for the tab, scrolling.
4. **Footer**: the sampler state ("Sampling every 10 s", or what failed), Restart and Quit. While
   GitHub says the user's `gh` account has not starred MacMax, a glowing gold "Star on GitHub" capsule
   comes first (10 pt before the sampler state, which truncates before it does). The glow is a Core
   Animation pulse, paused while the panel is hidden and under Reduce Motion. A press stars it through `gh`
   ("Starring..." with a spinner, disabled); on success the capsule goes and the answer is remembered
   in `config.json`, and on failure it stays. The capsule never changes the footer's height and has no
   close button.

### Overview
- **Verdict card**: the verdict in words ("2 things are slowing this Mac"), the top findings as one
  line each with their action pill, "Run audit now" (shows "Auditing..." at once).
- **Vitals tiles** (2 x 3): CPU, memory pressure, swap, disk free, network in, network out. Each
  tile: the value, a 1-hour sparkline, the hue of its resource, a warn or crit edge when a rule fires
  on it. A tile opens the matching tab, sorted by that resource.
- **Identity card**: public IP and country, VPN service name and state, ISP IP when a VPN is up,
  and the leak verdict chip (`tunnel_ok` green "Traffic goes through Outline", `leak` red "Traffic
  is leaving outside the VPN", `no_vpn` neutral, `unknown` grey with the reason). Copy buttons on
  the IPs. A switch-off note when the IP check is off.
- **Top consumers**: three rows, the heaviest app by CPU, memory and network right now.

### Apps
- One row per app (grouping rules in `docs/ARCHITECTURE.md`): icon, name, process count, CPU %,
  memory, disk read+write per second, network in+out per second. A sort segment (CPU, Memory, Disk,
  Network), a search field (name, bundle id, pid), and a filter row (All, Apps, Background, Claude
  Code, Docker).
- Expanding a row shows its processes (name, pid, user, CPU, memory, Rosetta badge, redacted command
  line on its own full-width line) and the actions it allows (`docs/RULES.md`, actions).
- Chrome's row carries a note: "Chrome's own Task Manager (Window > Task Manager) shows memory per
  tab; macOS does not expose it to other apps."

### Network
- Segment: Now, 1 hour, 24 hours. Rows per app: icon, name, in, out (rate for Now, totals for the
  windows), a small two-color bar. Interface totals at the top (Wi-Fi or Ethernet, the tunnel).
- The identity card again, with history: "IP changed at 14:02 from 198.51.100.7 (RO) to
  203.0.113.20 (DE)".
- Expanding an app lists its current connections on demand (remote host, port, state), read once
  on expand, with a refresh button.

### Findings
- Each finding: severity chip, title in plain words, the evidence (the numbers that fired it), why
  it matters (one line), and its action: a pill that acts in the app (Quit, End session, Stop
  container, Review cache cleanup, which opens the Cleanup tab) or, when nothing can be done from the app, the exact next step
  ("Reboot to reset the swap file"). Snooze for 24 hours. Resolved findings from today, greyed.

### History
- Range segment: 1 hour, 24 hours, 7 days, 90 days. Charts (Swift Charts): CPU, memory pressure and
  swap, disk IO, network in and out. Selecting a point shows the top 5 apps at that moment. Gaps
  where MacMax was not running are gaps.

### Menu bar icon
- A template glyph at rest. Tinted `warn` or `crit` when the verdict is WARN or CRIT, `unknown`
  when the last audit could not run. Optional live text (Settings > General): one of CPU %, memory
  pressure, network rate, or the public IP's country code, updated only when its text changes.

## Settings window

Structure per LESSONS.md section 5 (sidebar 196, window minimum 760 x 540, `PaneHeader` then
`SettingsCard`s, Restart and Quit at the foot of the sidebar). Panes, in order, each with its hue:

| Pane | Hue | Cards |
|------|-----|-------|
| General | brand | Sampling interval (5, 10, 30, 60 s); Menu bar text (none, CPU, memory, network, country); Theme (three looks); Open at login; Install updates automatically (off; shown only with Developer ID signing, `docs/RELEASE.md`); Data folder (Show in Finder, size, "Clear history" with confirm) |
| Audit | warn | Schedule (off, 1, 4, 12, 24 hours; on critical memory pressure); Notify on (CRIT only, WARN and CRIT, never); Rules: each rule with its threshold editable in place, its default shown, and a reset; a rule can be turned off |
| Network | netIn | Public IP check (on or off, with what it sends); Endpoint (default Cloudflare trace, editable, validated); Physical interface for the ISP IP (Automatic or a list); VPN services found, each with its state |
| Cleanup | disk | Protected paths (add by choosing a folder, remove). The cleanup itself (rules with sizes, Move to Trash, Large folders, Docker and Time Machine commands, Last cleanups) is the Cleanup tab of the panel |
| Agent access | brand | The MCP command with a copy button (`claude mcp add macmax -- ~/.local/bin/macmax mcp`); the tool list and that every tool is read-only; recent MCP calls (tool, time, size) |
| Permissions | unknown | Full Disk Access (state, what it unlocks, Open System Settings, a re-check button); Notifications (state, Open System Settings) |
| More apps | memory | The owner's other open source tools in two groups, In the menu bar (Bton, RMJ) and In the terminal (Axon, Run.dev, Cloak): each a card with its own icon (from the registry, glowing in its hue; full-bleed marks inset and rounded), name, platform chip, pitch, one line, Website and GitHub links (and Open when the Mac app is installed), a status line (the latest release and when it came out, In development when there is none; for Bton and RMJ the installed version, up to date or behind, or Built from source), and its install command with a copy button. The list, copy, icons and versions come from the app registry (github.com/danieltamas/registry): the bundled copy, then the last one read, then a fresh read when the pane opens (at most hourly) or on the refresh button, with progress while reading. The header says when the list was checked, how many apps need a newer MacMax, and why a refresh failed (the cards then keep the last good list). No install command for an app with no release yet (RMJ) |
| About | neutral | Per LESSONS.md section 6 |

Every card follows the Settings rules: saved as it changes, a problem shown under the control,
editors in sheets, nothing that needs a config file.

## States every view has

- **Loading** says what it waits for ("Reading processes...", "Asking Cloudflare for your IP...").
- **Empty** says what empty means ("No app used the network in the last hour").
- **Failed** names the collector and the reason, and what still works ("Network usage is unavailable:
  nettop exited. Retrying in 30 s.").
- **Stale** values (last good snapshot after a failure) are shown dimmed with their age.

## Copy

- Plain words, short, what the user gets or does next. No jargon on the surface ("memory pressure"
  is fine, `kern.memorystatus_level` lives in the evidence line).
- Plain ASCII punctuation in every string: `-`, `"`, `'`, `...`. `scripts/check.sh` enforces it.
- No vendor or AI attribution anywhere in the app. Naming the agent tools MacMax watches (Claude
  Code, Docker) is identification and fine.

## Checking a UI change

1. `MacMax --render-screenshots <dir>` renders every tab and Settings pane in all three looks, at the
   panel width, with the longest synthetic names and 5-digit values (`docs/SCREENSHOTS.md`).
2. Codex reviews the renders against this file and LESSONS.md section 4.
3. Install from source, open the live panel, and look at the same views. If that was not possible,
   say "UI not exercised live" in the report.
