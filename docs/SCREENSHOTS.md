# README screenshots

Every image in the README is rendered by the app itself from synthetic data. Nothing is captured
from a real screen: no `screencapture`, no Screen Recording permission, no real process names, IPs
or paths. This is how Bton's README images are made (`DemoShots.swift` in Bton's `main`).

## Command

```
scripts/bundle.sh --out "$SCRATCH/app"                         # a bundled build, for the real icon
"$SCRATCH/app/MacMax.app/Contents/MacOS/MacMax" --render-screenshots "$SCRATCH/shots"   # absolute path
cp "$SCRATCH/shots"/*.png docs/media/
```

Give the renderer an absolute path: the app has no permission to write into a relative one.
`--scale 3` renders the same set at 3x for the launch film's plates (`brag-output/`), not for the
README; the README set is 2x.

The flag is handled first thing in `MacMaxApp.init()`: it builds a demo store, renders, writes PNGs
and exits before the sampler, the database or any network call starts. Nothing is read from or
written to `~/.macmax`.

## Mechanism

- Each view is hosted in an `NSHostingView` inside a borderless `NSWindow` that is never ordered
  front; `layoutSubtreeIfNeeded()`; `RunLoop.main.run(until: now + 0.3)`; `cacheDisplay(in:to:)`
  into an `NSBitmapImageRep` at 2x; PNG.
- Not `ImageRenderer`: it leaves text fields and AppKit controls as placeholders and drops scroll
  content.
- An environment value `stillImage = true` makes pulses plain and rows already in place (no
  rise-in animation mid-frame).
- `--render-screenshots <dir> --all-looks` also renders every shot in all three looks with a
  `-solid-glass` and `-solid-glass-light` suffix, into a scratch dir for review, not for the README.
- `--render-screenshots <dir> --stress` renders with the longest synthetic names and the largest
  values (5-digit MB, 4-digit KB/s, a 40-character app name) to check that nothing wraps or truncates.

## Shot list (docs/media)

The README shows one wide composite per section: two panels, or a panel and a column of cards,
over the backdrop, each surface rounded (22 pt) and shadowed, 48 pt inset. The single shots are
rendered in the same run; they are the per-view sources (and, at `--scale 3`, the film's plates).

| File | What | Size (points) |
|------|------|---------------|
| `icon.png` | The app icon (`sips -s format png -z 256 256 Support/AppIcon.icns`, not rendered by the app), for the README header | 256 x 256 |
| `hero.png` | Overview and Network (1 hour) side by side | 926 x 860 |
| `findings-apps.png` | Findings and Apps side by side | 926 x 860 |
| `mac-cards.png` | The This Mac card and the Battery and heat card, with the Power sensor group open under its row | 926 x 652 |
| `network-leak.png` | Network (24 hours) and the identity card in the `leak` state | 926 x 860 |
| `cleanup-safety.png` | Cleanup, with the just-moved card, the last-cleanups card and the one permission prompt stacked beside it | 926 x 860 |
| `background-uninstall.png` | Background items with one item open, and Uninstall apps with one app selected | 926 x 776 |
| `downloads-folders.png` | Old downloads and Large folders | 926 x 483 |
| `history-pair.png` | History over the last hour and over the last week | 926 x 860 |
| `overview.png`, `apps.png`, `network.png`, `findings.png`, `cleanup.png`, `history.png`, `history-1h.png`, `history-7d.png` | One panel per tab: Overview (verdict WARN, two findings, vitals, identity `tunnel_ok`), Apps sorted by memory with the browser row expanded, Network (1 hour, eight apps), Findings (one CRIT, two WARN), Cleanup, History (24 hours, 1 hour, 7 days) with a memory spike and "who held it" open | 404 x 780 |
| `this-mac.png`, `battery-and-heat.png`, `leak.png`, `cleanup-results.png`, `cleanup-moving.png`, `large-folders.png`, `old-downloads.png`, `access-prompt.png`, `background-items.png`, `background-item-detail.png`, `uninstall-apps.png` | One card each: This Mac, Battery and heat, the identity card in the `leak` state, the just-moved and last-cleanups cards, a cleanup in progress, Large folders, Old downloads, the permission prompt, Background items closed and open, Uninstall apps | 404 wide |
| `settings-<pane>.png` | One per Settings pane (general, audit, network, cleanup, agent-access, permissions, about); `settings-audit.png` shows the rule list | 760 x 540 |

## Synthetic data (the demo store)

- Fixed clock: 2026-10-25 14:30 local, so relative times read the same in every render.
- Apps: made-up names with glyph icons drawn from SF Symbols: "Atlas Browser" (38 processes,
  5.6 GB), "Harbor Mail", "Northwind IDE", "Pixel Studio", "Tidal Notes", "Relay Chat". Two families
  MacMax recognizes appear by name, with generic glyphs and no logos: "Claude Code" (6 sessions, 3
  older than 7 days, 41 MCP sidecars) and "Docker" (VM with 2.3 GB compressed). No other real
  product names or icons.
- Machine: "MacBook Pro, 16 GB", 12 cores, uptime 9 days, swap 3.1 GB, compressor 24 percent, disk
  18 percent free.
- Identity: VPN "Outline" connected, public IP 203.0.113.20 (DE), ISP IP 198.51.100.7 (RO); the
  `leak` shot uses 198.51.100.7 for both. Only RFC 5737 addresses (192.0.2.0/24, 198.51.100.0/24,
  203.0.113.0/24), ever.
- History: generated from a seeded function (no randomness at render time) so every render is
  byte-stable on the same machine.
- No user names, home paths, hostnames, emails or tokens anywhere, including redacted command lines
  (use `/Applications/Northwind IDE.app/...` and `--token [redacted]`).

## Rules

- Update the screenshots in the same commit as the UI change they show.
- After rendering, open each PNG and check it against `docs/DESIGN.md` and the glitch list in
  `docs/LESSONS.md` section 4 before committing; the renders are also what Codex reviews.
- Renders check layout only. A change is not done until the live panel was looked at, or the
  report says "UI not exercised live".
- PNGs are committed as rendered (no external optimizers that change pixels); keep each under 1 MB.

## The README and its pictures

`scripts/check.sh` fails when the README shows a `docs/media` image that does not exist or names an
`install.sh` option the script lacks. A feature that reaches the app is moved from the README's
"Coming next" to "What you get" with its shot in the same commit (docs/PLAN.md, U13..U16).
