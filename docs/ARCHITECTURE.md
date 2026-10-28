# MacMax architecture

## Targets

```
Package.swift            swift-tools-version 6.0, macOS 13 deployment target, no dependencies
Sources/MacMaxCore/      everything testable; imports Foundation, Darwin, IOKit, SystemConfiguration,
                         Network, SQLite3; never SwiftUI or AppKit
  Collect/               SystemCollector, ProcessCollector, AppGrouping, NetworkTraffic, NetworkIdentity,
                         DockerCollector, ClaudeSessions, SystemArtifacts (crash reports, launch items, brew)
  Model/                 Snapshot, Reading<T> (ok | unavailable(reason) | failed(reason)), AppKey, ProcIdentity
  Rules/                 Rule, RuleSet (data), AuditEngine, Finding, Verdict, Thresholds
  Store/                 Database (SQLite actor), Schema + migrations, Rollups, Retention, Queries
  Act/                   ProcessActions, CleanupScanner, CleanupMover, ActionLog
  Agent/                 MCPServer (JSON-RPC over stdio), Tools, Redaction
  Release/               MacMaxRelease (standing, canUpdate), ReleaseCheck, GitHubReleases (the one
                         unauthenticated `releases/latest` fetch, for the update check and More apps),
                         InstalledStanding (an installed copy against a release)
  Support/               ProcessRunner, Executables, MacMaxHome, Clock, SafeFile
Sources/MacMax/          SwiftUI app: MacMaxApp, AppStore, RootView, tabs, SettingsView + panes,
                         MenuBarIcon, Theme, Looks, Components, Updater, LoginItem, Notifier, DemoShots
Sources/MacMaxCLI/       `macmax` (installed name): snapshot, apps, network, ip, audit, findings,
                         history, mcp
Tests/MacMaxCoreTests/   <Topic>AcceptanceTests (Codex), <Topic>RegressionTests, Fixtures/
Support/                 Info.plist, toolchain (pinned Xcode build), AppIcon.icns, MenuBarIcon.pdf
                         MoreApps/ (the other apps' icons for Settings > More apps, from their repos)
Brand/                   SVG sources for the icons
scripts/                 check.sh, bundle.sh, install-from-source.sh, release.sh, render-icons.sh,
                         make-signing-identity.sh, perf.sh, parity.sh, acceptance.sh
install.sh               the one-line installer, also bundled in the app for Update
```

## Data flow

```
             +--------------------- MacMax.app ----------------------+
collectors -> Snapshot (immutable, every tick) -> AppStore (@MainActor) -> views
                 |                                      |
                 +-> Database actor (one writer) <------+-- actions log
                 +-> AuditEngine (on schedule, on demand, on critical pressure) -> findings -> Notifier
             +-------------------------------------------------------+
macmax CLI / macmax mcp --(read-only SQLite + its own one-shot collectors)--> stdout JSON
```

- The sampler loop is started in `MacMaxApp.init()` (LESSONS.md section 2). Each tick builds one
  immutable `Snapshot`; the store publishes it, the database writes its rows, and the audit engine
  reads the latest one. No view reads a collector directly.
- **One writer.** The app holds an exclusive `flock` on `~/.macmax/writer.lock` (`O_CLOEXEC`) for
  its lifetime. A second app instance finds it held, shows "MacMax is already running", and quits.
  The CLI and the MCP server never write the database; they open it read-only.
- **When the app is not running**, the CLI and MCP server run the collectors once themselves for
  `snapshot`, `apps`, `network` (a 2-second sample), `ip` and `audit`, and say in the output that
  history is unavailable or stale (`"history": {"available": false, "reason": "app not running"}`).

## Readings

Every collected value is a `Reading<T>`: `ok(value, source, at)`, `unavailable(reason)` (the Mac does
not have it: no battery, no Docker, no GPU counter) or `failed(reason)` (it should be there and
could not be read). Rules and actions treat `failed` and `unavailable` as unknown, never as zero
or healthy (defect class 1). The UI shows failed readings as failed, with the reason.

## Data sources

