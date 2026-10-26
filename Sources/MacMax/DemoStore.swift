import Foundation
import MacMaxCore

/// Synthetic data for the README's screenshots (docs/SCREENSHOTS.md): made-up apps, RFC 5737 addresses, a fixed
/// clock. Nothing here comes from this Mac.
@MainActor
enum DemoStore {
    /// 2026-10-25 14:30 UTC.
    static let now = Date(timeIntervalSince1970: 1_792_938_600)

    static func model(stress: Bool = false, leak: Bool = false) -> PanelModel {
        let model = PanelModel()
        let long = "Northwind Integrated Development Environment"
        model.samplerNote = "Sampling every 10 s"
        model.vitals = vitals(stress: stress)
        model.vitalsState = .ready
        model.identity = identity(leak: leak)
        model.identityState = .ready
        model.verdict = leak ? .crit : .warn
        model.findings = findings()
        model.unknowns = [UnknownRule(ruleID: "thermal_limit", title: "Thermal limit",
                                      reason: "The thermal state could not be read.")]
        model.auditedAt = now.addingTimeInterval(-7 * 60)
        model.auditState = .ready
        model.apps = apps(stress: stress, longName: long)
        model.appsState = .ready
        model.sort = .memory
        model.expandedApp = "ro.example.atlas"
        model.processes = ["ro.example.atlas": processes(stress: stress)]
        model.topConsumers = PanelData.topConsumers(model.apps)
        model.interfaces = [InterfaceLine(name: "Wi-Fi (en0)", inPerSecond: stress ? 9_437_184 : 1_258_291, outPerSecond: 213_000),
                            InterfaceLine(name: "Outline (utun4)", inPerSecond: 1_100_000, outPerSecond: 190_000)]
        model.window = .hour
        model.traffic = traffic(stress: stress, longName: long)
        model.trafficState = .ready
        model.samplerFailed = false
        model.actionStates["end-302-2"] = .asked("Asked to end. Press again to force.")
        model.cleanupPreview = cleanup()
        model.lastCleanups = [
            ActionRow(ts: Int64(now.timeIntervalSince1970) - 3_600, kind: "cleanup", target: "/Users/example/Library/Caches/ro.example.pixel",
                      result: "trashed", detail: "app_caches, 1.2 GB"),
            ActionRow(ts: Int64(now.timeIntervalSince1970) - 86_400, kind: "cleanup", target: "/Users/example/.npm/_cacache",
                      result: "trashed", detail: "npm_cache, 640 MB"),
        ]
        model.config.protectedPaths = ["/Users/example/Projects"]
        return model
    }

    private static func series(_ base: Double, _ swing: Double, seed: Double) -> [Double] {
        (0 ..< 60).map { base + swing * sin(Double($0) / 6 + seed) * cos(Double($0) / 17 + seed * 2) }
    }

    private static func vitals(stress: Bool) -> [Vital] {
        [
            Vital(kind: .cpu, value: "38%", detail: "busy", series: series(40, 25, seed: 1), edge: nil),
            Vital(kind: .memory, value: "Warning", detail: stress ? "123 GB used" : "13 GB used", series: series(70, 12, seed: 2), edge: .warn),
            Vital(kind: .swap, value: "3.1 GB", detail: "in use", series: series(3, 1.2, seed: 3), edge: .warn),
            Vital(kind: .disk, value: "86 GB", detail: "free", series: series(86, 0.4, seed: 4), edge: nil),
            Vital(kind: .netIn, value: stress ? "9999 KB/s" : "1.2 MB/s", detail: "right now", series: series(1.2, 0.9, seed: 5), edge: nil),
            Vital(kind: .netOut, value: "208 KB/s", detail: "right now", series: series(0.2, 0.15, seed: 6), edge: nil),
        ]
    }

    private static func identity(leak: Bool) -> IdentityCard {
        if leak {
            return IdentityCard(verdict: .leak, publicIP: "198.51.100.7", publicCountry: "RO", ispIP: "198.51.100.7", ispCountry: "RO",
                                vpnName: "Outline", vpnState: "connected", checkEnabled: true, reason: nil, changeNote: nil)
        }
        return IdentityCard(verdict: .tunnelOK, publicIP: "203.0.113.20", publicCountry: "DE", ispIP: "198.51.100.7", ispCountry: "RO",
                            vpnName: "Outline", vpnState: "connected", checkEnabled: true, reason: nil,
                            changeNote: "IP changed at 14:02 from 198.51.100.7 (RO) to 203.0.113.20 (DE)")
    }

    private static func findings() -> [Finding] {
        func finding(_ id: String, _ severity: Severity, _ title: String, _ evidence: [EvidenceItem]) -> Finding {
            let rule = RuleSet.all.first { $0.id == id }
            return Finding(ruleID: id, severity: severity, title: title, evidence: evidence, why: rule?.why ?? "",
                           action: rule?.action, scriptPattern: nil)
        }
        return [
            finding("docker_vm_compressed", .crit, "Docker VM has 2.3 GB of its memory compressed by macOS", [EvidenceItem("compressed", "2.3 GB")]),
            finding("swap_used", .warn, "Swap 3.1 GB in use", [EvidenceItem("swap used", "3.1 GB")]),
            finding("claude_stale", .warn, "3 Claude Code sessions older than 7 days", [EvidenceItem("sessions", "3"), EvidenceItem("sidecars", "41")]),
        ]
    }

