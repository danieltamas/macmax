import Foundation
import Testing
@testable import MacMaxCore

private func measurement(
    pid: Int32,
    start: Int64 = 1,
    appID: String,
    cpu: Double? = nil,
    footprint: UInt64? = nil,
    read: Double? = nil,
    write: Double? = nil,
    netIn: UInt64? = nil,
    netOut: UInt64? = nil
) -> ProcessMeasurement {
    ProcessMeasurement(
        identity: ProcessIdentity(pid: pid, startTimeMicroseconds: start),
        app: AppKey(id: appID, name: "Example \(appID)"),
        name: "Example Helper",
        cpu: cpu,
        footprintBytes: footprint,
        diskReadBps: read,
        diskWriteBps: write,
        netInBytes: netIn,
        netOutBytes: netOut
    )
}

private func aggregate(
    id: String,
    cpu: Double? = nil,
    footprint: UInt64? = nil,
    read: Double? = nil,
    write: Double? = nil,
    netIn: UInt64? = nil,
    netOut: UInt64? = nil
) -> AppAggregate {
    AppAggregate(app: AppKey(id: id, name: "Example \(id)"), cpu: cpu, footprintBytes: footprint,
                 diskReadBps: read, diskWriteBps: write, netInBytes: netIn, netOutBytes: netOut,
                 processCount: 1)
}

@Suite("TickSelectionAcceptance")
struct TickSelectionAcceptanceTests {
    @Test("Aggregation groups by AppKey and sums every known value")
    func aggregation() throws {
        let alpha = measurement(pid: 1, appID: "com.example.Alpha", cpu: 2, footprint: 100,
                                read: nil, write: 4, netIn: 10, netOut: nil)
        let alphaHelper = measurement(pid: 2, appID: "com.example.Alpha", cpu: 3, footprint: nil,
                                      read: nil, write: 6, netIn: nil, netOut: nil)
        let beta = measurement(pid: 3, appID: "com.example.Beta", cpu: nil, footprint: nil)
        let result = TickSelection.aggregate([alpha, alphaHelper, beta])
        let a = try #require(result.first { $0.app.id == "com.example.Alpha" })
        #expect(a.cpu == 5)
        #expect(a.footprintBytes == 100)
        #expect(a.diskReadBps == nil)
        #expect(a.diskWriteBps == 10)
        #expect(a.netInBytes == 10)
        #expect(a.netOutBytes == nil)
        #expect(a.processCount == 2)
        let b = try #require(result.first { $0.app.id == "com.example.Beta" })
        #expect(b.cpu == nil)
        #expect(b.processCount == 1)
        #expect(TickSelection.aggregate([]).isEmpty)
    }

    @Test("Top apps use the best rank from every resource")
    func topAppsIncludesMetricSpecialist() {
        var apps: [AppAggregate] = []
        for index in 0..<100 {
            let inverse = 100 - index
            apps.append(aggregate(id: String(format: "com.example.App%03d", index),
                                  cpu: Double(inverse), footprint: UInt64(inverse),
                                  read: Double(inverse), write: 0,
                                  netIn: UInt64(index + 1), netOut: 0))
        }
        let selected = TickSelection.topApps(apps)
        #expect(selected.count == 40)
        #expect(selected.contains { $0.app.id == "com.example.App099" })
    }

    @Test("Top apps obey limits, put nil last, and are input-order independent")
    func topAppsBoundsAndDeterminism() {
        let known = (0..<12).map { aggregate(id: "com.example.\($0)", cpu: Double($0)) }
        let unknown = aggregate(id: "com.example.Unknown")
        #expect(TickSelection.topApps(known + [unknown], limit: 0).isEmpty)
        #expect(TickSelection.topApps(Array(known.prefix(4)) + [unknown], limit: 40).count == 5)
        let forward = TickSelection.topApps(known + [unknown], limit: 5).map(\.app.id)
        let reversed = TickSelection.topApps(Array((known + [unknown]).reversed()), limit: 5).map(\.app.id)
        #expect(Set(forward) == Set(reversed))
        #expect(forward.contains("com.example.Unknown") == false)
    }

    @Test("Top app ties use rank sum then app id")
    func topAppTieBreak() {
        let a = aggregate(id: "com.example.Alpha", cpu: 10, footprint: 1)
        let b = aggregate(id: "com.example.Beta", cpu: 1, footprint: 10)
        let c = aggregate(id: "com.example.Charlie", cpu: 5, footprint: 5)
        let selected = TickSelection.topApps([c, b, a], limit: 1)
        #expect(selected.map(\.app.id) == ["com.example.Alpha"])
    }

