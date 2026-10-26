import Foundation
import Testing
@testable import MacMaxCore

private struct UninstallFixture {
    let root: URL
    let home: URL
    let applications: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMaxUninstall-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("Home", isDirectory: true)
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func directory(_ relative: String, under base: URL? = nil) throws -> URL {
        let url = (base ?? home).appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ relative: String, bytes: Int, under base: URL? = nil) throws -> URL {
        let url = (base ?? home).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func app(folder: String, bundleID: String, displayName: String? = nil, bundleName: String? = nil,
             version: String? = nil, under base: URL? = nil, payloadBytes: Int = 0) throws -> URL {
        let url = try directory("\(folder).app", under: base ?? applications)
        let contents = try directory("Contents", under: url)
        var plist: [String: Any] = ["CFBundleIdentifier": bundleID]
        if let displayName { plist["CFBundleDisplayName"] = displayName }
        if let bundleName { plist["CFBundleName"] = bundleName }
        if let version { plist["CFBundleShortVersionString"] = version }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if payloadBytes > 0 {
            try Data(repeating: 0x42, count: payloadBytes).write(to: contents.appendingPathComponent("payload"))
        }
        return url.resolvingSymlinksInPath()
    }
}

private final class RecordingTrasher: Trasher, @unchecked Sendable {
    enum SyntheticError: Error { case refused }
    private let lock = NSLock()
    private let failures: Set<String>
    private var recorded: [URL] = []

    init(failures: Set<String> = []) { self.failures = failures }

    func trash(_ url: URL) throws {
        lock.withLock { recorded.append(url) }
        if failures.contains(url.path) { throw SyntheticError.refused }
    }

    var urls: [URL] { lock.withLock { recorded } }
}

private final class ProgressRecorder: @unchecked Sendable {
    struct Call: Equatable { let done: Int; let total: Int; let next: String? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    func add(done: Int, total: Int, next: String?) { lock.withLock { recorded.append(Call(done: done, total: total, next: next)) } }
    var calls: [Call] { lock.withLock { recorded } }
}

private func installedApp(path: String, name: String = "Example Notes", bundleID: String = "ro.example.notes") -> InstalledApp {
    InstalledApp(path: path, name: name, bundleID: bundleID, version: "1.2.3", bytes: 1000)
}

private func reason(of outcome: ActionOutcome) -> String? {
    switch outcome {
    case .done: nil
    case let .refused(reason), let .failed(reason): reason
    }
}

@Suite("U14 app listing")
struct AppListerSpecTests {
    @Test("Apps from all folders have plist metadata, canonical paths, sizes, and stable ordering")
    func validAppsAndOrdering() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let secondFolder = try fixture.directory("SecondApplications", under: fixture.root)
        let zebra = try fixture.app(folder: "Zebra", bundleID: "ro.example.zebra", bundleName: "Zebra", version: "3", payloadBytes: 1000)
        let notes = try fixture.app(folder: "NotesFolder", bundleID: "ro.example.notes", displayName: "example notes",
                                    bundleName: "Wrong Name", version: "1.2.3", payloadBytes: 1000)
        let alpha = try fixture.app(folder: "Alpha", bundleID: "ro.example.alpha", under: secondFolder, payloadBytes: 1000)
        let result = AppLister.list(folders: [fixture.applications.path, secondFolder.path])
        #expect(result.unreadable == 0)
        #expect(result.apps.map(\.name) == ["Alpha", "example notes", "Zebra"])
        #expect(result.apps.map(\.path) == [alpha.path, notes.path, zebra.path])
        #expect(result.apps.map(\.bundleID) == ["ro.example.alpha", "ro.example.notes", "ro.example.zebra"])
        #expect(result.apps.map(\.version) == [nil, "1.2.3", "3"])
        #expect(result.apps.allSatisfy { ($0.bytes ?? 0) >= 1000 })
    }

    @Test("Name fallback uses bundle name then folder name and path breaks case-insensitive ties")
    func nameFallbackAndTie() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let other = try fixture.directory("Other", under: fixture.root)
        let first = try fixture.app(folder: "Folder Fallback", bundleID: "ro.example.folder")
        let second = try fixture.app(folder: "Named", bundleID: "ro.example.named", bundleName: "Bundle Name")
        let tieA = try fixture.app(folder: "TieA", bundleID: "ro.example.tiea", displayName: "same", under: other)
        let tieB = try fixture.app(folder: "TieB", bundleID: "ro.example.tieb", displayName: "Same", under: other)
        let result = AppLister.list(folders: [fixture.applications.path, other.path])
        #expect(result.apps.contains { $0.path == first.path && $0.name == "Folder Fallback" })
        #expect(result.apps.contains { $0.path == second.path && $0.name == "Bundle Name" })
        #expect(result.apps.filter { $0.name.lowercased() == "same" }.map(\.path) == [tieA.path, tieB.path].sorted())
    }

