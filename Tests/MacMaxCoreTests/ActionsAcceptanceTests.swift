import Foundation
import Testing
@testable import MacMaxCore

private final class ProbeFake: ProcessProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LiveProcess?]
    private(set) var pids: [Int32] = []

    init(_ values: [LiveProcess?]) { self.values = values }

    func live(pid: Int32) -> LiveProcess? {
        lock.lock()
        defer { lock.unlock() }
        pids.append(pid)
        return values.isEmpty ? nil : values.removeFirst()
    }
}

private final class SignallerFake: Signaller, @unchecked Sendable {
    enum Call: Equatable { case pid(Int32, Int32), group(Int32, Int32) }
    private let lock = NSLock()
    private let result: Int32
    private var recorded: [Call] = []

    init(result: Int32 = 0) { self.result = result }
    var calls: [Call] { lock.withLock { recorded } }
    func send(_ signal: Int32, toPid pid: Int32) -> Int32 {
        lock.withLock { recorded.append(.pid(signal, pid)) }
        return result
    }
    func send(_ signal: Int32, toGroup group: Int32) -> Int32 {
        lock.withLock { recorded.append(.group(signal, group)) }
        return result
    }
}

private func identity(_ pid: Int32 = 501, _ start: Int64 = 10_000) -> ProcessIdentity {
    ProcessIdentity(pid: pid, startTimeMicroseconds: start)
}

private func live(_ pid: Int32 = 501, _ start: Int64 = 10_000, uid: UInt32 = 42,
                  path: String? = "/Applications/Synthetic.app/Contents/MacOS/Synthetic",
                  group: Int32? = 700) -> LiveProcess {
    LiveProcess(identity: identity(pid, start), uid: uid, path: path, processGroup: group)
}

private func processActions(_ value: LiveProcess?, result: Int32 = 0,
                            ownPid: Int32 = 900, ownGroup: Int32 = 901) -> (ProcessActions, SignallerFake) {
    let signaller = SignallerFake(result: result)
    return (ProcessActions(probe: ProbeFake([value]), signaller: signaller, currentUID: 42,
                           ownPid: ownPid, ownGroup: ownGroup), signaller)
}

private actor RunnerFake: CommandRunning {
    struct Call: Equatable { let executable: String; let arguments: [String] }
    private var responses: [(Int32, String)]
    private var recorded: [Call] = []

    init(_ responses: [(Int32, String)]) { self.responses = responses }
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        recorded.append(Call(executable: executable, arguments: arguments))
        return responses.isEmpty ? (70, "unexpected command") : responses.removeFirst()
    }
    func calls() -> [Call] { recorded }
}

@Suite("U9 process actions")
struct ProcessActionsAcceptanceTests {
    @Test("Every unsafe or unreadable process state is refused without a signal")
    func refusalGuards() {
        let expected = identity()
        let cases: [(String, LiveProcess?, Int32)] = [
            ("gone", nil, 900),
            ("different pid", live(502), 900),
            ("reused pid", live(501, 10_001), 900),
            ("other uid", live(uid: 43), 900),
            ("pid below 100", live(99), 900),
            ("own pid", live(), 501),
            ("unknown path", live(path: nil), 900),
            ("System", live(path: "/System/Library/Synthetic"), 900),
            ("libexec", live(path: "/usr/libexec/synthetic"), 900),
            ("sbin", live(path: "/sbin/synthetic"), 900),
        ]
        for (label, current, ownPid) in cases {
            let requested = label == "pid below 100" ? identity(99) : expected
            let (actions, signaller) = processActions(current, ownPid: ownPid)
            guard case .refused = actions.end(requested, force: false) else {
                Issue.record("\(label) was not refused")
                continue
            }
            #expect(signaller.calls.isEmpty, "\(label) sent a signal")
        }
    }

