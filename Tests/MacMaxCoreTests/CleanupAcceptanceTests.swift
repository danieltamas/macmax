import Foundation
import Testing
@testable import MacMaxCore

private struct CleanupHome {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("MacMaxCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
    func directory(_ relative: String) throws -> URL {
        let result = url.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    @discardableResult func file(_ relative: String, bytes: Int, modified: Date? = nil) throws -> URL {
        let result = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: result)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: result.path) }
        return result
    }
}

private func candidate(rule: String = "app_caches", url: URL, bytes: Int64? = nil) throws -> CleanupCandidate {
    let resolved = url.resolvingSymlinksInPath()
    let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
    let device = try #require(attributes[.systemNumber] as? NSNumber)
    let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
    let size: Int64
    if let bytes { size = bytes } else {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        size = Int64(values.fileSize ?? 0)
    }
    return CleanupCandidate(ruleID: rule, path: resolved.path, bytes: size,
                            device: device.int64Value, inode: inode.uint64Value)
}

private final class TrasherFake: Trasher, @unchecked Sendable {
    enum SyntheticError: Error { case refused }
    private let lock = NSLock()
    private let failing: Set<String>
    private var recorded: [String] = []
    private var missingAtCall: [String] = []
    init(failing: Set<String> = []) { self.failing = failing }
    func trash(_ url: URL) throws {
        lock.withLock {
            recorded.append(url.path)
            if !FileManager.default.fileExists(atPath: url.path) { missingAtCall.append(url.path) }
        }
        if failing.contains(url.path) { throw SyntheticError.refused }
    }
    var paths: [String] { lock.withLock { recorded } }
    var missing: [String] { lock.withLock { missingAtCall } }
}

private func candidatePaths(_ preview: CleanupPreview, rule: String) -> [String] {
    preview.candidates.filter { $0.ruleID == rule }.map(\.path)
}

