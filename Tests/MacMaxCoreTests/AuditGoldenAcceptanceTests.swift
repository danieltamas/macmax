import Foundation
import Testing
@testable import MacMaxCore

@Suite("Audit golden acceptance")
struct AuditGoldenAcceptanceTests {
    @Test("a fully healthy snapshot passes every rule")
    func allHealthy() {
        let report = AuditEngine.evaluate(healthyAuditSnapshot())
        #expect(report.findings.isEmpty)
        #expect(report.unknowns.isEmpty)
        #expect(report.verdict == .ok)
    }

    @Test("uptime uses inclusive warning and critical boundaries")
    func uptime() {
        var s = healthyAuditSnapshot(); s.uptimeDays = .ok(14)
        expectAuditFinding("uptime", .warn, s, evidence: [.init("value", "14"), .init("threshold", "14")])
        s.uptimeDays = .ok(30)
        expectAuditFinding("uptime", .crit, s, evidence: [.init("value", "30"), .init("threshold", "30")])
        s.uptimeDays = .ok(13); expectNoAuditFinding("uptime", s)
    }

    @Test("load compares load5 strictly above core-count multipliers")
    func load() {
        var s = healthyAuditSnapshot(); s.coreCount = .ok(4); s.load5 = .ok(4)
        expectNoAuditFinding("load", s); s.load5 = .ok(4.01)
        expectAuditFinding("load", .warn, s, evidence: [.init("value", "4.01"), .init("threshold", "4.00"), .init("cores", "4")])
        s.load5 = .ok(8); expectAuditFinding("load", .warn, s)
        s.load5 = .ok(8.01); expectAuditFinding("load", .crit, s,
            evidence: [.init("value", "8.01"), .init("threshold", "8.00"), .init("cores", "4")])
    }

    @Test("cpu idle is critical only below ten percent")
    func cpuIdle() {
        var s = healthyAuditSnapshot(); s.cpuIdlePercent = .ok(10); expectNoAuditFinding("cpu_idle", s)
        s.cpuIdlePercent = .ok(9.9); expectAuditFinding("cpu_idle", .crit, s,
            evidence: [.init("value", "9.9"), .init("threshold", "10.0")])
    }

    @Test("kernel CPU is warning only above forty percent")
    func kernelCPU() {
        var s = healthyAuditSnapshot(); s.kernelTaskCPU = .ok(40); expectNoAuditFinding("kernel_cpu", s)
        s.kernelTaskCPU = .ok(40.1); expectAuditFinding("kernel_cpu", .warn, s,
            evidence: [.init("value", "40.1"), .init("threshold", "40.0")])
    }

    @Test("process count is warning only above eight hundred")
    func processCount() {
        var s = healthyAuditSnapshot(); s.processCount = .ok(800); expectNoAuditFinding("process_count", s)
        s.processCount = .ok(801); expectAuditFinding("process_count", .warn, s,
            evidence: [.init("value", "801"), .init("threshold", "800")])
    }

    @Test("swap used has strict warning and critical boundaries")
    func swapUsed() {
        var s = healthyAuditSnapshot(); s.swapUsedGB = .ok(2); expectNoAuditFinding("swap_used", s)
        s.swapUsedGB = .ok(2.1); expectAuditFinding("swap_used", .warn, s,
            evidence: [.init("value", "2.1"), .init("threshold", "2.0")])
        s.swapUsedGB = .ok(6); expectAuditFinding("swap_used", .warn, s)
        s.swapUsedGB = .ok(6.1); expectAuditFinding("swap_used", .crit, s,
            evidence: [.init("value", "6.1"), .init("threshold", "6.0")])
    }

    @Test("swap-in rate is critical only above fifty pages per second")
    func swapInRate() {
        var s = healthyAuditSnapshot(); s.swapInsPerSecond = .ok(50); expectNoAuditFinding("swap_in_rate", s)
        s.swapInsPerSecond = .ok(50.1); expectAuditFinding("swap_in_rate", .crit, s,
            evidence: [.init("value", "50.1"), .init("threshold", "50.0")])
    }

