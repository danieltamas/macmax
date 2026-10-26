import Foundation
import Testing
@testable import MacMaxCore

private enum LaunchItemsFixtureError: Error {
    case expectedItem(String)
}

private struct LaunchItemsTempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMaxLaunchItems-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func directory(_ name: String) throws -> URL {
        let result = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    @discardableResult
    func write(_ data: Data, to relativePath: String) throws -> URL {
        let result = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: result.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: result)
        return result
    }
}

private func plistData(_ value: Any, format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
}

private func requireStartupItem(_ reading: Reading<StartupItem>) throws -> StartupItem {
    switch reading {
    case let .ok(item, _, _):
        return item
    case let .unavailable(reason):
        throw LaunchItemsFixtureError.expectedItem("unavailable: \(reason)")
    case let .failed(reason):
        throw LaunchItemsFixtureError.expectedItem("failed: \(reason)")
    }
}

private func isNotOK<T>(_ reading: Reading<T>) -> Bool {
    switch reading {
    case .ok:
        return false
    case .unavailable, .failed:
        return true
    }
}

private func startupItem(
    label: String,
    path: String,
    scope: StartupScope = .userAgent,
    isDisabled: Bool = false,
    isRunning: Bool = false
) -> StartupItem {
    StartupItem(
        label: label,
        path: path,
        scope: scope,
        program: nil,
        runsAtLoad: false,
        isDisabled: isDisabled,
        isRunning: isRunning
    )
}

@Suite("U13 startup plist parser")
struct StartupParserAcceptanceTests {
    @Test("XML and binary plists preserve identity, scope, program priority, and id")
    func validFormatsAndProgramPriority() throws {
        let xml = try plistData([
            "Label": "ro.example.xml",
            "Program": "/opt/example/preferred",
            "ProgramArguments": ["/opt/example/fallback", "--flag"],
        ])
        let binary = try plistData([
            "Label": "ro.example.binary",
            "ProgramArguments": ["/opt/example/binary", "--flag"],
        ], format: .binary)

        let xmlItem = try requireStartupItem(StartupParser.parse(xml, path: "/synthetic/xml.plist", scope: .globalAgent))
        let binaryItem = try requireStartupItem(StartupParser.parse(binary, path: "/synthetic/binary.plist", scope: .globalDaemon))

        #expect(xmlItem.label == "ro.example.xml")
        #expect(xmlItem.path == "/synthetic/xml.plist")
        #expect(xmlItem.id == "/synthetic/xml.plist")
        #expect(xmlItem.scope == .globalAgent)
        #expect(xmlItem.program == "/opt/example/preferred")
        #expect(binaryItem.program == "/opt/example/binary")
        #expect(binaryItem.scope == .globalDaemon)
    }

    @Test("Missing or non-string programs produce nil")
    func absentAndInvalidPrograms() throws {
        let fixtures: [[String: Any]] = [
            ["Label": "ro.example.absent"],
            ["Label": "ro.example.invalid", "Program": 7, "ProgramArguments": [8]],
            ["Label": "ro.example.non-string-program", "Program": 7, "ProgramArguments": ["/opt/example/must-not-win"]],
            ["Label": "ro.example.empty-arguments", "ProgramArguments": []],
        ]
        for (index, fixture) in fixtures.enumerated() {
            let item = try requireStartupItem(StartupParser.parse(
                try plistData(fixture),
                path: "/synthetic/no-program-\(index).plist",
                scope: .userAgent
            ))
            #expect(item.program == nil)
        }
    }

    @Test("RunAtLoad and KeepAlive determine whether an item runs at load")
    func runsAtLoadShapes() throws {
        let fixtures: [([String: Any], Bool)] = [
            (["Label": "ro.example.run", "RunAtLoad": true], true),
            (["Label": "ro.example.keep", "KeepAlive": true], true),
            (["Label": "ro.example.keep-dictionary", "KeepAlive": ["SuccessfulExit": false]], true),
            (["Label": "ro.example.false", "RunAtLoad": false], false),
            (["Label": "ro.example.invalid", "RunAtLoad": "yes"], false),
            (["Label": "ro.example.neither"], false),
        ]
        for (index, fixture) in fixtures.enumerated() {
            let item = try requireStartupItem(StartupParser.parse(
                try plistData(fixture.0),
                path: "/synthetic/run-\(index).plist",
                scope: .userAgent
            ))
            #expect(item.runsAtLoad == fixture.1)
        }
    }

