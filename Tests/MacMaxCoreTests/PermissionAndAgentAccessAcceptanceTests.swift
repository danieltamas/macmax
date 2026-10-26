import Darwin
import Foundation
import Testing
@testable import MacMaxCore

private final class AgentAccessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) { self.value = value }

    func get() -> Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}

private final class RecordingAgentBackend: AgentBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTools: [String] = []

    var calls: [String] { lock.withLock { recordedTools } }

    func call(_ tool: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        lock.withLock { recordedTools.append(tool) }
        return .object(["verdict": .string("ok")])
    }
}

private struct TemporaryAgentAccessHome {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacMax-AgentAccess-\(UUID().uuidString)", isDirectory: true)
    var home: MacMaxHome { MacMaxHome(environment: ["MACMAX_HOME": url.path]) }
    var configURL: URL { url.appendingPathComponent("config.json") }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

private func agentRequest(_ id: Int, method: String, params: String) -> String {
    "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":\(params)}"
}

private func agentResponse(_ line: String?) -> JSONValue {
    guard let line, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
        Issue.record("Expected one JSON-RPC response line")
        return .null
    }
    return value
}

private func loadAgentConfig(_ store: ConfigStore) -> PanelConfig {
    guard case let .ok(config) = store.load() else {
        Issue.record("Expected a valid panel config")
        return .default
    }
    return config
}

@Suite("Permission and agent access acceptance")
struct PermissionAndAgentAccessAcceptanceTests {
    @Test("Full Disk Access probes the TCC database and maps errno conservatively")
    func fullDiskAccessProbe() {
        let expectedPath = "/Library/Application Support/com.apple.TCC/TCC.db"
        for (result, expected) in [(Int32(0), PermissionState.granted), (EPERM, .denied), (EACCES, .denied), (ENOENT, .unknown)] {
            var probedPath: String?
            let actual = PermissionProbe.fullDiskAccess { path in
                probedPath = path
                return result
            }
            #expect(probedPath == expectedPath)
            #expect(actual == expected)
        }
    }

    @Test("Agent access defaults off, tolerates a missing key, and round trips through JSON")
    func agentAccessCodingContract() throws {
        #expect(!PanelConfig.default.agentAccess)

        let missingKey = Data("{}".utf8)
        let decodedMissing = try JSONDecoder().decode(PanelConfig.self, from: missingKey)
        #expect(!decodedMissing.agentAccess)

        var enabled = PanelConfig.default
        enabled.agentAccess = true
        let encoded = try JSONEncoder().encode(enabled)
        let decodedEnabled = try JSONDecoder().decode(PanelConfig.self, from: encoded)
        #expect(decodedEnabled.agentAccess)
    }

    @Test("ConfigStore saves and reloads enabled agent access")
    func configStorePersistsAgentAccess() throws {
        let temporary = TemporaryAgentAccessHome()
        defer { temporary.remove() }
        let store = ConfigStore(home: temporary.home)

        let saved = try store.update { $0.agentAccess = true }

        #expect(saved.agentAccess)
        #expect(loadAgentConfig(ConfigStore(home: temporary.home)).agentAccess)
        let json = try String(contentsOf: temporary.configURL, encoding: .utf8)
        #expect(json.contains("\"agent_access\" : true"))
    }

    @Test("Disabled access leaves discovery available but blocks known tools before the backend")
    func disabledAccessBoundary() async {
        let backend = RecordingAgentBackend()
        let server = MCPServer(backend: backend, agentAccess: { false })

        let initialized = agentResponse(await server.handle(line: agentRequest(1, method: "initialize", params: "{}")))
        #expect(initialized["result"] != nil)
        let listed = agentResponse(await server.handle(line: agentRequest(2, method: "tools/list", params: "{}")))
        #expect(listed["result"]?["tools"] != nil)

        let blocked = agentResponse(await server.handle(line: agentRequest(
            3, method: "tools/call", params: "{\"name\":\"snapshot\",\"arguments\":{}}")))
        #expect(blocked["error"] == nil)
        #expect(blocked["result"]?["isError"] == .bool(true))
        guard case let .array(content)? = blocked["result"]?["content"] else {
            Issue.record("Blocked tool call did not return content")
            return
        }
        guard case let .string(message)? = content.first?["text"] else {
            Issue.record("Blocked tool call did not return text")
            return
        }
        #expect(message.lowercased().contains("agent access"))
        #expect(message.lowercased().contains("off"))
        #expect(backend.calls.isEmpty)

        let unknown = agentResponse(await server.handle(line: agentRequest(
            4, method: "tools/call", params: "{\"name\":\"not_a_tool\",\"arguments\":{}}")))
        #expect(unknown["error"]?["code"] == .int(-32602))
        #expect(backend.calls.isEmpty)
    }

    @Test("Agent access is re-read for every call on one server")
    func accessChangesTakeEffectImmediately() async {
        let access = AgentAccessBox(false)
        let backend = RecordingAgentBackend()
        let server = MCPServer(backend: backend, agentAccess: { access.get() })
        let params = "{\"name\":\"snapshot\",\"arguments\":{}}"

        let blocked = agentResponse(await server.handle(line: agentRequest(1, method: "tools/call", params: params)))
        #expect(blocked["result"]?["isError"] == .bool(true))
        #expect(backend.calls.isEmpty)

        access.set(true)
        let allowed = agentResponse(await server.handle(line: agentRequest(2, method: "tools/call", params: params)))
        #expect(allowed["error"] == nil)
        #expect(allowed["result"]?["isError"] == .bool(false))
        #expect(backend.calls == ["snapshot"])
    }

    @Test("Omitting the access closure keeps tool calls enabled")
    func defaultAccessIsOn() async {
        let backend = RecordingAgentBackend()
        let server = MCPServer(backend: backend)

        let value = agentResponse(await server.handle(line: agentRequest(
            1, method: "tools/call", params: "{\"name\":\"snapshot\",\"arguments\":{}}")))

        #expect(value["result"]?["isError"] == .bool(false))
        #expect(backend.calls == ["snapshot"])
    }
}
