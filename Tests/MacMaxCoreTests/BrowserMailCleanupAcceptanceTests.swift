import Foundation
import Testing
@testable import MacMaxCore

private struct BrowserMailHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMaxBrowserMail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let result = url.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let result = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: result)
        return result
    }
}

private final class BrowserMailTrasher: Trasher, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func trash(_ url: URL) throws { lock.withLock { recorded.append(url.path) } }
    var paths: [String] { lock.withLock { recorded } }
}

private func browserMailCandidate(rule: String, url: URL, bytes: Int64? = nil) throws -> CleanupCandidate {
    let canonical = url.resolvingSymlinksInPath()
    let attributes = try FileManager.default.attributesOfItem(atPath: canonical.path)
    let device = try #require(attributes[.systemNumber] as? NSNumber)
    let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
    let measuredBytes: Int64
    if let bytes {
        measuredBytes = bytes
    } else {
        let values = try canonical.resourceValues(forKeys: [.fileSizeKey])
        measuredBytes = Int64(values.fileSize ?? 0)
    }
    return CleanupCandidate(ruleID: rule, path: canonical.path, bytes: measuredBytes,
                            device: device.int64Value, inode: inode.uint64Value)
}

private func candidates(_ preview: CleanupPreview, rule: String) -> [CleanupCandidate] {
    preview.candidates.filter { $0.ruleID == rule }
}

@Suite("U16 browser and Mail cleanup scanner")
struct BrowserMailCleanupScannerAcceptanceTests {
    @Test("Each existing browser cache is one candidate and a missing cache is absent")
    func browserCacheRules() throws {
        let home = try BrowserMailHome()
        defer { home.remove() }
        let cases = [
            ("chrome_cache", "Library/Caches/Google/Chrome"),
            ("firefox_cache", "Library/Caches/Firefox"),
            ("edge_cache", "Library/Caches/Microsoft Edge"),
        ]
        for (_, root) in cases { try home.file("\(root)/entry", bytes: 1_000) }

        let preview = CleanupScanner(home: home.url).scan()
        for (rule, root) in cases {
            let found = candidates(preview, rule: rule)
            #expect(found.count == 1)
            #expect(found.first?.path == home.url.appendingPathComponent(root).resolvingSymlinksInPath().path)
            #expect(found.first?.bytes == 1_000)
        }
        #expect(candidates(preview, rule: "brave_cache").isEmpty)
        #expect(!preview.skipped.contains { $0.ruleID == "brave_cache" })
    }

