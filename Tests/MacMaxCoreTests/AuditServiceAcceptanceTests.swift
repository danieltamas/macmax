import Foundation
import Testing
@testable import MacMaxCore

private actor AuditCallRecorder {
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var previous: [AuditSnapshot?] = []
    private let snapshots: [AuditSnapshot]

    init(_ snapshots: [AuditSnapshot]) { self.snapshots = snapshots }

    func collect(previous value: AuditSnapshot?, delay: Duration = .zero) async -> AuditSnapshot {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        previous.append(value)
        let index = min(calls - 1, snapshots.count - 1)
        if delay > .zero { try? await Task.sleep(for: delay) }
        active -= 1
        return snapshots[index]
    }

    func callCount() -> Int { calls }
    func maxActive() -> Int { maximumActive }
    func previousSnapshots() -> [AuditSnapshot?] { previous }
}

private final class AuditSettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AuditSettings

    init(_ settings: AuditSettings) { self.settings = settings }

    func get() -> AuditSettings { lock.withLock { settings } }
    func set(_ value: AuditSettings) { lock.withLock { settings = value } }
}

@Suite("Audit service acceptance", .serialized)
struct AuditServiceAcceptanceTests {
    @Test("runNow reads current settings, stores the report and passes the stored snapshot to the next collection")
    func runNowStoresAndUsesPrevious() async throws {
        let root = try temporaryAuditDirectory("AuditService")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try Database.open(at: root.appendingPathComponent("macmax.db"), mode: .readWrite)
        var critical = healthyAuditSnapshot()
        critical.timestamp = 10
        critical.swapUsedGB = .ok(7)
        var next = healthyAuditSnapshot()
        next.timestamp = 20
        next.swapUsedGB = .ok(7)
        let recorder = AuditCallRecorder([critical, next])
        let settings = AuditSettingsBox(AuditSettings(disabled: ["swap_used"]))
        let service = AuditService(database: database, collect: { previous in
            await recorder.collect(previous: previous)
        }, settings: { settings.get() })

        let first = await service.runNow()
        #expect(first.trigger == .onDemand)
        #expect(first.storedID != nil)
        #expect(first.report.findings.contains { $0.ruleID == "swap_used" } == false)
        #expect(try await database.latestAudit()?.report.verdict == first.report.verdict)
        settings.set(AuditSettings())
        let second = await service.runNow(.scheduled)
        #expect(second.trigger == .scheduled)
        #expect(second.report.findings.contains { $0.ruleID == "swap_used" && $0.severity == .crit })
        let previous = await recorder.previousSnapshots()
        #expect(previous.count == 2)
        #expect(previous[0] == nil)
        #expect(previous[1] == critical)
    }

    @Test("Notification diff uses the database's previous report and reports worsening only")
    func databaseNotificationDiff() async throws {
        let root = try temporaryAuditDirectory("AuditNotify")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try Database.open(at: root.appendingPathComponent("macmax.db"), mode: .readWrite)
        var warning = healthyAuditSnapshot()
        warning.timestamp = 1
        warning.swapUsedGB = .ok(3)
        var same = warning
        same.timestamp = 2
        var critical = warning
        critical.timestamp = 3
        critical.swapUsedGB = .ok(7)
        let recorder = AuditCallRecorder([warning, same, critical])
        let service = AuditService(database: database, collect: { previous in
            await recorder.collect(previous: previous)
        })
        let first = await service.runNow()
        #expect(first.notify.isEmpty) // First audit notifies only critical findings.
        let second = await service.runNow()
        #expect(second.notify.isEmpty)
        let third = await service.runNow()
        #expect(third.notify.map(\.ruleID) == ["swap_used"])
        #expect(third.notify.first?.severity == .crit)
    }

    @Test("Without a database the service retains the previous result in memory")
    func inMemoryPreviousAndNotifications() async {
        var critical = healthyAuditSnapshot()
        critical.timestamp = 100
        critical.uptimeDays = .ok(31)
        var same = critical
        same.timestamp = 101
        let recorder = AuditCallRecorder([critical, same])
        let service = AuditService(database: nil, collect: { previous in
            await recorder.collect(previous: previous)
        })
        let first = await service.runNow()
        #expect(first.storedID == nil)
        #expect(first.notify.map(\.ruleID).contains("uptime"))
        let second = await service.runNow()
        #expect(second.notify.isEmpty)
        let previous = await recorder.previousSnapshots()
        #expect(previous.count == 2)
        if previous.count == 2 { #expect(previous[1] == critical) }
    }

    @Test("Concurrent runNow calls coalesce, while a later call starts a fresh audit")
    func concurrentRunsCoalesce() async {
        var snapshot = healthyAuditSnapshot()
        snapshot.timestamp = 500
        let recorder = AuditCallRecorder([snapshot, snapshot])
        let service = AuditService(database: nil, collect: { previous in
            await recorder.collect(previous: previous, delay: .milliseconds(100))
        })
        async let first = service.runNow()
        async let second = service.runNow()
        let results = await [first, second]
        #expect(await recorder.callCount() == 1)
        #expect(results[0].snapshot == results[1].snapshot)
        #expect(results[0].report == results[1].report)
        _ = await service.runNow()
        #expect(await recorder.callCount() == 2)
    }

    @Test("A database write failure does not fail the audit result")
    func databaseFailureIsNonFatal() async throws {
        let root = try temporaryAuditDirectory("AuditReadOnly")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("macmax.db")
        _ = try Database.open(at: url, mode: .readWrite)
        let reader = try Database.open(at: url, mode: .readOnly)
        let snapshot = healthyAuditSnapshot()
        let service = AuditService(database: reader, collect: { _ in snapshot })
        let result = await service.runNow()
        #expect(result.snapshot == snapshot)
        #expect(result.storedID == nil)
    }

    @Test("Memory pressure triggers only on spaced entries into critical")
    func pressureTransitionsAndGap() async {
        let snapshot = healthyAuditSnapshot()
        let recorder = AuditCallRecorder([snapshot, snapshot])
        let service = AuditService(database: nil, collect: { previous in
            await recorder.collect(previous: previous)
        }, minimumPressureGap: .milliseconds(200))
        #expect(await service.memoryPressureChanged(to: .warning) == nil)
        let first = await service.memoryPressureChanged(to: .critical)
        #expect(first?.trigger == .memoryPressure)
        #expect(await service.memoryPressureChanged(to: .critical) == nil)
        #expect(await service.memoryPressureChanged(to: .normal) == nil)
        #expect(await service.memoryPressureChanged(to: .critical) == nil)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await service.memoryPressureChanged(to: .normal) == nil)
        let second = await service.memoryPressureChanged(to: .critical)
        #expect(second?.trigger == .memoryPressure)
        #expect(await recorder.callCount() == 2)
    }

    @Test("Scheduled runs start immediately, repeat without overlap, and stop after cancellation")
    func scheduling() async {
        let snapshot = healthyAuditSnapshot()
        let recorder = AuditCallRecorder([snapshot])
        let service = AuditService(database: nil, collect: { previous in
            await recorder.collect(previous: previous, delay: .milliseconds(120))
        })
        let task = Task { await service.run(every: .milliseconds(50)) }
        let deadline = ContinuousClock.now + .seconds(1)
        while await recorder.callCount() < 3, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await recorder.callCount() >= 3)
        #expect(await recorder.maxActive() == 1)
        task.cancel()
        await task.value
        let stoppedAt = await recorder.callCount()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await recorder.callCount() == stoppedAt)
    }
}