    @Test("compressor uses inclusive warning and critical percentages")
    func compressor() {
        var s = healthyAuditSnapshot(); s.compressorPercent = .ok(19); expectNoAuditFinding("compressor", s)
        s.compressorPercent = .ok(20); expectAuditFinding("compressor", .warn, s,
            evidence: [.init("value", "20"), .init("threshold", "20")])
        s.compressorPercent = .ok(35); expectAuditFinding("compressor", .crit, s,
            evidence: [.init("value", "35"), .init("threshold", "35")])
    }

    @Test("memory level uses inclusive low-side warning and critical boundaries")
    func memoryLevel() {
        var s = healthyAuditSnapshot(); s.memoryLevel = .ok(61); expectNoAuditFinding("memory_level", s)
        s.memoryLevel = .ok(60); expectAuditFinding("memory_level", .warn, s,
            evidence: [.init("value", "60"), .init("threshold", "60")])
        s.memoryLevel = .ok(40); expectAuditFinding("memory_level", .crit, s,
            evidence: [.init("value", "40"), .init("threshold", "40")])
    }

    @Test("stale Claude sessions count ages at least seven days")
    func claudeStale() {
        var s = healthyAuditSnapshot(); s.claudeSessionAgesDays = .ok([6]); expectNoAuditFinding("claude_stale", s)
        s.claudeSessionAgesDays = .ok([7]); expectAuditFinding("claude_stale", .warn, s,
            evidence: [.init("value", "1"), .init("threshold", "5"), .init("total", "1"), .init("oldest_days", "7")])
        s.claudeSessionAgesDays = .ok([8, 2]); expectAuditFinding("claude_stale", .warn, s,
            evidence: [.init("value", "1"), .init("threshold", "5"), .init("total", "2"), .init("oldest_days", "8")])
        s.claudeSessionAgesDays = .ok([10, 9, 8, 7]); expectAuditFinding("claude_stale", .warn, s,
            evidence: [.init("value", "4"), .init("threshold", "5"), .init("total", "4"), .init("oldest_days", "10")])
        s.claudeSessionAgesDays = .ok([12, 11, 10, 9, 8]); expectAuditFinding("claude_stale", .crit, s,
            evidence: [.init("value", "5"), .init("threshold", "5"), .init("total", "5"), .init("oldest_days", "12")])
    }

    @Test("MCP sidecars are warning only above thirty")
    func sidecars() {
        var s = healthyAuditSnapshot(); s.mcpSidecars = .ok(30); expectNoAuditFinding("mcp_sidecars", s)
        s.mcpSidecars = .ok(31); expectAuditFinding("mcp_sidecars", .warn, s,
            evidence: [.init("value", "31"), .init("threshold", "30")])
    }

    @Test("zombies are warning only above five")
    func zombies() {
        var s = healthyAuditSnapshot(); s.zombies = .ok(5); expectNoAuditFinding("zombies", s)
        s.zombies = .ok(6); expectAuditFinding("zombies", .warn, s,
            evidence: [.init("value", "6"), .init("threshold", "5")])
    }

    @Test("Docker VM compressed memory is critical only above two GB")
    func dockerVM() {
        var s = healthyAuditSnapshot(); s.dockerVMCompressedGB = .ok(2); expectNoAuditFinding("docker_vm_compressed", s)
        s.dockerVMCompressedGB = .ok(2.1); expectAuditFinding("docker_vm_compressed", .crit, s,
            evidence: [.init("value", "2.1"), .init("threshold", "2.0")])
    }

    @Test("hot containers use a strict threshold and sorted exact evidence")
    func containers() {
        var s = healthyAuditSnapshot(); s.containerCPU = .ok([.init(name: "web-1", value: 25)])
        expectNoAuditFinding("docker_hot_containers", s)
        s.containerCPU = .ok([.init(name: "worker-1", value: 26), .init(name: "web-1", value: 31)])
        expectAuditFinding("docker_hot_containers", .warn, s, evidence: [
            .init("threshold", "25.0"), .init("web-1", "31.0%"), .init("worker-1", "26.0%")])
    }

