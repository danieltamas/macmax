import Darwin
import Foundation
import Testing
@testable import MacMaxCore

private func processReadingFailed<Value>(_ reading: Reading<Value>) -> Bool {
    if case .failed = reading { return true }
    return false
}

private func sampleHasFailedField(_ sample: ProcessSample) -> Bool {
    processReadingFailed(sample.path)
        || processReadingFailed(sample.footprintBytes)
        || processReadingFailed(sample.cpuPercent)
        || processReadingFailed(sample.diskReadBytes)
        || processReadingFailed(sample.diskWriteBytes)
        || processReadingFailed(sample.isTranslated)
        || processReadingFailed(sample.cwd)
        || processReadingFailed(sample.argv)
}

private func unavailableReasonIsNonEmpty<Value>(_ reading: Reading<Value>) -> Bool {
    if case let .unavailable(reason) = reading { return !reason.isEmpty }
    return false
}

@Suite("ProcessCollectorAcceptance")
struct ProcessCollectorAcceptanceTests {
    @Test("outermost app bundle groups Chrome main and renderer")
    func chromeGrouping() throws {
        let main = ProcessRow(
            pid: 10,
            parentPid: 1,
            path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            name: "Google Chrome"
        )
        let renderer = ProcessRow(
            pid: 11,
            parentPid: 10,
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
            name: "Google Chrome Helper (Renderer)"
        )

        let groups = AppGrouping.group([main, renderer])
        let mainKey = try #require(groups[main.pid])
        let rendererKey = try #require(groups[renderer.pid])
        #expect(mainKey == rendererKey)
        #expect(mainKey.name == "Google Chrome")
    }

    @Test("each Claude Code session owns only its descendants")
    func claudeSessionGrouping() throws {
        let rows = [
            ProcessRow(pid: 20, parentPid: 1, path: "/usr/local/bin/claude", name: "claude"),
            ProcessRow(pid: 21, parentPid: 20, path: "/opt/homebrew/bin/node", name: "node"),
            ProcessRow(pid: 22, parentPid: 21, path: "/opt/homebrew/bin/node", name: "node"),
            ProcessRow(pid: 30, parentPid: 1, path: "/usr/local/bin/claude", name: "claude"),
            ProcessRow(pid: 31, parentPid: 30, path: "/opt/homebrew/bin/node", name: "node"),
            ProcessRow(pid: 40, parentPid: 1, path: "/opt/homebrew/bin/node", name: "node")
        ]

        let groups = AppGrouping.group(rows)
        let firstSession = try #require(groups[20])
        #expect(groups[21] == firstSession)
        #expect(groups[22] == firstSession)
        #expect(firstSession.name.contains("Claude Code"))

        let secondSession = try #require(groups[30])
        #expect(groups[31] == secondSession)
        #expect(secondSession.name.contains("Claude Code"))
        #expect(secondSession != firstSession)
        #expect(groups[40] != firstSession)
        #expect(groups[40] != secondSession)
    }

    @Test("node inherits the nearest ancestor app bundle")
    func electronAncestorGrouping() throws {
        let app = ProcessRow(
            pid: 50,
            parentPid: 1,
            path: "/Applications/Northwind IDE.app/Contents/MacOS/Northwind IDE",
            name: "Northwind IDE"
        )
        let node = ProcessRow(pid: 51, parentPid: 50, path: "/opt/homebrew/bin/node", name: "node")

        let groups = AppGrouping.group([app, node])
        #expect(groups[app.pid] == groups[node.pid])
        #expect(groups[node.pid]?.name == "Northwind IDE")
    }