    @Test("A running browser suppresses only its own rule with a running skip")
    func runningBrowser() throws {
        let cases = [
            ("chrome_cache", "Library/Caches/Google/Chrome", "Google Chrome"),
            ("firefox_cache", "Library/Caches/Firefox", "firefox"),
            ("edge_cache", "Library/Caches/Microsoft Edge", "Microsoft Edge"),
            ("brave_cache", "Library/Caches/BraveSoftware", "Brave Browser"),
        ]
        for blocked in cases {
            let home = try BrowserMailHome()
            defer { home.remove() }
            for entry in cases { try home.file("\(entry.1)/entry", bytes: 1_000) }
            let preview = CleanupScanner(home: home.url, running: Running(names: [blocked.2])).scan()
            #expect(candidates(preview, rule: blocked.0).isEmpty)
            #expect(preview.skipped.contains {
                $0.ruleID == blocked.0 && $0.reason.localizedCaseInsensitiveContains("running")
            })
            #expect(cases.filter { $0.0 != blocked.0 }.allSatisfy {
                candidates(preview, rule: $0.0).count == 1
            })
        }
    }

    @Test("Running Mail suppresses Mail Downloads without affecting browser caches")
    func runningMail() throws {
        let home = try BrowserMailHome()
        defer { home.remove() }
        try home.file("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/item", bytes: 4)
        try home.file("Library/Caches/Google/Chrome/item", bytes: 1_000)
        let preview = CleanupScanner(home: home.url, running: Running(names: ["Mail"])).scan()
        #expect(candidates(preview, rule: "mail_downloads").isEmpty)
        #expect(preview.skipped.contains {
            $0.ruleID == "mail_downloads" && $0.reason.localizedCaseInsensitiveContains("running")
        })
        #expect(candidates(preview, rule: "chrome_cache").count == 1)
    }

    @Test("Mail Downloads lists direct children but no other container or mailbox data")
    func mailDownloadsBoundary() throws {
        let home = try BrowserMailHome()
        defer { home.remove() }
        let root = "Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
        let file = try home.file("\(root)/invoice.pdf", bytes: 7)
        let folder = try home.directory("\(root)/Archive")
        try home.file("\(root)/Archive/attachment.bin", bytes: 11)
        try home.file("Library/Containers/com.apple.mail/Data/Library/Other/keep", bytes: 13)
        try home.file("Library/Containers/ro.example.app/Data/Library/Caches/x", bytes: 17)
        try home.file("Library/Mail/V10/Messages/a.emlx", bytes: 19)

        let preview = CleanupScanner(home: home.url).scan()
        let mail = candidates(preview, rule: "mail_downloads")
        let mailPaths = Set(mail.map(\.path))
        #expect(mailPaths == Set([file.path, folder.path]))
        #expect(mail.first { $0.path == file.path }?.bytes == 7)
        #expect(mail.first { $0.path == folder.path }?.bytes == 11)
        #expect(!mail.contains { $0.path.hasSuffix("Mail Downloads") })
        #expect(!preview.candidates.contains {
            $0.path.contains("/Library/Other/") || $0.path.contains("/ro.example.app/") || $0.path.contains("/Library/Mail/")
        })
    }

    @Test("A link in the allowed root fails closed and is not followed")
    func linkedRootComponent() throws {
        let home = try BrowserMailHome()
        defer { home.remove() }
        let target = try home.directory("SyntheticMailContainer")
        try home.file("SyntheticMailContainer/Data/Library/Mail Downloads/secret", bytes: 23)
        let containers = try home.directory("Library/Containers")
        try FileManager.default.createSymbolicLink(
            at: containers.appendingPathComponent("com.apple.mail"),
            withDestinationURL: target
        )
        let preview = CleanupScanner(home: home.url).scan()
        #expect(candidates(preview, rule: "mail_downloads").isEmpty)
        #expect(preview.skipped.contains {
            $0.ruleID == "mail_downloads" && $0.reason.localizedCaseInsensitiveContains("link")
        })
        #expect(!preview.candidates.contains { $0.path.contains("SyntheticMailContainer") })
    }

    @Test("A link inside Mail Downloads is never a candidate or followed")
    func linkedMailChild() throws {
        let home = try BrowserMailHome()
        defer { home.remove() }
        let target = try home.file("Documents/outside.bin", bytes: 29)
        let root = try home.directory("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        let link = root.appendingPathComponent("outside.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let preview = CleanupScanner(home: home.url).scan()
        #expect(candidates(preview, rule: "mail_downloads").isEmpty)
        #expect(!preview.candidates.contains { $0.path == target.path || $0.bytes == 29 })
    }

    @Test("Existing app caches remain and Chrome is not duplicated as an app cache")
    func existingAppCacheRule() throws {
        let home = try BrowserMailHome()
        defer { home.remove() }
        let app = try home.directory("Library/Caches/ro.example.app")
        try home.file("Library/Caches/ro.example.app/data", bytes: 3)
        try home.file("Library/Caches/Google/Chrome/data", bytes: 5)
        let preview = CleanupScanner(home: home.url).scan()
        let appCaches = candidates(preview, rule: "app_caches")
        let appCachePaths = appCaches.map(\.path)
        #expect(appCachePaths == [app.path])
        #expect(candidates(preview, rule: "chrome_cache").count == 1)
    }
}

@Suite("U16 browser and Mail cleanup mover")
struct BrowserMailCleanupMoverAcceptanceTests {
    @Test("A previewed Chrome cache moves through the supplied trasher")
    func chromeHappyPath() throws {
        let home = try BrowserMailHome()
        defer { home.remove() }
        try home.file("Library/Caches/Google/Chrome/data", bytes: 1_000)
        let scanned = try #require(candidates(CleanupScanner(home: home.url).scan(), rule: "chrome_cache").first)
        let trasher = BrowserMailTrasher()
        let result = CleanupMover(home: home.url, trasher: trasher).move([scanned])
        let outcomes = result.map(\.outcome)
        #expect(outcomes == [.done])
        #expect(trasher.paths == [scanned.path])
    }

    @Test("A browser that starts after preview blocks the move")
    func browserStartsAfterPreview() throws {
        let home = try BrowserMailHome()
        defer { home.remove() }
        try home.file("Library/Caches/Google/Chrome/data", bytes: 1_000)
        let scanned = try #require(candidates(CleanupScanner(home: home.url).scan(), rule: "chrome_cache").first)
        let trasher = BrowserMailTrasher()
        let results = CleanupMover(
            home: home.url, trasher: trasher, running: { Running(names: ["Google Chrome"]) }
        ).move([scanned])
        guard case .refused = results[0].outcome else {
            Issue.record("running browser candidate was accepted")
            return
        }
        #expect(trasher.paths.isEmpty)
    }

    @Test("A Mail candidate outside Mail Downloads is refused")
    func mailCandidateOutsideAllowedRoot() throws {
        let home = try BrowserMailHome()
        defer { home.remove() }
        let outside = try home.file("Library/Containers/com.apple.mail/Data/Library/Preferences/x.plist", bytes: 4)
        let handedIn = try browserMailCandidate(rule: "mail_downloads", url: outside)
        let trasher = BrowserMailTrasher()
        let results = CleanupMover(home: home.url, trasher: trasher).move([handedIn])
        guard case .refused = results[0].outcome else {
            Issue.record("Mail candidate outside Mail Downloads was accepted")
            return
        }
        #expect(trasher.paths.isEmpty)
    }
}
