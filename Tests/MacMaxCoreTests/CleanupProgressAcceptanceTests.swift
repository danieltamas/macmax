import Foundation
import Testing
@testable import MacMaxCore

private struct CleanupProgressHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMaxCleanupProgress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ relativePath: String) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x41]).write(to: file)
        return file
    }
}

private func cleanupProgressCandidate(_ url: URL) throws -> CleanupCandidate {
    let resolved = url.resolvingSymlinksInPath()
    let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
    let device = try #require(attributes[.systemNumber] as? NSNumber)
    let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
    return CleanupCandidate(
        ruleID: "app_caches",
        path: resolved.path,
        bytes: 1,
        device: device.int64Value,
        inode: inode.uint64Value
    )
}

private final class CleanupProgressTrasher: Trasher, @unchecked Sendable {
    enum SyntheticError: Error {
        case failed
    }

    private let failingPaths: Set<String>

    init(failingPaths: Set<String> = []) {
        self.failingPaths = failingPaths
    }

    func trash(_ url: URL) throws {
        if failingPaths.contains(url.path) {
            throw SyntheticError.failed
        }
    }
}

private struct CleanupProgressCall: Equatable {
    let done: Int
    let total: Int
    let next: String?
}

private final class CleanupProgressCallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [CleanupProgressCall] = []

    func append(done: Int, total: Int, next: String?) {
        lock.withLock {
            storedCalls.append(CleanupProgressCall(done: done, total: total, next: next))
        }
    }

    var calls: [CleanupProgressCall] {
        lock.withLock { storedCalls }
    }
}

@Suite("Cleanup mover progress")
struct CleanupProgressAcceptanceTests {
    @Test("Progress reports every candidate in order and then completion")
    func orderedProgress() throws {
        let home = try CleanupProgressHome()
        defer { home.remove() }
        let first = try home.file("Library/Caches/com.synthetic.First")
        let second = try home.file("Library/Caches/com.synthetic.Second")
        let candidates = try [cleanupProgressCandidate(first), cleanupProgressCandidate(second)]
        let calls = CleanupProgressCallBox()

        _ = CleanupMover(home: home.url, trasher: CleanupProgressTrasher()).move(candidates) {
            calls.append(done: $0, total: $1, next: $2)
        }

        #expect(calls.calls == [
            CleanupProgressCall(done: 0, total: 2, next: first.path),
            CleanupProgressCall(done: 1, total: 2, next: second.path),
            CleanupProgressCall(done: 2, total: 2, next: nil),
        ])
    }

    @Test("Refused and failed candidates still advance progress")
    func refusalAndFailureAdvanceProgress() throws {
        let home = try CleanupProgressHome()
        defer { home.remove() }
        let refused = try home.file("Documents/refused")
        let failed = try home.file("Library/Caches/com.synthetic.Failed")
        let candidates = try [cleanupProgressCandidate(refused), cleanupProgressCandidate(failed)]
        let calls = CleanupProgressCallBox()

        let results = CleanupMover(
            home: home.url,
            trasher: CleanupProgressTrasher(failingPaths: [failed.path])
        ).move(candidates) {
            calls.append(done: $0, total: $1, next: $2)
        }

        guard case .refused = results[0].outcome else {
            Issue.record("protected candidate was not refused")
            return
        }
        guard case .failed = results[1].outcome else {
            Issue.record("synthetic Trash failure was not reported")
            return
        }
        #expect(calls.calls == [
            CleanupProgressCall(done: 0, total: 2, next: refused.path),
            CleanupProgressCall(done: 1, total: 2, next: failed.path),
            CleanupProgressCall(done: 2, total: 2, next: nil),
        ])
    }

    @Test("Empty input reports completion once and returns no results")
    func emptyInput() throws {
        let home = try CleanupProgressHome()
        defer { home.remove() }
        let calls = CleanupProgressCallBox()

        let results = CleanupMover(home: home.url, trasher: CleanupProgressTrasher()).move([]) {
            calls.append(done: $0, total: $1, next: $2)
        }

        #expect(results.isEmpty)
        #expect(calls.calls == [CleanupProgressCall(done: 0, total: 0, next: nil)])
    }

    @Test("Omitting progress does not change results")
    func optionalProgressPreservesResults() throws {
        let home = try CleanupProgressHome()
        defer { home.remove() }
        let valid = try home.file("Library/Caches/com.synthetic.Valid")
        let refused = try home.file("Documents/refused")
        let candidates = try [cleanupProgressCandidate(valid), cleanupProgressCandidate(refused)]
        let mover = CleanupMover(home: home.url, trasher: CleanupProgressTrasher())
        let calls = CleanupProgressCallBox()

        let withoutProgress = mover.move(candidates)
        let withProgress = mover.move(candidates) {
            calls.append(done: $0, total: $1, next: $2)
        }

        #expect(withoutProgress == withProgress)
        #expect(calls.calls.count == candidates.count + 1)
    }
}