@Suite("U9 cleanup scanner")
struct CleanupScannerAcceptanceTests {
    @Test("All cache rules sum regular files and sort by bytes then path")
    func rulesSizesAndOrdering() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        try home.file("Library/Caches/com.synthetic.Small/a", bytes: 3)
        try home.file("Library/Caches/com.synthetic.Large/a", bytes: 7)
        try home.file("Library/Caches/com.synthetic.Large/nested/b", bytes: 5)
        try home.file("Library/Developer/Xcode/DerivedData/BuildA/a", bytes: 8)
        try home.file("Library/Developer/CoreSimulator/Caches/a", bytes: 9)
        try home.file(".npm/_cacache/a", bytes: 10)
        try home.file("Library/Caches/Yarn/a", bytes: 11)
        try home.file("Library/Caches/pip/a", bytes: 12)
        try home.file("Library/Caches/Homebrew/a", bytes: 13)
        let preview = CleanupScanner(home: home.url).scan()
        let byRule = Dictionary(grouping: preview.candidates, by: \.ruleID)
        #expect(byRule["app_caches"]?.map(\.bytes).sorted() == [3, 12])
        #expect(byRule["xcode_derived"]?.map(\.bytes) == [8])
        #expect(byRule["simulator_caches"]?.map(\.bytes) == [9])
        #expect(byRule["npm_cache"]?.map(\.bytes) == [10])
        #expect(byRule["yarn_cache"]?.map(\.bytes) == [11])
        #expect(byRule["pip_cache"]?.map(\.bytes) == [12])
        #expect(byRule["homebrew_cache"]?.map(\.bytes) == [13])
        #expect(preview.candidates.map(\.bytes) == preview.candidates.map(\.bytes).sorted(by: >))
        for pair in zip(preview.candidates, preview.candidates.dropFirst()) where pair.0.bytes == pair.1.bytes {
            #expect(pair.0.path < pair.1.path)
        }
    }

    @Test("Dedicated caches are not duplicated as app caches")
    func dedicatedCacheExclusions() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        for name in ["Yarn", "pip", "Homebrew"] { try home.file("Library/Caches/\(name)/item", bytes: 1) }
        let preview = CleanupScanner(home: home.url).scan()
        #expect(candidatePaths(preview, rule: "app_caches").isEmpty)
        #expect(Set(preview.candidates.map(\.ruleID)) == ["yarn_cache", "pip_cache", "homebrew_cache"])
    }

    @Test("A running app bundle is excluded from app caches")
    func runningBundle() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        try home.file("Library/Caches/com.synthetic.Running/a", bytes: 1)
        try home.file("Library/Caches/com.synthetic.Stopped/a", bytes: 1)
        let preview = CleanupScanner(home: home.url, running: Running(bundleIDs: ["com.synthetic.Running"])).scan()
        #expect(candidatePaths(preview, rule: "app_caches").count == 1)
        #expect(candidatePaths(preview, rule: "app_caches").first?.hasSuffix("com.synthetic.Stopped") == true)
    }

    @Test("Each running tool suppresses its rule and names the blocker")
    func runningConditions() throws {
        let cases: [(String, String, String)] = [
            ("Xcode", "Library/Developer/Xcode/DerivedData/BuildA/a", "xcode_derived"),
            ("Simulator", "Library/Developer/CoreSimulator/Caches/a", "simulator_caches"),
            ("npm", ".npm/_cacache/a", "npm_cache"),
            ("yarn", "Library/Caches/Yarn/a", "yarn_cache"),
            ("pip", "Library/Caches/pip/a", "pip_cache"),
            ("brew", "Library/Caches/Homebrew/a", "homebrew_cache"),
        ]
        for (program, relative, rule) in cases {
            let home = try CleanupHome()
            defer { home.remove() }
            try home.file(relative, bytes: 1)
            let preview = CleanupScanner(home: home.url, running: Running(names: [program])).scan()
            #expect(candidatePaths(preview, rule: rule).isEmpty)
            #expect(preview.skipped.contains { $0.reason.localizedCaseInsensitiveContains(program) })
        }
    }

    @Test("Old logs use a strict 30-day boundary and exclude DiagnosticReports")
    func oldLogsBoundary() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        let now = Date(timeIntervalSince1970: 4_000_000)
        let boundary = now.addingTimeInterval(-30 * 86_400)
        let old = try home.file("Library/Logs/old.log", bytes: 7, modified: boundary.addingTimeInterval(-1))
        try home.file("Library/Logs/boundary.log", bytes: 8, modified: boundary)
        try home.file("Library/Logs/new.log", bytes: 9, modified: boundary.addingTimeInterval(1))
        try home.file("Library/Logs/DiagnosticReports/crash.log", bytes: 10, modified: boundary.addingTimeInterval(-10))
        let logs = candidatePaths(CleanupScanner(home: home.url, now: now).scan(), rule: "old_logs")
        #expect(logs == [old.path])
    }

    @Test("Symlinks outside the rule root or into protected paths are skipped")
    func symlinkEscapes() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        let documents = try home.directory("Documents/x")
        try home.file("Documents/x/file", bytes: 1)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("MacMaxOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: try home.directory("Library/Caches").appendingPathComponent("protected"), withDestinationURL: documents)
        try FileManager.default.createSymbolicLink(at: home.url.appendingPathComponent("Library/Caches/outside"), withDestinationURL: outside)
        let preview = CleanupScanner(home: home.url).scan()
        #expect(preview.candidates.isEmpty)
        #expect(preview.skipped.count == 2)
        #expect(preview.skipped.contains { $0.path.contains("protected") })
        #expect(preview.skipped.contains { $0.path.contains("outside") })
    }

    @Test("Git directories and user-protected paths are never candidates")
    func protectedDirectories() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        let gitCache = try home.directory("Library/Caches/com.synthetic.Repository")
        try FileManager.default.createDirectory(at: gitCache.appendingPathComponent(".git"), withIntermediateDirectories: false)
        try home.file("Library/Caches/com.synthetic.Repository/data", bytes: 1)
        let userCache = try home.file("Library/Caches/com.synthetic.Protected/data", bytes: 1).deletingLastPathComponent()
        let preview = CleanupScanner(home: home.url, userProtected: [userCache.path]).scan()
        #expect(preview.candidates.isEmpty)
        #expect(preview.skipped.count == 2)
    }

    @Test("Missing roots and an empty home produce an empty preview")
    func emptyHome() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        #expect(CleanupScanner(home: home.url).scan() == CleanupPreview(candidates: [], skipped: []))
    }
}

