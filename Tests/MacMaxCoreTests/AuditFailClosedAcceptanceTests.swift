import Testing
@testable import MacMaxCore

@Suite("Audit fail-closed acceptance")
struct AuditFailClosedAcceptanceTests {
    @Test("every failed rule input produces exactly its unknown and never a finding")
    func everyFailedInput() {
        let cases: [(String, (inout AuditSnapshot) -> Void)] = [
            ("uptime", { $0.uptimeDays = .failed("reason X") }),
            ("load", { $0.load5 = .failed("reason X") }),
            ("cpu_idle", { $0.cpuIdlePercent = .failed("reason X") }),
            ("kernel_cpu", { $0.kernelTaskCPU = .failed("reason X") }),
            ("process_count", { $0.processCount = .failed("reason X") }),
            ("swap_used", { $0.swapUsedGB = .failed("reason X") }),
            ("swap_in_rate", { $0.swapInsPerSecond = .failed("reason X") }),
            ("compressor", { $0.compressorPercent = .failed("reason X") }),
            ("memory_level", { $0.memoryLevel = .failed("reason X") }),
            ("claude_stale", { $0.claudeSessionAgesDays = .failed("reason X") }),
            ("mcp_sidecars", { $0.mcpSidecars = .failed("reason X") }),
            ("zombies", { $0.zombies = .failed("reason X") }),
            ("docker_vm_compressed", { $0.dockerVMCompressedGB = .failed("reason X") }),
            ("docker_hot_containers", { $0.containerCPU = .failed("reason X") }),
            ("daemon_bloat", { $0.daemonResidentMB = .failed("reason X") }),
            ("disk_free", { $0.diskFreePercent = .failed("reason X") }),
            ("disk_iops", { $0.diskIOPS = .failed("reason X") }),
            ("chrome_processes", { $0.chromeProcesses = .failed("reason X") }),
            ("big_apps", { $0.apps = .failed("reason X") }),
            ("crash_reports", { $0.crashReports7d = .failed("reason X") }),
            ("jetsam", { $0.jetsam7d = .failed("reason X") }),
            ("launch_items", { $0.launchItems = .failed("reason X") }),
            ("thermal_limit", { $0.cpuSpeedLimit = .failed("reason X") }),
            ("brew_under_rosetta", { $0.appleSilicon = .failed("reason X") }),
            ("translated_hot", { $0.translatedProcesses = .failed("reason X") }),
            ("vpn_leak", { $0.identity = .failed("reason X") }),
            ("vpn_expected_down", { $0.vpnShouldBeOn = true; $0.identity = .failed("reason X") }),
            ("ip_changed", { $0.previousIdentity = .failed("reason X") }),
            ("memory_growth", { $0.appGrowth = .failed("reason X") })
        ]
        for (id, fail) in cases {
            var snapshot = healthyAuditSnapshot(); fail(&snapshot)
            let report = AuditEngine.evaluate(snapshot)
            #expect(!report.findings.map(\.ruleID).contains(id), "failed input must not find \(id)")
            let matching = report.unknowns.filter { $0.ruleID == id }
            #expect(matching.count == 1, "expected one unknown for \(id)")
            #expect(matching.first?.reason.contains("reason X") == true)
        }
    }

