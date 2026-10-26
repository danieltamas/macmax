import Foundation
import MacMaxCore

/// The read-only commands that answer with an agent tool's result: the same bytes `macmax mcp` returns, as JSON with
/// `--json` and as indented text otherwise.
enum AgentCommands {
    struct Spec {
        let tool: String
        /// Flags that take a value, mapped to the tool argument they set.
        let valued: [String: String]
        let flags: [String: String]
        /// A first positional word, mapped to the tool argument it sets.
        let positional: String?
    }

    private static let specs: [String: Spec] = [
        "snapshot": Spec(tool: "snapshot", valued: [:], flags: [:], positional: nil),
        "apps": Spec(tool: "top_apps", valued: ["--by": "by", "--limit": "limit"], flags: ["--processes": "include_processes"], positional: nil),
        "network": Spec(tool: "network_usage", valued: ["--window": "window", "--limit": "limit"], flags: [:], positional: nil),
        "ip": Spec(tool: "network_identity", valued: [:], flags: [:], positional: nil),
        "findings": Spec(tool: "findings", valued: ["--since": "since"], flags: [:], positional: nil),
        "history": Spec(tool: "history", valued: ["--range": "range", "--app": "app"], flags: [:], positional: "metric"),
    ]

    static let names: [String] = specs.keys.sorted()

    static func run(_ command: String, _ arguments: [String]) async -> Never {
        guard let spec = specs[command] else { fail("unknown command \(command)") }
        var json = false
        var toolArguments: [String: JSONValue] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--json" { json = true }
            else if let name = spec.flags[argument] { toolArguments[name] = .bool(true) }
            else if let name = spec.valued[argument] {
                guard index < arguments.count else { fail("\(argument) needs a value") }
                let value = arguments[index]
                index += 1
                toolArguments[name] = name == "limit" ? Int(value).map(JSONValue.int) ?? .string(value) : .string(value)
            } else if let name = spec.positional, toolArguments[name] == nil, !argument.hasPrefix("-") {
                toolArguments[name] = .string(argument)
            } else { fail("unexpected argument \(argument); usage: macmax \(command) [--json]") }
        }
        let sources = await LiveAgentSources.make(home: MacMaxHome())
        let server = MCPServer(backend: LiveAgentBackend(sources))
        let request: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
                                          "params": .object(["name": .string(spec.tool), "arguments": .object(toolArguments)])])
        guard let reply = await server.handle(line: request.line()),
              let message = try? JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8)) else { fail("no answer", code: 70) }
        if case let .string(text)? = message["error"]?["message"] { fail(text) }
        guard let result = message["result"]?["structuredContent"] else { fail("the answer has no data", code: 70) }
        if case .bool(true)? = message["result"]?["isError"] { fail("the tool failed: \(result.line())", code: 70) }
        print(json ? result.line() : render(result).joined(separator: "\n"))
        exit(0)
    }

    /// Plain text for a person: one `key: value` per line, nested values indented, arrays of objects as a list.
    static func render(_ value: JSONValue, indent: Int = 0) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case let .object(fields):
            return fields.keys.sorted().flatMap { key -> [String] in
                let child = fields[key] ?? .null
                if let scalar = scalarText(child) { return ["\(pad)\(key): \(scalar)"] }
                return ["\(pad)\(key):"] + render(child, indent: indent + 1)
            }
        case let .array(items):
            return items.flatMap { item -> [String] in
                if let scalar = scalarText(item) { return ["\(pad)- \(scalar)"] }
                let lines = render(item, indent: indent + 1)
                return lines.isEmpty ? [] : ["\(pad)-" + String(lines[0].dropFirst(pad.count + 1))] + lines.dropFirst()
            }
        default: return [pad + (scalarText(value) ?? "")]
        }
    }

    private static func scalarText(_ value: JSONValue) -> String? {
        switch value {
        case .null: "null"
        case let .bool(flag): flag ? "true" : "false"
        case let .int(number): String(number)
        case let .double(number): String(format: "%g", number)
        case let .string(text): text
        case let .array(items): items.isEmpty ? "[]" : nil
        case let .object(fields): fields.isEmpty ? "{}" : nil
        }
    }
}
