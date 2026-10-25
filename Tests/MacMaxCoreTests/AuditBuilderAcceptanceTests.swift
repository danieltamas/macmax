import Foundation
import Testing
@testable import MacMaxCore

func temporaryAuditDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacMax-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

func auditOK<T: Sendable>(_ value: T, at date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Reading<T> {
    .ok(value, source: "synthetic", at: date)
}

func auditSystem(now: Date = Date(timeIntervalSince1970: 1_700_000_000), swapGB: Double = 0,
                 compressedPercent: Double = 10, uptimeDays: Double = 1,
                 diskFree: UInt64 = 90, diskTotal: UInt64 = 100,
                 thermal: Reading<ThermalStatus>? = nil) -> SystemSnapshot {
    let gib = Double(1 << 30)
    let ram = UInt64(16 * gib)
    return SystemSnapshot(
        cpu: auditOK(CPUUsage(userPercent: 5, systemPercent: 5, idlePercent: 90, perCore: []), at: now),
        load: auditOK(LoadAverages(one: 1, five: 1, fifteen: 1), at: now), coreCount: auditOK(8, at: now),
        uptimeSeconds: auditOK(uptimeDays * 86_400, at: now), bootTime: auditOK(now.addingTimeInterval(-86_400), at: now),
        memory: auditOK(MemoryUsage(physicalBytes: ram, usedBytes: ram / 2, wiredBytes: ram / 8,
                                    compressedBytes: UInt64(Double(ram) * compressedPercent / 100)), at: now),
        pressure: auditOK(MemoryPressure(level: .normal, availablePercent: 90), at: now),
        swap: auditOK(SwapUsage(totalBytes: 8 << 30, usedBytes: UInt64(swapGB * gib),
                                freeBytes: UInt64(max(0, 8 - swapGB) * gib), encrypted: true), at: now),
        swapInsPerSecond: auditOK(0, at: now), swapOutsPerSecond: auditOK(0, at: now),
        diskSpace: auditOK(DiskSpace(freeBytes: diskFree, totalBytes: diskTotal), at: now),
        diskIO: auditOK(DiskIORates(readBytesPerSecond: 0, writeBytesPerSecond: 0,
                                   readOperationsPerSecond: 2.5, writeOperationsPerSecond: 3.5), at: now),
        thermal: thermal ?? auditOK(ThermalStatus(state: .nominal, cpuSpeedLimitPercent: nil), at: now),
        gpuUtilizationPercent: .unavailable(reason: "not used"), battery: .unavailable(reason: "not used"))
}

func auditProcess(pid: Int32, parentPid: Int32 = 1, start: Int64 = 1_699_900_000_000_000,
                  name: String = "Example App", path: Reading<String>? = nil, footprint: Reading<UInt64>? = nil,
                  cpu: Reading<Double>? = nil, translated: Reading<Bool>? = nil,
                  argv: Reading<[String]>? = nil) -> ProcessSample {
    ProcessSample(identity: ProcessIdentity(pid: pid, startTimeMicroseconds: start), parentPid: parentPid, uid: 501,
                  name: name, path: path ?? auditOK("/Applications/Example App.app/Contents/MacOS/Example App"),
                  footprintBytes: footprint ?? auditOK(100), cpuPercent: cpu ?? auditOK(1),
                  diskReadBytes: auditOK(0), diskWriteBytes: auditOK(0),
                  isTranslated: translated ?? auditOK(false), cwd: .unavailable(reason: "not used"),
                  tty: .unavailable(reason: "not used"), argv: argv ?? auditOK([name]))
}

func auditIdentity(verdict: LeakVerdict = .tunnelOK,
                   services: Reading<[VPNService]>? = nil) -> NetworkIdentity {
    NetworkIdentity(
        vpnServices: services ?? auditOK([VPNService(name: "Example VPN", bundleID: "com.example.vpn",
                                                     state: .connected, label: "Example VPN")]),
        defaultRoute: auditOK(DefaultRoute(interface: "utun9", isTunnel: true)),
        physicalInterface: auditOK("en0"),
        publicIP: auditOK(PublicIP(address: "192.0.2.10", country: "RO")),
        ispIP: auditOK(PublicIP(address: "198.51.100.10", country: "RO")), verdict: verdict)
}

func auditProbes() -> AuditProbeResults {
    AuditProbeResults(zombies: auditOK(0), kernelTaskCPU: auditOK(1), daemonResidentMB: auditOK([]),
                      dockerVMCompressedGB: .unavailable(reason: "Docker not installed"),
                      containerCPU: .unavailable(reason: "Docker not installed"), crashReports7d: auditOK(0),
                      jetsam7d: auditOK(0), launchItems: auditOK(0), appleSilicon: auditOK(true),
                      brew: auditOK(BrewInstalls(intelPrefixIsX86: false, nativePrefixPresent: true)))
}

func auditInputs(now: Date = Date(timeIntervalSince1970: 1_700_000_000),
                 system: SystemSnapshot? = nil, processes: Reading<[ProcessSample]>? = nil,
                 history: [ProcessIdentity: [Double]] = [:], identity: NetworkIdentity? = auditIdentity(),
                 probes: AuditProbeResults = auditProbes(), previous: AuditSnapshot? = nil,
                 oldFootprints: Reading<[String: UInt64]> = auditOK([:]), vpnShouldBeOn: Bool = false) -> AuditInputs {
    AuditInputs(now: now, system: system ?? auditSystem(now: now), processes: processes ?? auditOK([]),
                cpuHistory: history, identity: identity, probes: probes, previous: previous,
                footprintOneHourAgo: oldFootprints, vpnShouldBeOn: vpnShouldBeOn)
}

@Suite("Audit snapshot builder acceptance")
struct AuditBuilderAcceptanceTests {
    @Test("Builder applies specified roundings and copies independent system readings")
    func systemRounding() {
        let now = Date(timeIntervalSince1970: 1_700_000_000.9)
        let low = AuditSnapshotBuilder.build(auditInputs(now: now, system: auditSystem(now: now, swapGB: 2.25,
                                                                                       compressedPercent: 34.5,
                                                                                       uptimeDays: 13.99,
                                                                                       diskFree: 345, diskTotal: 1_000)))
        #expect(low.timestamp == 1_700_000_000)
        #expect(low.swapUsedGB == .ok(2.2))
        #expect(low.compressorPercent == .ok(34))
        #expect(low.diskFreePercent == .ok(34))
        #expect(low.uptimeDays == .ok(13))
        #expect(low.diskIOPS == .ok(6))
        #expect(low.cpuSpeedLimit == .ok(100))
        #expect(low.load5 == .ok(1))
        #expect(low.coreCount == .ok(8))
        #expect(low.ramBytes == .ok(16 << 30))
        #expect(low.cpuIdlePercent == .ok(90))
        #expect(low.swapInsPerSecond == .ok(0))
        #expect(low.memoryLevel == .ok(90))

        let high = AuditSnapshotBuilder.build(auditInputs(system: auditSystem(swapGB: 2.35, compressedPercent: 35.5)))
        #expect(high.swapUsedGB == .ok(2.4))
        #expect(high.compressorPercent == .ok(36))
    }

    @Test("Builder fails only dependent fields when system inputs fail")
    func systemFailuresAreLocal() {
        let failedThermal = AuditSnapshotBuilder.build(auditInputs(system: auditSystem(thermal: .failed(reason: "pmset denied"))))
        #expect(failedThermal.cpuSpeedLimit == .failed("pmset denied"))
        #expect(failedThermal.uptimeDays == .ok(1))

        let base = auditSystem()
        let failedUptime = SystemSnapshot(cpu: base.cpu, load: base.load, coreCount: base.coreCount,
            uptimeSeconds: .failed(reason: "clock failed"), bootTime: base.bootTime, memory: base.memory,
            pressure: base.pressure, swap: base.swap, swapInsPerSecond: base.swapInsPerSecond,
            swapOutsPerSecond: base.swapOutsPerSecond, diskSpace: base.diskSpace, diskIO: base.diskIO,
            thermal: base.thermal, gpuUtilizationPercent: base.gpuUtilizationPercent, battery: base.battery)
        let uptimeSnapshot = AuditSnapshotBuilder.build(auditInputs(system: failedUptime))
        #expect(uptimeSnapshot.uptimeDays == .failed("clock failed"))
        #expect(uptimeSnapshot.swapUsedGB == .ok(0))

        let zeroDisk = AuditSnapshotBuilder.build(auditInputs(system: auditSystem(diskFree: 0, diskTotal: 0)))
        guard case let .failed(reason) = zeroDisk.diskFreePercent else {
            Issue.record("zero total disk bytes must fail")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("Builder derives process counts, exact Claude ages, sidecars and grouped app footprints")
    func processReductions() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day: Int64 = 86_400_000_000
        let chrome = auditProcess(pid: 1, name: "Chrome Helper",
            path: auditOK("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper"), footprint: auditOK(100))
        let claude = auditProcess(pid: 2, parentPid: 900,
            start: Int64(now.timeIntervalSince1970 * 1_000_000) - 3 * day,
            name: "claude", path: auditOK("/Users/example/.local/bin/claude"), argv: auditOK(["npm", "exec", "server"]))
        let versioned = auditProcess(pid: 3, parentPid: 900,
            start: Int64(now.timeIntervalSince1970 * 1_000_000) - 8 * day,
            name: "claude", path: auditOK("/Users/example/.local/share/claude/versions/1.2.3"),
            footprint: auditOK(200), argv: auditOK(["supergateway", "--stdio"]))
        let helper = auditProcess(pid: 4, parentPid: 900,
            start: Int64(now.timeIntervalSince1970 * 1_000_000) - 20 * day,
            name: "claude-helper", path: auditOK("/usr/local/bin/claude-helper"))
        let unreadable = auditProcess(pid: 5, parentPid: 900, argv: .unavailable(reason: "root-owned"))
        let snapshot = AuditSnapshotBuilder.build(auditInputs(now: now, processes: auditOK([chrome, claude, versioned, helper, unreadable])))
        #expect(snapshot.processCount == .ok(5))
        #expect(snapshot.chromeProcesses == .ok(1))
        #expect(snapshot.claudeSessionAgesDays.value?.sorted() == [3, 8])
        #expect(snapshot.mcpSidecars == .ok(2))
        guard case let .ok(apps) = snapshot.apps else { Issue.record("apps must be available"); return }
        #expect(apps.contains(AppFootprint(name: "Google Chrome", footprintBytes: 100)))
        #expect(apps.contains(AppFootprint(name: "Claude Code", footprintBytes: 200)))
    }

    @Test("A failed process list fails every process-derived field with the same reason")
    func failedProcessesFailClosed() {
        let snapshot = AuditSnapshotBuilder.build(auditInputs(processes: .failed(reason: "proc denied")))
        #expect(snapshot.processCount == .failed("proc denied"))
        #expect(snapshot.chromeProcesses == .failed("proc denied"))
        #expect(snapshot.claudeSessionAgesDays == .failed("proc denied"))
        #expect(snapshot.mcpSidecars == .failed("proc denied"))
        #expect(snapshot.apps == .failed("proc denied"))
        #expect(snapshot.translatedProcesses == .failed("proc denied"))
        #expect(snapshot.appGrowth == .failed("proc denied"))
    }

    @Test("Translated processes use the last three samples and require collected history")
    func translatedHistory() {
        let process = auditProcess(pid: 7, name: "Example App", translated: auditOK(true))
        let history: [ProcessIdentity: [Double]] = [process.identity: [1, 2, 3, 4]]
        let snapshot = AuditSnapshotBuilder.build(auditInputs(processes: auditOK([process]), history: history))
        #expect(snapshot.translatedProcesses == .ok([TranslatedProcess(name: "Example App", app: "Example App",
                                                                       cpuSamples: [2, 3, 4])]))
        let missing = AuditSnapshotBuilder.build(auditInputs(processes: auditOK([process])))
        #expect(missing.translatedProcesses == .failed("CPU history not collected"))
        let none = AuditSnapshotBuilder.build(auditInputs(processes: auditOK([])))
        #expect(none.translatedProcesses == .ok([]))
    }

    @Test("App growth includes only comparable idle-readable apps and preserves prior-reading state")
    func appGrowth() {
        let good = auditProcess(pid: 10, footprint: auditOK(300), cpu: auditOK(1))
        let second = auditProcess(pid: 11, footprint: auditOK(200), cpu: auditOK(2))
        let unknownCPU = auditProcess(pid: 12, name: "Unknown CPU",
                                      path: auditOK("/Applications/Unknown CPU.app/Contents/MacOS/Unknown CPU"),
                                      footprint: auditOK(500),
                                      cpu: .unavailable(reason: "denied"))
        let absentBefore = auditProcess(pid: 13, name: "New App",
                                        path: auditOK("/Applications/New App.app/Contents/MacOS/New App"),
                                        footprint: auditOK(600))
        let old = auditOK(["/Applications/Example App.app": UInt64(100), "/Applications/Unknown CPU.app": UInt64(100)])
        let snapshot = AuditSnapshotBuilder.build(auditInputs(processes: auditOK([good, second, unknownCPU, absentBefore]),
                                                               oldFootprints: old))
        #expect(snapshot.appGrowth == .ok([AppGrowth(name: "Example App", footprintBytes: 500,
                                                     footprintOneHourAgoBytes: 100, cpuPercent: 3)]))
        #expect(AuditSnapshotBuilder.build(auditInputs(oldFootprints: .failed(reason: "store failed"))).appGrowth
                == .failed("store failed"))
        #expect(AuditSnapshotBuilder.build(auditInputs(oldFootprints: .unavailable(reason: "no history"))).appGrowth
                == .unavailable("no history"))
    }

    @Test("Identity, prior identity, probes and setting are mapped without unsafe text")
    func identityAndProbes() {
        var probes = auditProbes()
        probes.daemonResidentMB = auditOK([NamedValue(name: "Bad\u{0007}Name\u{202E}", value: 12)])
        let previous = healthyAuditSnapshot()
        let snapshot = AuditSnapshotBuilder.build(auditInputs(probes: probes, previous: previous, vpnShouldBeOn: true))
        #expect(snapshot.identity == .ok(IdentityFacts(verdict: LeakVerdict.tunnelOK.rawValue, vpnConnected: true,
                                                      publicIP: "192.0.2.10", publicCountry: "RO")))
        #expect(snapshot.previousIdentity == .ok(PreviousIdentity(publicIP: "192.0.2.10", publicCountry: "RO")))
        #expect(snapshot.vpnShouldBeOn)
        #expect(snapshot.daemonResidentMB.value?.first?.name == "BadName")
        #expect(snapshot.zombies == .ok(0))
        #expect(snapshot.kernelTaskCPU == .ok(1))
        #expect(snapshot.dockerVMCompressedGB == .unavailable("Docker not installed"))
        #expect(snapshot.containerCPU == .unavailable("Docker not installed"))
        #expect(snapshot.crashReports7d == .ok(0))
        #expect(snapshot.jetsam7d == .ok(0))
        #expect(snapshot.launchItems == .ok(0))
        #expect(snapshot.appleSilicon == .ok(true))
        #expect(snapshot.brewInstalls == .ok(BrewInstalls(intelPrefixIsX86: false, nativePrefixPresent: true)))

        let noIdentity = AuditSnapshotBuilder.build(auditInputs(identity: nil))
        #expect(noIdentity.identity == .failed("network identity not collected"))
        let failedServices = auditIdentity(services: .failed(reason: "scutil failed"))
        #expect(AuditSnapshotBuilder.build(auditInputs(identity: failedServices)).identity == .failed("scutil failed"))
        #expect(AuditSnapshotBuilder.build(auditInputs(previous: nil)).previousIdentity == .unavailable("first audit"))
        var withoutIP = healthyAuditSnapshot()
        withoutIP.identity = .ok(IdentityFacts(verdict: "off", vpnConnected: false, publicIP: nil, publicCountry: nil))
        guard case .unavailable = AuditSnapshotBuilder.build(auditInputs(previous: withoutIP)).previousIdentity else {
            Issue.record("a previous snapshot without a public IP must be unavailable")
            return
        }
    }

    @Test("Builder is deterministic and produces rule-ready healthy and critical snapshots")
    func determinismAndEvaluation() {
        let inputs = auditInputs()
        let first = AuditSnapshotBuilder.build(inputs)
        #expect(AuditSnapshotBuilder.build(inputs) == first)
        let healthy = AuditEngine.evaluate(first)
        #expect(healthy.verdict == .ok)
        #expect(healthy.findings.isEmpty)

        let critical = AuditSnapshotBuilder.build(auditInputs(system: auditSystem(swapGB: 7, uptimeDays: 31)))
        let report = AuditEngine.evaluate(critical)
        #expect(report.findings.contains { $0.ruleID == "swap_used" && $0.severity == .crit })
        #expect(report.findings.contains { $0.ruleID == "uptime" && $0.severity == .crit })
    }
}
