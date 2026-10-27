import Darwin
import Foundation

/// Reads the system's vitals once per tick. Native APIs first (Mach host statistics, sysctl, IOKit);
/// the parsers in Parsers.swift back them where docs/ARCHITECTURE.md names a command fallback.
/// Rates need two samples, so the first `collect()` reports them as `unavailable`.
public actor SystemCollector {
    private struct Previous {
        let ticks: [CPUTicks]?
        let swapIns: CounterSample?
        let swapOuts: CounterSample?
        let disk: (read: CounterSample, write: CounterSample, readOps: CounterSample, writeOps: CounterSample)?
    }

    private var previous: Previous?
    private var cachedThermal: (reading: Reading<ThermalStatus>, takenAt: UInt64)?
    private let thermalMaxAgeNanoseconds: UInt64 = 60_000_000_000
    private let firstSample = "needs a second sample to compute a rate"

    public init() {}

    public func collect() async -> SystemSnapshot {
        let now = Date()
        let clock = DispatchTime.now().uptimeNanoseconds
        let ticks = MachStatistics.cpuTicks()
        let vm = MachStatistics.vmCounters()
        let diskRead = IOKitReadings.diskCounters()
        let disk: DiskCounters? = if case .counters(let counters) = diskRead { counters } else { nil }

        let swapIns = vm.map { CounterSample(value: $0.swapins, uptimeNanoseconds: clock) }
        let swapOuts = vm.map { CounterSample(value: $0.swapouts, uptimeNanoseconds: clock) }
        let diskSamples = disk.map {
            (read: CounterSample(value: $0.readBytes, uptimeNanoseconds: clock),
             write: CounterSample(value: $0.writeBytes, uptimeNanoseconds: clock),
             readOps: CounterSample(value: $0.readOperations, uptimeNanoseconds: clock),
             writeOps: CounterSample(value: $0.writeOperations, uptimeNanoseconds: clock))
        }

        let cpu = Self.interval(first: firstSample, failure: "host_processor_info failed", previous: previous.map { $0.ticks },
                                current: ticks) { MachStatistics.usage(from: $0, to: $1, at: now) }
        let swapInRate = rate(previous?.swapIns, swapIns, source: "vm_statistics64 swapins", at: now, hadPrevious: previous != nil)
        let swapOutRate = rate(previous?.swapOuts, swapOuts, source: "vm_statistics64 swapouts", at: now, hadPrevious: previous != nil)
        let diskIO: Reading<DiskIORates> = diskRead == .absent
            ? .unavailable(reason: "this Mac publishes no internal disk counters")
            : diskRates(diskSamples, at: now)

        previous = Previous(ticks: ticks, swapIns: swapIns, swapOuts: swapOuts, disk: diskSamples)

        let physical = ProcessInfo.processInfo.physicalMemory
        return SystemSnapshot(
            cpu: cpu, load: Self.load(at: now), coreCount: Self.coreCount(at: now),
            uptimeSeconds: Self.uptime(at: now), bootTime: Self.bootTime(at: now),
            memory: vm.map { MachStatistics.memory(from: $0, physicalBytes: physical, at: now) }
                ?? .failed(reason: "host_statistics64 failed"),
            pressure: MachStatistics.pressure(at: now), swap: Self.swap(at: now),
            swapInsPerSecond: swapInRate, swapOutsPerSecond: swapOutRate,
            diskSpace: Self.diskSpace(at: now), diskIO: diskIO, thermal: await thermal(clock: clock, at: now),
            gpuUtilizationPercent: IOKitReadings.gpuUtilization(at: now), battery: IOKitReadings.battery(at: now))
    }

    // MARK: Intervals

    /// `previous` is nil on the first call (no sample yet) and `.some(nil)` when the last read failed.
    private static func interval<T: Sendable, S>(first: String, failure: String, previous: S??, current: S?,
                                                 compute: (S, S) -> Reading<T>) -> Reading<T> {
        guard let current else { return .failed(reason: failure) }
        guard let previous else { return .unavailable(reason: first) }
        guard let previous else { return .failed(reason: "the previous sample failed, so there is no interval") }
        return compute(previous, current)
    }

    private func rate(_ before: CounterSample?, _ after: CounterSample?, source: String, at: Date,
                      hadPrevious: Bool) -> Reading<Double> {
        guard let after else { return .failed(reason: "\(source) could not be read") }
        guard hadPrevious else { return .unavailable(reason: firstSample) }
        guard let before else { return .failed(reason: "\(source): the previous sample failed, so there is no interval") }
        return Rate.perSecond(from: before, to: after, source: source, at: at)
    }

    private func diskRates(_ current: (read: CounterSample, write: CounterSample, readOps: CounterSample, writeOps: CounterSample)?,
                           at: Date) -> Reading<DiskIORates> {
        guard let current else { return .failed(reason: "the IOBlockStorageDriver counters could not be read") }
        guard let previous else { return .unavailable(reason: firstSample) }
        guard let before = previous.disk else { return .failed(reason: "the previous disk sample failed, so there is no interval") }
        let source = "IOBlockStorageDriver"
        let parts = [Rate.perSecond(from: before.read, to: current.read, source: source, at: at),
                     Rate.perSecond(from: before.write, to: current.write, source: source, at: at),
                     Rate.perSecond(from: before.readOps, to: current.readOps, source: source, at: at),
                     Rate.perSecond(from: before.writeOps, to: current.writeOps, source: source, at: at)]
        guard let readBytes = parts[0].value, let writeBytes = parts[1].value,
              let readOps = parts[2].value, let writeOps = parts[3].value else {
            return .failed(reason: parts.compactMap(\.problem).first ?? "the disk counters did not advance")
        }
        return .ok(DiskIORates(readBytesPerSecond: readBytes, writeBytesPerSecond: writeBytes,
                               readOperationsPerSecond: readOps, writeOperationsPerSecond: writeOps), source: source, at: at)
    }

    // MARK: Point-in-time readings

    private static func load(at: Date) -> Reading<LoadAverages> {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) == 3, averages.allSatisfy({ $0 >= 0 && $0.isFinite }) else {
            return .failed(reason: "getloadavg failed")
        }
        return .ok(LoadAverages(one: averages[0], five: averages[1], fifteen: averages[2]), source: "getloadavg", at: at)
    }

    private static func coreCount(at: Date) -> Reading<Int> {
        guard let count = Sysctl.int32("hw.logicalcpu"), count > 0 else { return .failed(reason: "hw.logicalcpu did not answer") }
        return .ok(Int(count), source: "sysctl hw.logicalcpu", at: at)
    }

    private static func boot(at: Date) -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0, size == MemoryLayout<timeval>.size, value.tv_sec > 0
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000)
    }

    private static func bootTime(at: Date) -> Reading<Date> {
        guard let boot = boot(at: at), boot < at else { return .failed(reason: "kern.boottime did not answer") }
        return .ok(boot, source: "sysctl kern.boottime", at: at)
    }

    private static func uptime(at: Date) -> Reading<Double> {
        guard let boot = boot(at: at), at.timeIntervalSince(boot) > 0 else { return .failed(reason: "kern.boottime did not answer") }
        return .ok(at.timeIntervalSince(boot), source: "sysctl kern.boottime", at: at)
    }

    private static func swap(at: Date) -> Reading<SwapUsage> {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0, size == MemoryLayout<xsw_usage>.size,
              usage.xsu_used <= usage.xsu_total, usage.xsu_avail <= usage.xsu_total,
              usage.xsu_used + usage.xsu_avail <= usage.xsu_total + 1_048_576,
              usage.xsu_used + usage.xsu_avail + 1_048_576 >= usage.xsu_total else { return .failed(reason: "vm.swapusage did not answer") }
        return .ok(SwapUsage(totalBytes: usage.xsu_total, usedBytes: usage.xsu_used, freeBytes: usage.xsu_avail,
                             encrypted: usage.xsu_encrypted != 0), source: "sysctl vm.swapusage", at: at)
    }

    private static func diskSpace(at: Date) -> Reading<DiskSpace> {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity,
              free >= 0, total > 0, free <= Int64(total) else { return .failed(reason: "the startup volume capacity could not be read") }
        return .ok(DiskSpace(freeBytes: UInt64(free), totalBytes: UInt64(total)), source: "volume capacity", at: at)
    }

    /// `pmset -g therm` is a process spawn, so it is cached; `ProcessInfo.thermalState` is the fallback
    /// that keeps the reading alive when pmset fails.
    private func thermal(clock: UInt64, at: Date) async -> Reading<ThermalStatus> {
        if let cached = cachedThermal, clock >= cached.takenAt, clock - cached.takenAt < thermalMaxAgeNanoseconds,
           cached.reading.isOK {
            return cached.reading
        }
        let reading: Reading<ThermalStatus>
        if let output = try? await ProcessRunner().run("/usr/bin/pmset", ["-g", "therm"], timeout: .seconds(5)),
           output.status == 0, let text = String(data: output.stdout, encoding: .utf8),
           let parsed = PMSetThermParser.parse(text, at: at).value {
            reading = .ok(parsed, source: "pmset -g therm", at: at)
        } else {
            reading = Self.processInfoThermal(at: at)
        }
        // Collections can overlap at the await above; an older one finishing late must not replace a newer sample.
        if cachedThermal.map({ clock >= $0.takenAt }) ?? true { cachedThermal = (reading, clock) }
        return reading
    }

    private static func processInfoThermal(at: Date) -> Reading<ThermalStatus> {
        let state: ThermalState
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: state = .nominal
        case .fair: state = .fair
        case .serious: state = .serious
        case .critical: state = .critical
        @unknown default: return .failed(reason: "ProcessInfo.thermalState returned an unknown state")
        }
        return .ok(ThermalStatus(state: state, cpuSpeedLimitPercent: nil), source: "ProcessInfo.thermalState", at: at)
    }
}
