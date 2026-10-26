/// What an agent can reach: the CLI commands and the MCP tools. Both are reads; an action exists only behind a
/// press in the app, and a test checks that no name here is an action verb.
public enum AgentSurface {
    public static let cliCommands = ["snapshot", "apps", "network", "ip", "audit", "findings", "history", "mcp", "version"]
    public static let mcpTools = ["snapshot", "top_apps", "process", "network_usage", "network_identity", "run_audit",
                                  "findings", "history", "who_held", "cleanup_preview"]
}
