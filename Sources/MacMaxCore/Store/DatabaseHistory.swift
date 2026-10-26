import Foundation

public enum HistoryRange: CaseIterable, Sendable {
    case hour, day, week, quarter

    public var seconds: Int64 {
        switch self {
        case .hour: 3_600
        case .day: 86_400
        case .week: 604_800
        case .quarter: 7_776_000
        }
    }

    public var stepSeconds: Int64 {
        switch self {
        case .hour: 60
        case .day: 300
        case .week: 900
        case .quarter: 3_600
        }
    }

    /// Raw rows only live 48 hours, so longer ranges read the rollups.
    fileprivate var weight: String { suffix.isEmpty ? "1" : "n" }

    fileprivate var suffix: String {
        switch self {
        case .hour, .day: ""
        case .week: "_1m"
        case .quarter: "_1h"
        }
    }
}

public enum HistoryMetric: CaseIterable, Sendable {
    case cpu, pressure, memory, swap, diskIO, netIn, netOut

    /// The system-row expression, NULL when any part is unknown: a partial sum would read as a low value.
    fileprivate var systemExpression: String {
        switch self {
        case .cpu: "cpu_user + cpu_system"
        case .pressure: "pressure_level"
        case .memory: "mem_used"
        case .swap: "swap_used"
        case .diskIO: "disk_read_bps + disk_write_bps"
        case .netIn: "net_in_bps"
        case .netOut: "net_out_bps"
        }
    }

    fileprivate var appExpression: String {
        switch self {
        case .cpu: "cpu"
        case .pressure, .memory, .swap: "footprint"
        case .diskIO: "disk_read_bps + disk_write_bps"
        case .netIn: "net_in_bytes"
        case .netOut: "net_out_bytes"
        }
    }
}

/// `value` is nil where nothing was recorded: a gap, never interpolated.
public struct HistoryPoint: Sendable, Equatable {
    public let ts: Int64
    public let value: Double?

    public init(ts: Int64, value: Double?) {
        self.ts = ts
        self.value = value
    }
}

/// One app's line on a chart, aligned to the same buckets as the system line.
public struct HistoryAppSeries: Sendable, Equatable {
    public let appKey: String
    public let name: String
    public let points: [HistoryPoint]

    public init(appKey: String, name: String, points: [HistoryPoint]) {
        self.appKey = appKey
        self.name = name
        self.points = points
    }
}

public struct HistoryHolder: Sendable, Equatable {
    public let appKey: String
    public let name: String
    public let value: Double

    public init(appKey: String, name: String, value: Double) {
        self.appKey = appKey
        self.name = name
        self.value = value
    }
}

extension Database {
    /// The mean of `expression` over the rows of a group, each row weighted by the raw samples it stands for (`n` in
    /// the rollups, 1 raw) and skipped when the expression is unknown. Text, not REAL: the text rows keep 15 digits
    /// unless the number is printed at full precision. NULL when nothing in the group was known.
    private static func weightedMean(_ expression: String, weight: String) -> String {
        """
        CASE WHEN COUNT(\(expression)) = 0 THEN NULL
        ELSE printf('%!.17g', SUM((\(expression)) * \(weight)) * 1.0 / SUM(CASE WHEN (\(expression)) IS NOT NULL THEN \(weight) END)) END
        """
    }

    private static func grid(_ range: HistoryRange, now: Int64) -> (first: Int64, last: Int64) {
        let step = range.stepSeconds
        return ((now - range.seconds) / step * step, now / step * step)
    }

    /// One point per step across the range, aligned to the step, with a nil value for a bucket without a reading.
    public func history(_ metric: HistoryMetric, range: HistoryRange, now: Int64) throws -> [HistoryPoint] {
        let step = range.stepSeconds
        let (first, last) = Self.grid(range, now: now)
        let rows = try query("""
            SELECT (ts / ?1) * ?1 AS bucket, \(Self.weightedMean(metric.systemExpression, weight: range.weight))
            FROM samples\(range.suffix) WHERE ts >= ?2 AND ts < ?3 GROUP BY bucket
            """, [.int(step), .int(first), .int(last + step)]).textRows()
        var values: [Int64: Double] = [:]
        for row in rows {
            guard let bucket = row[0].flatMap({ Int64($0) }), let value = row[1].flatMap({ Double($0) }) else { continue }
            values[bucket] = value
        }
        return stride(from: first, through: last, by: Int(step)).map { HistoryPoint(ts: $0, value: values[$0]) }
    }

    /// The apps holding the resource in the bucket that starts at `ts`, heaviest first.
    public func holders(_ metric: HistoryMetric, range: HistoryRange, at ts: Int64, limit: Int = 5) throws -> [HistoryHolder] {
        try topApps(metric, range: range, from: ts, to: ts + range.stepSeconds, limit: limit).map {
            HistoryHolder(appKey: $0.appKey, name: $0.name, value: $0.value)
        }
    }

    /// Per-app lines for the apps that held the most of the resource over the whole range.
    public func appHistory(_ metric: HistoryMetric, range: HistoryRange, now: Int64, limit: Int = 5) throws -> [HistoryAppSeries] {
        let step = range.stepSeconds
        let (first, last) = Self.grid(range, now: now)
        let top = try topApps(metric, range: range, from: first, to: last + step, limit: limit)
        guard !top.isEmpty else { return [] }
        let marks = top.map { _ in "?" }.joined(separator: ",")
        let rows = try query("""
            SELECT app_key, (ts / ?) * ? AS bucket, \(Self.weightedMean(metric.appExpression, weight: range.weight))
            FROM app_samples\(range.suffix) WHERE ts >= ? AND ts < ? AND app_key IN (\(marks)) GROUP BY app_key, bucket
            """, [.int(step), .int(step), .int(first), .int(last + step)] + top.map { .text($0.appKey) }).textRows()
        var values: [String: [Int64: Double]] = [:]
        for row in rows {
            guard let key = row[0], let bucket = row[1].flatMap({ Int64($0) }), let value = row[2].flatMap({ Double($0) }) else { continue }
            values[key, default: [:]][bucket] = value
        }
        return top.map { app in
            HistoryAppSeries(appKey: app.appKey, name: app.name, points: stride(from: first, through: last, by: Int(step)).map {
                HistoryPoint(ts: $0, value: values[app.appKey]?[$0])
            })
        }
    }

    private func topApps(_ metric: HistoryMetric, range: HistoryRange, from: Int64, to: Int64, limit: Int) throws -> [HistoryHolder] {
        let rows = try query("""
            SELECT s.app_key, COALESCE(a.name, s.app_key),
                   \(Self.weightedMean(metric.appExpression, weight: range.suffix.isEmpty ? "1" : "s.n")) AS value
            FROM app_samples\(range.suffix) s LEFT JOIN apps a ON a.app_key = s.app_key
            WHERE s.ts >= ? AND s.ts < ? GROUP BY s.app_key
            HAVING CAST(value AS REAL) > 0
            ORDER BY CAST(value AS REAL) DESC, LOWER(COALESCE(a.name, s.app_key)), s.app_key
            LIMIT ?
            """, [.int(from), .int(to), .int(Int64(max(limit, 0)))]).textRows()
        return try rows.map { columns in
            guard let key = columns[0], let name = columns[1], let value = columns[2].flatMap({ Double($0) }) else {
                throw StoreError.invalid("a stored app is incomplete")
            }
            return HistoryHolder(appKey: key, name: name, value: value)
        }
    }
}