    private static func apps(stress: Bool, longName: String) -> [AppRow] {
        let big: UInt64 = stress ? 99_999 * 1_048_576 : 5_600 * 1_048_576
        return [
            AppRow(id: "ro.example.atlas", name: "Atlas Browser", bundleID: "ro.example.atlas", pids: [301, 302], processCount: 38,
                   cpuPercent: 24, footprintBytes: big, diskBytesPerSecond: 120_000, networkBytesPerSecond: 640_000),
            AppRow(id: "ro.example.northwind", name: stress ? longName : "Northwind IDE", bundleID: "ro.example.northwind", pids: [410],
                   processCount: 9, cpuPercent: stress ? 1_234 : 61, footprintBytes: 2_100 * 1_048_576, diskBytesPerSecond: 40_000,
                   networkBytesPerSecond: 12_000),
            AppRow(id: "claude", name: "Claude Code", kind: .claudeCode, pids: [520], processCount: 6, cpuPercent: 4,
                   footprintBytes: 1_300 * 1_048_576, diskBytesPerSecond: 2_000, networkBytesPerSecond: 90_000),
            AppRow(id: "ro.example.docker", name: "Docker", kind: .docker, pids: [600], processCount: 3, cpuPercent: 9,
                   footprintBytes: 4_000 * 1_048_576, diskBytesPerSecond: 800_000, networkBytesPerSecond: 20_000),
            AppRow(id: "ro.example.mail", name: "Harbor Mail", bundleID: "ro.example.mail", pids: [700], processCount: 4, cpuPercent: 2,
                   footprintBytes: 640 * 1_048_576, diskBytesPerSecond: 1_000, networkBytesPerSecond: 30_000),
            AppRow(id: "ro.example.pixel", name: "Pixel Studio", bundleID: "ro.example.pixel", pids: [800], processCount: 5, cpuPercent: 7,
                   footprintBytes: 980 * 1_048_576, diskBytesPerSecond: 5_000, networkBytesPerSecond: nil),
            AppRow(id: "ro.example.notes", name: "Tidal Notes", bundleID: "ro.example.notes", pids: [900], processCount: 2, cpuPercent: 0.4,
                   footprintBytes: 210 * 1_048_576, diskBytesPerSecond: 0, networkBytesPerSecond: 1_000),
            AppRow(id: "ro.example.chat", name: "Relay Chat", bundleID: "ro.example.chat", pids: [950], processCount: 6, cpuPercent: 3,
                   footprintBytes: 760 * 1_048_576, diskBytesPerSecond: 2_000, networkBytesPerSecond: 55_000),
        ]
    }

    private static func cleanup() -> CleanupPreview {
        func item(_ rule: String, _ path: String, _ megabytes: Int64) -> CleanupCandidate {
            CleanupCandidate(ruleID: rule, path: "/Users/example/" + path, bytes: megabytes * 1_048_576, device: 1, inode: UInt64(megabytes))
        }
        return CleanupPreview(candidates: [
            item("app_caches", "Library/Caches/ro.example.pixel", 1_229), item("xcode_derived", "Library/Developer/Xcode/DerivedData/Northwind-abc", 2_480),
            item("npm_cache", ".npm/_cacache", 640), item("homebrew_cache", "Library/Caches/Homebrew", 310),
            item("old_logs", "Library/Logs/example.log", 24),
        ], skipped: [CleanupSkip(path: "/Users/example/Library/Caches/Yarn", reason: "yarn is running")])
    }

    private static func processes(stress: Bool) -> [ProcessLine] {
        [
            ProcessLine(pid: 301, name: "Atlas Browser", cpuPercent: 8, footprintBytes: 640 * 1_048_576, isTranslated: false, commandLine: nil, startUs: 1),
            ProcessLine(pid: 302, name: "Atlas Browser Helper (Renderer)", cpuPercent: 11, footprintBytes: 910 * 1_048_576, isTranslated: true,
                        commandLine: "/Applications/Atlas Browser.app/Contents/MacOS/Helper --type=renderer --token [redacted]", startUs: 2),
        ]
    }

    private static func traffic(stress: Bool, longName: String) -> [TrafficLine] {
        let names = ["Atlas Browser", stress ? longName : "Northwind IDE", "Claude Code", "Relay Chat", "Harbor Mail", "Docker",
                     "Pixel Studio", "Tidal Notes"]
        return names.enumerated().map { index, name in
            let scale = Double(8 - index)
            return TrafficLine(id: name, name: name, bytesIn: scale * (stress ? 9_999_000_000 : 41_000_000), bytesOut: scale * 6_000_000)
        }
    }
}
