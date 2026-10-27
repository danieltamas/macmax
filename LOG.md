# Release log

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
