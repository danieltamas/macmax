import Foundation
import Testing
@testable import MacMaxCore

@Suite("Audit engine acceptance")
struct AuditEngineAcceptanceTests {
    @Test("rule ids, metadata, and threshold defaults are the documented contract")
    func ruleMetadata() {
        #expect(RuleSet.all.map(\.id) == auditRuleIDs)
        #expect(Set(RuleSet.all.map(\.id)).count == auditRuleIDs.count)
        #expect(RuleSet.all.allSatisfy { !$0.title.isEmpty && !$0.why.isEmpty })
        let thresholds = RuleSet.all.flatMap(\.thresholds)
        #expect(Set(thresholds.map(\.key)).count == thresholds.count)
        #expect(thresholds.allSatisfy { $0.range.contains($0.defaultValue) })
        let defaults = Dictionary(uniqueKeysWithValues: thresholds.map { ($0.key, $0.defaultValue) })
        let expected: [String: Double] = [
            "T_UPTIME_CRIT_D": 30, "T_UPTIME_WARN_D": 14,
            "T_LOAD_CRIT_X": 2, "T_LOAD_WARN_X": 1, "T_IDLE_CRIT": 10,
            "T_KERNEL_CPU_WARN": 40, "T_PROC_WARN": 800,
            "T_SWAP_CRIT_GB": 6, "T_SWAP_WARN_GB": 2, "T_SWAPIN_RATE": 50,
            "T_COMP_CRIT_PCT": 35, "T_COMP_WARN_PCT": 20,
            "T_MEMLEVEL_CRIT": 40, "T_MEMLEVEL_WARN": 60,
            "T_CLAUDE_DAYS": 7, "T_CLAUDE_WARN_N": 5, "T_SIDECAR_WARN": 30,
            "T_ZOMBIE_WARN": 5, "T_VM_CMPRS_GB": 2, "T_CONTAINER_CPU": 25,
            "T_DAEMON_RSS_MB": 1024, "T_DISK_CRIT_PCT": 10,
            "T_DISK_WARN_PCT": 15, "T_IOPS_WARN": 1500, "T_CHROME_PROCS": 40,
            "T_APP_RAM_PCT": 10, "T_CRASH_WARN": 10, "T_BG_ITEMS_WARN": 25,
            "T_TRANSLATED_CPU": 10, "T_GROWTH_MB": 1024,
            "T_GROWTH_PCT": 50, "T_GROWTH_CPU": 5
        ]
        #expect(defaults == expected)
    }

    @Test("finding and unknown ordering follow severity and rule order")
    func ordering() {
        var s = healthyAuditSnapshot()
        s.uptimeDays = .ok(14)
        s.swapUsedGB = .ok(7)
        s.processCount = .failed("reason process")
        s.zombies = .failed("reason zombies")
        s.ipChangedFixture()
        let report = AuditEngine.evaluate(s)
        #expect(report.findings.map(\.ruleID) == ["swap_used", "uptime", "ip_changed"])
        #expect(report.findings.map(\.severity) == [.crit, .warn, .info])
        #expect(report.unknowns.map(\.ruleID) == ["process_count", "zombies"])
    }

    @Test("verdict is highest actionable severity and info does not raise it")
    func verdict() {
        var s = healthyAuditSnapshot()
        #expect(AuditEngine.evaluate(s).verdict == .ok)
        s.ipChangedFixture(); #expect(AuditEngine.evaluate(s).verdict == .ok)
        s.uptimeDays = .ok(14); #expect(AuditEngine.evaluate(s).verdict == .warn)
        s.swapUsedGB = .ok(7); #expect(AuditEngine.evaluate(s).verdict == .crit)
        s.processCount = .failed("reason X")
        let report = AuditEngine.evaluate(s)
        #expect(report.verdict == .crit)
        #expect(report.unknowns.map(\.ruleID).contains("process_count"))
    }

    @Test("some unknown rules plus evaluated passes is ok")
    func partialUnknown() {
        var s = healthyAuditSnapshot(); s.processCount = .failed("reason X")
        let report = AuditEngine.evaluate(s)
        #expect(report.verdict == .ok)
        #expect(report.findings.isEmpty)
        #expect(report.unknowns.map(\.ruleID) == ["process_count"])
    }

    @Test("disabled rule is not evaluated or reported")
    func disabled() {
        var finding = healthyAuditSnapshot(); finding.swapUsedGB = .ok(7)
        var failed = healthyAuditSnapshot(); failed.swapUsedGB = .failed("reason X")
        for snapshot in [finding, failed] {
            let report = AuditEngine.evaluate(snapshot, disabled: ["swap_used"])
            #expect(!report.findings.map(\.ruleID).contains("swap_used"))
            #expect(!report.unknowns.map(\.ruleID).contains("swap_used"))
        }
    }

