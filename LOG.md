# Release log

## 0.4.0 (2026-10-28)

More apps now reads one shared list of the maker's apps, kept in the public danieltamas/registry repository, instead of a list built into MacMax. When a new app joins or an app ships a release, the page shows it without a MacMax update: the list carries each app's copy, icon, install command and latest release, and the registry picks up a new release within the hour. Bton's 0.11.0 is the first release that reached the page this way.

MacMax ships with a copy of the list, so the page is full on first launch and offline, and says how old that copy is. It reads the list again when the page opens and the last read is more than an hour old, and whenever you press refresh. A read that fails or is refused changes nothing on the cards; the header names the problem and the time of the last good read. An app the list describes in a way this MacMax cannot check is left out and counted, never shown half-read.

The page no longer asks GitHub's API about each app: the only request is one file from raw.githubusercontent.com, plus an icon the first time an app appears or its icon changes. README and SECURITY.md list it.

## 0.3.1 (2026-10-28)

More apps now follows each app's releases instead of showing what was true when MacMax was built. When you open the page, MacMax asks GitHub for the latest release of Bton, RMJ, Axon, Run.dev and Cloak and shows its version and how long ago it came out; the answer is kept for six hours, and the refresh button asks again. An app with no release yet shows In development and no install command, and switches to its install command on its own once its first release is out. A version GitHub could not give shows as Version unknown, never as an older answer.

For Bton and RMJ, the card also says whether the copy on this Mac is up to date or a newer release is out, with an Open link. A copy built from source says so and makes no claim about updates.

The only new network traffic is those GitHub requests, made only while the page is open; README and SECURITY.md list them.

## 0.3.0 (2026-10-28)

Settings has a new More apps page with the other open source tools from the maker of MacMax, for a Mac that runs coding agents: Bton and RMJ in the menu bar, Axon, Run.dev and Cloak in the terminal. Each one shows what it does, links to its website and GitHub, and its install command with a copy button. RMJ has no release yet, so it shows as in development with no install command. The page only opens links in your browser when you press them; MacMax still contacts nothing new.

The copy button in Agent access now turns into a check for a moment when you press it, so you can see the command was copied.

## 0.2.0 (2026-10-28)

Battery and heat now lists every sensor MacMax can name, in groups: the CPU cores it can tell apart, the GPU, memory, storage, the wireless chip, the battery cells and the airflow, each group with its hottest and average reading, plus what the Mac draws at the wall and on each Thunderbolt port. Press a group to see its sensors; the list opens right under it. The battery row is three dials (charge, health, cycles against the rated number) matching the heat row below it.

The hottest-sensor dial no longer shows a false 100 C. The SMC exposes limit keys that read above 100 C all day, and the dial used to pick them up; it now reports the hottest of the sensors MacMax can name. The battery's own temperature line is gone once the grid has the battery cells.

This Mac shows how busy the efficiency and performance clusters are, the CPU time split into user, system and idle as one bar, the load averages, uptime, the GPU and its memory, as a grid of small stats. A stat that does not read on your Mac is left out, never shown as zero. Core frequency is not shown: macOS offers it only through a private interface.

## 0.1.5 (2026-10-27)

Disk free in the Overview now shows the same figure as Finder and Disk Utility. Before, it counted purgeable space as free, so it read tens of GB above every other tool on a Mac with Time Machine local snapshots. The tile now says, for example, "329 GB free, 80 GB purgeable": the second number is what macOS would clear on its own when a write needs the room. The disk audit rule and the agent API already used the plain figure and are unchanged; the `snapshot` command gains `purgeable_bytes` when read live.

## 0.1.4 (2026-10-27)

MacMax now installs and runs on macOS 13 (Ventura) as well as 14 and newer, on Apple silicon and Intel. The one-line installer accepts a Mac on 13 and downloads the same release build; nothing is built on your Mac. Building MacMax from source still needs Xcode 26 on macOS 15 or newer.

## 0.1.3 (2026-10-27)

Disk IO no longer shows as a failure on a Mac that has no internal disk driver, such as a virtual machine. It now says the Mac publishes no internal disk counters. A disk read that really fails still shows as failed.

## 0.1.2 (2026-10-27)

Battery and heat shows fresh readings after the Mac wakes. Before, one sensor read that hung during sleep blocked every later read, so the next morning the fans showed 0 rpm and did not turn while the hottest sensor read hot. A read that takes too long is now dropped and a new one starts.

## 0.1.1 (2026-10-26)

"Check again" in About now checks when you press it. Before, a press within 15 minutes of the last check did nothing, so right after launch the button looked broken. It only waits now when GitHub has asked MacMax to pause, and it says so.

## 0.1.0 (2026-10-26)

The first release: a menu bar app that tells you why your Mac is slow and cleans up safely. A scheduled audit, per-app CPU, memory, disk and network, public IP and VPN state, cleanup that goes to the Trash after a preview, uninstall with leftovers, battery and heat, and a read-only MCP server and CLI for coding agents.
