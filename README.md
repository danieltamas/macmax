<p align="center">
  <img src="docs/media/icon.png" width="112" alt="MacMax">
</p>

<h1 align="center">MacMax</h1>

<p align="center">
  <b>Why is my Mac slow? One answer, from the menu bar.</b><br>
  MacMax watches CPU, memory, disk and network per app, audits your Mac on a schedule,<br>
  and tells you what to close, what to clean and whether your VPN is really on.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/agents-MCP%20read--only-3B82F6" alt="MCP read-only">
  <img src="https://img.shields.io/badge/license-MIT-22C55E" alt="MIT">
</p>

> **Status:** in development, nothing is released yet. The install line below works from v0.1.0.

```bash
curl -fsSL https://raw.githubusercontent.com/danieltamas/macmax/main/install.sh | bash
```

To update, press Update in Settings, About when a newer release is out (an arrow in the menu's
header says one is), or run the same line again.

<p align="center">
  <img src="docs/media/hero.png" alt="MacMax" width="860">
</p>

## A slow afternoon, explained

Your fans spin, typing lags, Chrome takes a second to switch tabs. You click the menu bar icon:

| | |
|---|---|
| **CRIT** | Docker's VM has 2.3 GB of its memory compressed by macOS: it spins waiting for its own RAM. **Stop idle containers** |
| **WARN** | 3 agent sessions older than 7 days still hold 1.8 GB and 41 helper processes. **End them** |
| **WARN** | 3.1 GB of swap in use: the working set does not fit in 16 GB. Atlas Browser holds 5.6 GB |
| **OK** | Traffic goes through your VPN as 203.0.113.20 (DE); your ISP address stays hidden |

Two presses later the swap is draining. Nothing was guessed: every finding names the numbers that
fired it.

## What you get

**One verdict.** OK, WARN or CRIT in the menu bar, and in the panel the few things that matter,
each with its evidence, why it slows the Mac, and the press that fixes it.

**Every app's real cost.** CPU, memory (the number Activity Monitor shows), disk and network,
grouped by app: Chrome's 38 helpers are one row, an agent session and its helper processes are one
row, Docker's VM is one row. Expand a row to see its processes.

**Traffic in and out, per app.** Who is uploading right now, who used the most in the last hour or
day, and the interface totals. MacMax reads the counters macOS already keeps; it does not capture
or inspect packets.

**Your IP and your VPN, checked.** The address the internet sees, its country, and whether your VPN
(Outline, Tailscale, WireGuard and others) is connected and actually carrying your traffic. If the
VPN says connected but your ISP address still shows, MacMax says so in red.

**A deterministic audit on a schedule.** The same checks every few hours, with fixed thresholds
you can edit: uptime, load, swap, the memory compressor, memory pressure, stale sessions, Docker,
runaway system daemons, disk space and IO, crash reports, launch items, thermal throttling, and
tools running under Rosetta. Same machine state in, same findings out.

**Cleanup that cannot hurt you.** Caches that rebuild themselves (app caches, Xcode DerivedData,
npm, pip, Homebrew), previewed with sizes, moved to the Trash only after you confirm. Your
documents, keychains, mail and anything with a `.git` folder are never touched.

**History.** CPU, memory, swap, disk and network for the last hour to the last 90 days. Point at a
spike to see which apps held the Mac then.

**Ask your coding agent.** `macmax mcp` lets Claude Code (or any MCP client) read the same data:
"what is slowing my Mac?" gets an answer from real numbers. Every tool is read-only; quitting or
cleaning stays a press in the app.

<table>
  <tr>
    <td width="50%"><img src="docs/media/apps.png" alt="Apps"></td>
    <td width="50%"><img src="docs/media/network.png" alt="Network"></td>
  </tr>
  <tr>
    <td align="center"><b>Apps</b>: every app's CPU, memory, disk and network</td>
    <td align="center"><b>Network</b>: traffic per app, your IP and your VPN</td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/media/findings.png" alt="Findings"></td>
    <td width="50%"><img src="docs/media/history.png" alt="History"></td>
  </tr>
  <tr>
    <td align="center"><b>Findings</b>: what fired, why, and the fix</td>
    <td align="center"><b>History</b>: who held the Mac at that spike</td>
  </tr>
</table>

## Get started

1. **Install** with the line above. You need macOS 14 or newer. Nothing else: no Homebrew, no
   developer tools, no admin password.
2. **Click the icon.** The first verdict appears within a minute; history fills in as MacMax runs.
3. **Optional:** Settings, Permissions, Full Disk Access lets MacMax size folders macOS protects.
   Everything else works without it.
4. **Optional:** connect your agent: `claude mcp add macmax -- ~/.local/bin/macmax mcp`.

What MacMax cannot do, by design: show memory per Chrome tab (only Chrome's own Task Manager can,
under Window, Task Manager), block traffic, or run anything as root.

## Privacy and security

MacMax makes two network requests and no others: the IP check (to `1.1.1.1` by default; editable
or off in Settings, Network) and the update check (GitHub's releases API). No telemetry, no
analytics, no account. Everything it records stays in `~/.macmax` on your Mac, readable only by
you. Command lines are redacted before they are stored or shown, so tokens in other apps' arguments
never land in its history. The agent server listens on no port: it talks only to the program that
started it. The threat model is in [`SECURITY.md`](SECURITY.md).

<details>
<summary><b>CLI</b></summary>

```bash
macmax snapshot            # verdict, vitals, top apps, IP and VPN
macmax apps --by memory    # apps by CPU, memory, disk or network
macmax network --window 1h # traffic per app
macmax ip                  # public IP, ISP IP, VPN state, leak verdict
macmax audit               # a fresh audit; exits 0 OK, 1 WARN, 2 CRIT, 3 unknown
macmax history swap --range 7d
macmax mcp                 # the read-only agent server on stdio
```

Add `--json` to any command. Everything MacMax keeps lives in `~/.macmax` (or `$MACMAX_HOME`).

</details>

<details>
<summary><b>Build from source</b></summary>

```bash
git clone https://github.com/danieltamas/macmax.git && cd macmax
scripts/install-from-source.sh
```

Needs Xcode with Swift 6.2. `scripts/check.sh` builds and runs the suite. Releases are
reproducible: `scripts/release.sh <x.y.z> --verify` builds twice and fails if one byte differs.

</details>

<details>
<summary><b>Uninstall</b></summary>

```bash
curl -fsSL https://raw.githubusercontent.com/danieltamas/macmax/main/install.sh | bash -s -- --uninstall
```

Removes the app and the `macmax` command, and keeps your history in `~/.macmax` unless you add
`--purge`. If you connected an agent: `claude mcp remove macmax`.

</details>

## License

MIT. Product names shown in MacMax identify the apps it measures and belong to their owners.
