import Foundation
import MacMaxCore

/// `macmax mcp`: the MCP server on stdio. Stdout carries JSON-RPC and nothing else; one message per line in, one per line
/// out, flushed as it is written. Anything for a person goes to stderr.
enum MCPCommand {
    static func run() async -> Never {
        let sources = await LiveAgentSources.make(home: MacMaxHome())
        // Read at every call, and a settings file that cannot be read counts as "off".
        let store = ConfigStore(home: MacMaxHome())
        let server = MCPServer(backend: LiveAgentBackend(sources), agentAccess: {
            if case let .ok(config) = store.load() { return config.agentAccess }
            return false
        })
        let output = FileHandle.standardOutput
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = await server.handle(line: line) { output.write(Data((reply + "\n").utf8)) }
        }
        exit(0)
    }
}
