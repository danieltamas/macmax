import Foundation

/// Rules that look at a list: the cores against the load, sessions, containers, daemons and apps.
enum WorkloadRules {
    static let load = Rule(
        id: "load", title: "Load average",
        thresholds: [Threshold(key: "T_LOAD_CRIT_X", defaultValue: 2, unit: "x cores", range: 0.5...20),
                     Threshold(key: "T_LOAD_WARN_X", defaultValue: 1, unit: "x cores", range: 0.25...20)],
        why: "More runnable work than cores means everything waits.", action: "Open Apps sorted by CPU",
        scriptPattern: #"^Load [\d.]+ (is over|exceeds) .*$"#
    ) { snapshot, thresholds in
        requiring(snapshot.load5, snapshot.coreCount) { load, cores in
            let levels: [(Severity, String)] = [(.crit, "T_LOAD_CRIT_X"), (.warn, "T_LOAD_WARN_X")]
            for (severity, key) in levels {
                let line = Double(cores) * thresholds[key]
                guard load > line else { continue }
                let text = String(format: "%.2f", load)
                return outcome(severity, severity == .crit ? "Load \(text) is over \(String(format: "%g", thresholds[key]))x the core count"
                                                          : "Load \(text) exceeds the core count",
                               [EvidenceItem("value", text), EvidenceItem("threshold", String(format: "%.2f", line)),
                                EvidenceItem("cores", String(cores))])
            }
            return .pass
        }
    }

    /// The script counts a session as stale from `T_CLAUDE_DAYS` days of age on.
    static let claudeStale = Rule(
        id: "claude_stale", title: "Stale Claude Code sessions",
        thresholds: [Threshold(key: "T_CLAUDE_DAYS", defaultValue: 7, unit: "days", range: 1...365),
                     Threshold(key: "T_CLAUDE_WARN_N", defaultValue: 5, unit: "sessions", range: 1...1000)],
        why: "A session left open keeps its memory and its MCP sidecars for days.", action: "End stale sessions",
        scriptPattern: #"^\d+ claude session.*$"#
    ) { snapshot, thresholds in
        requiring(snapshot.claudeSessionAgesDays) { ages in
            let stale = ages.filter { Double($0) >= thresholds["T_CLAUDE_DAYS"] }.count
            guard stale > 0 else { return .pass }
            let crit = Double(stale) >= thresholds["T_CLAUDE_WARN_N"]
            return outcome(crit ? .crit : .warn, "\(stale) claude session(s) older than \(String(format: "%g", thresholds["T_CLAUDE_DAYS"])) days",
                           [EvidenceItem("value", String(stale)), EvidenceItem("threshold", String(format: "%d", Int(thresholds["T_CLAUDE_WARN_N"]))),
                            EvidenceItem("total", String(ages.count)), EvidenceItem("oldest_days", String(ages.max() ?? 0))])
        }
    }

    static let hotContainers = Rule(
        id: "docker_hot_containers", title: "Busy containers",
        thresholds: [Threshold(key: "T_CONTAINER_CPU", defaultValue: 25, unit: "% CPU", range: 1...1000)],
        why: "A container that keeps a core busy keeps the Docker VM and its host awake.", action: "Stop the container",
        scriptPattern: #"^Containers above .*$"#
    ) { snapshot, thresholds in
        requiring(snapshot.containerCPU) { containers in
            let line = thresholds["T_CONTAINER_CPU"]
            let hot = containers.filter { $0.value > line }.map { (name: $0.name, value: $0.value) }
            guard !hot.isEmpty else { return .pass }
            return .warn(title: "Containers above \(String(format: "%.0f", line))% CPU: \(hot.count)",
                         evidence: [EvidenceItem("threshold", String(format: "%.1f", line))]
                            + sortedEvidence(hot) { String(format: "%.1f%%", $0) })
        }
    }

    static let daemonBloat = Rule(
        id: "daemon_bloat", title: "Bloated system daemons",
        thresholds: [Threshold(key: "T_DAEMON_RSS_MB", defaultValue: 1024, unit: "MB", range: 64...65536)],
        why: "Long-lived system daemons grow over time and only a reboot resets them.", action: "Reboot",
        scriptPattern: #"^(fseventsd|WindowServer|Finder|mds_stores) at .*$"#
    ) { snapshot, thresholds in
        requiring(snapshot.daemonResidentMB) { daemons in
            let line = thresholds["T_DAEMON_RSS_MB"]
            let big = daemons.filter { $0.value > line }.map { (name: $0.name, value: $0.value) }
            guard !big.isEmpty else { return .pass }
            return .warn(title: "\(big.count) system daemon(s) above \(String(format: "%.0f", line)) MB resident",
                         evidence: [EvidenceItem("threshold", String(format: "%d", Int(line)))]
                            + sortedEvidence(big) { String(format: "%d", Int($0)) })
        }
    }

    static let bigApps = Rule(
        id: "big_apps", title: "Apps holding a lot of memory",
        thresholds: [Threshold(key: "T_APP_RAM_PCT", defaultValue: 10, unit: "% of RAM", range: 1...100)],
        why: "One app holding a tenth of the RAM leaves less for everything else.", action: "Quit the app",
        scriptPattern: #"^Single apps above .*$"#
    ) { snapshot, thresholds in
        requiring(snapshot.apps, snapshot.ramBytes) { apps, ram in
            let percent = thresholds["T_APP_RAM_PCT"]
            let big = apps.filter { Double($0.footprintBytes) * 100 > Double(ram) * percent }
                .map { (name: $0.name, value: Double($0.footprintBytes) / 1_048_576) }
            guard !big.isEmpty else { return .pass }
            return .warn(title: "Single apps above \(String(format: "%.0f", percent))% of RAM: \(big.count)",
                         evidence: [EvidenceItem("threshold", String(format: "%.1f", percent))]
                            + sortedEvidence(big) { String(format: "%d", Int($0)) })
        }
    }
}
