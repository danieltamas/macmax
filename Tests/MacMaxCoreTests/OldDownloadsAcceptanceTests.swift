import Foundation
import Testing
@testable import MacMaxCore

private struct DownloadsHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMaxDownloads-\(UUID().uuidString)", isDirectory: true)
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

private final class DownloadsTrasher: Trasher, @unchecked Sendable {
    enum SyntheticError: Error { case refused }
    private let lock = NSLock()
    private let failing: Set<String>
    private var recorded: [String] = []

    init(failing: Set<String> = []) { self.failing = failing }

    func trash(_ url: URL) throws {
        lock.withLock { recorded.append(url.path) }
        if failing.contains(url.path) { throw SyntheticError.refused }
    }

    var paths: [String] { lock.withLock { recorded } }
}

private final class ProgressRecorder: @unchecked Sendable {
    struct Call: Equatable { let done: Int; let total: Int; let next: String? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    func append(done: Int, total: Int, next: String?) {
        lock.withLock { recorded.append(Call(done: done, total: total, next: next)) }
    }
    var calls: [Call] { lock.withLock { recorded } }
}

private func oldDownload(url: URL, bytes: Int64? = nil, modified: Date? = nil,
                         device: Int64? = nil, inode: UInt64? = nil) throws -> OldDownload {
    let canonical = url.resolvingSymlinksInPath()
    let attributes = try FileManager.default.attributesOfItem(atPath: canonical.path)
    let systemNumber = try #require(attributes[.systemNumber] as? NSNumber)
    let systemFileNumber = try #require(attributes[.systemFileNumber] as? NSNumber)
    let modificationDate = try #require(attributes[.modificationDate] as? Date)
    let fileType = try #require(attributes[.type] as? FileAttributeType)
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    return OldDownload(path: canonical.path, name: canonical.lastPathComponent, bytes: bytes ?? size,
                       modified: modified ?? modificationDate, isDirectory: fileType == .typeDirectory,
                       device: device ?? systemNumber.int64Value, inode: inode ?? systemFileNumber.uint64Value)
}

private func scannedDownloads(home: URL, days: Int, now: Date) throws -> [OldDownload] {
    switch OldDownloads.scan(home: home, olderThanDays: days, now: now) {
    case let .ok(items, _, _): return items
    case let .unavailable(reason):
        Issue.record("Downloads unexpectedly unavailable: \(reason)")
        return []
    case let .failed(reason):
        Issue.record("Downloads unexpectedly failed: \(reason)")
        return []
    }
}

@Suite("U16 old Downloads scanner")
struct OldDownloadsScannerAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("Missing, linked, unreadable, empty and invalid inputs have distinct outcomes")
    func rootOutcomes() throws {
        let missing = try DownloadsHome()
        defer { missing.remove() }
        guard case .unavailable = OldDownloads.scan(home: missing.url, olderThanDays: 90, now: now) else {
            Issue.record("missing Downloads was not unavailable")
            return
        }

        let linked = try DownloadsHome()
        defer { linked.remove() }
        let target = try linked.directory("Elsewhere")
        try FileManager.default.createSymbolicLink(at: linked.url.appendingPathComponent("Downloads"), withDestinationURL: target)
        guard case .failed = OldDownloads.scan(home: linked.url, olderThanDays: 90, now: now) else {
            Issue.record("linked Downloads was not failed")
            return
        }

        let unreadable = try DownloadsHome()
        defer { unreadable.remove() }
        let unreadableRoot = try unreadable.directory("Downloads")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadableRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadableRoot.path) }
        guard case .failed = OldDownloads.scan(home: unreadable.url, olderThanDays: 90, now: now) else {
            Issue.record("unreadable Downloads was not failed")
            return
        }

        let empty = try DownloadsHome()
        defer { empty.remove() }
        try empty.directory("Downloads")
        #expect(try scannedDownloads(home: empty.url, days: 90, now: now).isEmpty)
        guard case .failed = OldDownloads.scan(home: empty.url, olderThanDays: 0, now: now) else {
            Issue.record("days below one was not failed")
            return
        }
    }

    @Test("Successful metadata identifies Downloads and the requested instant")
    func readingMetadata() throws {
        let home = try DownloadsHome()
        defer { home.remove() }
        try home.directory("Downloads")
        switch OldDownloads.scan(home: home.url, olderThanDays: OldDownloads.defaultDays, now: now) {
        case let .ok(items, source, at):
            #expect(items.isEmpty)
            #expect(source == "Downloads")
            #expect(at == now)
            #expect(OldDownloads.defaultDays == 90)
        case .unavailable: Issue.record("existing Downloads was unavailable")
        case .failed: Issue.record("existing Downloads failed")
        }
    }

    @Test("Age includes the cutoff and only direct children are returned")
    func ageBoundaryAndDirectChildren() throws {
        let home = try DownloadsHome()
        defer { home.remove() }
        let old = try home.file("Downloads/old.dmg", bytes: 4, modified: now.addingTimeInterval(-100 * 86_400))
        let boundary = try home.file("Downloads/boundary.zip", bytes: 5, modified: now.addingTimeInterval(-90 * 86_400))
        try home.file("Downloads/recent.pkg", bytes: 6, modified: now.addingTimeInterval(-80 * 86_400))
        let folder = try home.directory("Downloads/Folder", modified: now.addingTimeInterval(-100 * 86_400))
        try home.file("Downloads/Folder/nested.bin", bytes: 7, modified: now.addingTimeInterval(-100 * 86_400))
        try home.setModified(folder, now.addingTimeInterval(-100 * 86_400))
        let items = try scannedDownloads(home: home.url, days: 90, now: now)
        let itemPaths = Set(items.map(\.path))
        #expect(itemPaths == Set([old.path, boundary.path, folder.path]))
        #expect(!items.contains { $0.name == "nested.bin" })
    }

    @Test("A folder uses its newest recursive modification and sums regular files")
    func folderAgeAndMeasurement() throws {
        let home = try DownloadsHome()
        defer { home.remove() }
        let recentFolder = try home.directory("Downloads/RecentInside", modified: now.addingTimeInterval(-120 * 86_400))
        try home.file("Downloads/RecentInside/old", bytes: 8, modified: now.addingTimeInterval(-110 * 86_400))
        try home.file("Downloads/RecentInside/recent", bytes: 9, modified: now.addingTimeInterval(-5 * 86_400))
        try home.setModified(recentFolder, now.addingTimeInterval(-120 * 86_400))

        let oldFolder = try home.directory("Downloads/AllOld", modified: now.addingTimeInterval(-120 * 86_400))
        let newest = now.addingTimeInterval(-95 * 86_400)
        try home.file("Downloads/AllOld/a", bytes: 10, modified: now.addingTimeInterval(-100 * 86_400))
        try home.file("Downloads/AllOld/deep/b", bytes: 11, modified: newest)
        try home.setModified(home.url.appendingPathComponent("Downloads/AllOld/deep"), now.addingTimeInterval(-110 * 86_400))
        try home.setModified(oldFolder, now.addingTimeInterval(-120 * 86_400))

        let items = try scannedDownloads(home: home.url, days: 90, now: now)
        #expect(!items.contains { $0.path == recentFolder.path })
        let folder = try #require(items.first { $0.path == oldFolder.path })
        #expect(folder.modified == newest)
        #expect(folder.isDirectory)
        #expect(folder.bytes == 21)
    }

    @Test("Hidden, unfinished, linked and git-containing items are excluded")
    func exclusions() throws {
        let home = try DownloadsHome()
        defer { home.remove() }
        let old = now.addingTimeInterval(-100 * 86_400)
        for name in [".DS_Store", ".localized", "a.download", "b.CRDOWNLOAD", "c.part", "d.PARTIAL", "e.opdownload"] {
            try home.file("Downloads/\(name)", bytes: 2, modified: old)
        }
        let target = try home.file("Elsewhere/target", bytes: 31, modified: old)
        try FileManager.default.createSymbolicLink(at: try home.directory("Downloads").appendingPathComponent("old.dmg"),
                                                    withDestinationURL: target)
        let gitFolder = try home.directory("Downloads/Project", modified: old)
        try home.directory("Downloads/Project/deep/.git", modified: old)
        try home.file("Downloads/Project/data", bytes: 3, modified: old)
        try home.setModified(gitFolder, old)
        let items = try scannedDownloads(home: home.url, days: 90, now: now)
        #expect(items.isEmpty)
    }

    @Test("Items sort by bytes descending then name ascending and expose filesystem identity")
    func orderingAndIdentity() throws {
        let home = try DownloadsHome()
        defer { home.remove() }
        let old = now.addingTimeInterval(-100 * 86_400)
        let beta = try home.file("Downloads/beta", bytes: 5, modified: old)
        let alpha = try home.file("Downloads/alpha", bytes: 5, modified: old)
        let large = try home.file("Downloads/large", bytes: 9, modified: old)
        let items = try scannedDownloads(home: home.url, days: 90, now: now)
        // Equal sizes use Swift's case-sensitive String < ordering.
        let names = items.map(\.name)
        #expect(names == ["large", "alpha", "beta"])
        for url in [large, alpha, beta] {
            let item = try #require(items.first { $0.path == url.path })
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let device = try #require(attributes[.systemNumber] as? NSNumber)
            let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
            #expect(item.device == device.int64Value)
            #expect(item.inode == inode.uint64Value)
        }
    }
}