    @Test("threshold overrides move lines, clamp bounds, and ignore invalid keys and numbers")
    func thresholdOverrides() throws {
        var s = healthyAuditSnapshot(); s.swapUsedGB = .ok(7)
        #expect(auditFinding("swap_used", in: s)?.severity == .crit)
        #expect(auditFinding("swap_used", in: s, thresholds: ["T_SWAP_CRIT_GB": 8])?.severity == .warn)
        let threshold = try #require(RuleSet.all.flatMap(\.thresholds).first { $0.key == "T_SWAP_CRIT_GB" })
        let below = AuditEngine.evaluate(s, thresholds: [threshold.key: threshold.range.lowerBound - 1])
        let lower = AuditEngine.evaluate(s, thresholds: [threshold.key: threshold.range.lowerBound])
        #expect(below == lower)
        let above = AuditEngine.evaluate(s, thresholds: [threshold.key: threshold.range.upperBound + 1])
        let upper = AuditEngine.evaluate(s, thresholds: [threshold.key: threshold.range.upperBound])
        #expect(above == upper)
        let baseline = AuditEngine.evaluate(s)
        #expect(AuditEngine.evaluate(s, thresholds: [threshold.key: .nan]) == baseline)
        #expect(AuditEngine.evaluate(s, thresholds: [threshold.key: .infinity]) == baseline)
        #expect(AuditEngine.evaluate(s, thresholds: ["T_UNKNOWN": 1]) == baseline)
    }

    @Test("array evidence sorting and JSON are independent of input order")
    func arrayOrder() throws {
        var a = healthyAuditSnapshot()
        a.containerCPU = .ok([.init(name: "worker-1", value: 30), .init(name: "web-1", value: 30), .init(name: "api-1", value: 40)])
        a.daemonResidentMB = .ok([.init(name: "Finder", value: 1200), .init(name: "WindowServer", value: 1400)])
        var b = a
        b.containerCPU = .ok([.init(name: "api-1", value: 40), .init(name: "web-1", value: 30), .init(name: "worker-1", value: 30)])
        b.daemonResidentMB = .ok([.init(name: "WindowServer", value: 1400), .init(name: "Finder", value: 1200)])
        let ra = AuditEngine.evaluate(a), rb = AuditEngine.evaluate(b)
        #expect(ra == rb)
        #expect(try AuditJSON.encode(ra) == AuditJSON.encode(rb))
        #expect(auditFinding("docker_hot_containers", in: a)?.evidence.dropFirst().map(\.key)
                == ["api-1", "web-1", "worker-1"])
    }

    @Test("one snapshot encodes byte-identically one hundred times")
    func deterministicJSON() throws {
        var s = healthyAuditSnapshot(); s.swapUsedGB = .ok(7); s.uptimeDays = .ok(14)
        let report = AuditEngine.evaluate(s)
        let expected = try AuditJSON.encode(report)
        for _ in 0..<100 { #expect(try AuditJSON.encode(report) == expected) }
    }

    @Test("JSON uses sorted snake-case keys and exact enum strings")
    func exactJSON() throws {
        let report = AuditReport(timestamp: 42, verdict: .crit, findings: [Finding(
            ruleID: "example_rule", severity: .crit, title: "Example title",
            evidence: [.init("value", "7")], why: "Example why", action: "Example action",
            scriptPattern: "^Example$")], unknowns: [
                UnknownRule(ruleID: "other_rule", title: "Other title", reason: "reason X")])
        let expected = #"{"findings":[{"action":"Example action","evidence":[{"key":"value","value":"7"}],"rule_id":"example_rule","script_pattern":"^Example$","severity":"crit","title":"Example title","why":"Example why"}],"timestamp":42,"unknowns":[{"reason":"reason X","rule_id":"other_rule","title":"Other title"}],"verdict":"crit"}"#
        #expect(String(decoding: try AuditJSON.encode(report), as: UTF8.self) == expected)
    }

    @Test("notification diff emits first criticals and only new or worsened findings")
    func notificationDiff() {
        let info = finding("ip_changed", .info), warn = finding("uptime", .warn)
        let crit = finding("swap_used", .crit), worsened = finding("uptime", .crit)
        let first = report([info, warn, crit])
        #expect(NotificationDiff.changes(previous: nil, current: first).map(\.ruleID) == ["swap_used"])
        let previous = report([warn, crit])
        let current = report([crit, worsened, finding("memory_growth", .warn), info])
        #expect(NotificationDiff.changes(previous: previous, current: current).map(\.ruleID)
                == ["uptime", "memory_growth", "ip_changed"])
        #expect(NotificationDiff.changes(previous: current, current: current).isEmpty)
    }

    private func finding(_ id: String, _ severity: Severity) -> Finding {
        Finding(ruleID: id, severity: severity, title: id, evidence: [], why: "why",
                action: nil, scriptPattern: nil)
    }

    private func report(_ findings: [Finding]) -> AuditReport {
        AuditReport(timestamp: 1, verdict: .ok, findings: findings, unknowns: [])
    }
}

private extension AuditSnapshot {
    mutating func ipChangedFixture() {
        previousIdentity = .ok(.init(publicIP: "198.51.100.20", publicCountry: "DE"))
    }
}
