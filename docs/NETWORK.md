# Network: traffic per app, public IP, VPN state

## Traffic per app (U3)

**Source (verified 2026-10-25, no root):** `/usr/bin/nettop -P -L 1 -x -J bytes_in,bytes_out`
prints a CSV snapshot of every process with network activity since it started:

```
,bytes_in,bytes_out,
<process name>.<pid>,447318,0,
<process name>.<pid>,19409,510465,
```

- Line 1 is the header. Each row is `name.pid,bytes_in,bytes_out,` with cumulative bytes for the
  life of the process. The name may contain dots and spaces and may be truncated: split on the
  last `.` before the first `,` to get the pid, and take the name from the process collector by
  pid (never from nettop's text).
- A row that does not parse is skipped and counted (`network.parse_skipped`); it is never read as
  zero traffic. A run whose header is missing or that exits non-zero is `failed`.

**Sampling.** Per-interval bytes are deltas between two cumulative readings of the same
(pid, start time). A process that is new since the last reading counts from zero at its first
reading (its earlier traffic is attributed to "before MacMax looked", not to this interval). A
counter that went down marks that process's interval `failed`.

**Streaming (verified in U3).** One long-lived child, `nettop -P -L 0 -s <interval> -x -J
bytes_in,bytes_out`. The one-shot `-L 1` run is not an option: a process's totals vanish once its
sockets close (a 5 MiB loopback download read 5242943 bytes while the socket was open and 0 after
close), so a one-shot run misses every short connection. The running child keeps the totals. Two
facts the reader depends on: nettop prints no block terminator (a block starts at the header line
`,bytes_in,bytes_out,`), and through a pipe it buffers 4 KB so a block's tail arrives one sample late;
on a pty it flushes the whole block at once. So the child's stdout is a pty (lines end in `\r\n`), a block
counts as complete when its rows stop arriving for 200 ms, and `collect` waits for the first block
that started after the call, so a transfer that just ended is in it (up to one interval of latency).

**Supervision.** The child is a small `sh` guard that runs nettop and ends it when the app exits (the
guard polls its parent pid), when nettop exits, or when the app terminates the guard; nettop itself
does not exit when its reader goes away. The collector starts it on the first `collect`; if it dies
or produces no block within the interval plus 4 s, that tick's process readings are `failed` with the
reason and the next tick starts a new child (restart backoff arrives with the sampler in U5). A CPU check on the child is part of `scripts/perf.sh`.

**Grouping and storage.** Rows are grouped by app (ARCHITECTURE.md, App grouping) and stored as
`app_samples.net_in_bytes` and `net_out_bytes` per tick; interface totals come from the sum and
from the kernel's 64-bit interface counters (`sysctl NET_RT_IFLIST2`, `if_data64`; `getifaddrs` counters are
32-bit and wrap within minutes on a fast link; loopback is left out),
so traffic of processes that ended between ticks still shows in the totals.

**Connections on demand.** Expanding an app in the Network tab reads its current connections once:
`nettop -m tcp -L 1 -x -n -p <pid>` (verified in U3; open sockets only, which is what the panel shows). Remote
addresses are shown as IPs; reverse DNS only on a press per row (it is a network call to the
resolver and can be slow).

**What the README must say.** MacMax reads traffic counters macOS already keeps; it does not
capture or inspect packets, cannot see what a connection carries, and cannot block anything.

## Network identity (U4)

### VPN state (verified)

`/usr/sbin/scutil --nc list` lists Network Extension VPN services with their state. Captured on the
owner's Mac (values replaced):

```
Available network connection services in the current set (*=enabled):
* (Connected)      <UUID> VPN (org.outline.macos.client) "<name>" [VPN:org.outline.macos.client]
* (Disconnected)   <UUID> VPN (io.tailscale.ipn.macsys) "<name>" [VPN:io.tailscale.ipn.macsys]
```

