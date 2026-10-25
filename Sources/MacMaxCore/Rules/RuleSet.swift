import Foundation

/// Every audit rule in evaluation order (docs/RULES.md).
public enum RuleSet {
    static let order = [
        "uptime", "load", "cpu_idle", "kernel_cpu", "process_count", "swap_used", "swap_in_rate", "compressor",
        "memory_level", "claude_stale", "mcp_sidecars", "zombies", "docker_vm_compressed", "docker_hot_containers",
        "daemon_bloat", "disk_free", "disk_iops", "chrome_processes", "big_apps", "crash_reports", "jetsam",
        "launch_items", "thermal_limit", "brew_under_rosetta", "translated_hot", "vpn_leak", "vpn_expected_down",
        "ip_changed", "memory_growth",
    ]

    public static let all: [Rule] = {
        let rules = ThresholdRules.all + [
            WorkloadRules.load, WorkloadRules.claudeStale, WorkloadRules.hotContainers, WorkloadRules.daemonBloat,
            WorkloadRules.bigApps, NewRules.brewUnderRosetta, NewRules.translatedHot, NewRules.vpnLeak,
            NewRules.vpnExpectedDown, NewRules.ipChanged, NewRules.memoryGrowth,
        ]
        let byID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        precondition(byID.count == order.count, "RuleSet.order and the rule definitions disagree")
        return order.map { byID[$0]! }
    }()
}
