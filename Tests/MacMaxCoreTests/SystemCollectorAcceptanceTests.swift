import Foundation
import Testing
@testable import MacMaxCore

private enum Samples {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Samples", isDirectory: true)

    private static func read(_ name: String) -> String {
        do {
            return try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        } catch {
            Issue.record("Could not read Samples/\(name): \(error)")
            return ""
        }
    }

    static let vmStat = read("vm_stat.txt")
    static let swapUsage = read("swapusage.txt")
    static let thermNominal = read("pmset_therm_nominal.txt")
    static let thermLimited = read("pmset_therm_limited.txt")
    static let iostat = read("iostat.txt")
    static let top = read("top_header_two_blocks.txt")
    static let batteryAC = read("pmset_batt_ac.txt")
    static let batteryDischarging = read("pmset_batt_discharging.txt")
    static let batteryNone = read("pmset_batt_none.txt")
    static let sysctlMisc = read("sysctl_misc.txt")
}

private func isFailed<Value>(_ reading: Reading<Value>) -> Bool {
    if case .failed = reading { return true }
    return false
}

private func isUnavailableWithReason<Value>(_ reading: Reading<Value>) -> Bool {
    if case let .unavailable(reason) = reading { return !reason.isEmpty }
    return false
}

private func isOKOrUnavailableWithReason<Value>(_ reading: Reading<Value>) -> Bool {
    switch reading {
    case .ok: true
    case let .unavailable(reason): !reason.isEmpty
    case .failed: false
    }
}

private func truncations(_ text: String, markers: [String]) -> [String] {
    markers.compactMap { marker in
        guard let range = text.range(of: marker), marker.count > 1 else { return nil }
        let middle = text.index(range.lowerBound, offsetBy: marker.count / 2)
        return String(text[..<middle])
    }
}

private func removingLine(containing needle: String, from text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.contains(needle) }
        .joined(separator: "\n")
}

@Suite("SystemCollectorAcceptance")
struct SystemCollectorAcceptanceTests {
    @Test("vm_stat fixture preserves every required counter")
    func vmStatFixture() throws {
        let value = try #require(VMStatParser.parse(Samples.vmStat).value)
        #expect(value.pageSize == 16_384)
        #expect(value.free == 5_000)
        #expect(value.active == 800_000)
        #expect(value.inactive == 700_000)
        #expect(value.speculative == 1_000)
        #expect(value.wired == 600_000)
        #expect(value.purgeable == 20_000)
        #expect(value.fileBacked == 500_000)
        #expect(value.anonymous == 1_000_000)
        #expect(value.compressorStored == 7_000_000)
        #expect(value.compressorOccupied == 1_800_000)
        #expect(value.pageins == 1_800_000_000)
        #expect(value.pageouts == 30_000_000)
        #expect(value.swapins == 50_000_000)
        #expect(value.swapouts == 60_000_000)
    }

    @Test("swapusage fixture uses binary megabytes and nearest-byte rounding")
    func swapUsageFixture() throws {
        let value = try #require(SwapUsageParser.parse(Samples.swapUsage).value)
        #expect(value.totalBytes == 20_480 * 1_048_576)
        #expect(value.usedBytes == 19_000 * 1_048_576 + 524_288)
        #expect(value.freeBytes == 1_479 * 1_048_576 + 524_288)
        #expect(value.encrypted)
    }

    @Test("pmset thermal fixtures distinguish nominal and limited states")
    func thermalFixtures() throws {
        let nominal = try #require(PMSetThermParser.parse(Samples.thermNominal).value)
        #expect(nominal.state == .nominal)
        #expect(nominal.cpuSpeedLimitPercent == 100)

        let limited = try #require(PMSetThermParser.parse(Samples.thermLimited).value)
        #expect(limited.state != .nominal)
        #expect(limited.cpuSpeedLimitPercent == 72)
    }

    @Test("top parser uses the last complete header block")
    func topFixture() throws {
        let value = try #require(TopHeaderParser.parse(Samples.top).value)
        #expect(value.cpuUserPercent == 10)
        #expect(value.cpuSystemPercent == 5)
        #expect(value.cpuIdlePercent == 85)
        #expect(value.load == LoadAverages(one: 6, five: 4.5, fifteen: 3.1))
        #expect(value.processes == 1_000)
        #expect(value.physicalUsedBytes == 61 * 1_073_741_824)
        #expect(value.wiredBytes == 10 * 1_073_741_824)
        #expect(value.compressorBytes == 28 * 1_073_741_824)
        #expect(value.unusedBytes == 90 * 1_048_576)
        #expect(value.swapins == 50_000_100)
        #expect(value.swapouts == 60_000_200)
    }

