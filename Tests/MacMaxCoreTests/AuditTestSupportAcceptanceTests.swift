import Foundation
import Testing
@testable import MacMaxCore

let auditRuleIDs = [
    "uptime", "load", "cpu_idle", "kernel_cpu", "process_count", "swap_used",
    "swap_in_rate", "compressor", "memory_level", "claude_stale", "mcp_sidecars",
    "zombies", "docker_vm_compressed", "docker_hot_containers", "daemon_bloat",
    "disk_free", "disk_iops", "chrome_processes", "big_apps", "crash_reports",
    "jetsam", "launch_items", "thermal_limit", "brew_under_rosetta", "translated_hot",
    "vpn_leak", "vpn_expected_down", "ip_changed", "memory_growth"
]

func healthyAuditSnapshot() -> AuditSnapshot {
    var snapshot = AuditSnapshot()
    snapshot.timestamp = 1_700_000_000
    snapshot.uptimeDays = .ok(1)
    snapshot.load5 = .ok(1)
    snapshot.coreCount = .ok(8)
    snapshot.ramBytes = .ok(16 * 1_073_741_824)
    snapshot.cpuIdlePercent = .ok(90)
    snapshot.kernelTaskCPU = .ok(1)
    snapshot.processCount = .ok(100)
    snapshot.zombies = .ok(0)
    snapshot.swapUsedGB = .ok(0)
    snapshot.swapInsPerSecond = .ok(0)
    snapshot.compressorPercent = .ok(1)
    snapshot.memoryLevel = .ok(100)
    snapshot.claudeSessionAgesDays = .ok([])
    snapshot.mcpSidecars = .ok(0)
    snapshot.dockerVMCompressedGB = .unavailable("Docker not installed")
    snapshot.containerCPU = .unavailable("Docker not installed")
    snapshot.daemonResidentMB = .ok([])
    snapshot.diskFreePercent = .ok(90)
    snapshot.diskIOPS = .ok(0)
    snapshot.chromeProcesses = .ok(0)
    snapshot.apps = .ok([])
    snapshot.crashReports7d = .ok(0)
    snapshot.jetsam7d = .ok(0)
    snapshot.launchItems = .ok(0)
    snapshot.cpuSpeedLimit = .ok(100)
    snapshot.appleSilicon = .ok(true)
    snapshot.brewInstalls = .ok(BrewInstalls(intelPrefixIsX86: false, nativePrefixPresent: true))
    snapshot.translatedProcesses = .ok([])
    snapshot.identity = .ok(IdentityFacts(verdict: "protected", vpnConnected: true,
                                          publicIP: "192.0.2.10", publicCountry: "RO"))
    snapshot.previousIdentity = .ok(PreviousIdentity(publicIP: "192.0.2.10", publicCountry: "RO"))
    snapshot.appGrowth = .ok([])
    return snapshot
}

func auditFinding(_ id: String, in snapshot: AuditSnapshot,
                  thresholds: [String: Double] = [:], disabled: Set<String> = []) -> Finding? {
    AuditEngine.evaluate(snapshot, thresholds: thresholds, disabled: disabled)
        .findings.first { $0.ruleID == id }
}

func expectAuditFinding(_ id: String, _ severity: Severity, _ snapshot: AuditSnapshot,
                        evidence: [EvidenceItem]? = nil,
                        thresholds: [String: Double] = [:]) {
    let finding = auditFinding(id, in: snapshot, thresholds: thresholds)
    #expect(finding?.ruleID == id)
    #expect(finding?.severity == severity)
    if let evidence { #expect(finding?.evidence == evidence) }
}

func expectNoAuditFinding(_ id: String, _ snapshot: AuditSnapshot,
                          thresholds: [String: Double] = [:]) {
    #expect(auditFinding(id, in: snapshot, thresholds: thresholds) == nil)
}
