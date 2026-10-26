import Foundation
import Testing
@testable import MacMaxCore

private enum StartupDetailFixtureError: Error {
    case expectedDetail(String)
}

private func startupDetailPlist(_ value: Any) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}

private func requireStartupDetail(_ reading: Reading<StartupDetail>) throws -> StartupDetail {
    switch reading {
    case let .ok(detail, _, _):
        return detail
    case let .unavailable(reason):
        throw StartupDetailFixtureError.expectedDetail("unavailable: \(reason)")
    case let .failed(reason):
        throw StartupDetailFixtureError.expectedDetail("failed: \(reason)")
    }
}

private func isFailed<T>(_ reading: Reading<T>) -> Bool {
    switch reading {
    case .failed:
        return true
    case .ok, .unavailable:
        return false
    }
}

private func startupDetailItem(
    label: String,
    program: String? = nil
) -> StartupItem {
    StartupItem(
        label: label,
        path: "/synthetic/\(label).plist",
        scope: .userAgent,
        program: program,
        runsAtLoad: false,
        isDisabled: false,
        isRunning: false
    )
}

@Suite("Background item detail plist parser")
struct StartupDetailParserSpecTests {
    @Test("A complete plist preserves supported detail while discarding environment values")
    func completePlist() throws {
        let secret = "recognisable-secret-value"
        let plist = try startupDetailPlist([
            "Program": "/synthetic/preferred-helper",
            "ProgramArguments": [
                "/synthetic/argument-helper",
                "--mode",
                42,
                "foreground",
            ],
            "AssociatedBundleIdentifiers": ["ro.example.notes", 17, "ro.example.shared"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "StartInterval": 300,
            "StartCalendarInterval": ["Hour": 9],
            "WatchPaths": ["/synthetic/watch-a", 12, "/synthetic/watch-b"],
            "QueueDirectories": ["/synthetic/queue-a", false, "/synthetic/queue-b"],
            "WorkingDirectory": "/synthetic/work",
            "StandardOutPath": "/synthetic/logs/out.log",
            "StandardErrorPath": "/synthetic/logs/error.log",
            "EnvironmentVariables": [
                "VISIBLE_NAME": secret,
                "ANOTHER_NAME": "another-private-value",
            ],
            "UserName": "synthetic-user",
        ])

        let detail = try requireStartupDetail(StartupDetailParser.parse(plist))

        #expect(detail.program == "/synthetic/preferred-helper")
        #expect(detail.arguments == ["/synthetic/argument-helper", "--mode", "foreground"])
        #expect(detail.associatedBundleIDs == ["ro.example.notes", "ro.example.shared"])
        #expect(detail.runAtLoad)
        #expect(detail.keepAlive)
        #expect(detail.startIntervalSeconds == 300)
        #expect(detail.hasCalendarSchedule)
        #expect(detail.watchPaths == [
            "/synthetic/watch-a",
            "/synthetic/watch-b",
            "/synthetic/queue-a",
            "/synthetic/queue-b",
        ])
        #expect(detail.workingDirectory == "/synthetic/work")
        #expect(detail.standardOutPath == "/synthetic/logs/out.log")
        #expect(detail.standardErrorPath == "/synthetic/logs/error.log")
        #expect(detail.environmentKeys == ["ANOTHER_NAME", "VISIBLE_NAME"])
        #expect(detail.userName == "synthetic-user")