    @Test("Top processes rank CPU or memory with deterministic ties")
    func topProcesses() {
        let cpuBest = measurement(pid: 30, appID: "com.example.CPU", cpu: 100, footprint: 1)
        let memoryBest = measurement(pid: 20, appID: "com.example.Memory", cpu: 1, footprint: 100)
        let middleLowPID = measurement(pid: 10, appID: "com.example.MiddleA", cpu: 50, footprint: 50)
        let middleHighPID = measurement(pid: 11, appID: "com.example.MiddleB", cpu: 50, footprint: 50)
        let values = [middleHighPID, memoryBest, cpuBest, middleLowPID]
        #expect(TickSelection.topProcesses(values, limit: 0).isEmpty)
        #expect(TickSelection.topProcesses(values, limit: 10).count == 4)
        let first = TickSelection.topProcesses(values, limit: 3).map(\.identity.pid)
        let second = TickSelection.topProcesses(values.reversed(), limit: 3).map(\.identity.pid)
        #expect(first == second)
        #expect(first.contains(30))
        #expect(first.contains(20))
        #expect(first.contains(10))
    }

    @Test("Disk rates need two observations and use monotonic elapsed time")
    func diskRates() throws {
        var tracker = DiskRateTracker()
        let id = ProcessIdentity(pid: 7, startTimeMicroseconds: 100)
        let first = tracker.update([id: ProcessDiskCounters(readBytes: 1_000, writeBytes: 2_000)],
                                   uptimeNanoseconds: 1_000_000_000)
        #expect(first.keys.contains(id))
        #expect(try #require(first[id]) == nil)
        let second = tracker.update([id: ProcessDiskCounters(readBytes: 1_001_000, writeBytes: 502_000)],
                                    uptimeNanoseconds: 3_000_000_000)
        guard case let .some(.some(rate)) = second[id] else {
            Issue.record("second observation did not produce a rate")
            return
        }
        #expect(rate.readBps == 500_000)
        #expect(rate.writeBps == 250_000)
    }

    @Test("Disk counter failure is isolated by process identity")
    func diskCounterRegressionAndRestart() throws {
        var tracker = DiskRateTracker()
        let bad = ProcessIdentity(pid: 1, startTimeMicroseconds: 10)
        let good = ProcessIdentity(pid: 2, startTimeMicroseconds: 20)
        _ = tracker.update([bad: .init(readBytes: 100, writeBytes: 100),
                            good: .init(readBytes: 100, writeBytes: 100)], uptimeNanoseconds: 1)
        let rates = tracker.update([bad: .init(readBytes: 99, writeBytes: 110),
                                    good: .init(readBytes: 110, writeBytes: 120)], uptimeNanoseconds: 1_000_000_001)
        #expect(try #require(rates[bad]) == nil)
        guard case let .some(.some(goodRate)) = rates[good] else {
            Issue.record("sound identity did not produce a rate")
            return
        }
        #expect(goodRate.readBps == 10)
        let restarted = ProcessIdentity(pid: 2, startTimeMicroseconds: 21)
        let afterRestart = tracker.update([restarted: .init(readBytes: 1, writeBytes: 1)],
                                          uptimeNanoseconds: 2_000_000_001)
        #expect(try #require(afterRestart[restarted]) == nil)
    }

    @Test("Absent identities are forgotten and invalid elapsed time invalidates all rates")
    func diskElapsedTimeAndAbsence() throws {
        var tracker = DiskRateTracker()
        let firstID = ProcessIdentity(pid: 1, startTimeMicroseconds: 1)
        let secondID = ProcessIdentity(pid: 2, startTimeMicroseconds: 2)
        _ = tracker.update([firstID: .init(readBytes: 1, writeBytes: 1)], uptimeNanoseconds: 100)
        _ = tracker.update([secondID: .init(readBytes: 1, writeBytes: 1)], uptimeNanoseconds: 200)
        let returned = tracker.update([firstID: .init(readBytes: 2, writeBytes: 2)], uptimeNanoseconds: 300)
        #expect(try #require(returned[firstID]) == nil)
        let equal = tracker.update([firstID: .init(readBytes: 3, writeBytes: 3)], uptimeNanoseconds: 300)
        #expect(try #require(equal[firstID]) == nil)
        let backwards = tracker.update([firstID: .init(readBytes: UInt64.max, writeBytes: UInt64.max)],
                                       uptimeNanoseconds: 299)
        #expect(try #require(backwards[firstID]) == nil)
    }

    @Test("Disk counters near UInt64.max never overflow")
    func diskCounterBoundary() throws {
        var tracker = DiskRateTracker()
        let id = ProcessIdentity(pid: 9, startTimeMicroseconds: 9)
        _ = tracker.update([id: .init(readBytes: UInt64.max - 10, writeBytes: UInt64.max - 5)],
                           uptimeNanoseconds: 1_000_000_000)
        let rates = tracker.update([id: .init(readBytes: UInt64.max, writeBytes: UInt64.max)],
                                   uptimeNanoseconds: 2_000_000_000)
        guard case let .some(.some(value)) = rates[id] else {
            Issue.record("boundary counters did not produce a rate")
            return
        }
        #expect(value.readBps == 10)
        #expect(value.writeBps == 5)
    }

    @Test("Only supported sampler intervals initialize")
    func samplerIntervals() {
        for seconds in [5, 10, 30, 60] { #expect(SamplerInterval(seconds: seconds)?.rawValue == seconds) }
        for seconds in [0, 1, 7, 15, 3_600, -5] { #expect(SamplerInterval(seconds: seconds) == nil) }
    }
}
