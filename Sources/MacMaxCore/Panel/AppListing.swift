import Foundation

public enum AppKind: Sendable, Equatable { case app, background, claudeCode, docker }

/// One row of the Apps tab: an app with its current measures. A measure that was not read is nil, never zero.
public struct AppRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let bundleID: String?
    public let kind: AppKind
    public let pids: [Int32]
    public let processCount: Int
    public let cpuPercent: Double?
    public let footprintBytes: UInt64?
    public let diskBytesPerSecond: Double?
    public let networkBytesPerSecond: Double?

    public init(id: String, name: String, bundleID: String? = nil, kind: AppKind = .app, pids: [Int32] = [],
                processCount: Int = 1, cpuPercent: Double? = nil, footprintBytes: UInt64? = nil,
                diskBytesPerSecond: Double? = nil, networkBytesPerSecond: Double? = nil) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.kind = kind
        self.pids = pids
        self.processCount = processCount
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
        self.diskBytesPerSecond = diskBytesPerSecond
        self.networkBytesPerSecond = networkBytesPerSecond
    }
}

public enum AppSort: CaseIterable, Sendable { case cpu, memory, disk, network }
public enum AppFilter: CaseIterable, Sendable { case all, apps, background, claudeCode, docker }

/// Sorting, filtering and paging of the Apps tab as pure functions of the store's rows.
public enum AppListing {
    public static let pageSize = 25

    public static func sorted(_ rows: [AppRow], by sort: AppSort) -> [AppRow] {
        func measure(_ row: AppRow) -> Double? {
            let value: Double? = switch sort {
            case .cpu: row.cpuPercent
            case .memory: row.footprintBytes.map(Double.init)
            case .disk: row.diskBytesPerSecond
            case .network: row.networkBytesPerSecond
            }
            return value.flatMap { $0.isNaN ? nil : $0 }
        }
        return rows.sorted { left, right in
            switch (measure(left), measure(right)) {
            case let (a?, b?) where a != b: return a > b
            case (.some, .none): return true
            case (.none, .some): return false
            default:
                let order = left.name.caseInsensitiveCompare(right.name)
                return order == .orderedSame ? left.id < right.id : order == .orderedAscending
            }
        }
    }

    public static func filtered(_ rows: [AppRow], filter: AppFilter, query: String) -> [AppRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            let kindMatches: Bool = switch filter {
            case .all: true
            case .apps: row.kind == .app
            case .background: row.kind == .background
            case .claudeCode: row.kind == .claudeCode
            case .docker: row.kind == .docker
            }
            guard kindMatches else { return false }
            if needle.isEmpty { return true }
            return row.name.localizedCaseInsensitiveContains(needle)
                || row.bundleID?.localizedCaseInsensitiveContains(needle) == true
                || row.pids.contains { String($0) == needle }
        }
    }

    public static func page(_ rows: [AppRow], shown: Int) -> (visible: [AppRow], remaining: Int) {
        let count = min(max(shown, 0), rows.count)
        return (Array(rows.prefix(count)), rows.count - count)
    }
}