        let retainedStrings = [
            detail.program,
            detail.workingDirectory,
            detail.standardOutPath,
            detail.standardErrorPath,
            detail.userName,
        ].compactMap { $0 } + detail.arguments + detail.associatedBundleIDs + detail.watchPaths + detail.environmentKeys
        #expect(!retainedStrings.contains(secret))
        #expect(!retainedStrings.contains("another-private-value"))
    }

    @Test("Program falls back to the first string argument only when Program is absent")
    func programFallback() throws {
        let fallback = try requireStartupDetail(StartupDetailParser.parse(try startupDetailPlist([
            "ProgramArguments": ["/synthetic/fallback-helper", "--once"],
        ])))
        let invalidProgram = try requireStartupDetail(StartupDetailParser.parse(try startupDetailPlist([
            "Program": 19,
            "ProgramArguments": ["/synthetic/must-not-win"],
        ])))
        let nonStringFirstArgument = try requireStartupDetail(StartupDetailParser.parse(try startupDetailPlist([
            "ProgramArguments": [19, "/synthetic/not-first"],
        ])))

        #expect(fallback.program == "/synthetic/fallback-helper")
        #expect(fallback.arguments == ["/synthetic/fallback-helper", "--once"])
        #expect(invalidProgram.program == nil)
        #expect(invalidProgram.arguments == ["/synthetic/must-not-win"])
        #expect(nonStringFirstArgument.program == nil)
        #expect(nonStringFirstArgument.arguments == ["/synthetic/not-first"])
    }

    @Test("Missing keys produce the documented empty values")
    func missingKeys() throws {
        let detail = try requireStartupDetail(StartupDetailParser.parse(try startupDetailPlist([:] as [String: Any])))

        #expect(detail.program == nil)
        #expect(detail.arguments.isEmpty)
        #expect(detail.associatedBundleIDs.isEmpty)
        #expect(!detail.runAtLoad)
        #expect(!detail.keepAlive)
        #expect(detail.startIntervalSeconds == nil)
        #expect(!detail.hasCalendarSchedule)
        #expect(detail.watchPaths.isEmpty)
        #expect(detail.workingDirectory == nil)
        #expect(detail.standardOutPath == nil)
        #expect(detail.standardErrorPath == nil)
        #expect(detail.environmentKeys.isEmpty)
        #expect(detail.userName == nil)
    }

    @Test("Wrong types stay successful and use the documented empty values")
    func wrongTypes() throws {
        let detail = try requireStartupDetail(StartupDetailParser.parse(try startupDetailPlist([
            "Program": 1,
            "ProgramArguments": "not-an-array",
            "AssociatedBundleIdentifiers": 2,
            "RunAtLoad": "true",
            "KeepAlive": ["not", "a", "dictionary"],
            "StartInterval": "300",
            "StartCalendarInterval": "not-a-schedule",
            "WatchPaths": "not-an-array",
            "QueueDirectories": 3,
            "WorkingDirectory": false,
            "StandardOutPath": 4,
            "StandardErrorPath": ["not-a-string"],
            "EnvironmentVariables": ["not", "a", "dictionary"],
            "UserName": 5,
        ])))

        #expect(detail.program == nil)
        #expect(detail.arguments.isEmpty)
        #expect(detail.associatedBundleIDs.isEmpty)
        #expect(!detail.runAtLoad)
        #expect(!detail.keepAlive)
        #expect(detail.startIntervalSeconds == nil)
        #expect(!detail.hasCalendarSchedule)
        #expect(detail.watchPaths.isEmpty)
        #expect(detail.workingDirectory == nil)
        #expect(detail.standardOutPath == nil)
        #expect(detail.standardErrorPath == nil)
        #expect(detail.environmentKeys.isEmpty)
        #expect(detail.userName == nil)
    }

    @Test("Scalar associated bundle identifiers and calendar arrays use their supported shapes")
    func alternateSupportedShapes() throws {
        let scalarBundle = try requireStartupDetail(StartupDetailParser.parse(try startupDetailPlist([
            "AssociatedBundleIdentifiers": "ro.example.single",
            "KeepAlive": true,
            "StartCalendarInterval": [["Weekday": 2]],
        ])))
        let emptyCalendar = try requireStartupDetail(StartupDetailParser.parse(try startupDetailPlist([
            "StartCalendarInterval": [],
        ])))

        #expect(scalarBundle.associatedBundleIDs == ["ro.example.single"])
        #expect(scalarBundle.keepAlive)
        #expect(scalarBundle.hasCalendarSchedule)
        #expect(!emptyCalendar.hasCalendarSchedule)
    }

    @Test("StartInterval accepts only positive integers")
    func positiveStartInterval() throws {
        let fixtures: [(Any, Int?)] = [
            (1, 1),
            (0, nil),
            (-1, nil),
            (1.5, nil),
            (true, nil),
        ]

        for (value, expected) in fixtures {
            let detail = try requireStartupDetail(StartupDetailParser.parse(try startupDetailPlist([
                "StartInterval": value,
            ])))
            #expect(detail.startIntervalSeconds == expected)
        }
    }

    @Test("Malformed data and non-dictionary plists fail")
    func invalidTopLevelValues() throws {
        #expect(isFailed(StartupDetailParser.parse(Data("not a plist".utf8))))
        #expect(isFailed(StartupDetailParser.parse(try startupDetailPlist(["array", "value"]))))
        #expect(isFailed(StartupDetailParser.parse(try startupDetailPlist("string value"))))
    }
}

