import Foundation

public struct AgentTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let outputSchema: JSONValue
    public let readOnlyHint: Bool
    public let destructiveHint: Bool
    public let openWorldHint: Bool
}

/// The tools of docs/AGENT-API.md, in the order of its table. Every one only reads: there is no tool that acts.
public enum AgentCatalog {
    private static let metrics = ["cpu", "memory", "swap", "pressure", "disk_io", "net_in", "net_out"]

    private static func schema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string)),
                 "additionalProperties": .bool(false)])
    }

    private static func choice(_ values: [String], _ note: String) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string)), "description": .string(note)])
    }

    private static func limit(_ note: String) -> JSONValue {
        .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(50), "description": .string(note)])
    }

    private static func text(_ note: String) -> JSONValue { .object(["type": .string("string"), "description": .string(note)]) }

    /// What every result carries, plus the keys that tool always answers with. Other keys are free: a collector that
    /// failed answers with `status` and `reason` in place of its numbers.
    private static func output(_ required: [String] = [], _ typed: [String: String] = [:]) -> JSONValue {
        var properties: [String: JSONValue] = ["source": .object(["type": .string("string")]),
                                               "generated_at": .object(["type": .string("string")]),
                                               "data_note": .object(["type": .string("string")])]
        for (name, type) in typed { properties[name] = .object(["type": .string(type)]) }
        return .object(["type": .string("object"), "properties": .object(properties),
                        "required": .array((["source", "generated_at", "data_note"] + required).map(JSONValue.string))])
    }

    private static func tool(_ name: String, _ description: String, input: JSONValue = schema(), output: JSONValue,
                             openWorld: Bool = false) -> AgentTool {
        AgentTool(name: name, description: description, inputSchema: input, outputSchema: output,
                  readOnlyHint: true, destructiveHint: false, openWorldHint: openWorld)
    }

    public static let tools: [AgentTool] = [
        tool("snapshot", "The state of this Mac now: verdict, vitals, the top 5 apps by CPU, memory and network, and the network identity.",
             output: output(["verdict", "vitals"], ["verdict": "string", "vitals": "object"])),
        tool("top_apps", "Apps ranked by one resource, with their metrics and, when asked, their processes with a redacted command line.",
             input: schema(["by": choice(["cpu", "memory", "disk", "network"], "The resource to rank by; cpu when omitted."),
                            "limit": limit("How many apps, 1 to 50; 10 when omitted."),
                            "include_processes": .object(["type": .string("boolean"), "description": .string("Also list each app's processes.")])]),
             output: output(["by", "apps"], ["by": "string", "apps": "array"])),
        tool("process", "One process: identity, app, user, path, metrics, parent chain and the redacted command line.",
             input: schema(["pid": .object(["type": .string("integer"), "minimum": .int(1), "description": .string("The process id.")])], required: ["pid"]),
             output: output(["pid"], ["pid": "integer"])),
        tool("network_usage", "Network traffic per app over a window, and the rates of each interface.",
             input: schema(["window": choice(["now", "1h", "24h"], "now when omitted."), "limit": limit("How many apps, 1 to 50; 10 when omitted.")]),
             output: output(["window", "apps"], ["window": "string", "apps": "array"])),
        tool("network_identity", "The public IP and country, the ISP IP and country, VPN services and states, whether the route goes through a tunnel, the leak verdict and the last change. Makes the IP request when no fresh value exists.",
             output: output(["verdict"], ["verdict": "string"]), openWorld: true),
        tool("run_audit", "A fresh audit of this Mac: verdict and findings with evidence, why and the suggested next step.",
             output: output(["verdict", "findings"], ["verdict": "string", "findings": "array"])),
        tool("findings", "Findings from stored audits since a time (the last audit when omitted).",
             input: schema(["since": text("ISO 8601 time.")]),
             output: output(["findings"], ["available": "boolean", "findings": "array"])),
        tool("history", "A metric over a range, aligned to the range's step, gaps as nulls; needs MacMax running.",
             input: schema(["metric": choice(metrics, "The metric."), "range": choice(["1h", "24h", "7d", "90d"], "24h when omitted."),
                            "app": text("An app key, for that app's own line.")], required: ["metric"]),
             output: output(["available"], ["available": "boolean", "points": "array"])),
        tool("who_held", "The top 5 apps for a metric at one moment or over a window, from stored samples; needs MacMax running.",
             input: schema(["metric": choice(metrics, "The metric."), "at": text("ISO 8601 time."), "from": text("ISO 8601 time."),
                            "to": text("ISO 8601 time.")], required: ["metric"]),
             output: output(["apps"], ["available": "boolean", "apps": "array"])),
        tool("cleanup_preview", "What the cleanup rules would move to the Trash, with sizes. Scans only: nothing is moved.",
             output: output(["total_bytes", "items"], ["total_bytes": "integer", "items": "array"])),
    ]
}

public enum AgentVersion {
    /// The MCP `serverInfo` version; the release unit keeps it equal to the tag.
    public static let current = "0.1.0"
}
