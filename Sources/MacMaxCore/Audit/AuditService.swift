import Foundation

public enum AuditTrigger: String, Sendable, Equatable {
    case scheduled, onDemand = "on_demand", memoryPressure = "memory_pressure"
}

/// The user's audit settings: threshold overrides by `T_*` key and the rule ids turned off.
public struct AuditSettings: Sendable, Equatable {
    public var thresholds: [String: Double]
    public var disabled: Set<String>

    public init(thresholds: [String: Double] = [:], disabled: Set<String> = []) {
        self.thresholds = thresholds
        self.disabled = disabled
    }
}

public struct AuditResult: Sendable {
    public let trigger: AuditTrigger
    public let snapshot: AuditSnapshot
    public let report: AuditReport
    /// The findings worth a notification (`NotificationDiff`).
    public let notify: [Finding]
    /// The stored audit id; nil when there is no database or the write failed.
    public let storedID: Int64?
    /// Why the audit was not stored, when a database was given and the write failed. The report stays valid.
    public let storageError: String?

    public init(trigger: AuditTrigger, snapshot: AuditSnapshot, report: AuditReport, notify: [Finding],
                storedID: Int64?, storageError: String? = nil) {
        self.trigger = trigger
        self.snapshot = snapshot
        self.report = report
        self.notify = notify
        self.storedID = storedID
        self.storageError = storageError
    }
}

/// Runs audits: scheduled, on demand and when memory pressure enters critical. One audit at a time: a call made
/// while one is running joins it and gets the same result. The previous audit comes from the database when there
/// is one, else from the last audit this service ran.
public actor AuditService {
    private let database: Database?
    private let collect: @Sendable (AuditSnapshot?) async -> AuditSnapshot
    private let settings: @Sendable () -> AuditSettings
    private let minimumPressureGap: Duration
    private var inFlight: Task<AuditResult, Never>?
    private var lastRun: (snapshot: AuditSnapshot, report: AuditReport)?
    private var pressure = MemoryPressureLevel.normal
    private var lastPressureAudit: ContinuousClock.Instant?

    public init(database: Database?, collect: @escaping @Sendable (AuditSnapshot?) async -> AuditSnapshot,
                settings: @escaping @Sendable () -> AuditSettings = { AuditSettings() },
                minimumPressureGap: Duration = .seconds(600)) {
        self.database = database
        self.collect = collect
        self.settings = settings
        self.minimumPressureGap = minimumPressureGap
    }

    public func runNow(_ trigger: AuditTrigger = .onDemand) async -> AuditResult {
        if let inFlight { return await inFlight.value }
        let task = Task { await perform(trigger) }
        inFlight = task
        return await task.value
    }

    /// Audits when the level enters critical from another level and the last pressure audit is at least
    /// `minimumPressureGap` old. A level that stays critical, or a re-entry inside the gap, does nothing.
    public func memoryPressureChanged(to level: MemoryPressureLevel) async -> AuditResult? {
        let entered = level == .critical && pressure != .critical
        pressure = level
        guard entered else { return nil }
        let now = ContinuousClock.now
        if let last = lastPressureAudit, now - last < minimumPressureGap { return nil }
        lastPressureAudit = now
        return await runNow(.memoryPressure)
    }

    /// Audits now, then every `interval`, never two at once, until the task is cancelled. `onResult` receives
    /// each result (for notifications and the panel).
    public func run(every interval: Duration, onResult: @Sendable (AuditResult) async -> Void = { _ in }) async {
        while !Task.isCancelled {
            let result = await runNow(.scheduled)
            if Task.isCancelled { return }
            await onResult(result)
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    private func perform(_ trigger: AuditTrigger) async -> AuditResult {
        var storageError: String?
        var previousSnapshot = lastRun?.snapshot
        var previousReport = lastRun?.report
        if let database {
            // The database is the truth about the previous audit. When it cannot be read, an older audit held in
            // memory must not stand in for it: the audit runs as a first one and the result says why.
            do {
                let stored = try await database.latestAudit()
                previousSnapshot = stored?.snapshot
                previousReport = stored?.report
            } catch {
                // Only the snapshot is dropped: the diff for notifications may still use the last audit this
                // service ran, so a new warning is not swallowed as a "first audit".
                previousSnapshot = nil
                storageError = "previous audit unreadable: \(error)"
            }
        }
        let started = ContinuousClock.now
        var snapshot = await collect(previousSnapshot)
        // An unreadable history is not a first audit: ip_changed must come out unknown, never not applicable.
        if storageError != nil { snapshot.previousIdentity = .failed("the previous audit could not be read") }
        let current = settings()
        let report = AuditEngine.evaluate(snapshot, thresholds: current.thresholds, disabled: current.disabled)
        let elapsed = started.duration(to: .now).components
        let milliseconds = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        var storedID: Int64?
        if let database {
            do { storedID = try await database.writeAudit(report, snapshot: snapshot, durationMilliseconds: milliseconds) }
            catch { storageError = [storageError, "audit not stored: \(error)"].compactMap { $0 }.joined(separator: "; ") }
        }
        lastRun = (snapshot, report)
        inFlight = nil
        return AuditResult(trigger: trigger, snapshot: snapshot, report: report,
                           notify: NotificationDiff.changes(previous: previousReport, current: report),
                           storedID: storedID, storageError: storageError)
    }
}
