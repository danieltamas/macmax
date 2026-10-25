# Audit rules, cleanup rules and actions

## Origin

The audit rules are the checks of `mac-audit.sh` (the owner's deterministic audit script, in the
owner's agent-os repo at `skills/mac-audit/bin/mac-audit.sh`, 336 lines, 2026-10-24), ported one to
one: same thresholds, same comparison operators, same severities. The script was written after a
real slowdown on the owner's Mac (swap, stale Claude Code sessions with MCP sidecars, a Docker VM
starved by the host's compressor, Intel Homebrew under Rosetta, 30+ days of uptime). Its threshold
names (`T_*`) are kept as the default-threshold keys so the two stay comparable.

## Rule schema

Rules are data in `Sources/MacMaxCore/Rules/` (`RuleSet.all`, in evaluation order), one entry per rule:

```swift
struct Rule: Sendable {
    let id: String                 // stable, snake_case, never reused
    let title: String              // plain words, the user's view
    let thresholds: [Threshold]    // key (T_* name), default, unit, bounds for Settings
    let why: String                // one line: why it slows the Mac
    let action: String?            // the next step or what the app can do, if anything
    let scriptPattern: String?     // anchored regex of the mac-audit.sh message, for parity
    let evaluate: @Sendable (AuditSnapshot, ResolvedThresholds) -> Outcome   // pure
}
enum Outcome { case pass, info(title:evidence:), warn(...), crit(...), unknown(reason: String) }
```

A rule reads `Measure` fields of the snapshot (below): `ok(value)`, `unavailable` (this Mac lacks it:
the rule passes as not applicable) and `failed` (could not be read: the rule is `unknown`). A rule
sorts anything it lists as evidence (by value descending, then name), so the order of an array in the
snapshot never changes the output.

- Evaluation is pure over one immutable snapshot. Findings are ordered CRIT, WARN, INFO, then by
  rule order in the set; the same snapshot always yields byte-identical JSON.
- Verdict: CRIT if any CRIT, else WARN if any WARN, else OK. INFO never changes the verdict.
  `unknown` outcomes are listed as "could not check" and make the verdict `unknown` only when no
  rule could be evaluated at all.
- Thresholds are editable per rule in Settings > Audit within their bounds; the default is shown
  next to the field; a rule can be turned off.

## Inputs: the audit snapshot

An audit evaluates one immutable `AuditSnapshot`: a flat, `Sendable`, `Codable` struct of readings
already reduced to what the rules compare, built by `AuditSnapshotBuilder` from the per-tick
collectors plus one audit-time probe pass. Rounding follows the script before the comparison (uptime
floor days, swap one decimal of GB, compressor and disk free whole percent), so parity differs only by
live drift. The stored `snapshot_json` is this struct: it carries no argv, cwd, tty or path.

`unavailable` (this Mac does not have it, such as no Docker) makes a rule pass as not applicable;
`failed` makes it `unknown` with the reason. A snapshot field nobody filled is `failed("not collected")`.

| Snapshot field | Source | Rules |
|----------------|--------|-------|
| `uptimeDays`, `load5`, `coreCount` (`hw.ncpu`, the script's base), `cpuIdlePercent` | `SystemSnapshot` | uptime, load, cpu_idle |
| `swapUsedGB`, `swapInsPerSecond` (pages/s), `compressorPercent`, `memoryLevel` (`kern.memorystatus_level`) | `SystemSnapshot` | swap_used, swap_in_rate, compressor, memory_level |
| `diskFreePercent`, `diskIOPS`, `cpuSpeedLimit` | `SystemSnapshot` | disk_free, disk_iops, thermal_limit |
| `processCount`, `chromeProcesses`, `claudeSessionAgesDays`, `mcpSidecars`, `apps` (grouped footprint) | `[ProcessSample]` and app grouping | process_count, chrome_processes, claude_stale, mcp_sidecars, big_apps |
| `zombies` | probe: `ps -Axo stat=` count of `Z` | zombies |
| `kernelTaskCPU`, `daemonResidentMB` (fseventsd, WindowServer, Finder, mds_stores) | probe: `top -l 2 -s 3 -pid` (rusage is EPERM for root processes) | kernel_cpu, daemon_bloat |
| `dockerVMCompressedGB`, `containerCPU` | probe: `top -pid <VM>`, `docker stats --no-stream` | docker_vm_compressed, docker_hot_containers |
| `crashReports7d`, `jetsam7d`, `launchItems` | probe: file counts (a denied folder is `failed`: could not check) | crash_reports, jetsam, launch_items |
| `brewInstalls` | probe: brew prefixes and their architecture | brew_under_rosetta |
| `translatedProcesses` (last 3 CPU samples) | sampler ring (not wired until the UI unit: `unavailable`) | translated_hot |
| `identity` (verdict, VPN state, public IP and country) and `previousPublicIP` | `NetworkIdentity`, last stored audit | vpn_leak, vpn_expected_down, ip_changed |
| `appGrowth` (footprint now and one hour ago, CPU) | store (`app_samples`) | memory_growth |

## Findings, evidence and output

A rule with two severities yields one finding at the higher one (like the script). Evidence is an ordered
list of `(key, value)` strings so the JSON is byte-identical:

- Threshold rules: `("value", v)` then `("threshold", t)`. Integers print as `%d`, other numbers as
  `%.1f`, except `load` (`%.2f`; its threshold is cores x the multiplier, plus `("cores", n)` third).
  `cpu_idle` and `disk_free` compare "below"; the rest "above" or "at least" exactly as in the table.
- List rules put `("threshold", t)` first, then one item per entry sorted by value descending, then name:
  `docker_hot_containers` (`name`, `"%.1f%%"`), `daemon_bloat` (`name`, MB as `%d`), `big_apps` (`name`, MB as
  `%d`), `translated_hot` (`name (app)`, last CPU as `%.1f`), `memory_growth` (`name`, `"+<MB> MB"`).
  `claude_stale` gives `("value", stale count)`, `("threshold", T_CLAUDE_WARN_N)`, `("total", sessions)`,
  `("oldest_days", n)`. `brew_under_rosetta`, `vpn_leak`, `vpn_expected_down` and `ip_changed` give facts
  (`("verdict", ...)`, `("previous", ip country)`, `("current", ip country)`).
- A finding's `title` is a plain sentence containing the rounded value; `why` and `action` come from the rule.

JSON (`AuditJSON.encode`): `JSONEncoder` with `.sortedKeys` and `.convertToSnakeCase`, UTF-8, no
pretty printing; severities and verdicts are the strings `crit`, `warn`, `info`, `ok`, `unknown`. The CLI
prints the report with `source`, `generated_at`, `data_note`, `rules` (id, title and script pattern of every rule)
and `summary` (`uptime_d`, `claude_stale`, `procs`, `swap_gb`, `disk_free_pct`, `crit`, `warn`; a number the audit
could not read is left out) added (docs/AGENT-API.md) and exits
0 for `ok` and `info` only, 1 for `warn`, 2 for `crit`, 3 for `unknown` (no rule could be evaluated).

Notifications: `NotificationDiff.changes(previous:current:)` returns findings of `current` that are new
or have a higher severity than the same rule in `previous`. With no previous audit only `crit` findings.

## Ported rules

`>` and `>=` are exactly as in the script. Units as stored. Sample windows: 3 s live sample like
the script's `T_SAMPLE_S`, taken from the sampler's last ticks when available.

| id | Severity and condition (defaults) | Threshold keys | Script message (pattern in RuleSet) | Action |
|----|-----------------------------------|----------------|---------------|--------|
| `uptime` | CRIT days >= 30; WARN days >= 14 | T_UPTIME_CRIT_D, T_UPTIME_WARN_D | `Uptime` | Next step: reboot after closing stale sessions |
| `load` | CRIT load5 > cores x 2; WARN load5 > cores x 1 | T_LOAD_CRIT_X, T_LOAD_WARN_X | `Load` | Open Apps sorted by CPU |
| `cpu_idle` | CRIT idle % < 10 | T_IDLE_CRIT | `CPU idle` | Open Apps sorted by CPU |
| `kernel_cpu` | WARN kernel_task CPU % > 40 | T_KERNEL_CPU_WARN | `kernel_task at` | Next step: fix memory first |
| `process_count` | WARN processes > 800 | T_PROC_WARN | (number) `processes` | Open Apps sorted by process count |
| `swap_used` | CRIT swap GB > 6; WARN > 2 | T_SWAP_CRIT_GB, T_SWAP_WARN_GB | `Swap` | Open Apps sorted by memory |
| `swap_in_rate` | CRIT swap-ins pages/s > 50 | T_SWAPIN_RATE | `Swapping in` | Open Apps sorted by memory |
| `compressor` | CRIT compressed % of RAM >= 35; WARN >= 20 | T_COMP_CRIT_PCT, T_COMP_WARN_PCT | `Compressor holds` | Open Apps sorted by memory |
| `memory_level` | CRIT memorystatus_level <= 40; WARN <= 60 | T_MEMLEVEL_CRIT, T_MEMLEVEL_WARN | `memorystatus_level` | Open Apps sorted by memory |
| `claude_stale` | CRIT sessions older than 7 days >= 5; WARN >= 1 | T_CLAUDE_DAYS, T_CLAUDE_WARN_N | (number) `claude session` | End stale sessions (U9) |
| `mcp_sidecars` | WARN MCP sidecar processes > 30 | T_SIDECAR_WARN | (number) `MCP sidecar` | Next step: scope MCP servers to projects |
| `zombies` | WARN zombie processes > 5 | T_ZOMBIE_WARN | (number) `zombie` | Shows their parents |
| `docker_vm_compressed` | CRIT Docker VM memory compressed by macOS GB > 2 | T_VM_CMPRS_GB | `Docker VM has` | Stop idle containers |
| `docker_hot_containers` | WARN any container CPU % > 25 | (fixed 25 in the script; key T_CONTAINER_CPU added, default 25) | `Containers above` | Stop container |
| `daemon_bloat` | WARN fseventsd, WindowServer or Finder resident MB > 1024 | T_DAEMON_RSS_MB | (daemon name) `at` | Next step: reboot |
| `disk_free` | CRIT free % < 10; WARN < 15 | T_DISK_CRIT_PCT, T_DISK_WARN_PCT | `Only` / (number)`% disk free` | Review cleanup |
| `disk_iops` | WARN boot disk ops/s > 1500 sustained | T_IOPS_WARN | `Boot disk at` | Open Apps sorted by disk |
| `chrome_processes` | WARN Chrome processes > 40 | T_CHROME_PROCS | (number) `Chrome processes` | Next step: close tab groups or turn on Memory Saver |
| `big_apps` | WARN any app (grouped) > 10% of RAM | (fixed 10 in the script; key T_APP_RAM_PCT added, default 10) | `Single apps above` | Quit app |
| `crash_reports` | WARN reports in 7 days > 10 | T_CRASH_WARN | (number) `crash or resource reports` | Lists the top names |
| `jetsam` | WARN Jetsam events in 7 days > 0 | none | (number) `Jetsam events` | Open Apps sorted by memory |
| `launch_items` | WARN third-party launch items > 25 | T_BG_ITEMS_WARN | (number) `third-party launch items` | Lists them; Reveal in Finder |
| `thermal_limit` | WARN CPU_Speed_Limit < 100 | none | `CPU speed limit` | Open Apps sorted by CPU |

The script reads "big apps" from `ps` resident memory; MacMax uses footprint grouped by app. That
is a deliberate difference: parity for `big_apps` is checked on the script's own rule (single
processes over 10 percent of RAM by resident size) in the parity run, and MacMax's grouped rule is
tested on its own fixtures.

## New rules

| id | Severity and condition | Why | Action |
|----|------------------------|-----|--------|
| `brew_under_rosetta` | WARN on Apple Silicon when `/usr/local/bin/brew` is an x86_64 install and `/opt/homebrew` has none | Every brew tool runs translated and slower; native installs are skipped | Next step: install native Homebrew in `/opt/homebrew`, link to the guide |
| `translated_hot` | WARN any process under Rosetta above 10% CPU for 3 samples | Translated code costs extra CPU and battery | Shows the process and its app |
| `vpn_leak` | CRIT identity verdict `leak`; verdict `unknown` (a read failed) is `unknown`; verdict `off` (IP check disabled) is not applicable | The VPN says connected but traffic leaves outside it | Open Network; next step: reconnect the VPN |
| `vpn_expected_down` | WARN a VPN the user marked "should be on" is disconnected (off by default) | Traffic is not protected | Open Network |
| `ip_changed` | INFO public IP or its country changed since the last audit | Know when the VPN exit or the network changed | none |
| `memory_growth` | WARN an app's footprint grew by more than 1 GB and 50% over 1 hour while its CPU stayed under 5% | A likely leak; relaunching frees it | Quit app (relaunch) |

New rules need their own golden fixtures, and their thresholds have bounds in Settings like the rest.

## Building the snapshot

`AuditSnapshotBuilder.build` is a pure function of `AuditInputs` (docs above) and applies these reductions,
the script's own roundings first:

- `timestamp` = whole epoch seconds of `now`. `uptimeDays` = whole days, rounded down. `swapUsedGB` = GB
  (2^30) to one decimal, ties to even. `compressorPercent` and `diskFreePercent` = whole percent, ties to
  even (`diskFreePercent` is free / total of the data volume; a zero total is `failed`). `diskIOPS` = read plus
  write operations per second. `cpuSpeedLimit` = the thermal limit, 100 when pmset reported none.
  `memoryLevel` = the pressure reading's `availablePercent`; `ramBytes` = physical memory.
- From the process list: `processCount`; `chromeProcesses` = processes whose path contains `Google Chrome`;
  `claudeSessionAgesDays` = whole days since start (never negative) of processes whose path ends in `/claude`
  or matches `/claude/versions/<digits and dots>`; `mcpSidecars` = processes whose redacted argv joined by
  spaces matches `supergateway|playwright-mcp|@playwright/mcp|server-pdf|context7|mcp-remote|mcp-wrapper|npm exec`
  (a process whose argv could not be read does not match). If the process list itself is not `ok`, all of
  these are `failed` with its reason.
- `apps`: footprint summed per app (`AppGrouping`), a process without a footprint adds nothing.
  `translatedProcesses`: processes with `isTranslated` true, app = their group's name, `cpuSamples` = the last
  three of `cpuHistory[identity]`; when `cpuHistory` is empty and any process is translated the field is
  `failed("CPU history not collected")`; with no translated process it is `ok([])`.
- `appGrowth`: apps present now and in `footprintOneHourAgo` (by app key), with the CPU summed over the app's
  processes; an app with any process whose CPU is not `ok` is left out (a growth we cannot call idle is not
  reported). `footprintOneHourAgo` not `ok` gives the same outcome kind (`failed` or `unavailable`).
- `identity`: `vpnConnected` is true when any VPN service is `connected`; the field is `failed` when the
  services reading is `failed`, `failed("network identity not collected")` when `identity` is nil.
  `publicIP`/`publicCountry` come from the public IP reading when it is ok, else nil. `previousIdentity`:
  `unavailable("first audit")` without `previous`; `unavailable` when the previous snapshot had no public IP.
- Rounding snaps to six decimals before the tie rule applies, so a byte count a few bytes short of a tie still
  counts as the tie (the script reads decimal text, which has no such error).
- `disk_free` reads the data volume's plain available capacity (what `df` reports), not the important-usage
  figure of the Overview, which adds purgeable space: a nearly full disk must not hide behind space the system
  may not give back. `claude_stale` counts a process whose binary was replaced by an update (no readable path)
  by its kernel command name, `claude` or a version number, as the script's `ps` does.
- The top probe samples a 3 second window (`top -l 2 -s 3`), like the script. kernel_task CPU swings widely on
  a Mac that is swapping (37 to 169 percent within a minute was measured) and the two tools sample about 40
  seconds apart, so `kernel_cpu` near its threshold can differ between them.
- `vpn_leak`: a `leak` verdict is CRIT, `unknown` makes the rule unknown with a reason, `off` is not applicable.
- Probe fields are copied as they are, except that `NamedValue` names go through `Redaction.sanitizeText`.
- A `Reading` that is not ok keeps its kind (`unavailable` stays `unavailable`, `failed` stays `failed`) and its
  reason in the matching field.

## Parity with mac-audit.sh

`scripts/parity.sh` (U6) runs, outside the Claude Code sandbox:
1. `mac-audit.sh -o $tmp/report.md --json-summary` and `macmax audit --json` within 60 seconds.
2. Parses the script's verdict list (`N. [CRIT] message -> action`) and maps each line to a rule id
   by the rule's `scriptPattern` (an anchored regex on the message after `[SEV] `, defined once in `RuleSet`).
3. Passes when every (rule id, severity) the script reports is reported by MacMax, except a rule
   whose measured value is within 5 percent of its threshold in either tool (live samples differ by
   seconds); those are printed as "near threshold" and do not fail.
4. Also compares the JSON summary's numbers within tolerance: `crit`/`warn` counts equal after the
   exclusions, `procs` within 5 percent, `swap_gb` within 0.1, `disk_free_pct` within 1,
   `uptime_d` equal, `claude_stale` equal.

The script must be present for parity; on a Mac without it, `parity.sh` exits 0 with "skipped:
mac-audit.sh not found" and `acceptance.sh` reports the skip.

## Cleanup rules (U9, decision D4)

Cleanup removes only regenerable data, only by moving it to the Trash, only after a preview with
sizes that the user confirms. Nothing is ever deleted permanently by MacMax.

**Allowed roots** (cleanup never looks anywhere else):

| Rule | Path | Condition |
|------|------|-----------|
| `app_caches` | `~/Library/Caches/<bundle id>` | The app is not running; not in the protected list |
| `xcode_derived` | `~/Library/Developer/Xcode/DerivedData/*` | Xcode is not running |
| `simulator_caches` | `~/Library/Developer/CoreSimulator/Caches` | Simulator is not running |
| `npm_cache` | `~/.npm/_cacache` | No `npm` process running |
| `yarn_cache` | `~/Library/Caches/Yarn` | No `yarn` process running |
| `pip_cache` | `~/Library/Caches/pip` | No `pip` process running |
| `homebrew_cache` | `~/Library/Caches/Homebrew` | No `brew` process running |
| `old_logs` | files in `~/Library/Logs` older than 30 days | not under `DiagnosticReports` |

**Shown, never run** (the app gives the size and the exact command with a copy button, because
they are not Trash operations): `docker system df` with `docker system prune` (never `--volumes`),
Time Machine local snapshots with `tmutil listlocalsnapshots /`.

**Protected, always** (also through symlinks, also when a rule's root would include them):
`~/Documents`, `~/Desktop`, `~/Downloads`, `~/Pictures`, `~/Movies`, `~/Music`,
`~/Library/Mobile Documents`, `~/Library/Keychains`, `~/Library/Mail`, `~/Library/Messages`,
`~/Library/Containers`, `~/Library/Group Containers`, `~/Library/Application Support`, `~/.ssh`,
`~/.gnupg`, `~/.aws`, `~/.config`, `~/.macmax`, any directory containing `.git`, `/System`,
`/Library`, `/usr`, `/bin`, `/sbin`, `/Applications`, plus the user's own list (Settings > Cleanup).

**Mechanics**: scan sizes in a detached task with a time bound; resolve every path
(`realpath`) and check it is under an allowed root and not under a protected path; right before
moving, re-check the path is the same file (inode and device) and has not grown more than 10
percent past its previewed size; move with `FileManager.trashItem`; record each move in `actions`.
A path that fails any check is skipped and listed with the reason.

## Actions (U9)

| Action | Target | Mechanics | Guard |
|--------|--------|-----------|-------|
| Quit app | an app (grouped) | `NSRunningApplication.terminate()` | Same user; shows "Quitting..." until it exits or 10 s pass, then offers Force Quit |
| Force quit app | an app | `forceTerminate()` | Second explicit press |
| End process | one process | SIGTERM, then a second press for SIGKILL | Same user; not a system process (pid < 100 or under `/System`, `/usr/libexec`, `/sbin`); (pid, start time) re-read and equal right before the signal |
| End stale Claude Code session | a `claude` session | SIGTERM to the session's process group | Same as End process; shows what will end (the session and its sidecars) |
| Stop container | a Docker container | `docker stop <id>` via ProcessRunner, 30 s timeout | Re-reads the container id is running first |
| Move caches to Trash | cleanup rules | above | Preview and confirm |

Every action is UI-only: no CLI command and no MCP tool performs an action (PLAN.md trust
boundary 6). Every action is logged with its target and result.