    @Test("PID 100 and a near-miss system prefix are allowed")
    func boundaryAndPrefixNearMiss() {
        for process in [live(100), live(path: "/usr/libexecx/synthetic")] {
            let signaller = SignallerFake()
            let actions = ProcessActions(probe: ProbeFake([process]), signaller: signaller,
                                         currentUID: 42, ownPid: 900, ownGroup: 901)
            #expect(actions.end(process.identity, force: false) == .done)
            #expect(signaller.calls == [.pid(15, process.identity.pid)])
        }
    }

    @Test("End uses TERM, force uses KILL, and errno is a failure")
    func signalsAndErrno() {
        let expected = identity()
        let (term, termSignaller) = processActions(live())
        #expect(term.end(expected, force: false) == .done)
        #expect(termSignaller.calls == [.pid(15, 501)])

        let (kill, killSignaller) = processActions(live())
        #expect(kill.end(expected, force: true) == .done)
        #expect(killSignaller.calls == [.pid(9, 501)])

        let (failed, failedSignaller) = processActions(live(), result: 13)
        guard case let .failed(message) = failed.end(expected, force: false) else {
            Issue.record("signal errno did not fail")
            return
        }
        #expect(message.contains("13"))
        #expect(failedSignaller.calls == [.pid(15, 501)])
    }

    @Test("The live identity is read at action time and a changed start time fails closed")
    func rechecksAtActionTime() {
        let expected = identity()
        let probe = ProbeFake([live(501, 10_001)])
        let signaller = SignallerFake()
        let actions = ProcessActions(probe: probe, signaller: signaller, currentUID: 42,
                                     ownPid: 900, ownGroup: 901)
        guard case .refused = actions.end(expected, force: false) else {
            Issue.record("changed start time was not refused")
            return
        }
        #expect(probe.pids == [501])
        #expect(signaller.calls.isEmpty)
    }

    @Test("Session end signals only the process group")
    func sessionGroup() {
        let expected = identity()
        let (actions, signaller) = processActions(live(group: 700))
        #expect(actions.endSession(expected, force: false) == .done)
        #expect(signaller.calls == [.group(15, 700)])
    }

    @Test("Invalid, kernel, and own groups are refused without signalling")
    func invalidGroups() {
        for group in [nil, Int32(0), Int32(1), Int32(901)] {
            let (actions, signaller) = processActions(live(group: group))
            guard case .refused = actions.endSession(identity(), force: false) else {
                Issue.record("group \(String(describing: group)) was not refused")
                continue
            }
            #expect(signaller.calls.isEmpty)
        }
    }
}

@Suite("U9 Docker actions")
struct DockerActionsAcceptanceTests {
    @Test("Malformed IDs are refused before Docker runs", arguments: ["-f", "abc", "ABCDEF123456", String(repeating: "a", count: 65), "; rm"])
    func badIDs(value: String) async {
        let runner = RunnerFake([])
        let outcome = await DockerActions(runner: runner, docker: "/synthetic/docker").stop(containerID: value)
        guard case .refused = outcome else { Issue.record("accepted bad id \(value)"); return }
        #expect(await runner.calls().isEmpty)
    }

    @Test("A failed running-container read fails closed")
    func psFailure() async {
        let runner = RunnerFake([(1, "daemon unavailable")])
        guard case .failed = await DockerActions(runner: runner, docker: "/synthetic/docker").stop(containerID: "abcdef123456") else {
            Issue.record("ps failure did not fail closed"); return
        }
        #expect(await runner.calls() == [.init(executable: "/synthetic/docker", arguments: ["ps", "--no-trunc", "--format", "{{.ID}}"])])
    }

    @Test("A container absent from the fresh list is refused")
    func notRunning() async {
        let runner = RunnerFake([(0, "1111111111111111111111111111111111111111111111111111111111111111\n")])
        let outcome = await DockerActions(runner: runner, docker: "/synthetic/docker").stop(containerID: "abcdef123456")
        #expect(outcome == .refused("not running"))
        #expect(await runner.calls().count == 1)
    }