    @Test("daemons, missing paths, cycles, and missing parents stand alone")
    func standaloneAndMalformedTrees() throws {
        let rows = [
            ProcessRow(pid: 1, parentPid: 0, path: "/sbin/launchd", name: "launchd"),
            ProcessRow(pid: 60, parentPid: 1, path: "/usr/libexec/exampled", name: "exampled"),
            ProcessRow(pid: 61, parentPid: 1, path: nil, name: "nameless-path-process"),
            ProcessRow(pid: 62, parentPid: 63, path: "/usr/bin/cycle-a", name: "cycle-a"),
            ProcessRow(pid: 63, parentPid: 62, path: "/usr/bin/cycle-b", name: "cycle-b"),
            ProcessRow(pid: 64, parentPid: 9999, path: "/usr/bin/orphan", name: "orphan")
        ]

        let groups = AppGrouping.group(rows)
        #expect(groups.count == rows.count)
        #expect(Set(groups.keys) == Set(rows.map(\.pid)))
        let keys = try rows.map { try #require(groups[$0.pid]) }
        #expect(Set(keys).count == rows.count)
        #expect(groups[60]?.name == "exampled")
        #expect(groups[61]?.id == "nameless-path-process")
        #expect(groups[61]?.name == "nameless-path-process")
    }

    @Test("process identity includes start time and works in hashed collections")
    func processIdentity() {
        let first = ProcessIdentity(pid: 100, startTimeMicroseconds: 1)
        let same = ProcessIdentity(pid: 100, startTimeMicroseconds: 1)
        let reusedPid = ProcessIdentity(pid: 100, startTimeMicroseconds: 2)

        #expect(first == same)
        #expect(first != reusedPid)
        #expect(Set([first, same, reusedPid]).count == 2)
        #expect([first: "first", reusedPid: "reused"].count == 2)
    }

    @Test("first collection finds this process and withholds CPU deltas")
    func firstCollection() async throws {
        let result = await ProcessCollector().collect()
        let samples = try #require(result.value)
        #expect(!samples.isEmpty)
        let ownPid = Int32(ProcessInfo.processInfo.processIdentifier)
        #expect(samples.contains { $0.identity.pid == ownPid })
        #expect(samples.allSatisfy { unavailableReasonIsNonEmpty($0.cpuPercent) })
        #expect(samples.allSatisfy { !sampleHasFailedField($0) })
    }
}

@Suite(
    "ProcessCollectorLiveAcceptance",
    .enabled(if: ProcessInfo.processInfo.environment["MACMAX_LIVE"] == "1")
)
struct ProcessCollectorLiveAcceptanceTests {
    @Test("two snapshots report live process fields, identity, and busy CPU")
    func liveSnapshots() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "while :; do :; done"]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }

        let collector = ProcessCollector()
        let firstSamples = try #require((await collector.collect()).value)
        try await Task.sleep(for: .seconds(2))
        let secondSamples = try #require((await collector.collect()).value)
        let childPid = Int32(child.processIdentifier)
        let ownPid = Int32(ProcessInfo.processInfo.processIdentifier)
        let firstChild = try #require(firstSamples.first { $0.identity.pid == childPid })
        let secondChild = try #require(secondSamples.first { $0.identity.pid == childPid })
        let ownSample = try #require(secondSamples.first { $0.identity.pid == ownPid })

        #expect(secondSamples.count > 20)
        #expect(secondSamples.contains { $0.identity.pid == 1 })
        #expect(secondSamples.allSatisfy { !sampleHasFailedField($0) })
        #expect(firstChild.identity == secondChild.identity)
        #expect(secondChild.identity.pid == childPid)
        #expect(secondChild.identity.startTimeMicroseconds > 0)
        let nowMicroseconds = Int64(Date().timeIntervalSince1970 * 1_000_000)
        #expect(abs(nowMicroseconds - secondChild.identity.startTimeMicroseconds) < 60_000_000)
        #expect(secondChild.parentPid == ownPid)
        #expect(secondChild.uid == getuid())
        #expect(ownSample.uid == getuid())

        guard case let .ok(cpuPercent, _, _) = secondChild.cpuPercent else {
            Issue.record("Busy child CPU percent was not available")
            return
        }
        #expect(cpuPercent > 80)

        for sample in [secondChild, ownSample] {
            #expect((sample.footprintBytes.value ?? 0) > 0)
            #expect(!(sample.path.value ?? "").isEmpty)
            #expect(sample.argv.isOK)
            #expect(sample.diskReadBytes.isOK)
            #expect(sample.diskWriteBytes.isOK)
            #expect(sample.isTranslated.isOK)
            #expect(sample.cwd.isOK)
        }
        let childArgv = try #require(secondChild.argv.value)
        #expect(childArgv.contains("-c"))
        #expect(childArgv.contains("while :; do :; done"))
        #expect(!childArgv.contains(Redaction.marker))
    }
}