    @Test("bloated daemons use a strict MB threshold and sorted exact evidence")
    func daemons() {
        var s = healthyAuditSnapshot(); s.daemonResidentMB = .ok([.init(name: "Finder", value: 1024)])
        expectNoAuditFinding("daemon_bloat", s)
        s.daemonResidentMB = .ok([.init(name: "Finder", value: 1100), .init(name: "WindowServer", value: 1500)])
        expectAuditFinding("daemon_bloat", .warn, s, evidence: [
            .init("threshold", "1024"), .init("WindowServer", "1500"), .init("Finder", "1100")])
    }

    @Test("disk free uses strict low-side warning and critical boundaries")
    func diskFree() {
        var s = healthyAuditSnapshot(); s.diskFreePercent = .ok(15); expectNoAuditFinding("disk_free", s)
        s.diskFreePercent = .ok(14); expectAuditFinding("disk_free", .warn, s,
            evidence: [.init("value", "14"), .init("threshold", "15")])
        s.diskFreePercent = .ok(10); expectAuditFinding("disk_free", .warn, s)
        s.diskFreePercent = .ok(9); expectAuditFinding("disk_free", .crit, s,
            evidence: [.init("value", "9"), .init("threshold", "10")])
    }

    @Test("disk IOPS are warning only above fifteen hundred")
    func diskIOPS() {
        var s = healthyAuditSnapshot(); s.diskIOPS = .ok(1500); expectNoAuditFinding("disk_iops", s)
        s.diskIOPS = .ok(1500.1); expectAuditFinding("disk_iops", .warn, s,
            evidence: [.init("value", "1500.1"), .init("threshold", "1500.0")])
    }

    @Test("Chrome process count is warning only above forty")
    func chrome() {
        var s = healthyAuditSnapshot(); s.chromeProcesses = .ok(40); expectNoAuditFinding("chrome_processes", s)
        s.chromeProcesses = .ok(41); expectAuditFinding("chrome_processes", .warn, s,
            evidence: [.init("value", "41"), .init("threshold", "40")])
    }

    @Test("big apps compare grouped footprint with RAM percentage")
    func bigApps() {
        var s = healthyAuditSnapshot(); s.ramBytes = .ok(10_000_000_000)
        s.apps = .ok([.init(name: "Example App", footprintBytes: 1_000_000_000)])
        expectNoAuditFinding("big_apps", s)
        s.apps = .ok([.init(name: "Example Helper", footprintBytes: 1_100_000_000),
                      .init(name: "Example App", footprintBytes: 2_000_000_000)])
        expectAuditFinding("big_apps", .warn, s, evidence: [
            .init("threshold", "10.0"), .init("Example App", "1907"), .init("Example Helper", "1049")])
    }

    @Test("crash reports are warning only above ten")
    func crashes() {
        var s = healthyAuditSnapshot(); s.crashReports7d = .ok(10); expectNoAuditFinding("crash_reports", s)
        s.crashReports7d = .ok(11); expectAuditFinding("crash_reports", .warn, s,
            evidence: [.init("value", "11"), .init("threshold", "10")])
    }

    @Test("any Jetsam event warns")
    func jetsam() {
        var s = healthyAuditSnapshot(); s.jetsam7d = .ok(0); expectNoAuditFinding("jetsam", s)
        s.jetsam7d = .ok(1); expectAuditFinding("jetsam", .warn, s,
            evidence: [.init("value", "1"), .init("threshold", "0")])
    }

    @Test("launch items are warning only above twenty-five")
    func launchItems() {
        var s = healthyAuditSnapshot(); s.launchItems = .ok(25); expectNoAuditFinding("launch_items", s)
        s.launchItems = .ok(26); expectAuditFinding("launch_items", .warn, s,
            evidence: [.init("value", "26"), .init("threshold", "25")])
    }

    @Test("thermal limit warns only below one hundred")
    func thermal() {
        var s = healthyAuditSnapshot(); s.cpuSpeedLimit = .ok(100); expectNoAuditFinding("thermal_limit", s)
        s.cpuSpeedLimit = .ok(99); expectAuditFinding("thermal_limit", .warn, s,
            evidence: [.init("value", "99"), .init("threshold", "100")])
    }