    @Test("A 64-character ID and its 12-character prefix use exact argv", arguments: [false, true])
    func fullAndPrefix(prefixOnly: Bool) async {
        let full = String(repeating: "a", count: 64)
        let requested = prefixOnly ? String(full.prefix(12)) : full
        let runner = RunnerFake([(0, full + "\n"), (0, "stopped")])
        #expect(await DockerActions(runner: runner, docker: "/synthetic/docker").stop(containerID: requested) == .done)
        #expect(await runner.calls() == [
            .init(executable: "/synthetic/docker", arguments: ["ps", "--no-trunc", "--format", "{{.ID}}"]),
            .init(executable: "/synthetic/docker", arguments: ["stop", requested]),
        ])
    }

    @Test("A failed stop is reported after the exact two commands")
    func stopFailure() async {
        let full = String(repeating: "b", count: 64)
        let runner = RunnerFake([(0, full), (9, "stop failed")])
        guard case .failed = await DockerActions(runner: runner, docker: "/synthetic/docker").stop(containerID: full) else {
            Issue.record("stop failure was not reported"); return
        }
        #expect(await runner.calls().count == 2)
    }
}

@Suite("U9 action persistence and agent surface")
struct ActionPersistenceAcceptanceTests {
    @Test("Action rows round trip newest first with filtering and limits")
    func roundTrip() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        try await database.logAction(ts: 10, kind: "process", target: "first", result: "done", detail: nil)
        try await database.logAction(ts: 30, kind: "docker", target: "third", result: "failed", detail: "detail")
        try await database.logAction(ts: 20, kind: "process", target: "second", result: "refused", detail: nil)
        #expect(try await database.recentActions(limit: 2).map(\.ts) == [30, 20])
        #expect(try await database.recentActions(kind: "process", limit: 10).map(\.target) == ["second", "first"])
    }

    @Test("Stored target and detail are sanitized and truncated to 500 characters")
    func sanitizedAndBounded() async throws {
        let temporary = try StoreTestDirectory()
        defer { temporary.remove() }
        let database = try Database.open(at: temporary.databaseURL, mode: .readWrite)
        let unsafe = "safe\u{1B}[31mRED\u{7}\n" + String(repeating: "x", count: 600)
        try await database.logAction(ts: 1, kind: "process", target: unsafe, result: "done", detail: unsafe)
        let row = try #require(await database.recentActions(limit: 1).first)
        #expect(row.target.count == 500)
        #expect(row.detail?.count == 500)
        #expect(!row.target.contains("\u{1B}"))
        #expect(!row.target.contains("\n"))
        #expect(row.detail?.contains("RED") == true)
    }

    @Test("Agent surfaces are exact and contain no mutation verb")
    func exactSurfaces() {
        #expect(AgentSurface.cliCommands == ["snapshot", "apps", "network", "ip", "audit", "findings", "history", "mcp", "version"])
        #expect(AgentSurface.mcpTools == ["snapshot", "top_apps", "process", "network_usage", "network_identity", "run_audit", "findings", "history", "who_held", "cleanup_preview"])
        let forbidden = ["quit", "kill", "end", "stop", "move", "trash", "clean", "cleanup"]
        for name in AgentSurface.cliCommands + AgentSurface.mcpTools where name != "cleanup_preview" {
            #expect(!forbidden.contains { name.split(separator: "_").contains(Substring($0)) })
        }
    }

    @Test("Every CLI switch case is declared read-only surface")
    func cliCasesAreDeclared() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/MacMaxCLI/main.swift"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"case\s+\"([^\"]+)\""#)
        let names = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
        #expect(!names.isEmpty)
        #expect(names.allSatisfy(AgentSurface.cliCommands.contains))
    }

    @Test("Core and app sources never call permanent-removal APIs")
    func allRemovalUsesTrash() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manager = FileManager.default
        let roots = [root.appendingPathComponent("Sources/MacMaxCore"), root.appendingPathComponent("Sources/MacMax")]
        let forbidden = ["removeItem(", "unlink(", "rmdir(", "removefile("]
        var violations: [String] = []
        for sourceRoot in roots {
            let enumerator = try #require(manager.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                if forbidden.contains(where: text.contains) { violations.append(file.path) }
            }
        }
        #expect(violations.isEmpty)
    }
}
