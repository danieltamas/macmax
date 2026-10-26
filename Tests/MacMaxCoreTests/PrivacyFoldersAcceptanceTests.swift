import Foundation
import Testing
@testable import MacMaxCore

private struct SyntheticPrivacyHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMaxPrivacyFolders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func directory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func file(_ relativePath: String) throws {
        let fileURL = url.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("synthetic".utf8).write(to: fileURL)
    }
}

@Suite("Privacy folders")
struct PrivacyFoldersAcceptanceTests {
    @Test("Protected relative paths include the required macOS privacy folders")
    func requiredProtectedPaths() {
        let required = [
            "Desktop",
            "Documents",
            "Downloads",
            "Library/Containers",
            "Library/Mail",
            "Library/Application Support/AddressBook",
        ]

        for path in required {
            #expect(PrivacyFolders.relative.contains(path))
        }
    }

    @Test("Walkable returns only safe folders with the remaining depth")
    func safeFoldersAndDepths() throws {
        let home = try SyntheticPrivacyHome()
        defer { home.remove() }
        for directory in [
            "Desktop",
            "Documents",
            "Projects/app",
            "Library/Caches/com.example",
            "Library/Containers/x",
            "Library/Mail",
            "Library/Application Support/Code",
            "Library/Application Support/AddressBook",
        ] {
            try home.directory(directory)
        }
        try home.file("notes.txt")

        let result = PrivacyFolders.walkable(home: home.url.path, depth: 4)
        let relativeResults = result.map { entry in
            (path: String(entry.path.dropFirst(home.url.path.count + 1)), depth: entry.depth)
        }
        let depths = Dictionary(uniqueKeysWithValues: relativeResults.map { ($0.path, $0.depth) })

        #expect(depths["Projects"] == 3)
        #expect(depths["Library/Caches"] == 2)
        #expect(depths["Library/Application Support/Code"] == 1)
        #expect(depths["notes.txt"] == 3)

        let forbidden = [
            "Desktop",
            "Documents",
            "Library/Containers",
            "Library/Mail",
            "Library/Application Support/AddressBook",
        ]
        for entry in relativeResults {
            #expect(entry.path != "")
            #expect(entry.path != "Library")
            #expect(entry.path != "Library/Application Support")
            #expect(!forbidden.contains(entry.path))
        }
        #expect(!result.contains { $0.path == home.url.path })
    }

    @Test("No returned path equals or lies inside any protected relative path")
    func excludesProtectedTrees() throws {
        let home = try SyntheticPrivacyHome()
        defer { home.remove() }
        for protected in PrivacyFolders.relative {
            try home.directory(protected + "/synthetic-child")
        }
        try home.directory("Projects/app")

        let result = PrivacyFolders.walkable(home: home.url.path, depth: 4)
        let relativePaths = result.map { String($0.path.dropFirst(home.url.path.count + 1)) }

        for path in relativePaths {
            #expect(!PrivacyFolders.relative.contains { protected in
                path == protected || path.hasPrefix(protected + "/")
            })
        }
    }

    @Test("A missing home returns no walkable folders")
    func missingHome() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMaxPrivacyFolders-Missing-\(UUID().uuidString)", isDirectory: true)

        #expect(PrivacyFolders.walkable(home: missing.path, depth: 4).isEmpty)
    }
}