@Suite("Background item launchctl PID parser")
struct LaunchctlPIDSpecTests {
    @Test("Only positive PID rows are returned and keys match running labels")
    func positivePIDs() {
        let output = """
        PID\tStatus\tLabel
        123\t0\tro.example.first
        -\t0\tro.example.stopped
        0\t0\tro.example.zero
        -4\t0\tro.example.negative
        456\t1\tro.example.second

        malformed
        789\t0
        nope\t0\tro.example.bad-pid
        """

        let pids = LaunchctlList.pids(output)
        #expect(pids == ["ro.example.first": 123, "ro.example.second": 456])
        #expect(Set(pids.keys) == LaunchctlList.running(output))
    }
}

@Suite("Background item lsof connection parser")
struct LsofConnectionsSpecTests {
    @Test("TCP, UDP, listeners, IPv4, and IPv6 preserve input order")
    func supportedConnections() throws {
        let output = """
        COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        helper  123 synthetic  8u  IPv4 0x1234  0t0  TCP 192.0.2.10:50000->198.51.100.7:443 (ESTABLISHED)
        helper  123 synthetic  9u  IPv4 0x1235  0t0  TCP *:8080 (LISTEN)
        helper  123 synthetic  10u IPv4 0x1236  0t0  UDP *:5353
        helper  123 synthetic  11u IPv6 0x1237  0t0  TCP [2001:db8::1]:50001->[2001:db8::2]:443 (ESTABLISHED)
        helper  123 synthetic  12u IPv4 0x1238  0t0  UDP 192.0.2.10:60000->203.0.113.9:53
        """

        let connections = LsofConnections.parse(output)
        #expect(connections.count == 5)

        let first = try #require(connections.first)
        #expect(first.transport == .tcp)
        #expect(first.localAddress == "192.0.2.10")
        #expect(first.localPort == "50000")
        #expect(first.remoteAddress == "198.51.100.7")
        #expect(first.remotePort == "443")
        #expect(first.state == "ESTABLISHED")
        #expect(first.isOutbound)

        let second = connections[1]
        #expect(second.transport == .tcp)
        #expect(second.localAddress == "*")
        #expect(second.localPort == "8080")
        #expect(second.remoteAddress == nil)
        #expect(second.remotePort == nil)
        #expect(second.state == "LISTEN")
        #expect(!second.isOutbound)

        let third = connections[2]
        #expect(third.transport == .udp)
        #expect(third.localAddress == "*")
        #expect(third.localPort == "5353")
        #expect(third.remoteAddress == nil)
        #expect(third.remotePort == nil)
        #expect(third.state == nil)

        let fourth = connections[3]
        #expect(fourth.transport == .tcp)
        #expect(fourth.localAddress == "2001:db8::1")
        #expect(fourth.localPort == "50001")
        #expect(fourth.remoteAddress == "2001:db8::2")
        #expect(fourth.remotePort == "443")
        #expect(fourth.state == "ESTABLISHED")

        let fifth = connections[4]
        #expect(fifth.transport == .udp)
        #expect(fifth.localAddress == "192.0.2.10")
        #expect(fifth.localPort == "60000")
        #expect(fifth.remoteAddress == "203.0.113.9")
        #expect(fifth.remotePort == "53")
        #expect(fifth.state == nil)
        #expect(fifth.isOutbound)
    }

    @Test("Malformed and unsupported rows are skipped without disturbing valid terminal states")
    func malformedAndTerminalStates() {
        let output = """
        COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME

        malformed
        helper  123 synthetic  8u  IPv4 0x1234  0t0  SCTP 192.0.2.10:1->198.51.100.7:2
        helper  123 synthetic  9u  IPv4 0x1235  0t0  TCP missing-port (LISTEN)
        helper  123 synthetic  10u IPv4 0x1236  0t0  TCP 192.0.2.10:50000->198.51.100.7:443 (CLOSED)
        helper  123 synthetic  11u IPv4 0x1237  0t0  TCP 192.0.2.10:50001->203.0.113.9:443 (TIME_WAIT)
        """

        let connections = LsofConnections.parse(output)
        #expect(connections.count == 2)
        #expect(connections.map(\.state) == ["CLOSED", "TIME_WAIT"])
        let outbound = connections.allSatisfy { $0.isOutbound }
        #expect(outbound)
    }

