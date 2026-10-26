import Foundation
import Testing
@testable import MacMaxCore

private struct UnavailablePolicyFixture {
    let root: URL
    let home: URL
    let appPath: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMaxUnavailablePolicy-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("Home", isDirectory: true)
        let applications = home.appendingPathComponent("Applications", isDirectory: true)
        let app = applications.appendingPathComponent("Example Notes.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        appPath = app.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func app(path: String? = nil, bundleID: String = "ro.example.notes") -> InstalledApp {
        InstalledApp(
            path: path ?? appPath,
            name: "Example Notes",
            bundleID: bundleID,
            version: "1.2.3",
            bytes: 1000
        )
    }
}

@Suite("AppUninstallPolicy unavailable")
struct AppUninstallPolicyUnavailableTests {
    @Test("Direct Applications folders are available")
    func directApplicationsFoldersAreAvailable() throws {
        let fixture = try UnavailablePolicyFixture(); defer { fixture.remove() }

        #expect(AppUninstallPolicy.unavailable(for: fixture.app(), home: fixture.home.path) == nil)
        #expect(AppUninstallPolicy.unavailable(
            for: fixture.app(path: "/Applications/Example Notes.app"),
            home: fixture.home.path
        ) == nil)
    }

    @Test("Protected apps and apps outside direct Applications folders are unavailable")
    func protectedAppsAndLocationsAreUnavailable() throws {
        let fixture = try UnavailablePolicyFixture(); defer { fixture.remove() }
        let cases = [
            fixture.app(bundleID: "com.apple.Safari"),
            fixture.app(bundleID: "ro.danieltamas.macmax"),
            fixture.app(path: "/Applications/Folder/X.app"),
            fixture.app(path: "/System/Applications/X.app"),
            fixture.app(path: "/Library/X.app"),
        ]

        for app in cases {
            #expect(AppUninstallPolicy.unavailable(for: app, home: fixture.home.path)?.isEmpty == false)
        }
    }

    @Test("One inner space in a bundle id label is allowed and malformed ids are unavailable")
    func bundleIDValidation() throws {
        let fixture = try UnavailablePolicyFixture(); defer { fixture.remove() }
        let tor = fixture.app(bundleID: "org.mozilla.tor browser")
        #expect(AppUninstallPolicy.unavailable(for: tor, home: fixture.home.path) == nil)

        let refused = [
            "notabundleid",
            "a..b",
            "-a.b",
            "a/b.c",
            " org.example.x",
            "org.example.x ",
            "org.example.a  b",
            "org.example. x",
        ]
        for bundleID in refused {
            let reason = AppUninstallPolicy.unavailable(
                for: fixture.app(bundleID: bundleID),
                home: fixture.home.path
            )
            #expect(reason?.isEmpty == false)
        }
    }

    @Test("Refusal keeps running-state checks around the unavailable policy")
    func refusalKeepsRunningStateChecks() throws {
        let fixture = try UnavailablePolicyFixture(); defer { fixture.remove() }
        let tor = fixture.app(bundleID: "org.mozilla.tor browser")

        #expect(AppUninstallPolicy.refusal(for: tor, home: fixture.home.path, running: nil)?.isEmpty == false)
        #expect(AppUninstallPolicy.refusal(for: tor, home: fixture.home.path, running: Running()) == nil)
        #expect(AppUninstallPolicy.refusal(
            for: tor,
            home: fixture.home.path,
            running: Running(names: [tor.name])
        )?.isEmpty == false)
    }

    @Test("Leftover candidates preserve the spaced bundle id inside the home Library")
    func spacedBundleIDLeftoverCandidates() throws {
        let fixture = try UnavailablePolicyFixture(); defer { fixture.remove() }
        let bundleID = "org.mozilla.tor browser"
        let candidates = LeftoverFinder.candidates(
            for: fixture.app(bundleID: bundleID),
            home: fixture.home.path
        )
        let library = fixture.home.appendingPathComponent("Library", isDirectory: true).path + "/"

        #expect(candidates.contains {
            $0.path == library + "Application Support/" + bundleID
        })
        #expect(candidates.contains {
            $0.path == library + "Preferences/" + bundleID + ".plist"
        })
        #expect(candidates.filter { $0.match == .bundleID }.allSatisfy {
            $0.path.contains(bundleID) && $0.path.hasPrefix(library)
        })
        #expect(candidates.allSatisfy { $0.path.hasPrefix(library) })
    }
}