    @Test("Invalid bundles and app symlinks count unreadable while irrelevant entries do not")
    func invalidBundlesAndIgnoredEntries() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let valid = try fixture.app(folder: "Valid", bundleID: "ro.example.valid")
        _ = try fixture.directory("Missing.app", under: fixture.applications)
        let malformed = try fixture.directory("Malformed.app/Contents", under: fixture.applications)
        try Data("not a plist".utf8).write(to: malformed.appendingPathComponent("Info.plist"))
        _ = try fixture.app(folder: "Empty", bundleID: "")
        _ = try fixture.app(folder: "Control", bundleID: "ro.example.bad\nvalue")
        _ = try fixture.app(folder: "Long", bundleID: "r." + String(repeating: "a", count: 255))
        try FileManager.default.createSymbolicLink(at: fixture.applications.appendingPathComponent("Linked.app"), withDestinationURL: valid)
        let utilities = try fixture.directory("Utilities", under: fixture.applications)
        _ = try fixture.app(folder: "Nested", bundleID: "ro.example.nested", under: utilities)
        _ = try fixture.file("notes.txt", bytes: 4, under: fixture.applications)
        let result = AppLister.list(folders: [fixture.applications.path, fixture.root.appendingPathComponent("Absent").path])
        #expect(result.apps.map(\.bundleID) == ["ro.example.valid"])
        #expect(result.unreadable == 6)
    }
}

@Suite("U14 leftover discovery")
struct LeftoverFinderSpecTests {
    @Test("Candidates are exactly the ten bundle paths and two safe name paths")
    func exactCandidates() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let app = installedApp(path: fixture.applications.appendingPathComponent("Example Notes.app").path)
        let candidates = LeftoverFinder.candidates(for: app, home: fixture.home.path)
        let expected: [(String, LeftoverKind, LeftoverMatch)] = [
            ("Library/Application Support/ro.example.notes", .applicationSupport, .bundleID),
            ("Library/Caches/ro.example.notes", .caches, .bundleID),
            ("Library/Preferences/ro.example.notes.plist", .preferences, .bundleID),
            ("Library/Containers/ro.example.notes", .container, .bundleID),
            ("Library/Logs/ro.example.notes", .logs, .bundleID),
            ("Library/Saved Application State/ro.example.notes.savedState", .savedState, .bundleID),
            ("Library/HTTPStorages/ro.example.notes", .httpStorage, .bundleID),
            ("Library/WebKit/ro.example.notes", .webKit, .bundleID),
            ("Library/Cookies/ro.example.notes.binarycookies", .cookies, .bundleID),
            ("Library/LaunchAgents/ro.example.notes.plist", .launchAgent, .bundleID),
            ("Library/Application Support/Example Notes", .applicationSupport, .name),
            ("Library/Logs/Example Notes", .logs, .name),
        ]
        #expect(candidates.map(\.path) == expected.map { fixture.home.appendingPathComponent($0.0).path })
        #expect(candidates.map(\.kind) == expected.map { $0.1 })
        #expect(candidates.map(\.match) == expected.map { $0.2 })
        #expect(candidates.allSatisfy { !$0.path.contains("Group Containers") && !$0.path.contains("Documents") })
    }

    @Test("Unsafe or duplicate names add no name candidates")
    func unsafeNames() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        for name in ["abc", "bad/name", ".", "..", "ro.example.notes"] {
            let app = installedApp(path: "/Applications/X.app", name: name)
            let candidates = LeftoverFinder.candidates(for: app, home: fixture.home.path)
            #expect(candidates.count == 10)
            #expect(candidates.allSatisfy { $0.match == .bundleID })
        }
    }

    @Test("Find returns only existing non-symlink candidates with measured sizes and specified ordering")
    func existingMeasuredLeftovers() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let app = installedApp(path: "/Applications/Example Notes.app")
        let support = try fixture.file("Library/Application Support/ro.example.notes/data", bytes: 1000).deletingLastPathComponent()
        let cache = try fixture.file("Library/Caches/ro.example.notes", bytes: 20)
        let log = try fixture.file("Library/Logs/Example Notes", bytes: 20)
        _ = try fixture.file("Library/Caches/ro.example.other", bytes: 2000)
        _ = try fixture.file("Library/Application Support/Example Notes Backup/data", bytes: 3000)
        let outside = try fixture.directory("Outside", under: fixture.root)
        try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent("Library/Containers"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.home.appendingPathComponent("Library/Containers/ro.example.notes"), withDestinationURL: outside)
        let found = LeftoverFinder.find(for: app, home: fixture.home.path)
        #expect(Set(found.map(\.path)) == Set([support.path, cache.path, log.path]))
        #expect(found.first?.path == support.path)
        #expect(found.first?.bytes == 1000)
        #expect(found.dropFirst().map(\.path) == [cache.path, log.path].sorted())
        #expect(found.contains { $0.path == cache.path && $0.kind == .caches && $0.match == .bundleID && $0.bytes == 20 })
        #expect(found.contains { $0.path == log.path && $0.kind == .logs && $0.match == .name && $0.bytes == 20 })
    }
}