    @Test("An unspecified port is preserved as an asterisk")
    func unspecifiedPort() throws {
        let output = """
        COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        helper  123 synthetic  8u  IPv4 0x1234  0t0  TCP *:* (LISTEN)
        """

        let connection = try #require(LsofConnections.parse(output).first)
        #expect(connection.localAddress == "*")
        #expect(connection.localPort == "*")
        #expect(connection.remoteAddress == nil)
        #expect(connection.remotePort == nil)
        #expect(connection.state == "LISTEN")
        #expect(!connection.isOutbound)
    }
}

@Suite("Background item owner guess")
struct StartupOwnerGuessSpecTests {
    @Test("An item program app bundle wins and returns the first app component")
    func itemProgramAppBundle() throws {
        let item = startupDetailItem(
            label: "com.example.sync.agent",
            program: "/Applications/Example Notes.app/Contents/MacOS/helper"
        )
        let detail = try requireStartupDetail(StartupDetailParser.parse(try startupDetailPlist([
            "Program": "/Applications/Other.app/Contents/MacOS/other",
            "AssociatedBundleIdentifiers": ["ro.example.associated"],
        ])))

        let owner = StartupOwnerGuess.owner(of: item, detail: detail)
        #expect(owner.source == .appBundle)
        #expect(owner.appName == "Example Notes")
        #expect(owner.appPath == "/Applications/Example Notes.app")
        #expect(!owner.note.isEmpty)
    }

    @Test("A detail program supplies the app bundle when the item has no program")
    func detailProgramAppBundle() throws {
        let item = startupDetailItem(label: "ro.example.helper")
        let detail = try requireStartupDetail(StartupDetailParser.parse(try startupDetailPlist([
            "Program": "/Synthetic/Outer.app/Helpers/Inner.app/Contents/MacOS/helper",
        ])))

        let owner = StartupOwnerGuess.owner(of: item, detail: detail)
        #expect(owner.source == .appBundle)
        #expect(owner.appName == "Outer")
        #expect(owner.appPath == "/Synthetic/Outer.app")
        #expect(!owner.note.isEmpty)
    }

    @Test("The first associated bundle identifier wins when there is no app path")
    func associatedBundle() throws {
        let item = startupDetailItem(label: "com.label.must.not.win", program: "relative/helper")
        let detail = try requireStartupDetail(StartupDetailParser.parse(try startupDetailPlist([
            "AssociatedBundleIdentifiers": ["ro.example.first", "ro.example.second"],
        ])))

        let owner = StartupOwnerGuess.owner(of: item, detail: detail)
        #expect(owner.source == .associatedBundle)
        #expect(owner.appName == "ro.example.first")
        #expect(owner.appPath == nil)
        #expect(!owner.note.isEmpty)
    }

    @Test("Supported reverse-DNS labels produce a clearly marked vendor guess", arguments: [
        "com.example.sync.agent",
        "org.example.sync",
        "net.example.sync",
        "io.example.sync",
        "ro.example.sync",
        "eu.example.sync",
        "app.example.sync",
        "co.example.sync",
    ])
    func labelVendor(label: String) {
        let owner = StartupOwnerGuess.owner(of: startupDetailItem(label: label), detail: nil)
        #expect(owner.source == .labelVendor)
        #expect(owner.appName == "Example")
        #expect(owner.appPath == nil)
        #expect(owner.note.lowercased().contains("guess"))
    }

    @Test("Relative programs and short or unsupported labels remain unknown", arguments: [
        "example.sync",
        "dev.example.sync",
        "plain-label",
    ])
    func unknownOwner(label: String) {
        let item = startupDetailItem(label: label, program: "relative/Example.app/helper")
        let owner = StartupOwnerGuess.owner(of: item, detail: nil)
        #expect(owner.source == .unknown)
        #expect(owner.appName == nil)
        #expect(owner.appPath == nil)
        #expect(owner.note.lowercased().contains("cannot tell"))
    }
}
