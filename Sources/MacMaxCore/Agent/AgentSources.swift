import Foundation

/// Where the live backend reads from. Closures, so a test hands it fixtures and the CLI hands it the collectors.
public struct AgentSources: Sendable {
    /// Opened read-only; nil when MacMax has no history here.
    public let database: Database?
    /// Whether the app is the one keeping `database` current: `history` and `who_held` are answered from it only then.
    public let appRunning: Bool
    public let processes: @Sendable () async -> Reading<[ProcessSample]>
    public let system: @Sendable () async -> SystemSnapshot
    public let network: @Sendable ([ProcessSample]) async -> NetworkSnapshot
    public let identity: @Sendable (_ ipCheck: Bool) async -> NetworkIdentity
    public let audit: @Sendable () async -> AuditResult
    public let cleanup: @Sendable () async -> CleanupPreview
    public let now: @Sendable () -> Date

    public init(database: Database?, appRunning: Bool,
                processes: @escaping @Sendable () async -> Reading<[ProcessSample]>,
                system: @escaping @Sendable () async -> SystemSnapshot,
                network: @escaping @Sendable ([ProcessSample]) async -> NetworkSnapshot,
                identity: @escaping @Sendable (_ ipCheck: Bool) async -> NetworkIdentity,
                audit: @escaping @Sendable () async -> AuditResult,
                cleanup: @escaping @Sendable () async -> CleanupPreview,
                now: @escaping @Sendable () -> Date) {
        self.database = database
        self.appRunning = appRunning
        self.processes = processes
        self.system = system
        self.network = network
        self.identity = identity
        self.audit = audit
        self.cleanup = cleanup
        self.now = now
    }
}

extension Reading {
    /// The value as JSON, or `{"status", "reason"}` when it was not read: a reading that failed is never a number.
    func json(_ transform: (Value) -> JSONValue) -> JSONValue {
        switch self {
        case let .ok(value, _, _): transform(value)
        case let .unavailable(reason): .object(["status": .string("unavailable"), "reason": .string(reason)])
        case let .failed(reason): .object(["status": .string("failed"), "reason": .string(reason)])
        }
    }
}

enum AgentJSON {
    static func time(_ date: Date) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return .string(formatter.string(from: date))
    }

    static func time(seconds: Int64) -> JSONValue { time(Date(timeIntervalSince1970: TimeInterval(seconds))) }

    static func number(_ value: Double) -> JSONValue { value.isFinite ? .double((value * 100).rounded() / 100) : .null }

    static func notRead(_ reason: String) -> JSONValue { .object(["status": .string("unavailable"), "reason": .string(reason)]) }

    static func failed(_ reason: String) -> JSONValue { .object(["status": .string("failed"), "reason": .string(reason)]) }

    static func notRunning(_ empty: [String: JSONValue] = [:]) -> JSONValue {
        .object(empty.merging(["available": .bool(false), "reason": .string("MacMax is not running")]) { first, _ in first })
    }
}