    @Test("iostat parser returns every device from only the last data row")
    func iostatFixture() throws {
        let samples = try #require(IostatParser.parse(Samples.iostat).value)
        #expect(samples.count == 2)
        let disk0 = try #require(samples.first { $0.device == "disk0" })
        #expect(disk0.kilobytesPerTransfer == 32)
        #expect(disk0.transfersPerSecond == 2_000)
        #expect(disk0.megabytesPerSecond == 60)
        let disk1 = try #require(samples.first { $0.device == "disk1" })
        #expect(disk1.kilobytesPerTransfer == 0)
        #expect(disk1.transfersPerSecond == 0)
        #expect(disk1.megabytesPerSecond == 0)
    }

    @Test("vm_stat malformed and truncated input fails")
    func vmStatFailures() {
        var inputs = ["", " \t\n"]
        inputs += truncations(Samples.vmStat, markers: ["16384", "800000", "1800000", "60000000"])
        inputs += [
            Samples.vmStat.replacingOccurrences(of: "800000", with: "abc"),
            removingLine(containing: "Pages wired down", from: Samples.vmStat)
        ]
        for input in inputs { #expect(isFailed(VMStatParser.parse(input))) }
    }

    @Test("swapusage malformed and truncated input fails")
    func swapUsageFailures() {
        var inputs = ["", " \t\n"]
        inputs += truncations(Samples.swapUsage, markers: ["20480.00", "19000.50", "1479.50"])
        inputs += [
            Samples.swapUsage.replacingOccurrences(of: "19000.50", with: "abc"),
            Samples.swapUsage.replacingOccurrences(of: "used = 19000.50M  ", with: "")
        ]
        for input in inputs { #expect(isFailed(SwapUsageParser.parse(input))) }
    }

    @Test("pmset thermal malformed and truncated input fails")
    func thermalFailures() {
        var inputs = ["", " \t\n"]
        inputs += truncations(Samples.thermNominal, markers: ["thermal warning", "performance warning", "CPU power status"])
        inputs += truncations(Samples.thermLimited, markers: ["CPU performance", "100", "72"])
        inputs += [
            Samples.thermLimited.replacingOccurrences(of: "72", with: "abc"),
            removingLine(containing: "CPU_Speed_Limit", from: Samples.thermLimited)
        ]
        for input in inputs { #expect(isFailed(PMSetThermParser.parse(input))) }
    }

    @Test("top malformed, incomplete, and truncated input fails")
    func topFailures() {
        var inputs = ["", " \t\n"]
        inputs += truncations(Samples.top, markers: ["Processes: 1000", "10.00", "61G", "60000200"])
        inputs += [
            Samples.top.replacingOccurrences(of: "10.00% user", with: "abc% user"),
            removingLine(containing: "CPU usage:", from: Samples.top),
            removingLine(containing: "PhysMem:", from: Samples.top)
        ]
        for input in inputs { #expect(isFailed(TopHeaderParser.parse(input))) }
    }

    @Test("iostat malformed, incomplete, and truncated input fails")
    func iostatFailures() {
        var inputs = ["", " \t\n"]
        inputs += truncations(Samples.iostat, markers: ["disk1", "32.00", "2000", "60.00"])
        inputs += [
            Samples.iostat.replacingOccurrences(of: "32.00", with: "abc", options: [], range: Samples.iostat.range(of: "32.00")),
            "              disk0               disk1\n    KB/t  tps  MB/s     KB/t  tps  MB/s\n"
        ]
        for input in inputs { #expect(isFailed(IostatParser.parse(input))) }
    }

    @Test("rates use counter samples and reject reset or invalid clocks")
    func rates() throws {
        let previous = CounterSample(value: 1_000, uptimeNanoseconds: 4_000_000_000)
        let normal = try #require(Rate.perSecond(
            from: previous,
            to: CounterSample(value: 1_500, uptimeNanoseconds: 6_000_000_000),
            source: "fixture"
        ).value)
        #expect(abs(normal - 250) <= 1e-9)

        let unchanged = try #require(Rate.perSecond(
            from: previous,
            to: CounterSample(value: 1_000, uptimeNanoseconds: 6_000_000_000),
            source: "fixture"
        ).value)
        #expect(unchanged == 0)
        #expect(isFailed(Rate.perSecond(
            from: previous,
            to: CounterSample(value: 999, uptimeNanoseconds: 6_000_000_000), source: "fixture"
        )))
        #expect(isFailed(Rate.perSecond(
            from: previous,
            to: CounterSample(value: 1_500, uptimeNanoseconds: 4_000_000_000), source: "fixture"
        )))
        #expect(isFailed(Rate.perSecond(
            from: previous,
            to: CounterSample(value: 1_500, uptimeNanoseconds: 3_999_999_999), source: "fixture"
        )))
        #expect(isFailed(Rate.perSecond(
            from: CounterSample(value: UInt64.max, uptimeNanoseconds: 1),
            to: CounterSample(value: 2, uptimeNanoseconds: 2), source: "fixture"
        )))
    }

    @Test("first collection withholds exactly the four interval readings and never fails")
    func firstCollection() async {
        let snapshot = await SystemCollector().collect()
        #expect(isUnavailableWithReason(snapshot.cpu))
        #expect(isUnavailableWithReason(snapshot.swapInsPerSecond))
        #expect(isUnavailableWithReason(snapshot.swapOutsPerSecond))
        #expect(isUnavailableWithReason(snapshot.diskIO))
        #expect(!snapshotHasFailure(snapshot))
    }
}