Status legend: **verified** = run on the owner's Mac (macOS 15, Apple Silicon) without root on
2026-10-25 or used by `mac-audit.sh` in the 2026-10-24 audit; **verify in Ux** = believed to work,
not yet run, the unit's first task is to prove it with a live test and update this table. If a
source fails its proof, pick the fallback, update this table and PLAN.md, and tell the owner.

| Reading | Source | Status | Fallback |
|---------|--------|--------|----------|
| CPU total and per core | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` tick deltas | verified in U1 | `top -l 2 -n 0` header |
| Load, cores, uptime | `getloadavg`, `sysctl hw.ncpu hw.perflevel0.logicalcpu kern.boottime` | verified (mac-audit) | none needed |
| Memory used, wired, compressed, free | `host_statistics64(HOST_VM_INFO64)` | verified in U1 | `vm_stat` (verified) |
| Swap used | `sysctl vm.swapusage` | verified (mac-audit) | none |
| Swap-ins per second | `vm_statistics64.swapins` deltas | verified in U1 | `vm_stat` deltas (verified) |
| Memory pressure level | `sysctl kern.memorystatus_level` | verified (mac-audit) | `memory_pressure -Q` |
| Disk free | `URLResourceValues.volumeAvailableCapacity` on `/System/Volumes/Data` (the Finder and `df` figure); purgeable is `volumeAvailableCapacityForImportantUsage` minus it, shown next to the free figure | verified in U1 | `df -k /System/Volumes/Data` (verified) |
| Disk IO bytes and ops | IOKit `IOBlockStorageDriver` "Statistics" deltas, summed over the internal drivers (the boot disk on a Mac with one internal drive; external drives and disk images are excluded) | verified in U1 | `iostat -d -c 2 -w 1` (verified) |
| Thermal | `ProcessInfo.thermalState`; `pmset -g therm` CPU_Speed_Limit | verified (mac-audit, pmset) | thermalState only |
| GPU utilization | IOKit `IOAccelerator` PerformanceStatistics "Device Utilization %" | verified in U1 | `unavailable` |
| Battery, power source | `IOPSCopyPowerSourcesInfo` | verified in U1 | `pmset -g batt` (verified) |
| Fans, temperatures, named sensors | `AppleSMC` user client (no root): every `T` key, the fan keys and the catalog's electrical keys; `SensorCatalog` names only allowlisted keys, choosing the chip generation's list by how many of its keys read, never by chip name | verified in U15 on M2 Pro (M1 key layout) | the hottest-sensor summary still counts every plausible `T` key |
| Process list | `proc_listallpids` | verified in U2 | `ps -axo` (verified) |
| Pid, ppid, start time, user | `sysctl KERN_PROC_PID` (`p_starttime`, `e_ppid`, `cr_uid`); `proc_pidinfo(PROC_PIDTBSDINFO)` is denied (EPERM) for about 20% of processes, root-owned ones included | verified in U2 (the sysctl, not pidinfo) | `ps -o lstart` |
| Footprint, CPU time, disk bytes | `proc_pid_rusage(RUSAGE_INFO_V4)` (`ri_phys_footprint`, `ri_user_time`, `ri_system_time`, `ri_diskio_bytes*`) | verified in U2: EPERM on root-owned processes is `unavailable` (about 18% of processes) | `ps -o rss,time` (rss, not footprint: label it) |
| Executable path | `proc_pidpath` (ENOENT when the binary was replaced while running: `unavailable`) | verified in U2 | `ps -o comm` |
| Argv, cwd | `sysctl KERN_PROCARGS2` (argc strings only, never the environment); `proc_pidinfo(PROC_PIDVNODEPATHINFO)`; both `unavailable` for the same root-owned set | verified in U2 | omit (never `ps` full lines into logs) |
| Rosetta | `kinfo_proc.kp_proc.p_flag & P_TRANSLATED` (0x20000) | verified in U2 | `unavailable` |
| Compressed memory per process (Docker VM) | `top -l 1 -stats pid,cmprs` (what mac-audit uses) | verified (mac-audit) | `unavailable` |
| Bytes in and out per process, one-shot | `/usr/bin/nettop -P -L 1 -x -J bytes_in,bytes_out` | verified: loses totals of closed sockets, so not used per tick | none: `failed` |
| Same, once per tick | `nettop -P -L 1 -x -J bytes_in,bytes_out` (a long-lived child cost 120 percent of a core) | verified in U3 | none: `failed` for the tick, restart on the next |
| Connections of one process | `nettop -m tcp -L 1 -x -n -p <pid>` | verified in U3 | `failed` |
| VPN services and state | `/usr/sbin/scutil --nc list` | verified (Outline, Tailscale, Pangolin listed) | `unknown` |
| Default route interface | `route -n get default` (interface `utun*`, `ipsec*`, `ppp*` = tunnel); the path-change trigger (`NWPathMonitor`) arrives with the sampler in U5 | verified in U4 | `failed` |
| Physical interface for the ISP IP | `scutil --nwi`: first non-tunnel, non-`lo` interface in the service order | verified in U4 | `unavailable` (only a tunnel is up) or `failed` |
| Public IP, country | `curl https://1.1.1.1/cdn-cgi/trace` (`ip=`, `loc=`) | verified (VPN IP shown, country DE) | `failed`, shown as unknown |
| ISP IP behind a VPN | same request with `curl --interface <physical>` | verified (ISP IP shown, country RO) | `failed` |
| Docker containers | `docker stats --no-stream --format '{{json .}}'`, `docker info` | verified (mac-audit) | `unavailable` (no Docker) |
| Claude Code sessions | process name `claude` + start time; MCP sidecars = its descendants that run MCP servers | verified (mac-audit) | none |
| Crash and Jetsam reports | count `~/Library/Logs/DiagnosticReports` and `/Library/Logs/DiagnosticReports` modified in 7 days; `JetsamEvent-*` | verified (mac-audit) | `unavailable` without permission |
| Launch items | third-party plists in `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons` | verified (mac-audit) | none |
| Homebrew prefix | `/opt/homebrew/bin/brew`, `/usr/local/bin/brew` existence and `file` arch on Apple Silicon | verified (Intel brew found on 2026-10-24) | none |

