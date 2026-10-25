import Foundation
import Testing
@testable import MacMaxCore

@Suite("Audit parity pattern acceptance")
struct AuditPatternAcceptanceTests {
    private let messages: [String: [String]] = [
        "uptime": ["Uptime 31 days: fseventsd, WindowServer and the compressor only reset on reboot", "Uptime 15 days"],
        "load": ["Load 9.5 is over 2x the core count", "Load 5.1 exceeds the core count"],
        "cpu_idle": ["CPU idle 5% (system 20%)"],
        "kernel_cpu": ["kernel_task at 55% CPU: memory compression or swap, not an app"],
        "process_count": ["900 processes"],
        "swap_used": ["Swap 7.2 GB in use: the working set does not fit in 16 GB", "Swap 3.0 GB in use"],
        "swap_in_rate": ["Swapping in 80 pages/s right now: active thrash"],
        "compressor": ["Compressor holds 40% of RAM"],
        "memory_level": ["memorystatus_level 30: the kernel is in its critical band (Jetsam territory)", "memorystatus_level 55"],
        "claude_stale": ["6 claude sessions older than 7 days hold about 900 MB plus 4 sidecars", "2 claude session(s) older than 7 days"],
        "mcp_sidecars": ["35 MCP sidecar processes"],
        "zombies": ["7 zombie processes"],
        "docker_vm_compressed": ["Docker VM has 3.1G of its memory compressed by macOS: the guest spins waiting for its own RAM"],
        "docker_hot_containers": ["Containers above 25% CPU: web-1 (31.0%) "],
        "daemon_bloat": ["WindowServer at 1500 MB resident (normal is well under 1 GB); only a reboot resets it"],
        "disk_free": ["Only 8% disk free: APFS and the swap file degrade here", "12% disk free"],
        "disk_iops": ["Boot disk at 2000 IOPS sustained: swap or a heavy writer (see containers and top CPU)"],
        "chrome_processes": ["45 Chrome processes"],
        "big_apps": ["Single apps above 10% of RAM: Example App (3000 MB) "],
        "crash_reports": ["12 crash or resource reports in 7 days"],
        "jetsam": ["3 Jetsam events: the kernel ran out of memory headroom"],
        "launch_items": ["30 third-party launch items"],
        "thermal_limit": ["CPU speed limit 70%: thermal throttling"]
    ]

    @Test("ported patterns are anchored, compile, match their messages, and do not overlap")
    func patterns() throws {
        let ported = RuleSet.all.filter { messages[$0.id] != nil }
        #expect(ported.count == messages.count)
        for rule in ported {
            let pattern = try #require(rule.scriptPattern)
            #expect(pattern.hasPrefix("^") && pattern.hasSuffix("$"), "pattern for \(rule.id) must be anchored")
            let regex = try NSRegularExpression(pattern: pattern)
            for message in try #require(messages[rule.id]) {
                #expect(matches(regex, message), "\(rule.id) did not match \(message)")
                for other in ported where other.id != rule.id {
                    let otherPattern = try #require(other.scriptPattern)
                    #expect(!matches(try NSRegularExpression(pattern: otherPattern), message),
                            "\(other.id) also matched message for \(rule.id)")
                }
            }
        }
    }

    @Test("new rules deliberately have no private-script pattern")
    func newRules() {
        let ids = ["brew_under_rosetta", "translated_hot", "vpn_leak", "vpn_expected_down", "ip_changed", "memory_growth"]
        #expect(RuleSet.all.filter { ids.contains($0.id) }.allSatisfy { $0.scriptPattern == nil })
    }

    private func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