Parse state (`Connected`, `Disconnected`, `Connecting`, `Disconnecting`, `Invalid`), the provider
bundle id and the quoted name (names can contain quotes and spaces: parse from the bracketed type
backwards). Known bundle ids get a friendly label (Outline, Tailscale, WireGuard, Mullvad,
ProtonVPN); others show their quoted name. This command returns nothing inside the Claude Code
sandbox: live tests run outside it.

Not every VPN is a Network Extension service (some run a `utun` interface from a daemon). The route
check below catches those: a default route through `utun*` with no service listed is shown as
"Tunnel active (unknown app)".

### Default route (verified in U4)

`route -n get default` gives the interface of the default route; `utun*`, `ipsec*` or `ppp*` means
the route goes through a tunnel. The physical interface comes from `scutil --nwi` (first non-tunnel, non-`lo` entry in the service order; with Outline connected `utun7` is listed before `en0`). `NWPathMonitor` (wired in U5) triggers a re-check on every path change (Wi-Fi
switch, VPN connect or disconnect, sleep and wake). Split-tunnel VPNs keep the default route on the
physical interface; the verdict accounts for that (below).

### Public IP and ISP IP (verified)

- **Public IP** = what the internet sees on the default route:
  `curl -sS --connect-timeout 5 --max-time 10 https://1.1.1.1/cdn-cgi/trace`, fields `ip=` and
  `loc=` (two-letter country). With Outline connected this returned the VPN server's IP and DE.
- **ISP IP** = what the internet would see without the tunnel: the same request with
  `--interface <physical>` where `<physical>` is the primary non-tunnel interface (`en0` on most
  Macs; taken from the system's service order, not hard-coded). With Outline connected this
  returned the home ISP's IP and RO.
- Requests by IP literal avoid a DNS lookup that could itself leak or fail; TLS is verified (the
  certificate covers 1.1.1.1). Both values are validated as IPv4 or IPv6 literals; anything else is
  `failed`. Both requests run through ProcessRunner with the timeouts above. The client runs `/usr/bin/curl` with `--proto =http,https`, a 64 KiB body cap and `-w` for the status; only an HTTP 200 whose body parses is `ok`. The endpoint must start with `http://` or `https://`, is passed after `--`, and the interface must be letters then digits, so neither can become a curl flag.
- When: at launch, on every path change (debounced 3 s), every 5 minutes, and on "Check now". Never
  more than once per 30 s.
- Turned off in Settings > Network: no request is made, the card says the check is off.
- The endpoint is editable (D3). A custom endpoint must return the same `key=value` lines or JSON
  with `ip` and `country`; the parser accepts only those two shapes.

### Leak verdict

Inputs: VPN state (any service `Connected`), route through a tunnel, public IP, ISP IP, and whether
any lookup failed. Rules, first match wins:

| Condition | Verdict | Shown |
|-----------|---------|-------|
| IP check turned off | `off` | "IP check is off" (neutral) |
| a lookup failed or timed out | `unknown` | "Could not check: <reason>" (grey, never green) |
| no VPN connected and no tunnel route ("in use" below means a connected service or a tunnel route) | `no_vpn` | "No VPN. Your IP: <public> (<cc>)" |
| VPN connected and public IP equals ISP IP | `leak` | "VPN connected, but traffic leaves through your ISP" (red, CRIT) |
| VPN connected, route not via tunnel, public IP differs from ISP IP | `split_tunnel` | "VPN connected for some traffic; your default traffic leaves as <public>" (warn color, INFO finding) |
| VPN connected, route via tunnel, public IP differs from ISP IP | `tunnel_ok` | "Traffic goes through <VPN name> as <public> (<cc>)" |
| tunnel route with no VPN service listed, IPs differ | `tunnel_ok` | "Tunnel active (unknown app) as <public>" |

`vpn_leak` and `ip_changed` rules read this verdict (RULES.md). The verdict and the IPs are stored
in `identity` only when something changed.

### Privacy

The IPs are personal data of the user. They stay on the Mac: stored in `~/.macmax` (0700), shown in
the app, returned by the local MCP server to the user's own agent. Screenshots and fixtures use
RFC 5737 addresses only (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24). The request to the IP
endpoint is the only network call MacMax makes besides the update check, and the README says so.
