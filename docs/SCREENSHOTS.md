# README screenshots

Every image in the README is rendered by the app itself from synthetic data. Nothing is captured
from a real screen: no `screencapture`, no Screen Recording permission, no real process names, IPs
or paths. This is how Bton's README images are made (`DemoShots.swift` in Bton's `main`).

## Command

```
scripts/bundle.sh --out "$SCRATCH/app"                         # a bundled build, for the real icon
"$SCRATCH/app/MacMax.app/Contents/MacOS/MacMax" --render-screenshots docs/media
```

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

| File | What | Size (points) |
|------|------|---------------|
| `icon.png` | The app icon, for the README header | 128 x 128 |
| `hero.png` | Overview and Network panels side by side over the backdrop, slight overlap | about 860 x 640 |
| `overview.png` | Overview: verdict WARN with two findings, vitals tiles, identity card (`tunnel_ok`) | 404 x panel height |
| `apps.png` | Apps sorted by memory, the browser row expanded to its processes | 404 x panel height |
| `network.png` | Network, 1 hour window, eight apps, interface totals | 404 x panel height |
| `findings.png` | Findings: one CRIT (Docker VM compressed), two WARN (stale agent sessions, swap) | 404 x panel height |
| `history.png` | History, 24 hours, a memory spike with "who held it" open | 404 x panel height |
| `leak.png` | The identity card in the `leak` state | 404 x card height |
| `settings.png` | Settings > Audit with the rule list | 760 x 540 |
| `agent.png` | Settings > Agent access with the MCP line | 760 x 540 |

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
