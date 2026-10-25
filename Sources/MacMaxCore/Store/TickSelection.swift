import Foundation

/// One process's values for the tick, already per interval (disk as a rate, network as bytes).
public struct ProcessMeasurement: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var app: AppKey
    public var name: String
    public var cpu: Double?
    public var footprintBytes: UInt64?
    public var diskReadBps: Double?
    public var diskWriteBps: Double?
    public var netInBytes: UInt64?
    public var netOutBytes: UInt64?

    public init(identity: ProcessIdentity, app: AppKey, name: String, cpu: Double? = nil, footprintBytes: UInt64? = nil,
                diskReadBps: Double? = nil, diskWriteBps: Double? = nil, netInBytes: UInt64? = nil, netOutBytes: UInt64? = nil) {
        self.identity = identity
        self.app = app
        self.name = name
        self.cpu = cpu
        self.footprintBytes = footprintBytes
        self.diskReadBps = diskReadBps
        self.diskWriteBps = diskWriteBps
        self.netInBytes = netInBytes
        self.netOutBytes = netOutBytes
    }
}

public struct AppAggregate: Sendable, Equatable {
    public var app: AppKey
    public var cpu: Double?
    public var footprintBytes: UInt64?
    public var diskReadBps: Double?
    public var diskWriteBps: Double?
    public var netInBytes: UInt64?
    public var netOutBytes: UInt64?
    public var processCount: Int

    public init(app: AppKey, cpu: Double? = nil, footprintBytes: UInt64? = nil, diskReadBps: Double? = nil,
                diskWriteBps: Double? = nil, netInBytes: UInt64? = nil, netOutBytes: UInt64? = nil, processCount: Int) {
        self.app = app
        self.cpu = cpu
        self.footprintBytes = footprintBytes
        self.diskReadBps = diskReadBps
        self.diskWriteBps = diskWriteBps
        self.netInBytes = netInBytes
        self.netOutBytes = netOutBytes
        self.processCount = processCount
    }
}

public struct ProcessDiskCounters: Sendable, Equatable {
    public var readBytes: UInt64
    public var writeBytes: UInt64

    public init(readBytes: UInt64, writeBytes: UInt64) {
        self.readBytes = readBytes
        self.writeBytes = writeBytes
    }
}

public struct ProcessDiskRates: Sendable, Equatable {
    public var readBps: Double
    public var writeBps: Double

    public init(readBps: Double, writeBps: Double) {
        self.readBps = readBps
        self.writeBps = writeBps
    }
}

/// Pure selection and aggregation for a tick.
public enum TickSelection {
    /// One aggregate per app: sums over its processes; a value no process could read stays nil.
    public static func aggregate(_ processes: [ProcessMeasurement]) -> [AppAggregate] {
        var byApp: [AppKey: AppAggregate] = [:]
        for process in processes {
            var aggregate = byApp[process.app] ?? AppAggregate(app: process.app, processCount: 0)
            aggregate.cpu = add(aggregate.cpu, process.cpu)
            aggregate.footprintBytes = add(aggregate.footprintBytes, process.footprintBytes)
            aggregate.diskReadBps = add(aggregate.diskReadBps, process.diskReadBps)
            aggregate.diskWriteBps = add(aggregate.diskWriteBps, process.diskWriteBps)
            aggregate.netInBytes = add(aggregate.netInBytes, process.netInBytes)
            aggregate.netOutBytes = add(aggregate.netOutBytes, process.netOutBytes)
            aggregate.processCount += 1
            byApp[process.app] = aggregate
        }
        return Array(byApp.values)
    }

