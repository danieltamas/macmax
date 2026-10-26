import Foundation
import Testing
@testable import MacMaxCore

private let fixtureDate = Date(timeIntervalSince1970: 1_798_190_042)
private let fixtureSecret = "abc123SECRET"

private func fixtureReading<T: Sendable>(_ value: T) -> Reading<T> { .ok(value, source: "fixture", at: fixtureDate) }

private func fixtureProcess(argv: Reading<[String]>? = nil) -> ProcessSample {
    ProcessSample(
        identity: ProcessIdentity(pid: 4242, startTimeMicroseconds: 1_798_198_400_000_000),
        parentPid: 1, uid: 501, name: "Orbit Worker", path: fixtureReading("/Applications/Orbit.app/Contents/MacOS/Orbit"),
        footprintBytes: fixtureReading(1_048_576), cpuPercent: fixtureReading(12.5),
        diskReadBytes: fixtureReading(4096), diskWriteBytes: fixtureReading(1024),
        isTranslated: fixtureReading(false), cwd: fixtureReading("/Users/sampleuser/Projects/Example"),
        tty: .unavailable(reason: "no terminal"),
        argv: argv ?? fixtureReading(["orbit", "--token", "Bearer \(fixtureSecret)", "--mode", "test"])
    )
}

private func fixtureSystem(cpu: Reading<CPUUsage>? = nil) -> SystemSnapshot {
    SystemSnapshot(
        cpu: cpu ?? fixtureReading(CPUUsage(userPercent: 20, systemPercent: 5, idlePercent: 75, perCore: [])),
        load: fixtureReading(LoadAverages(one: 1, five: 1, fifteen: 1)), coreCount: fixtureReading(8),
        uptimeSeconds: fixtureReading(7200), bootTime: fixtureReading(fixtureDate.addingTimeInterval(-7200)),
        memory: fixtureReading(MemoryUsage(physicalBytes: 16_000_000_000, usedBytes: 8_000_000_000,
                                           wiredBytes: 1_000_000_000, compressedBytes: 500_000_000)),
        pressure: fixtureReading(MemoryPressure(level: .normal, availablePercent: 50)),
        swap: fixtureReading(SwapUsage(totalBytes: 2_000_000_000, usedBytes: 100_000_000,
                                       freeBytes: 1_900_000_000, encrypted: true)),
        swapInsPerSecond: fixtureReading(0), swapOutsPerSecond: fixtureReading(0),
        diskSpace: fixtureReading(DiskSpace(freeBytes: 50_000_000_000, totalBytes: 500_000_000_000)),
        diskIO: fixtureReading(DiskIORates(readBytesPerSecond: 100, writeBytesPerSecond: 50,
                                           readOperationsPerSecond: 2, writeOperationsPerSecond: 1)),
        thermal: fixtureReading(ThermalStatus(state: .nominal, cpuSpeedLimitPercent: 100)),
        gpuUtilizationPercent: .unavailable(reason: "not available"),
        battery: fixtureReading(BatteryStatus(chargePercent: 80, powerSource: .ac, isCharging: true))
    )
}

private func fixtureNetwork() -> NetworkSnapshot {
    let identity = ProcessIdentity(pid: 4242, startTimeMicroseconds: 1_798_198_400_000_000)
    return NetworkSnapshot(
        processes: fixtureReading([identity: fixtureReading(NetworkCounters(bytesIn: 4096, bytesOut: 1024))]),
        skippedRows: 0,
        interfaces: fixtureReading([InterfaceRate(name: "en0", bytesInPerSecond: 1200, bytesOutPerSecond: 300)])
    )
}

private func fixtureIdentity() -> NetworkIdentity {
    NetworkIdentity(
        vpnServices: fixtureReading([]), defaultRoute: fixtureReading(DefaultRoute(interface: "en0", isTunnel: false)),
        physicalInterface: fixtureReading("en0"), publicIP: fixtureReading(PublicIP(address: "192.0.2.40", country: "RO")),
        ispIP: fixtureReading(PublicIP(address: "198.51.100.20", country: "RO")), verdict: .noVPN
    )
}

private func fixtureAudit() -> AuditResult {
    var snapshot = healthyAuditSnapshot()
    snapshot.timestamp = Int64(fixtureDate.timeIntervalSince1970)
    let report = AuditEngine.evaluate(snapshot)
    return AuditResult(trigger: .onDemand, snapshot: snapshot, report: report, notify: [], storedID: nil)
}

private func fixtureSources(database: Database? = nil, appRunning: Bool = false,
                            cpu: Reading<CPUUsage>? = nil) -> AgentSources {
    AgentSources(
        database: database, appRunning: appRunning,
        processes: { fixtureReading([fixtureProcess()]) }, system: { fixtureSystem(cpu: cpu) },
        network: { _ in fixtureNetwork() }, identity: { _ in fixtureIdentity() }, audit: { fixtureAudit() },
        cleanup: { CleanupPreview(candidates: [CleanupCandidate(ruleID: "old_logs", path: "/Users/sampleuser/Library/Logs/Example/old.log", bytes: 4096, device: 1, inode: 2)], skipped: []) },
        now: { fixtureDate }
    )
}