Why curl and not URLSession for the IP checks: binding a request to the physical interface is
proven with `curl --interface`; URLSession cannot bind an interface. `NWConnection` with
`requiredInterface` could replace it later; that is a change with its own live test.

Not available, by design (README says so): memory per Chrome tab, blocking traffic, per-process
energy from `powermetrics` (root), anything that needs a kernel or system extension.

## App grouping

`AppKey` = bundle id when known, else the executable path, else the process name. A process belongs
to the outermost `.app` in its executable path (Chrome Helper (Renderer) -> Google Chrome); if it
has none, to its nearest ancestor that has one (a `node` started by an Electron app); else it stands
alone. Families with one label: Claude Code (each `claude` session with its descendants), Docker
(the VM process and its helpers), Chrome, Electron apps by bundle. Grouping is a pure function over
(pid, ppid, path, name) rows, tested on fixtures.

## Store

SQLite through `import SQLite3`, `~/.macmax/macmax.db`, WAL, `busy_timeout` 2000 ms, one writer actor.
Parameterized statements only. Schema version in `PRAGMA user_version`; migrations are idempotent.

```
apps(app_key TEXT PRIMARY KEY, name TEXT, bundle_id TEXT, path TEXT, first_seen INT)
samples(ts INT, cpu_user REAL, cpu_system REAL, mem_used INT, mem_compressed INT, swap_used INT,
        swapins_ps REAL, pressure_level INT, disk_free INT, disk_read_bps REAL, disk_write_bps REAL,
        net_in_bps REAL, net_out_bps REAL, thermal INT)                   -- one row per tick
app_samples(ts INT, app_key TEXT, cpu REAL, footprint INT, disk_read_bps REAL, disk_write_bps REAL,
            net_in_bytes INT, net_out_bytes INT, procs INT)               -- top 40 apps per tick
proc_samples(ts INT, pid INT, start_us INT, app_key TEXT, name TEXT, cpu REAL, footprint INT)
samples_1m, app_samples_1m, samples_1h, app_samples_1h                    -- same columns as averages, plus n, maxima and byte sums
identity(ts INT, public_ip TEXT, public_cc TEXT, isp_ip TEXT, isp_cc TEXT, vpn_service TEXT,
         vpn_state TEXT, route_tunnel INT, verdict TEXT)                  -- on change only
audits(id INTEGER PRIMARY KEY, ts INT, verdict TEXT, duration_ms INT, snapshot_json TEXT)
findings(audit_id INT, rule_id TEXT, severity TEXT, title TEXT, evidence_json TEXT)
actions(ts INT, kind TEXT, target TEXT, result TEXT, detail TEXT)
```