private func snapshotHasFailure(_ snapshot: SystemSnapshot) -> Bool {
    isFailed(snapshot.cpu) || isFailed(snapshot.load) || isFailed(snapshot.coreCount)
        || isFailed(snapshot.uptimeSeconds) || isFailed(snapshot.bootTime) || isFailed(snapshot.memory)
        || isFailed(snapshot.pressure) || isFailed(snapshot.swap) || isFailed(snapshot.swapInsPerSecond)
        || isFailed(snapshot.swapOutsPerSecond) || isFailed(snapshot.diskSpace) || isFailed(snapshot.diskIO)
        || isFailed(snapshot.thermal) || isFailed(snapshot.gpuUtilizationPercent) || isFailed(snapshot.battery)
}

@Suite(
    "SystemCollectorLiveAcceptance",
    .enabled(if: ProcessInfo.processInfo.environment["MACMAX_LIVE"] == "1")
)
struct SystemCollectorLiveAcceptanceTests {
    @Test("second collection supplies required readings and valid ranges")
    func secondCollection() async throws {
        let collector = SystemCollector()
        _ = await collector.collect()
        try await Task.sleep(for: .seconds(1))
        let snapshot = await collector.collect()

        #expect(!snapshotHasFailure(snapshot))
        #expect(snapshot.cpu.isOK)
        #expect(snapshot.load.isOK)
        #expect(snapshot.coreCount.isOK)
        #expect(snapshot.uptimeSeconds.isOK)
        #expect(snapshot.bootTime.isOK)
        #expect(snapshot.memory.isOK)
        #expect(snapshot.pressure.isOK)
        #expect(snapshot.swap.isOK)
        #expect(snapshot.swapInsPerSecond.isOK)
        #expect(snapshot.swapOutsPerSecond.isOK)
        #expect(snapshot.diskSpace.isOK)
        #expect(snapshot.diskIO.isOK)
        #expect(snapshot.thermal.isOK)
        #expect(isOKOrUnavailableWithReason(snapshot.battery))
        #expect(isOKOrUnavailableWithReason(snapshot.gpuUtilizationPercent))

        let cpu = try #require(snapshot.cpu.value)
        #expect(abs(cpu.userPercent + cpu.systemPercent + cpu.idlePercent - 100) <= 1)
        for core in cpu.perCore {
            #expect(abs(core.userPercent + core.systemPercent + core.idlePercent - 100) <= 1)
        }
        let coreCount = try #require(snapshot.coreCount.value)
        #expect(cpu.perCore.count == coreCount)
        #expect(coreCount == ProcessInfo.processInfo.processorCount)

        let load = try #require(snapshot.load.value)
        #expect(load.one >= 0 && load.five >= 0 && load.fifteen >= 0)
        let uptime = try #require(snapshot.uptimeSeconds.value)
        #expect(uptime > 0)
        #expect(try #require(snapshot.bootTime.value) < Date())

        let memory = try #require(snapshot.memory.value)
        #expect(memory.physicalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.usedBytes > 0 && memory.usedBytes <= memory.physicalBytes)
        #expect(memory.wiredBytes <= memory.usedBytes)
        #expect(memory.compressedBytes <= memory.physicalBytes)

        let pressure = try #require(snapshot.pressure.value)
        #expect([.normal, .warning, .critical].contains(pressure.level))
        #expect((0...100).contains(pressure.availablePercent))
        let swap = try #require(snapshot.swap.value)
        #expect(swap.usedBytes <= swap.totalBytes)
        #expect(try #require(snapshot.swapInsPerSecond.value) >= 0)
        #expect(try #require(snapshot.swapOutsPerSecond.value) >= 0)

        let disk = try #require(snapshot.diskSpace.value)
        #expect(disk.freeBytes > 0 && disk.freeBytes <= disk.totalBytes)
        let diskIO = try #require(snapshot.diskIO.value)
        #expect(diskIO.readBytesPerSecond >= 0)
        #expect(diskIO.writeBytesPerSecond >= 0)
        #expect(diskIO.readOperationsPerSecond >= 0)
        #expect(diskIO.writeOperationsPerSecond >= 0)

        if let battery = snapshot.battery.value {
            #expect((0...100).contains(battery.chargePercent))
        }
        if let gpu = snapshot.gpuUtilizationPercent.value {
            #expect((0...100).contains(gpu))
        }
    }
}
