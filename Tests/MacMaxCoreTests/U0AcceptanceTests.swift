import Darwin
import Foundation
import Testing
@testable import MacMaxCore

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private final class LockedPID: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int32?

    func store(_ value: Int32) {
        lock.withLock { storedValue = value }
    }

    func load() -> Int32? {
        lock.withLock { storedValue }
    }
}

private struct CommandResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacMax-U0-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func runCommand(_ executable: String, _ arguments: [String], in directory: URL? = nil) throws -> CommandResult {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return CommandResult(
        status: process.terminationStatus,
        stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
        stderr: stderr.fileHandleForReading.readDataToEndOfFile()
    )
}

private func writeFixtureTree(readme: String = "MacMax\n", swiftLineCount: Int = 1) throws -> URL {
    let root = try temporaryDirectory()
    let sources = root.appendingPathComponent("Sources", isDirectory: true)
    let tests = root.appendingPathComponent("Tests", isDirectory: true)
    let docs = root.appendingPathComponent("docs", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try Data(readme.utf8).write(to: root.appendingPathComponent("README.md"))
    let swift = String(repeating: "// line\n", count: swiftLineCount)
    try Data(swift.utf8).write(to: sources.appendingPathComponent("A.swift"))
    return root
}

private func checkLint(on root: URL) throws -> CommandResult {
    try runCommand(
        "/bin/bash",
        [repositoryRoot.appendingPathComponent("scripts/check.sh").path, "--lint-only", "--root", root.path]
    )
}

private let hasRSVGConvert: Bool = {
    (try? runCommand("/usr/bin/env", ["sh", "-c", "command -v rsvg-convert >/dev/null"]).status) == 0
}()

@Test("Package declares the U0 SwiftPM layout")
func packageDeclaresRequiredTargetsAndPlatform() throws {
    let files = FileManager.default
    for directory in ["MacMaxCore", "MacMax", "MacMaxCLI"] {
        #expect(files.fileExists(atPath: repositoryRoot.appendingPathComponent("Sources/\(directory)").path))
    }

    let package = try String(contentsOf: repositoryRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    #expect(package.contains("// swift-tools-version: 6.0"))
    #expect(package.contains(".macOS(.v14)"))
    #expect(package.contains(".target(name: \"MacMaxCore\"") )
    #expect(package.contains(".executableTarget(name: \"MacMax\"") )
    #expect(package.contains(".executableTarget(name: \"MacMaxCLI\"") )
    #expect(package.contains(".testTarget(name: \"MacMaxCoreTests\"") )
    #expect(!package.contains(".package("))

    let lowercasedTarget = try Regex(#"\.(?:executableT|t|testT)arget\s*\(\s*name\s*:\s*"macmax""#)
    #expect(package.firstMatch(of: lowercasedTarget) == nil)
}

@Test("MacMaxCore never imports a UI framework")
func coreHasNoSwiftUIOrAppKitImports() throws {
    let root = repositoryRoot.appendingPathComponent("Sources/MacMaxCore", isDirectory: true)
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    let forbiddenImport = try Regex(
        #"(?m)^\s*(?:@_exported\s+)?import(?:\s+(?:class|struct|enum|protocol|typealias|func|var|let))?\s+(?:SwiftUI|AppKit)(?:\.|\s*$)"#
    )

    for case let file as URL in enumerator where file.pathExtension == "swift" {
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(source.firstMatch(of: forbiddenImport) == nil, "Forbidden UI import in \(file.path)")
    }
}

@Test("ProcessRunner kills a SIGTERM-ignoring process group after timeout")
func processRunnerKillsTermIgnoringChild() async throws {
    let pid = LockedPID()

    await #expect(throws: ProcessRunner.Failure.timedOut) {
        try await ProcessRunner().run(
            "/bin/sh", ["-c", "trap '' TERM; while :; do sleep 30; done"],
            timeout: .seconds(1),
            started: { pid.store($0) }
        )
    }

    let childPID = try #require(pid.load())
    #expect(kill(childPID, 0) == -1)
    #expect(errno == ESRCH)
}

@Test("ProcessRunner does not hang when a grandchild inherits its pipes")
func processRunnerStopsGrandchildHoldingPipe() async throws {
    let clock = ContinuousClock()
    let started = clock.now

    await #expect(throws: ProcessRunner.Failure.timedOut) {
        try await ProcessRunner().run(
            "/bin/sh", ["-c", "sleep 30 & exit 0"],
            timeout: .seconds(1)
        )
    }

    #expect(started.duration(to: clock.now) < .seconds(8))
}

@Test("ProcessRunner reports timeout even when TERM leads to exit zero")
func processRunnerPreservesTimeoutFailureAfterZeroExit() async throws {
    await #expect(throws: ProcessRunner.Failure.timedOut) {
        try await ProcessRunner().run(
            "/bin/sh", ["-c", "trap 'exit 0' TERM; while :; do sleep 1; done"],
            timeout: .seconds(1)
        )
    }
}