@Suite("U14 uninstall policy")
struct AppUninstallPolicySpecTests {
    @Test("A stopped user app directly in either allowed Applications folder is allowed")
    func allowedLocations() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let userApp = try fixture.app(folder: "Example Notes", bundleID: "ro.example.notes", displayName: "Example Notes", under: fixture.home.appendingPathComponent("Applications"))
        #expect(AppUninstallPolicy.refusal(for: installedApp(path: userApp.path), home: fixture.home.path, running: Running()) == nil)
        #expect(AppUninstallPolicy.refusal(for: installedApp(path: "/Applications/Example Notes.app"), home: fixture.home.path, running: Running()) == nil)
    }

    @Test("Unknown running state, running identity, protected identity, bad bundle IDs, and other locations are refused")
    func refusalMatrix() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let base = installedApp(path: "/Applications/Example Notes.app")
        let cases: [(InstalledApp, Running?)] = [
            (base, nil),
            (base, Running(bundleIDs: [base.bundleID])),
            (base, Running(names: ["Example Notes"])),
            (installedApp(path: base.path, name: "Different", bundleID: base.bundleID), Running(names: ["Example Notes"])),
            (installedApp(path: base.path, bundleID: "com.apple.Safari"), Running()),
            (installedApp(path: base.path, bundleID: "ro.danieltamas.macmax.helper"), Running()),
            (installedApp(path: base.path, bundleID: "invalid"), Running()),
            (installedApp(path: "/System/Applications/X.app"), Running()),
            (installedApp(path: "/Library/X.app"), Running()),
            (installedApp(path: "/Applications/Utilities/X.app"), Running()),
            (installedApp(path: "/Applications/Folder/X.app"), Running()),
        ]
        for (app, running) in cases {
            let refusal = AppUninstallPolicy.refusal(for: app, home: fixture.home.path, running: running)
            #expect(refusal?.isEmpty == false)
        }
        for bundleID in ["a.b", "1a.b-2", "a..b", "-a.b", "a_.b", "a/b.c"] {
            #expect(CleanupPolicy.isBundleID(bundleID) == (["a.b", "1a.b-2"].contains(bundleID)))
        }
    }
}

@Suite("U14 app uninstaller")
struct AppUninstallerSpecTests {
    private func preview() throws -> (UninstallFixture, InstalledApp, [Leftover]) {
        let fixture = try UninstallFixture()
        let appURL = try fixture.app(folder: "Example Notes", bundleID: "ro.example.notes", displayName: "Example Notes",
                                     under: fixture.home.appendingPathComponent("Applications"))
        _ = try fixture.file("Library/Caches/ro.example.notes", bytes: 40)
        _ = try fixture.file("Library/Logs/Example Notes", bytes: 20)
        let app = installedApp(path: appURL.path)
        return (fixture, app, LeftoverFinder.find(for: app, home: fixture.home.path))
    }

    @Test("The app moves first, then previewed leftovers in order, with complete progress")
    func happyPathAndProgress() throws {
        let (fixture, app, leftovers) = try preview(); defer { fixture.remove() }
        let trasher = RecordingTrasher()
        let progress = ProgressRecorder()
        let results = AppUninstaller(home: fixture.home, trasher: trasher).uninstall(app, leftovers: leftovers) {
            progress.add(done: $0, total: $1, next: $2)
        }
        let paths = [app.path] + leftovers.map(\.path)
        #expect(results.map(\.path) == paths)
        #expect(results.map(\.outcome) == Array(repeating: .done, count: paths.count))
        #expect(trasher.urls.map(\.path) == paths)
        #expect(progress.calls.map(\.done) == Array(0...paths.count))
        #expect(progress.calls.allSatisfy { $0.total == paths.count })
        #expect(progress.calls.dropLast().map(\.next) == paths.map(Optional.some))
        #expect(progress.calls.last == ProgressRecorder.Call(done: paths.count, total: paths.count, next: nil))
    }