@Suite("U16 old Downloads mover")
struct OldDownloadsMoverAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var old: Date { now.addingTimeInterval(-100 * 86_400) }

    @Test("Unchanged old items move in order and progress covers zero through total")
    func happyPathAndProgress() throws {
        let home = try DownloadsHome()
        defer { home.remove() }
        try home.file("Downloads/first", bytes: 5, modified: old)
        try home.file("Downloads/second", bytes: 4, modified: old)
        let items = try scannedDownloads(home: home.url, days: 90, now: now)
        let trasher = DownloadsTrasher()
        let progress = ProgressRecorder()
        let fixedNow = now
        let results = OldDownloadsMover(home: home.url, trasher: trasher, now: { fixedNow }).move(
            items, olderThanDays: 90,
            progress: { progress.append(done: $0, total: $1, next: $2) }
        )
        let outcomes = results.map(\.outcome)
        let itemPaths = items.map(\.path)
        let progressDone = progress.calls.map(\.done)
        #expect(outcomes == [.done, .done])
        #expect(trasher.paths == itemPaths)
        #expect(progressDone == [0, 1, 2])
        #expect(progress.calls.allSatisfy { $0.total == items.count })
        #expect(progress.calls.last?.next == nil)
    }

    @Test("Only canonical direct children of Downloads can move")
    func directChildBoundary() throws {
        let home = try DownloadsHome()
        defer { home.remove() }
        let document = try home.file("Documents/outside", bytes: 1, modified: old)
        let nested = try home.file("Downloads/sub/nested", bytes: 1, modified: old)
        let root = try home.directory("Downloads", modified: old)
        let items = try [oldDownload(url: document), oldDownload(url: nested), oldDownload(url: root, bytes: 1)]
        let trasher = DownloadsTrasher()
        let fixedNow = now
        let results = OldDownloadsMover(home: home.url, trasher: trasher, now: { fixedNow })
            .move(items, olderThanDays: 90, progress: nil)
        for result in results {
            guard case .refused = result.outcome else { Issue.record("non-child path was accepted"); return }
        }
        #expect(trasher.paths.isEmpty)
    }

    @Test("Missing, linked and replaced identities are refused")
    func changedIdentity() throws {
        let home = try DownloadsHome()
        defer { home.remove() }
        let missingURL = try home.file("Downloads/missing", bytes: 2, modified: old)
        let linkURL = try home.file("Downloads/link", bytes: 2, modified: old)
        let replacedURL = try home.file("Downloads/replaced", bytes: 2, modified: old)
        let items = try [oldDownload(url: missingURL), oldDownload(url: linkURL), oldDownload(url: replacedURL)]
        try FileManager.default.removeItem(at: missingURL)
        try FileManager.default.removeItem(at: linkURL)
        let target = try home.file("Elsewhere/target", bytes: 2, modified: old)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target)
        try FileManager.default.removeItem(at: replacedURL)
        try home.file("Downloads/replaced", bytes: 2, modified: old)
        let trasher = DownloadsTrasher()
        let fixedNow = now
        let results = OldDownloadsMover(home: home.url, trasher: trasher, now: { fixedNow })
            .move(items, olderThanDays: 90, progress: nil)
        for result in results {
            guard case .refused = result.outcome else { Issue.record("changed item was accepted"); return }
        }
        #expect(trasher.paths.isEmpty)
    }

    @Test("Items made recent after scan are refused, including folders")
    func recentAfterScan() throws {
        let home = try DownloadsHome()
        defer { home.remove() }
        let file = try home.file("Downloads/file", bytes: 2, modified: old)
        let folder = try home.directory("Downloads/folder", modified: old)
        try home.file("Downloads/folder/old", bytes: 2, modified: old)
        try home.setModified(folder, old)
        let items = try scannedDownloads(home: home.url, days: 90, now: now)
        try home.setModified(file, now.addingTimeInterval(-5 * 86_400))
        try home.file("Downloads/folder/recent", bytes: 1, modified: now.addingTimeInterval(-5 * 86_400))
        let trasher = DownloadsTrasher()
        let fixedNow = now
        let results = OldDownloadsMover(home: home.url, trasher: trasher, now: { fixedNow })
            .move(items, olderThanDays: 90, progress: nil)
        for result in results {
            guard case .refused = result.outcome else { Issue.record("recent item was accepted"); return }
        }
        #expect(trasher.paths.isEmpty)
    }

    @Test("Handed-in hidden and unfinished names are refused")
    func unsafeNames() throws {
        let home = try DownloadsHome()
        defer { home.remove() }
        let names = [".hidden", "a.download", "b.crdownload", "c.part"]
        let urls = try names.map { try home.file("Downloads/\($0)", bytes: 1, modified: old) }
        let items = try urls.map { try oldDownload(url: $0) }
        let trasher = DownloadsTrasher()
        let fixedNow = now
        let results = OldDownloadsMover(home: home.url, trasher: trasher, now: { fixedNow })
            .move(items, olderThanDays: 90, progress: nil)
        for result in results {
            guard case .refused = result.outcome else { Issue.record("unsafe name was accepted"); return }
        }
        #expect(trasher.paths.isEmpty)
    }

    @Test("A Trash failure affects one item and later items continue")
    func trashFailureContinues() throws {
        let home = try DownloadsHome()
        defer { home.remove() }
        let first = try home.file("Downloads/first", bytes: 5, modified: old)
        try home.file("Downloads/second", bytes: 4, modified: old)
        let items = try scannedDownloads(home: home.url, days: 90, now: now)
        let trasher = DownloadsTrasher(failing: [first.path])
        let fixedNow = now
        let results = OldDownloadsMover(home: home.url, trasher: trasher, now: { fixedNow })
            .move(items, olderThanDays: 90, progress: nil)
        guard case .failed = results[0].outcome else { Issue.record("Trash failure was not reported"); return }
        #expect(results[1].outcome == .done)
        let itemPaths = items.map(\.path)
        #expect(trasher.paths == itemPaths)
        #expect(Set(trasher.paths).isSubset(of: Set(itemPaths)))
    }
}