@Test("MacMaxHome uses the default location and MACMAX_HOME override")
func macMaxHomeResolvesLocations() throws {
    let fakeHome = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fakeHome) }
    let override = fakeHome.appendingPathComponent("isolated")

    #expect(MacMaxHome(environment: [:], homeDirectory: fakeHome).url.standardizedFileURL.path == fakeHome.appendingPathComponent(".macmax").standardizedFileURL.path)
    #expect(MacMaxHome(environment: ["MACMAX_HOME": override.path], homeDirectory: fakeHome).url.standardizedFileURL.path == override.standardizedFileURL.path)
}

@Test("MacMaxHome creates and repairs its directory with mode 0700")
func macMaxHomeEnforcesPrivatePermissions() throws {
    let parent = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: parent) }
    let location = parent.appendingPathComponent("home")
    let home = MacMaxHome(environment: ["MACMAX_HOME": location.path], homeDirectory: parent)

    try home.prepare()
    var attributes = try FileManager.default.attributesOfItem(atPath: location.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: location.path)
    try home.prepare()
    attributes = try FileManager.default.attributesOfItem(atPath: location.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test("check.sh accepts 500 lines and rejects 501 lines")
func checkScriptEnforcesSwiftLineLimit() throws {
    let valid = try writeFixtureTree(swiftLineCount: 500)
    let invalid = try writeFixtureTree(swiftLineCount: 501)
    defer {
        try? FileManager.default.removeItem(at: valid)
        try? FileManager.default.removeItem(at: invalid)
    }

    #expect(try checkLint(on: valid).status == 0)
    #expect(try checkLint(on: invalid).status != 0)
}

@Test("check.sh rejects non-ASCII punctuation and accepts ASCII punctuation")
func checkScriptEnforcesPlainPunctuation() throws {
    let invalidCharacters = ["\u{2013}", "\u{2014}", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{2026}", "\u{00A0}"]
    for character in invalidCharacters {
        let root = try writeFixtureTree(readme: "before\(character)after\n")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try checkLint(on: root).status != 0, "Expected rejection of U+\(String(character.unicodeScalars.first!.value, radix: 16))")
    }

    let valid = try writeFixtureTree(readme: "ASCII - dash, \"quotes\", 'apostrophe', and ...\n")
    defer { try? FileManager.default.removeItem(at: valid) }
    #expect(try checkLint(on: valid).status == 0)
}

@Test(
    "Icon rendering is deterministic and matches committed resources",
    .enabled(if: hasRSVGConvert, "rsvg-convert is not on PATH")
)
func iconRenderingIsReproducible() throws {
    let first = try temporaryDirectory()
    let second = try temporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    let script = repositoryRoot.appendingPathComponent("scripts/render-icons.sh").path

    #expect(try runCommand("/bin/bash", [script, first.path], in: repositoryRoot).status == 0)
    #expect(try runCommand("/bin/bash", [script, second.path], in: repositoryRoot).status == 0)

    for name in ["AppIcon.icns", "MenuBarIcon.pdf"] {
        let firstBytes = try Data(contentsOf: first.appendingPathComponent(name))
        let secondBytes = try Data(contentsOf: second.appendingPathComponent(name))
        let committedBytes = try Data(contentsOf: repositoryRoot.appendingPathComponent("Support/\(name)"))
        #expect(firstBytes == secondBytes)
        #expect(firstBytes == committedBytes)
    }
}

@Test("Bundled icon metadata and menu bar template are configured")
func bundleIconAndTemplateConfiguration() throws {
    let infoData = try Data(contentsOf: repositoryRoot.appendingPathComponent("Support/Info.plist"))
    let plist = try #require(
        PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
    )
    #expect(plist["CFBundleIdentifier"] as? String == "ro.danieltamas.macmax")
    #expect(plist["LSUIElement"] as? Bool == true)
    #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
    #expect(plist["LSMinimumSystemVersion"] as? String == "14.0")

    let appIcon = try Data(contentsOf: repositoryRoot.appendingPathComponent("Support/AppIcon.icns"))
    #expect(appIcon.starts(with: Data("icns".utf8)))
    let menuBarIcon = try Data(contentsOf: repositoryRoot.appendingPathComponent("Support/MenuBarIcon.pdf"))
    #expect(menuBarIcon.starts(with: Data("%PDF".utf8)))

    let appSource = try String(
        contentsOf: repositoryRoot.appendingPathComponent("Sources/MacMax/MacMaxApp.swift"),
        encoding: .utf8
    )
    let templateResource = try Regex(
        #"(?s)forResource:\s*"MenuBarIcon".{0,600}?isTemplate\s*=\s*true"#
    )
    #expect(appSource.firstMatch(of: templateResource) != nil)
}