    @Test("Running or unknown state refuses the app and every leftover without Trash calls")
    func failClosedRunningState() throws {
        for running: Running? in [nil, Running(bundleIDs: ["ro.example.notes"])] {
            let (fixture, app, leftovers) = try preview(); defer { fixture.remove() }
            let trasher = RecordingTrasher()
            let results = AppUninstaller(home: fixture.home, trasher: trasher, running: { [running] in running }).uninstall(app, leftovers: leftovers)
            #expect(results.count == 1 + leftovers.count)
            #expect(results.allSatisfy { if case .refused = $0.outcome { true } else { false } })
            #expect(results.dropFirst().allSatisfy { (reason(of: $0.outcome) ?? "").localizedCaseInsensitiveContains("app") })
            #expect(trasher.urls.isEmpty)
        }
    }

    @Test("An app Trash failure fails the app and refuses all leftovers")
    func appFailureStopsLeftovers() throws {
        let (fixture, app, leftovers) = try preview(); defer { fixture.remove() }
        let trasher = RecordingTrasher(failures: [app.path])
        let results = AppUninstaller(home: fixture.home, trasher: trasher).uninstall(app, leftovers: leftovers)
        guard case .failed = results[0].outcome else { Issue.record("app Trash failure was not failed"); return }
        #expect(results.dropFirst().allSatisfy { if case .refused = $0.outcome { true } else { false } })
        #expect(trasher.urls.map(\.path) == [app.path])
    }

    @Test("Unallowlisted, missing, and replaced-by-symlink leftovers are refused while valid work continues")
    func invalidLeftoversDoNotBlockValidOnes() throws {
        let (fixture, app, found) = try preview(); defer { fixture.remove() }
        let valid = try #require(found.first)
        let documents = try fixture.file("Documents/x", bytes: 1)
        let other = try fixture.file("Library/Caches/ro.example.other", bytes: 1)
        let missingPath = fixture.home.appendingPathComponent("Library/Preferences/ro.example.notes.plist").path
        let stale = Leftover(path: missingPath, kind: .preferences, match: .bundleID, bytes: 1)
        let symlinkPath = fixture.home.appendingPathComponent("Library/Containers/ro.example.notes")
        let target = try fixture.directory("SymlinkTarget", under: fixture.root)
        try FileManager.default.createDirectory(at: symlinkPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: target)
        let leftovers = [
            Leftover(path: documents.path, kind: .caches, match: .bundleID, bytes: 1),
            Leftover(path: other.path, kind: .caches, match: .bundleID, bytes: 1),
            stale,
            Leftover(path: symlinkPath.path, kind: .container, match: .bundleID, bytes: 0),
            valid,
        ]
        let trasher = RecordingTrasher()
        let results = AppUninstaller(home: fixture.home, trasher: trasher).uninstall(app, leftovers: leftovers)
        #expect(results[0].outcome == .done)
        #expect(results.dropFirst().dropLast().allSatisfy { if case .refused = $0.outcome { true } else { false } })
        #expect(results.last?.outcome == .done)
        #expect(trasher.urls.map(\.path) == [app.path, valid.path])
    }

    @Test("A leftover Trash failure fails only that item and later items continue")
    func leftoverFailureContinues() throws {
        let (fixture, app, leftovers) = try preview(); defer { fixture.remove() }
        let first = try #require(leftovers.first)
        let trasher = RecordingTrasher(failures: [first.path])
        let results = AppUninstaller(home: fixture.home, trasher: trasher).uninstall(app, leftovers: leftovers)
        #expect(results[0].outcome == .done)
        guard case .failed = results[1].outcome else { Issue.record("leftover Trash failure was not failed"); return }
        #expect(results.dropFirst(2).allSatisfy { $0.outcome == .done })
        #expect(trasher.urls.map(\.path) == [app.path] + leftovers.map(\.path))
    }

    @Test("Apple apps and MacMax are refused without calling Trash")
    func protectedApps() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        for bundleID in ["com.apple.Safari", "ro.danieltamas.macmax"] {
            let path = fixture.home.appendingPathComponent("Applications/Protected.app").path
            let app = installedApp(path: path, name: "Protected", bundleID: bundleID)
            let trasher = RecordingTrasher()
            let results = AppUninstaller(home: fixture.home, trasher: trasher).uninstall(app, leftovers: [])
            #expect(results.count == 1)
            #expect(reason(of: results[0].outcome)?.isEmpty == false)
            #expect(trasher.urls.isEmpty)
        }
    }
}