Rollup tables (U5): `samples_1m`/`_1h` hold `ts` (bucket start), `n` (raw rows), each `samples` column as the
average over its non-NULL values, and `cpu_max`, `mem_used_max`, `net_in_bps_max`, `net_out_bps_max`. The
`app_samples_*` tables hold `(ts, app_key)`, `n`, averaged cpu, footprint and disk rates, summed
`net_in_bytes`/`net_out_bytes`, `procs` as a maximum, `cpu_max` and `footprint_max`. An hour is built from its
minutes weighted by `n`; a bucket is rolled up only when complete, so rollup is idempotent. Completeness is per
`(ts, app_key)`, and an hour waits until every raw minute in it is rolled. Rows added later to a bucket that already
exists are not folded in: a tick is stamped when it starts and written seconds later, so whoever schedules
`rollup(now:)` must pass `now` 60 s behind the clock (`Sampler` does not call it). Tick seconds are strictly
increasing within a process. The `apps` upsert keeps a known `bundle_id` and `path` when a tick has none. The
database and its `-wal`/`-shm` files are forced to 0600 on open. `app_samples` and
`proc_samples` are WITHOUT ROWID with the natural key as primary key and no second index: 90 days of synthetic
samples at the 10 s cadence measured 162 MB (limit 250 MB). A column nobody could read is NULL, never zero.
The newest schema this build writes is `Database.schemaVersion`; a file with a higher `user_version` opens
read-only and refuses writes. One sampler tick takes about one nettop interval (2 s) because the network
reading waits for a fresh block.

Retention: raw 48 hours, 1-minute 14 days, 1-hour 365 days, audits 90 days, actions 365 days.
Rollup and retention run hourly in bounded batches. Command lines are never stored, only the
redacted short form in `proc_samples.name` when needed for display.

## Audit

`AuditRunner` samples the system and processes for three seconds, reads the network identity (the public IP
check only when asked) and `AuditProbes` (zombies, kernel_task and daemons from one `top` window, Docker VM
and containers, report counts, launch items, Homebrew prefixes), then `AuditSnapshotBuilder` reduces them to
an immutable `AuditSnapshot` (docs/RULES.md, "Building the snapshot"). `AuditEngine.evaluate` is a pure
function of the snapshot, the thresholds and the disabled rules. `AuditService` is the actor around it: one
audit at a time (a second caller joins the running one), a scheduled loop, a pressure trigger on entering
critical at most once per gap, the previous audit from the database (else from memory) for the notification
diff, and a failed write reported in the result without failing the audit. `macmax audit` runs the runner once
and never writes the database.

## Settings

`~/.macmax/config.json`, read before every write, validated on load with every number bounded
(defect class 12). A file that fails to parse is not overwritten: the app shows a problem in
Settings and keeps the last valid config in memory, read-only, until the user fixes or resets it.
Every key is editable in Settings; the file exists for backup and for the CLI.

## CLI

`macmax <command> [--json]`, one `do { } catch { print the message; exit 3 }` around the switch so
a missing tool prints a sentence. Commands and JSON shapes: `docs/AGENT-API.md`. Exit codes: 0 OK,
1 WARN present (audit), 2 CRIT present (audit), 3 audit verdict unknown (no rule could be evaluated), 64 usage,
70 the output could not be encoded.

## Concurrency

- `PanelModel` is a `@MainActor ObservableObject` (`@Observable` is macOS 14; the floor is 13); collectors and the database are actors or nonisolated
  pure functions; heavy work never runs on the main actor.
- The tick is a detached loop with a monotonic clock; a slow collector times out and yields a
  `failed` reading instead of delaying the tick. The `nettop` stream is one supervised child.
- In-flight flags (audit running, action running, update installing) live in the store, keyed by
  the target's stable identity.
