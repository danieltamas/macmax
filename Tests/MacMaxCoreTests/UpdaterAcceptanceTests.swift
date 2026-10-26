import Darwin
import Foundation
import Testing
@testable import MacMaxCore

private struct StandingCase: Sendable {
    let version: String
    let source: String?
    let latestTag: String?
    let expected: Standing
}

private final class LaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var versions: [String] = []

    func record(_ version: String) {
        lock.withLock { versions.append(version) }
    }

    var recordedVersions: [String] {
        lock.withLock { versions }
    }
}

private struct SyntheticLaunchError: LocalizedError {
    var errorDescription: String? { "launch\u{0000} failed\nretry" }
}

private func updaterTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacMax-Updater-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func releaseJSON(
    tag: String? = "v1.2.3",
    draft: Bool = false,
    prerelease: Bool = false,
    htmlURL: String? = "https://github.com/example/macmax/releases/tag/v1.2.3"
) throws -> Data {
    var object: [String: Any] = ["draft": draft, "prerelease": prerelease]
    if let tag { object["tag_name"] = tag }
    if let htmlURL { object["html_url"] = htmlURL }
    return try JSONSerialization.data(withJSONObject: object)
}

private func parsedRelease(_ reading: Reading<ReleaseInfo>) -> ReleaseInfo? {
    if case let .ok(info, _, _) = reading { return info }
    return nil
}

private func failedUpdateMessage(_ state: UpdateState) -> String? {
    if case let .failed(message) = state { return message }
    return nil
}

@Suite("U11 release standing and offer")
struct ReleaseStandingAcceptanceTests {
    @Test("version standing follows numeric semver and source state")
    func standingTable() {
        let cases = [
            StandingCase(version: "0.1.0", source: "v0.1.0", latestTag: "v0.2.0", expected: .behind),
            StandingCase(version: "0.1.0", source: "v0.1.0-dirty", latestTag: "v0.2.0", expected: .behind),
            StandingCase(version: "0.2.0", source: nil, latestTag: "v0.2.0", expected: .latest),
            StandingCase(version: "0.2.0", source: "v0.2.0", latestTag: "0.2.0", expected: .latest),
            StandingCase(version: "0.2.0", source: "v0.2.0-3-gabc1234", latestTag: "v0.2.0", expected: .ahead),
            StandingCase(version: "0.2.0", source: "v0.2.0-dirty", latestTag: "v0.2.0", expected: .ahead),
            StandingCase(version: "0.2.0", source: "v0.2.0-3-gabc1234-dirty", latestTag: "v0.2.0", expected: .ahead),
            StandingCase(version: "0.2.0", source: "abc1234", latestTag: "v0.2.0", expected: .ahead),
            StandingCase(version: "0.3.0", source: "v0.3.0", latestTag: "v0.2.0", expected: .ahead),
            StandingCase(version: "0.9.0", source: nil, latestTag: "v0.10.0", expected: .behind),
            StandingCase(version: "0.10.0", source: nil, latestTag: "v0.9.0", expected: .ahead),
            StandingCase(version: "garbage", source: nil, latestTag: "v0.2.0", expected: .unknown),
            StandingCase(version: "0.2.0", source: nil, latestTag: nil, expected: .unknown),
            StandingCase(version: "0.2.0", source: nil, latestTag: "latest", expected: .unknown),
            StandingCase(version: "0.2.0", source: nil, latestTag: "v1.2", expected: .unknown),
            StandingCase(version: "1.2.3.4", source: nil, latestTag: "v1.2.3", expected: .unknown),
            StandingCase(version: "0.2.0", source: nil, latestTag: "  v0.2.0\n", expected: .latest)
        ]

        for testCase in cases {
            let actual = MacMaxRelease.standing(
                version: testCase.version,
                source: testCase.source,
                latestTag: testCase.latestTag
            )
            #expect(actual == testCase.expected)
        }
    }

    @Test("only exact installed bundle paths are accepted")
    func installedLocationRequiresExactPath() {
        let home = "/Users/example"
        #expect(UpdateOffer.isInstalledLocation(bundlePath: "/Applications/MacMax.app", home: home))
        #expect(UpdateOffer.isInstalledLocation(bundlePath: "/Users/example/Applications/MacMax.app", home: home))

        let refused = [
            "/Users/example/Downloads/MacMax.app",
            "/Users/example/Build/MacMax.app",
            "/Applications/MacMax.app/Contents",
            "/Applications/MacMax.app.old",
            "/Applications/Sub/MacMax.app",
            "/Applications/../Applications/MacMax.app",
            "/Users/example/Applications/../Applications/MacMax.app",
            "/Applications/MacMax.app/",
            "/Users/example/Applications/MacMax.app/"
        ]
        for path in refused {
            #expect(!UpdateOffer.isInstalledLocation(bundlePath: path, home: home))
        }
    }