    @Test("every unavailable rule input is not applicable, not unknown")
    func everyUnavailableInput() {
        let cases: [(String, (inout AuditSnapshot) -> Void)] = [
            ("uptime", { $0.uptimeDays = .unavailable("not applicable") }),
            ("load", { $0.load5 = .unavailable("not applicable") }),
            ("cpu_idle", { $0.cpuIdlePercent = .unavailable("not applicable") }),
            ("kernel_cpu", { $0.kernelTaskCPU = .unavailable("not applicable") }),
            ("process_count", { $0.processCount = .unavailable("not applicable") }),
            ("swap_used", { $0.swapUsedGB = .unavailable("not applicable") }),
            ("swap_in_rate", { $0.swapInsPerSecond = .unavailable("not applicable") }),
            ("compressor", { $0.compressorPercent = .unavailable("not applicable") }),
            ("memory_level", { $0.memoryLevel = .unavailable("not applicable") }),
            ("claude_stale", { $0.claudeSessionAgesDays = .unavailable("not applicable") }),
            ("mcp_sidecars", { $0.mcpSidecars = .unavailable("not applicable") }),
            ("zombies", { $0.zombies = .unavailable("not applicable") }),
            ("docker_vm_compressed", { $0.dockerVMCompressedGB = .unavailable("not applicable") }),
            ("docker_hot_containers", { $0.containerCPU = .unavailable("not applicable") }),
            ("daemon_bloat", { $0.daemonResidentMB = .unavailable("not applicable") }),
            ("disk_free", { $0.diskFreePercent = .unavailable("not applicable") }),
            ("disk_iops", { $0.diskIOPS = .unavailable("not applicable") }),
            ("chrome_processes", { $0.chromeProcesses = .unavailable("not applicable") }),
            ("big_apps", { $0.apps = .unavailable("not applicable") }),
            ("crash_reports", { $0.crashReports7d = .unavailable("not applicable") }),
            ("jetsam", { $0.jetsam7d = .unavailable("not applicable") }),
            ("launch_items", { $0.launchItems = .unavailable("not applicable") }),
            ("thermal_limit", { $0.cpuSpeedLimit = .unavailable("not applicable") }),
            ("brew_under_rosetta", { $0.appleSilicon = .unavailable("not applicable") }),
            ("translated_hot", { $0.translatedProcesses = .unavailable("not applicable") }),
            ("vpn_leak", { $0.identity = .unavailable("not applicable") }),
            ("vpn_expected_down", { $0.vpnShouldBeOn = true; $0.identity = .unavailable("not applicable") }),
            ("ip_changed", { $0.previousIdentity = .unavailable("not applicable") }),
            ("memory_growth", { $0.appGrowth = .unavailable("not applicable") })
        ]
        for (id, unavailable) in cases {
            var snapshot = healthyAuditSnapshot(); unavailable(&snapshot)
            let report = AuditEngine.evaluate(snapshot)
            #expect(!report.findings.map(\.ruleID).contains(id))
            #expect(!report.unknowns.map(\.ruleID).contains(id))
        }
    }

    @Test("untouched snapshot is wholly unknown with no findings")
    func untouched() {
        let report = AuditEngine.evaluate(AuditSnapshot())
        #expect(report.findings.isEmpty)
        #expect(report.unknowns.map(\.ruleID) == auditRuleIDs.filter { $0 != "vpn_expected_down" })
        #expect(report.verdict == .unknown)
    }

    @Test("multi-input rules require only the documented conditional inputs")
    func conditionalInputs() {
        var uptime = healthyAuditSnapshot(); uptime.coreCount = .failed("irrelevant")
        #expect(!AuditEngine.evaluate(uptime).unknowns.map(\.ruleID).contains("uptime"))

        var load = healthyAuditSnapshot(); load.coreCount = .failed("reason X")
        #expect(AuditEngine.evaluate(load).unknowns.first { $0.ruleID == "load" }?.reason.contains("reason X") == true)

        var bigApps = healthyAuditSnapshot(); bigApps.ramBytes = .failed("reason X")
        #expect(AuditEngine.evaluate(bigApps).unknowns.first { $0.ruleID == "big_apps" }?.reason.contains("reason X") == true)

        var vpnOff = healthyAuditSnapshot(); vpnOff.vpnShouldBeOn = false; vpnOff.identity = .failed("ignored")
        #expect(!AuditEngine.evaluate(vpnOff).unknowns.map(\.ruleID).contains("vpn_expected_down"))
        var vpnOn = vpnOff; vpnOn.vpnShouldBeOn = true
        #expect(AuditEngine.evaluate(vpnOn).unknowns.map(\.ruleID).contains("vpn_expected_down"))

        var intel = healthyAuditSnapshot(); intel.appleSilicon = .ok(false); intel.brewInstalls = .failed("ignored")
        #expect(!AuditEngine.evaluate(intel).unknowns.map(\.ruleID).contains("brew_under_rosetta"))
        var arm = intel; arm.appleSilicon = .ok(true)
        #expect(AuditEngine.evaluate(arm).unknowns.map(\.ruleID).contains("brew_under_rosetta"))
    }
}