    /// Every app that ranks within the top `limit` by CPU, memory, disk or network is a candidate; the
    /// result is the `limit` apps with the best (lowest) rank in any metric, ties by the sum of ranks, then by app id.
    public static func topApps(_ apps: [AppAggregate], limit: Int = 40) -> [AppAggregate] {
        let ranks = ranked(apps, metrics: [
            { $0.cpu }, { $0.footprintBytes.map(Double.init) },
            { sum($0.diskReadBps, $0.diskWriteBps) },
            { sum($0.netInBytes.map(Double.init), $0.netOutBytes.map(Double.init)) },
        ])
        return pick(apps, ranks: ranks, limit: limit) { $0.app.id < $1.app.id }
    }

    /// The `limit` processes with the best rank by CPU or memory, ties by the sum of ranks, then pid.
    public static func topProcesses(_ processes: [ProcessMeasurement], limit: Int = 30) -> [ProcessMeasurement] {
        let ranks = ranked(processes, metrics: [{ $0.cpu }, { $0.footprintBytes.map(Double.init) }])
        return pick(processes, ranks: ranks, limit: limit) {
            ($0.identity.pid, $0.identity.startTimeMicroseconds) < ($1.identity.pid, $1.identity.startTimeMicroseconds)
        }
    }

    private static func add(_ total: Double?, _ value: Double?) -> Double? {
        guard let value else { return total }
        return (total ?? 0) + value
    }

    /// Byte counts saturate instead of trapping on overflow.
    private static func add(_ total: UInt64?, _ value: UInt64?) -> UInt64? {
        guard let value else { return total }
        let (sum, overflow) = (total ?? 0).addingReportingOverflow(value)
        return overflow ? UInt64.max : sum
    }

    private static func sum(_ first: Double?, _ second: Double?) -> Double? { add(first, second) }

    /// Rank 0 is the largest value; a nil metric ranks after every known one. Equal values share a rank.
    private static func ranked<T>(_ items: [T], metrics: [(T) -> Double?]) -> [[Int]] {
        metrics.map { metric in
            let values = items.map(metric)
            let known = Set(values.compactMap { $0 }).sorted(by: >)
            let position = Dictionary(uniqueKeysWithValues: known.enumerated().map { ($1, $0) })
            return values.map { $0.flatMap { position[$0] } ?? known.count }
        }
    }

    private static func pick<T>(_ items: [T], ranks: [[Int]], limit: Int, tiebreak: (T, T) -> Bool) -> [T] {
        guard limit > 0, !items.isEmpty else { return [] }
        let scored = items.indices.map { index in
            (item: items[index], best: ranks.map { $0[index] }.min() ?? 0, total: ranks.map { $0[index] }.reduce(0, +))
        }
        let ordered = scored.sorted { left, right in
            if left.best != right.best { return left.best < right.best }
            if left.total != right.total { return left.total < right.total }
            return tiebreak(left.item, right.item)
        }
        return ordered.prefix(limit).map(\.item)
    }
}

/// Per-process disk rates from cumulative counters and a monotonic clock.
public struct DiskRateTracker: Sendable {
    private var previous: [ProcessIdentity: ProcessDiskCounters] = [:]
    private var previousUptime: UInt64?

    public init() {}

    /// nil for an identity seen for the first time, or whose counter went backwards.
    public mutating func update(_ counters: [ProcessIdentity: ProcessDiskCounters],
                                uptimeNanoseconds: UInt64) -> [ProcessIdentity: ProcessDiskRates?] {
        defer {
            previous = counters
            previousUptime = uptimeNanoseconds
        }
        guard let before = previousUptime, uptimeNanoseconds > before else { return counters.mapValues { _ in nil } }
        let seconds = Double(uptimeNanoseconds - before) / 1_000_000_000
        return Dictionary(uniqueKeysWithValues: counters.map { identity, now -> (ProcessIdentity, ProcessDiskRates?) in
            guard let old = previous[identity], now.readBytes >= old.readBytes, now.writeBytes >= old.writeBytes else {
                return (identity, nil)
            }
            return (identity, ProcessDiskRates(readBps: Double(now.readBytes - old.readBytes) / seconds,
                                               writeBps: Double(now.writeBytes - old.writeBytes) / seconds))
        })
    }
}