@Suite("U9 cleanup mover")
struct CleanupMoverAcceptanceTests {
    @Test("Valid candidates are offered to Trash once each in order and still exist")
    func happyPath() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        let first = try home.file("Library/Caches/com.synthetic.First", bytes: 4)
        let second = try home.file("Library/Caches/com.synthetic.Second", bytes: 5)
        let candidates = try [candidate(url: first), candidate(url: second)]
        let trasher = TrasherFake()
        let results = CleanupMover(home: home.url, trasher: trasher).move(candidates)
        #expect(results.map(\.outcome) == [.done, .done])
        #expect(trasher.paths == [first.path, second.path])
        #expect(trasher.missing.isEmpty)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("A candidate replaced by a symlink to a protected path is refused")
    func replacedByProtectedSymlink() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        let path = try home.file("Library/Caches/com.synthetic.Target", bytes: 4)
        let scanned = try candidate(url: path)
        let protected = try home.file("Documents/valuable", bytes: 4)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: protected)
        let trasher = TrasherFake()
        guard case .refused = CleanupMover(home: home.url, trasher: trasher).move([scanned])[0].outcome else {
            Issue.record("replacement symlink was accepted"); return
        }
        #expect(trasher.paths.isEmpty)
    }

    @Test("Delete and recreate changes inode and is refused")
    func changedInode() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        let path = try home.file("Library/Caches/com.synthetic.Target", bytes: 4)
        let scanned = try candidate(url: path)
        try FileManager.default.removeItem(at: path)
        _ = try home.file("Library/Caches/com.synthetic.Target", bytes: 4)
        let trasher = TrasherFake()
        guard case .refused = CleanupMover(home: home.url, trasher: trasher).move([scanned])[0].outcome else {
            Issue.record("changed inode was accepted"); return
        }
        #expect(trasher.paths.isEmpty)
    }

    @Test("A path changed to resolve outside its allowed root is refused")
    func movedOutsideRoot() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        let path = try home.file("Library/Caches/com.synthetic.Target", bytes: 4)
        let scanned = try candidate(url: path)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("MacMaxMoved-\(UUID().uuidString)")
        try Data(repeating: 0x41, count: 4).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        let trasher = TrasherFake()
        guard case .refused = CleanupMover(home: home.url, trasher: trasher).move([scanned])[0].outcome else {
            Issue.record("outside-root replacement was accepted"); return
        }
        #expect(trasher.paths.isEmpty)
    }

    @Test("Growth above 10 percent is refused while exactly 10 percent is allowed")
    func growthBoundary() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        let allowed = try home.file("Library/Caches/com.synthetic.Allowed", bytes: 100)
        let refused = try home.file("Library/Caches/com.synthetic.Refused", bytes: 100)
        let candidates = try [candidate(url: refused), candidate(url: allowed)]
        let refusedHandle = try FileHandle(forWritingTo: refused)
        try refusedHandle.seekToEnd()
        try refusedHandle.write(contentsOf: Data(repeating: 0, count: 11))
        try refusedHandle.close()
        let allowedHandle = try FileHandle(forWritingTo: allowed)
        try allowedHandle.seekToEnd()
        try allowedHandle.write(contentsOf: Data(repeating: 0, count: 10))
        try allowedHandle.close()
        let trasher = TrasherFake()
        let results = CleanupMover(home: home.url, trasher: trasher).move(candidates)
        guard case .refused = results[0].outcome else { Issue.record("11 percent growth was accepted"); return }
        #expect(results[1].outcome == .done)
        #expect(trasher.paths == [allowed.path])
    }

    @Test("Outside-root and protected candidates are refused while later valid work continues")
    func pathPolicyAndContinuation() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        let outside = try home.file("Elsewhere/outside", bytes: 1)
        let protected = try home.file("Documents/protected", bytes: 1)
        let valid = try home.file("Library/Caches/com.synthetic.Valid", bytes: 1)
        let trasher = TrasherFake()
        let results = CleanupMover(home: home.url, trasher: trasher).move(try [
            candidate(url: outside), candidate(url: protected), candidate(url: valid),
        ])
        guard case .refused = results[0].outcome else { Issue.record("outside root accepted"); return }
        guard case .refused = results[1].outcome else { Issue.record("protected path accepted"); return }
        #expect(results[2].outcome == .done)
        #expect(trasher.paths == [valid.path])
    }

    @Test("A Trash error fails that candidate and the next candidate is still processed")
    func trashFailureContinues() throws {
        let home = try CleanupHome()
        defer { home.remove() }
        let first = try home.file("Library/Caches/com.synthetic.First", bytes: 1)
        let second = try home.file("Library/Caches/com.synthetic.Second", bytes: 1)
        let trasher = TrasherFake(failing: [first.path])
        let results = CleanupMover(home: home.url, trasher: trasher).move(try [candidate(url: first), candidate(url: second)])
        guard case .failed = results[0].outcome else { Issue.record("Trash error did not fail"); return }
        #expect(results[1].outcome == .done)
        #expect(trasher.paths == [first.path, second.path])
        #expect(trasher.missing.isEmpty)
    }
}
