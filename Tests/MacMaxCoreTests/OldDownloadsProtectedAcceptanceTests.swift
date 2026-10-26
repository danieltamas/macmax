import Darwin
import Foundation
import Testing
@testable import MacMaxCore

private struct ProtectedDownloadsHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMaxProtectedDownloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func directory(_ relative: String, modified: Date? = nil) throws -> URL {
        let result = url.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        if let modified { try setModified(result, modified) }
        return result
    }

    @discardableResult
    func file(_ relative: String, bytes: Int, modified: Date) throws -> URL {
        let result = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: result)
        try setModified(result, modified)
        return result
    }

    func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

private final class ProtectedDownloadsTrasher: Trasher, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func trash(_ url: URL) throws {
        lock.withLock { recorded.append(url.path) }
    }

    var paths: [String] { lock.withLock { recorded } }
}

private func protectedScannedDownloads(
    home: URL,
    userProtected: [String] = [],
    days: Int,
    now: Date
) throws -> [OldDownload] {
    switch OldDownloads.scan(home: home, userProtected: userProtected, olderThanDays: days, now: now) {
    case let .ok(items, _, _):
        return items
    case let .unavailable(reason):
        Issue.record("Downloads unexpectedly unavailable: \(reason)")
        return []
    case let .failed(reason):
        Issue.record("Downloads unexpectedly failed: \(reason)")
        return []
    }
}

@Suite("Old Downloads protected paths")
struct OldDownloadsProtectedAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var old: Date { now.addingTimeInterval(-100 * 86_400) }

    @Test("Protected items and containers are excluded while unprotected items remain")
    func scanProtectedItemsAndContainers() throws {
        let home = try ProtectedDownloadsHome()
        defer { home.remove() }
        let protectedFile = try home.file("Downloads/protected.txt", bytes: 1, modified: old)
        let protectedContainer = try home.directory("Downloads/ProtectedContainer", modified: old)
        let protectedChild = try home.file("Downloads/ProtectedContainer/keep.txt", bytes: 2, modified: old)
        try home.setModified(protectedContainer, old)
        let unprotected = try home.file("Downloads/unprotected.txt", bytes: 3, modified: old)

        let items = try protectedScannedDownloads(
            home: home.url,
            userProtected: [protectedFile.path, protectedChild.path],
            days: 90,
            now: now
        )

        #expect(Set(items.map(\.path)) == [unprotected.path])
    }

    @Test("An old folder below a protected parent is excluded")
    func scanProtectedParent() throws {
        let home = try ProtectedDownloadsHome()
        defer { home.remove() }
        let downloads = try home.directory("Downloads")
        let oldFolder = try home.directory("Downloads/OldFolder", modified: old)

        let items = try protectedScannedDownloads(
            home: home.url,
            userProtected: [downloads.path],
            days: 90,
            now: now
        )

        #expect(!items.contains { $0.path == oldFolder.path })
    }

    @Test("Move rechecks protected paths and continues with unprotected items")
    func moverRechecksProtection() throws {
        let home = try ProtectedDownloadsHome()
        defer { home.remove() }
        let protectedAtMove = try home.file("Downloads/protected-at-move", bytes: 2, modified: old)
        let unprotected = try home.file("Downloads/unprotected", bytes: 1, modified: old)
        let preview = try protectedScannedDownloads(home: home.url, days: 90, now: now)
        let trasher = ProtectedDownloadsTrasher()
        let fixedNow = now

        let results = OldDownloadsMover(
            home: home.url,
            userProtected: [protectedAtMove.path],
            trasher: trasher,
            now: { fixedNow }
        ).move(preview, olderThanDays: 90, progress: nil)

        let outcomes = Dictionary(uniqueKeysWithValues: results.map { ($0.path, $0.outcome) })
        guard case .refused = outcomes[protectedAtMove.path] else {
            Issue.record("item protected after preview was not refused")
            return
        }
        #expect(outcomes[unprotected.path] == .done)
        #expect(trasher.paths == [unprotected.path])
    }

    @Test("Finder hidden flag excludes scanning and refuses a previewed move")
    func finderHiddenFlag() throws {
        let home = try ProtectedDownloadsHome()
        defer { home.remove() }
        let hidden = try home.file("Downloads/hidden-by-finder", bytes: 1, modified: old)
        let preview = try protectedScannedDownloads(home: home.url, days: 90, now: now)
        let flagResult = hidden.path.withCString { lchflags($0, UInt32(UF_HIDDEN)) }
        try #require(flagResult == 0)

        let afterFlag = try protectedScannedDownloads(home: home.url, days: 90, now: now)
        #expect(!afterFlag.contains { $0.path == hidden.path })

        let trasher = ProtectedDownloadsTrasher()
        let fixedNow = now
        let results = OldDownloadsMover(home: home.url, trasher: trasher, now: { fixedNow })
            .move(preview, olderThanDays: 90, progress: nil)

        let outcome = try #require(results.first { $0.path == hidden.path }?.outcome)
        guard case .refused = outcome else {
            Issue.record("Finder-hidden item was not refused")
            return
        }
        #expect(trasher.paths.isEmpty)
    }
}