    @Test("an update version is offered only for an installed behind build and valid tag")
    func offeredVersionRequiresEveryGate() {
        #expect(UpdateOffer.version(standing: .behind, installed: true, latestTag: "v0.2.0") == "0.2.0")
        #expect(UpdateOffer.version(standing: .behind, installed: true, latestTag: "0.2.0") == "0.2.0")
        #expect(UpdateOffer.version(standing: .latest, installed: true, latestTag: "v0.2.0") == nil)
        #expect(UpdateOffer.version(standing: .ahead, installed: true, latestTag: "v0.2.0") == nil)
        #expect(UpdateOffer.version(standing: .unknown, installed: true, latestTag: "v0.2.0") == nil)
        #expect(UpdateOffer.version(standing: .behind, installed: false, latestTag: "v0.2.0") == nil)
        #expect(UpdateOffer.version(standing: .behind, installed: true, latestTag: nil) == nil)
        #expect(UpdateOffer.version(standing: .behind, installed: true, latestTag: "v1.2") == nil)
    }
}

@Suite("U11 release response")
struct ReleaseParserAcceptanceTests {
    @Test("valid final releases parse and retain only trusted GitHub URLs")
    func validReleaseResponse() throws {
        let prefixed = try #require(parsedRelease(ReleaseParser.parse(try releaseJSON())))
        #expect(prefixed.tag == "v1.2.3")
        #expect(prefixed.version == "1.2.3")
        #expect(prefixed.htmlURL == "https://github.com/example/macmax/releases/tag/v1.2.3")

        let plain = try #require(parsedRelease(ReleaseParser.parse(try releaseJSON(tag: "1.2.3"))))
        #expect(plain.tag == "1.2.3")
        #expect(plain.version == "1.2.3")

        let untrustedURLs = [
            "http://github.com/example/macmax/releases/tag/v1.2.3",
            "https://example.com/release",
            "https://github.com.evil.example/release"
        ]
        for url in untrustedURLs {
            let info = try #require(parsedRelease(ReleaseParser.parse(try releaseJSON(htmlURL: url))))
            #expect(info.htmlURL == nil)
        }
    }

    @Test("malformed unsafe draft and prerelease responses never parse as ok")
    func invalidReleaseResponsesFailClosed() throws {
        let responses = [
            Data("not json".utf8),
            try releaseJSON(tag: nil),
            try releaseJSON(tag: "v1.2"),
            try releaseJSON(tag: "v1.2.3/bad"),
            try releaseJSON(tag: "v1.2.3; rm -rf"),
            try releaseJSON(draft: true),
            try releaseJSON(prerelease: true),
            Data("{}".utf8)
        ]

        for data in responses {
            #expect(parsedRelease(ReleaseParser.parse(data)) == nil)
        }
    }
}

@Suite("U11 release check schedule")
struct ReleaseCheckScheduleAcceptanceTests {
    @Test("attempts have an inclusive fifteen minute floor")
    func attemptFloor() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = ReleaseCheckSchedule(now: start)
        schedule.recordAttempt(at: start)
        #expect(!schedule.mayCheck(at: start.addingTimeInterval(14 * 60)))
        #expect(schedule.mayCheck(at: start.addingTimeInterval(15 * 60)))
    }

    @Test("success schedules the next automatic check for twenty four hours")
    func successInterval() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = ReleaseCheckSchedule(now: start)
        schedule.recordSuccess(at: start)
        #expect(schedule.nextAutomatic == start.addingTimeInterval(24 * 60 * 60))
    }

    @Test("rate limits honor retry after with floors and caps")
    func rateLimitBounds() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        var oneHour = ReleaseCheckSchedule(now: start)
        oneHour.recordRateLimit(at: start, retryAfter: 3_600)
        #expect(!oneHour.mayCheck(at: start.addingTimeInterval(3_599)))
        #expect(oneHour.mayCheck(at: start.addingTimeInterval(3_600)))

        var missingHeader = ReleaseCheckSchedule(now: start)
        missingHeader.recordRateLimit(at: start, retryAfter: nil)
        #expect(!missingHeader.mayCheck(at: start.addingTimeInterval(3_599)))

        var shortHeader = ReleaseCheckSchedule(now: start)
        shortHeader.recordRateLimit(at: start, retryAfter: 60)
        #expect(!shortHeader.mayCheck(at: start.addingTimeInterval(14 * 60)))
        #expect(shortHeader.mayCheck(at: start.addingTimeInterval(15 * 60)))

        var capped = ReleaseCheckSchedule(now: start)
        capped.recordRateLimit(at: start, retryAfter: 10 * 24 * 60 * 60)
        #expect(!capped.mayCheck(at: start.addingTimeInterval(24 * 60 * 60 - 1)))
        #expect(capped.mayCheck(at: start.addingTimeInterval(24 * 60 * 60)))
    }
}