    @Test("Malformed plist shapes and unusable labels fail closed")
    func invalidPlistsAndLabels() throws {
        let invalid: [Data] = [
            Data("not a plist".utf8),
            try plistData(["array", "not", "dictionary"]),
            try plistData(["Program": "/opt/example/helper"]),
            try plistData(["Label": ""]),
            try plistData(["Label": 17]),
            try plistData(["Label": "ro.example.bad\nlabel"]),
            try plistData(["Label": "x" + String(repeating: "a", count: 256)]),
        ]
        for (index, data) in invalid.enumerated() {
            let reading = StartupParser.parse(data, path: "/synthetic/invalid-\(index).plist", scope: .userAgent)
            #expect(isNotOK(reading), "Invalid plist \(index) was accepted")
        }

        let boundary = try requireStartupItem(StartupParser.parse(
            try plistData(["Label": String(repeating: "a", count: 256)]),
            path: "/synthetic/boundary.plist",
            scope: .userAgent
        ))
        #expect(boundary.label.count == 256)
    }
}

@Suite("U13 launchctl parsers")
struct LaunchctlListAcceptanceTests {
    @Test("Only labels with positive PIDs are running")
    func runningLabels() {
        let output = """
        PID\tStatus\tLabel
        42\t0\tro.example.running
        -\t0\tro.example.stopped
        0\t0\tro.example.zero
        7\t1\tro.example.running-error

        malformed
        9\t0
        nope\t0\tro.example.bad-pid
        """
        #expect(LaunchctlList.running(output) == ["ro.example.running", "ro.example.running-error"])
    }

    @Test("Disabled words and booleans are parsed while enabled entries are skipped")
    func disabledLabels() {
        let output = """
        disabled services = {
        \t"ro.example.word-off" => disabled
        \t"ro.example.word-on" => enabled
        \t"ro.example.bool-off" => true
        \t"ro.example.bool-on" => false
        \tro.example.unquoted => disabled
        \t"ro.example.malformed" = disabled
        }
        """
        #expect(LaunchctlList.disabled(output) == ["ro.example.word-off", "ro.example.bool-off"])
    }
}

@Suite("U13 startup analysis")
struct StartupAnalysisAcceptanceTests {
    @Test("State is applied by label, with disabled limited to user agents")
    func appliesRunningAndDisabledState() throws {
        let parsed = [
            startupItem(label: "ro.example.user", path: "/user.plist"),
            startupItem(label: "ro.example.global", path: "/global.plist", scope: .globalAgent),
            startupItem(label: "ro.example.daemon", path: "/daemon.plist", scope: .globalDaemon),
        ]
        let result = StartupAnalysis.items(
            parsed,
            running: ["ro.example.global", "ro.example.daemon"],
            disabled: ["ro.example.user", "ro.example.global", "ro.example.daemon"]
        )
        let byPath = Dictionary(uniqueKeysWithValues: result.map { ($0.path, $0) })
        #expect(try #require(byPath["/user.plist"]).isDisabled)
        #expect(!(try #require(byPath["/global.plist"])).isDisabled)
        #expect(!(try #require(byPath["/daemon.plist"])).isDisabled)
        #expect((try #require(byPath["/global.plist"])).isRunning)
        #expect((try #require(byPath["/daemon.plist"])).isRunning)
    }

    @Test("Items sort by state then case-insensitive label and duplicate paths appear once")
    func sortingAndDeduplication() {
        let parsed = [
            startupItem(label: "zeta", path: "/duplicate.plist"),
            startupItem(label: "ignored-duplicate", path: "/duplicate.plist"),
            startupItem(label: "Bravo", path: "/running-b.plist"),
            startupItem(label: "alpha", path: "/running-a.plist"),
            startupItem(label: "delta", path: "/enabled-d.plist"),
            startupItem(label: "Charlie", path: "/enabled-c.plist"),
            startupItem(label: "echo", path: "/disabled-e.plist"),
        ]
        let result = StartupAnalysis.items(
            parsed,
            running: ["alpha", "Bravo"],
            disabled: ["echo", "zeta"]
        )
        #expect(result.map(\.label) == ["alpha", "Bravo", "Charlie", "delta", "echo", "zeta"])
        #expect(result.filter { $0.path == "/duplicate.plist" }.count == 1)
    }
}

