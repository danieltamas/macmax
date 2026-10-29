import Testing
@testable import MacMaxCore
import Foundation

private struct TemporaryRepoStarHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacMax-RepoStar-\(UUID().uuidString)", isDirectory: true)
    }

    var home: MacMaxHome { MacMaxHome(environment: ["MACMAX_HOME": url.path]) }
    var configURL: URL { url.appendingPathComponent("config.json") }
    var configExists: Bool { FileManager.default.fileExists(atPath: configURL.path) }

    func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: configURL)
    }

    func json() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private actor RepoStarGHRecorder {
    private var arguments: [[String]] = []
    let status: Int32
    let output: String

    init(status: Int32 = 0, output: String = "HTTP/2.0 204 No Content") {
        self.status = status
        self.output = output
    }

    func run(_ args: [String]) -> (status: Int32, output: String) {
        arguments.append(args)
        return (status, output)
    }

    func calls() -> [[String]] { arguments }
}

private let repoStarGET = ["api", "-i", "user/starred/danieltamas/macmax"]
private let repoStarPUT = ["api", "-i", "-X", "PUT", "user/starred/danieltamas/macmax"]

@Test("Offer reads disk without gh for absent, missing, false, true and malformed flags",
      arguments: [nil, "{}", #"{"starred_repo":false}"#, #"{"starred_repo":true}"#, "{not json"] as [String?])
func repoStarOfferReadsDiskWithoutGH(config: String?) async throws {
    let temporary = try TemporaryRepoStarHome()
    defer { temporary.remove() }
    if let config { try temporary.write(config) }
    let recorder = RepoStarGHRecorder()
    let star = RepoStar(home: temporary.home, gh: { await recorder.run($0) })

    let expected = config != #"{"starred_repo":true}"# && config != "{not json"
    #expect(star.shouldOffer() == expected)
    #expect(await recorder.calls() == [])
    if let config {
        #expect(try Data(contentsOf: temporary.configURL) == Data(config.utf8))
    } else {
        #expect(!temporary.configExists)
    }
}

@Test("Refresh skips gh when the saved flag is true")
func repoStarRefreshSkipsGHForSavedStar() async throws {
    let temporary = try TemporaryRepoStarHome()
    defer { temporary.remove() }
    try temporary.write(#"{"starred_repo":true}"#)
    let recorder = RepoStarGHRecorder(status: 127, output: "")
    let star = RepoStar(home: temporary.home, gh: { await recorder.run($0) })

    #expect(!star.shouldOffer())
    #expect(await star.refresh() == .starred)
    #expect(await recorder.calls() == [])
}

@Test("Refresh fails closed without gh and preserves malformed config bytes")
func repoStarRefreshPreservesMalformedConfigWithoutGH() async throws {
    let temporary = try TemporaryRepoStarHome()
    defer { temporary.remove() }
    let malformed = "{not json"
    try temporary.write(malformed)
    let recorder = RepoStarGHRecorder()
    let star = RepoStar(home: temporary.home, gh: { await recorder.run($0) })

    #expect(!star.shouldOffer())
    #expect(await star.refresh() == .unknown)
    #expect(await recorder.calls() == [])
    #expect(try Data(contentsOf: temporary.configURL) == Data(malformed.utf8))
}

@Test("Refresh GET 204 persists the star and existing settings and suppresses future queries")
func repoStarRefreshPersistsStarAcrossInstances() async throws {
    let temporary = try TemporaryRepoStarHome()
    defer { temporary.remove() }
    try temporary.write(#"{"agent_access":true,"audit_every_hours":12}"#)
    let recorder = RepoStarGHRecorder(output: "HTTP/2.0 204 No Content\nServer: github.com")
    let star = RepoStar(home: temporary.home, gh: { await recorder.run($0) })

    #expect(star.shouldOffer())
    #expect(await star.refresh() == .starred)
    #expect(await recorder.calls() == [repoStarGET])
    let json = try temporary.json()
    #expect(json["starred_repo"] as? Bool == true)
    #expect(json["agent_access"] as? Bool == true)
    #expect(json["audit_every_hours"] as? Int == 12)
    #expect(!star.shouldOffer())
    let reopened = RepoStar(home: temporary.home, gh: { await recorder.run($0) })
    #expect(!reopened.shouldOffer())
    #expect(await star.refresh() == .starred)
    #expect(await reopened.refresh() == .starred)
    #expect(await recorder.calls() == [repoStarGET])
}

@Test("Refresh GET 404 with nonzero exit leaves the offer and creates no config")
func repoStarRefresh404DoesNotWrite() async throws {
    let temporary = try TemporaryRepoStarHome()
    defer { temporary.remove() }
    let recorder = RepoStarGHRecorder(status: 1, output: "HTTP/2.0 404 Not Found\nServer: github.com")
    let star = RepoStar(home: temporary.home, gh: { await recorder.run($0) })

    #expect(await star.refresh() == .notStarred)
    #expect(await recorder.calls() == [repoStarGET])
    #expect(!temporary.configExists)
    #expect(star.shouldOffer())
}

@Test("Unknown refresh responses write nothing and are retried on the next refresh",
      arguments: [
        (Int32(127), ""), (Int32(1), ""),
        (Int32(1), "HTTP/2.0 500 Internal Server Error"),
        (Int32(1), "HTTP/2.0 401 Unauthorized"),
        (Int32(0), #"{"message":"Not Found"}"#),
      ], [false, true])
func repoStarUnknownRefreshRetriesWithoutWriting(response: (Int32, String), seeded: Bool) async throws {
    let temporary = try TemporaryRepoStarHome()
    defer { temporary.remove() }
    let seed = #"{"agent_access":true,"audit_every_hours":12}"#
    if seeded { try temporary.write(seed) }
    let recorder = RepoStarGHRecorder(status: response.0, output: response.1)
    let star = RepoStar(home: temporary.home, gh: { await recorder.run($0) })

    for _ in 0..<2 {
        #expect(await star.refresh() == .unknown)
        #expect(star.shouldOffer())
        if seeded {
            #expect(try Data(contentsOf: temporary.configURL) == Data(seed.utf8))
        } else {
            #expect(!temporary.configExists)
        }
    }
    #expect(await recorder.calls() == [repoStarGET, repoStarGET])
}

@Test("Star PUT 204 saves the flag, preserves existing settings and suppresses the offer")
func repoStarPUT204PersistsStarAcrossInstances() async throws {
    let temporary = try TemporaryRepoStarHome()
    defer { temporary.remove() }
    try temporary.write(#"{"agent_access":true,"audit_every_hours":12}"#)
    let recorder = RepoStarGHRecorder()
    let star = RepoStar(home: temporary.home, gh: { await recorder.run($0) })

    #expect(await star.star())
    #expect(await recorder.calls() == [repoStarPUT])
    let json = try temporary.json()
    #expect(json["starred_repo"] as? Bool == true)
    #expect(json["agent_access"] as? Bool == true)
    #expect(json["audit_every_hours"] as? Int == 12)
    #expect(!star.shouldOffer())
    let reopened = RepoStar(home: temporary.home, gh: { await recorder.run($0) })
    #expect(!reopened.shouldOffer())
    #expect(await recorder.calls() == [repoStarPUT])
}

@Test("Failed star responses leave config untouched and keep the offer",
      arguments: [
        (Int32(1), "HTTP/2.0 403 Forbidden"), (Int32(1), "HTTP/2.0 401 Unauthorized"),
        (Int32(1), ""), (Int32(127), ""),
      ], [false, true])
func repoStarFailedPUTDoesNotWrite(response: (Int32, String), seeded: Bool) async throws {
    let temporary = try TemporaryRepoStarHome()
    defer { temporary.remove() }
    let seed = #"{"agent_access":true,"audit_every_hours":12}"#
    if seeded { try temporary.write(seed) }
    let recorder = RepoStarGHRecorder(status: response.0, output: response.1)
    let star = RepoStar(home: temporary.home, gh: { await recorder.run($0) })

    #expect(await star.star() == false)
    #expect(await recorder.calls() == [repoStarPUT])
    #expect(star.shouldOffer())
    if seeded {
        #expect(try Data(contentsOf: temporary.configURL) == Data(seed.utf8))
    } else {
        #expect(!temporary.configExists)
    }
}

@Test("Star PUT 204 reports GitHub success while preserving malformed config bytes")
func repoStarSuccessfulPUTPreservesMalformedConfig() async throws {
    let temporary = try TemporaryRepoStarHome()
    defer { temporary.remove() }
    let malformed = "{not json"
    try temporary.write(malformed)
    let recorder = RepoStarGHRecorder()
    let star = RepoStar(home: temporary.home, gh: { await recorder.run($0) })

    #expect(await star.star())
    #expect(await recorder.calls() == [repoStarPUT])
    #expect(try Data(contentsOf: temporary.configURL) == Data(malformed.utf8))
}

@Test("HTTP status parses supported versions on the first line only",
      arguments: [
        ("HTTP/2.0 204 No Content\nServer: github.com", 204),
        ("HTTP/1.1 404 Not Found\r\nX: y", 404), ("HTTP/2 204", 204),
      ])
func repoStarHTTPStatusParsesFirstLine(response: (String, Int)) {
    #expect(RepoStar.httpStatus(response.0) == response.1)
}

@Test("HTTP status rejects absent, JSON, later-line and nonnumeric statuses",
      arguments: ["", #"{"message":"Not Found"}"#, "Server: x\nHTTP/2.0 204", "HTTP/2.0 abc"])
func repoStarHTTPStatusRejectsInvalidFirstLine(output: String) {
    #expect(RepoStar.httpStatus(output) == nil)
}

@Test("Writing unrelated config leaves the optional starred_repo key absent")
func repoStarUnstarredConfigOmitsFlag() async throws {
    let temporary = try TemporaryRepoStarHome()
    defer { temporary.remove() }
    let recorder = RepoStarGHRecorder()
    let star = RepoStar(home: temporary.home, gh: { await recorder.run($0) })

    let config = try ConfigStore(home: temporary.home).update { $0.agentAccess = true }
    #expect(config.starredRepo == nil)
    let json = try temporary.json()
    #expect(json["agent_access"] as? Bool == true)
    #expect(json["starred_repo"] == nil)
    #expect(star.shouldOffer())
    #expect(await recorder.calls() == [])
}