@Suite("U11 single installer")
struct UpdateCoordinatorAcceptanceTests {
    @Test("a started update stays in flight and cannot launch twice")
    func repeatedStartIsIdempotent() async {
        let recorder = LaunchRecorder()
        let coordinator = UpdateCoordinator { version in recorder.record(version) }

        #expect(await coordinator.start(version: "0.2.0") == .updating("0.2.0"))
        #expect(await coordinator.start(version: "0.3.0") == .updating("0.2.0"))
        #expect(await coordinator.state == .updating("0.2.0"))
        #expect(recorder.recordedVersions == ["0.2.0"])
    }

    @Test("twenty concurrent starts launch exactly one installer")
    func concurrentStartsLaunchOnce() async {
        let recorder = LaunchRecorder()
        let coordinator = UpdateCoordinator { version in recorder.record(version) }

        await withTaskGroup(of: UpdateState.self) { group in
            for _ in 0..<20 {
                group.addTask { await coordinator.start(version: "0.2.0") }
            }
            for await result in group {
                #expect(result == .updating("0.2.0"))
            }
        }
        #expect(recorder.recordedVersions == ["0.2.0"])
    }

    @Test("invalid versions are refused without launching")
    func invalidVersionsAreRefused() async {
        let recorder = LaunchRecorder()
        for version in ["0.2", "0.2.0; ls", ""] {
            let coordinator = UpdateCoordinator { launched in recorder.record(launched) }
            let state = await coordinator.start(version: version)
            #expect(failedUpdateMessage(state) != nil)
        }
        #expect(recorder.recordedVersions.isEmpty)
    }

    @Test("launch failures are sanitized and allow a retry")
    func failureCanBeRetried() async {
        let recorder = LaunchRecorder()
        let attempts = LaunchRecorder()
        let coordinator = UpdateCoordinator { version in
            attempts.record(version)
            if attempts.recordedVersions.count == 1 {
                throw SyntheticLaunchError()
            }
            recorder.record(version)
        }

        let first = await coordinator.start(version: "0.2.0")
        let message = failedUpdateMessage(first)
        #expect(message != nil)
        #expect(message?.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } == true)
        #expect(await coordinator.start(version: "0.2.0") == .updating("0.2.0"))
        #expect(attempts.recordedVersions.count == 2)
        #expect(recorder.recordedVersions == ["0.2.0"])
    }
}

@Suite("U11 update log", .serialized)
struct UpdateLogAcceptanceTests {
    @Test("new logs use mode 0600 and accept writes")
    func createsPrivateWritableFile() throws {
        let directory = try updaterTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("update.log")
        let descriptor = try UpdateLog.open(at: url)
        defer { close(descriptor) }

        var status = stat()
        #expect(fstat(descriptor, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFREG)
        #expect(status.st_mode & 0o777 == 0o600)
        let flags = fcntl(descriptor, F_GETFL)
        #expect(flags & O_ACCMODE == O_WRONLY)
        #expect(flags & O_NONBLOCK == O_NONBLOCK)
        let bytes = Array("written\n".utf8)
        #expect(bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) } == bytes.count)
    }

    @Test("an existing log is truncated")
    func truncatesExistingFile() throws {
        let directory = try updaterTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("update.log")
        try Data("old contents".utf8).write(to: url)

        let descriptor = try UpdateLog.open(at: url)
        defer { close(descriptor) }
        var status = stat()
        #expect(fstat(descriptor, &status) == 0)
        #expect(status.st_size == 0)
    }

    @Test("a symlink is refused without changing its target")
    func refusesSymlink() throws {
        let directory = try updaterTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let link = directory.appendingPathComponent("update.log")
        try Data("keep me".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: (any Error).self) { try UpdateLog.open(at: link) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep me")
    }

    @Test("directories and FIFOs are refused")
    func refusesNonRegularFiles() throws {
        let directory = try updaterTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let childDirectory = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try UpdateLog.open(at: childDirectory) }

        let fifo = directory.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let reader = open(fifo.path, O_RDONLY | O_NONBLOCK)
        #expect(reader >= 0)
        defer { if reader >= 0 { close(reader) } }
        #expect(throws: (any Error).self) { try UpdateLog.open(at: fifo) }
    }

    @Test("last line is trimmed sanitized bounded and skips empty lines")
    func lastLineSanitization() {
        #expect(UpdateLog.lastLine(of: "") == nil)
        #expect(UpdateLog.lastLine(of: "  \n\t\n") == nil)
        #expect(UpdateLog.lastLine(of: "first\n\n  final line  \n") == "final line")
        #expect(UpdateLog.lastLine(of: "first\n bad\u{0000}line\u{0007} \n") == "badline")

        let longLine = String(repeating: "x", count: 250)
        let result = UpdateLog.lastLine(of: longLine)
        #expect(result?.count == 200)
        #expect(result == String(repeating: "x", count: 200))
    }
}