@Suite("U13 startup control")
struct StartupControlAcceptanceTests {
    @Test("User agents receive exact argv-only disable and enable commands")
    func exactCommands() throws {
        let item = startupItem(label: "ro.example.helper_1-test", path: "/synthetic/helper.plist")
        let disable = try #require(StartupControl.disableCommands(for: item, uid: 501))
        let enable = try #require(StartupControl.enableCommands(for: item, uid: 501))
        #expect(disable == [
            ["/bin/launchctl", "disable", "gui/501/ro.example.helper_1-test"],
            ["/bin/launchctl", "bootout", "gui/501/ro.example.helper_1-test"],
        ])
        #expect(enable == [["/bin/launchctl", "enable", "gui/501/ro.example.helper_1-test"]])
        #expect(disable.flatMap { $0 }.filter { $0.contains(item.label) } == [
            "gui/501/ro.example.helper_1-test",
            "gui/501/ro.example.helper_1-test",
        ])
        #expect(enable.flatMap { $0 }.filter { $0.contains(item.label) } == ["gui/501/ro.example.helper_1-test"])
    }

    @Test("Global, system, MacMax, empty, and unsafe labels cannot be controlled")
    func refusedItems() {
        let items = [
            startupItem(label: "ro.example.global", path: "/global.plist", scope: .globalAgent),
            startupItem(label: "ro.example.daemon", path: "/daemon.plist", scope: .globalDaemon),
            startupItem(label: "com.apple.synthetic", path: "/apple.plist"),
            startupItem(label: "ro.danieltamas.macmax", path: "/macmax.plist"),
            startupItem(label: "ro.danieltamas.macmax.helper", path: "/macmax-helper.plist"),
            startupItem(label: "", path: "/empty.plist"),
            startupItem(label: "ro.example bad", path: "/space.plist"),
            startupItem(label: "ro.example/bad", path: "/slash.plist"),
            startupItem(label: "ro.example\"bad", path: "/quote.plist"),
            startupItem(label: "ro.example;bad", path: "/semicolon.plist"),
        ]
        for item in items {
            #expect(StartupControl.disableCommands(for: item, uid: 501) == nil)
            #expect(StartupControl.enableCommands(for: item, uid: 501) == nil)
        }
    }
}

@Suite("U13 startup scanner")
struct StartupScannerAcceptanceTests {
    @Test("Direct valid plists retain folder scope while ignored and unreadable entries are handled")
    func folderScanning() throws {
        let temp = try LaunchItemsTempDirectory()
        defer { temp.remove() }
        let user = try temp.directory("UserAgents")
        let global = try temp.directory("GlobalAgents")
        let nested = try temp.directory("UserAgents/Nested")
        let validOne = try plistData(["Label": "ro.example.one"])
        let validTwo = try plistData(["Label": "ro.example.two"])
        let validThree = try plistData(["Label": "ro.example.three"])
        try validOne.write(to: user.appendingPathComponent("one.plist"))
        try validTwo.write(to: user.appendingPathComponent("two.plist"))
        try validThree.write(to: global.appendingPathComponent("three.plist"))
        try Data("ignored".utf8).write(to: user.appendingPathComponent("notes.txt"))
        try Data("broken".utf8).write(to: user.appendingPathComponent("broken.plist"))
        try validOne.write(to: nested.appendingPathComponent("nested.plist"))
        try FileManager.default.createSymbolicLink(
            at: user.appendingPathComponent("linked.plist"),
            withDestinationURL: user.appendingPathComponent("one.plist")
        )
        let missing = temp.url.appendingPathComponent("Missing", isDirectory: true)

        let result = StartupScanner.load(folders: [
            (user.path, .userAgent),
            (global.path, .globalAgent),
            (missing.path, .globalDaemon),
        ])

        #expect(Set(result.items.map(\.label)) == ["ro.example.one", "ro.example.two", "ro.example.three"])
        #expect(result.items.filter { $0.scope == .userAgent }.count == 2)
        #expect(result.items.filter { $0.scope == .globalAgent }.count == 1)
        #expect(result.items.contains { $0.label == "ro.example.nested" } == false)
        #expect(result.unreadable == 2)
    }

    @Test("A plist larger than one megabyte is unreadable and is not parsed")
    func oversizedPlist() throws {
        let temp = try LaunchItemsTempDirectory()
        defer { temp.remove() }
        let folder = try temp.directory("Agents")
        let oversized = Data(repeating: 0x41, count: 1_048_577)
        try oversized.write(to: folder.appendingPathComponent("oversized.plist"))

        let result = StartupScanner.load(folders: [(folder.path, .userAgent)])
        #expect(result.items.isEmpty)
        #expect(result.unreadable == 1)
    }
}