private func call(_ tool: String, arguments: String = "{}", server: MCPServer) async -> String {
    let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"\(tool)\",\"arguments\":\(arguments)}}"
    guard let output = await server.handle(line: line) else {
        Issue.record("tool call returned no JSON-RPC response")
        return ""
    }
    #expect(!output.contains("\n"))
    #expect(decoded(output)["jsonrpc"] == .string("2.0"))
    return output
}

private func decoded(_ line: String) -> JSONValue {
    (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))) ?? .null
}

private func keys(named name: String, in value: JSONValue) -> [JSONValue] {
    switch value {
    case let .object(object):
        return object.flatMap { key, child in (key == name ? [child] : []) + keys(named: name, in: child) }
    case let .array(values): return values.flatMap { keys(named: name, in: $0) }
    default: return []
    }
}

private let liveCalls: [(String, String)] = [
    ("snapshot", "{}"), ("top_apps", "{\"include_processes\":true}"), ("process", "{\"pid\":4242}"),
    ("network_usage", "{}"), ("network_identity", "{}"), ("run_audit", "{}"), ("findings", "{}"),
    ("history", "{\"metric\":\"cpu\",\"range\":\"7d\"}"),
    ("who_held", "{\"metric\":\"memory\",\"at\":\"2026-12-25T09:14:02Z\"}"), ("cleanup_preview", "{}")
]

@Suite("Agent API live backend acceptance")
struct AgentApiRedactionAcceptanceTests {
    @Test("All live responses redact secrets and expose command lines only on the two documented calls")
    func redactionAndCommandLineScope() async {
        let server = MCPServer(backend: LiveAgentBackend(fixtureSources()), now: { fixtureDate })
        for (tool, arguments) in liveCalls {
            let text = await call(tool, arguments: arguments, server: server)
            #expect(!text.contains(fixtureSecret))
            let value = decoded(text)
            let commands = keys(named: "command_line", in: value)
            if tool == "top_apps" || tool == "process" {
                #expect(!commands.isEmpty)
                #expect(text.contains("[redacted]"))
                #expect(text.contains("Orbit Worker"))
                #expect(text.contains("4242"))
            } else {
                #expect(commands.isEmpty)
                #expect(!text.contains("--token"))
            }
        }
    }

    @Test("Without the app, history is unavailable while snapshot is still collected")
    func appNotRunning() async {
        let server = MCPServer(backend: LiveAgentBackend(fixtureSources()), now: { fixtureDate })
        let history = decoded(await call("history", arguments: "{\"metric\":\"cpu\",\"range\":\"7d\"}", server: server))
        #expect(history["result"]?["structuredContent"]?["available"] == .bool(false))
        #expect(history["result"]?["structuredContent"]?["reason"] == .string("MacMax is not running"))
        let snapshot = decoded(await call("snapshot", server: server))
        #expect(snapshot["result"]?["structuredContent"]?["verdict"] != nil)
        #expect(snapshot["result"]?["structuredContent"]?["vitals"] != nil)
    }

    @Test("A failed collector is surfaced as failure text and never fabricated as zero")
    func collectorFailure() async {
        let sources = fixtureSources(cpu: .failed(reason: "fixture CPU read failed"))
        let server = MCPServer(backend: LiveAgentBackend(sources), now: { fixtureDate })
        let value = decoded(await call("snapshot", server: server))
        let structured = value["result"]?["structuredContent"] ?? .null
        #expect(keys(named: "status", in: structured).contains(.string("failed")))
        #expect(keys(named: "reason", in: structured).contains(.string("fixture CPU read failed")))
        #expect(!keys(named: "cpu_pct", in: structured).contains(.int(0)))
        #expect(!keys(named: "cpu_pct", in: structured).contains(.double(0)))
    }

    @Test("Calling every tool through a read-only database leaves database bytes unchanged")
    func toolsDoNotWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacMaxAgentReadOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("macmax.db")
        var writer: Database? = try Database.open(at: url, mode: .readWrite)
        try await writer?.write(TickRows(
            system: SystemSampleRow(ts: Int64(fixtureDate.timeIntervalSince1970), cpuUser: 20, cpuSystem: 5, memUsed: 8_000_000_000),
            apps: [AppSampleRow(ts: Int64(fixtureDate.timeIntervalSince1970), appKey: "com.example.Orbit", cpu: 12.5, footprint: 1_048_576, procs: 1)],
            processes: [ProcSampleRow(ts: Int64(fixtureDate.timeIntervalSince1970), pid: 4242, startUs: 1_798_198_400_000_000, appKey: "com.example.Orbit", name: "Orbit Worker", cpu: 12.5, footprint: 1_048_576)],
            appInfo: [AppInfo(appKey: "com.example.Orbit", name: "Orbit", bundleID: "com.example.Orbit", path: "/Applications/Orbit.app", firstSeen: Int64(fixtureDate.timeIntervalSince1970))]
        ))
        writer = nil
        let before = try Data(contentsOf: url)
        let reader = try Database.open(at: url, mode: .readOnly)
        let server = MCPServer(backend: LiveAgentBackend(fixtureSources(database: reader, appRunning: true)), now: { fixtureDate })
        for (tool, arguments) in liveCalls {
            let line = await call(tool, arguments: arguments, server: server)
            #expect(!line.isEmpty)
            #expect(decoded(line)["error"] == nil)
        }
        let after = try Data(contentsOf: url)
        #expect(after == before)
    }
}