    @Test("Intel-only Homebrew warns only in the three required states")
    func brew() {
        var s = healthyAuditSnapshot(); s.appleSilicon = .ok(false)
        s.brewInstalls = .ok(.init(intelPrefixIsX86: true, nativePrefixPresent: false)); expectNoAuditFinding("brew_under_rosetta", s)
        s.appleSilicon = .ok(true); s.brewInstalls = .ok(.init(intelPrefixIsX86: true, nativePrefixPresent: true)); expectNoAuditFinding("brew_under_rosetta", s)
        s.brewInstalls = .ok(.init(intelPrefixIsX86: true, nativePrefixPresent: false))
        expectAuditFinding("brew_under_rosetta", .warn, s)
    }

    @Test("translated process needs three last samples all strictly above ten")
    func translated() {
        var s = healthyAuditSnapshot(); s.translatedProcesses = .ok([.init(name: "Example Worker", app: "Example App", cpuSamples: [11, 10, 12])])
        expectNoAuditFinding("translated_hot", s)
        s.translatedProcesses = .ok([.init(name: "Example Worker", app: "Example App", cpuSamples: [1, 11, 12, 13])])
        expectAuditFinding("translated_hot", .warn, s,
            evidence: [.init("threshold", "10.0"), .init("Example Worker (Example App)", "13.0")])
    }

    @Test("VPN leak is critical only for the leak verdict")
    func vpnLeak() {
        var s = healthyAuditSnapshot(); expectNoAuditFinding("vpn_leak", s)
        s.identity = .ok(.init(verdict: "leak", vpnConnected: true, publicIP: "192.0.2.10", publicCountry: "RO"))
        expectAuditFinding("vpn_leak", .crit, s, evidence: [.init("verdict", "leak")])
    }

    @Test("expected VPN down warns only when the setting is on")
    func expectedVPN() {
        var s = healthyAuditSnapshot(); s.identity = .ok(.init(verdict: "direct", vpnConnected: false, publicIP: "192.0.2.10", publicCountry: "RO"))
        s.vpnShouldBeOn = false; expectNoAuditFinding("vpn_expected_down", s)
        s.vpnShouldBeOn = true; expectAuditFinding("vpn_expected_down", .warn, s)
    }

    @Test("IP changed compares prior and current public identity")
    func ipChanged() {
        var s = healthyAuditSnapshot(); expectNoAuditFinding("ip_changed", s)
        s.previousIdentity = .unavailable("first audit"); expectNoAuditFinding("ip_changed", s)
        s.previousIdentity = .ok(.init(publicIP: "198.51.100.20", publicCountry: "DE"))
        expectAuditFinding("ip_changed", .info, s, evidence: [
            .init("previous", "198.51.100.20 DE"), .init("current", "192.0.2.10 RO")])
    }

    @Test("memory growth requires over one GiB, over fifty percent, and CPU below five")
    func memoryGrowth() {
        var s = healthyAuditSnapshot(); let gib: UInt64 = 1_073_741_824
        s.appGrowth = .ok([.init(name: "Example App", footprintBytes: 3 * gib, footprintOneHourAgoBytes: 2 * gib, cpuPercent: 1)])
        expectNoAuditFinding("memory_growth", s)
        s.appGrowth = .ok([.init(name: "Example App", footprintBytes: 3 * gib + 1, footprintOneHourAgoBytes: 2 * gib, cpuPercent: 1)])
        expectAuditFinding("memory_growth", .warn, s)
        s.appGrowth = .ok([.init(name: "Example App", footprintBytes: 3 * gib + 2, footprintOneHourAgoBytes: 2 * gib, cpuPercent: 4.9)])
        expectAuditFinding("memory_growth", .warn, s)
        let evidence = auditFinding("memory_growth", in: s)?.evidence
        #expect(evidence?.first?.key == "threshold")
        #expect(evidence?.dropFirst().first == .init("Example App", "+1024 MB"))
        s.appGrowth = .ok([.init(name: "Example App", footprintBytes: 23 * gib / 2, footprintOneHourAgoBytes: 10 * gib, cpuPercent: 1)])
        expectNoAuditFinding("memory_growth", s)
        s.appGrowth = .ok([.init(name: "Example App", footprintBytes: 3 * gib + 2, footprintOneHourAgoBytes: 2 * gib, cpuPercent: 5)])
        expectNoAuditFinding("memory_growth", s)
    }
}
