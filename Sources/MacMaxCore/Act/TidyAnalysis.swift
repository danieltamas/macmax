import Foundation

/// One line of `ps -Axo pid=,ppid=,stat=,command=`.
public struct PsRow: Sendable, Equatable {
    public let pid: Int32
    public let parentPid: Int32
    public let state: String
    public let command: String

    public init(pid: Int32, parentPid: Int32, state: String, command: String) {
        self.pid = pid
        self.parentPid = parentPid
        self.state = state
        self.command = command
    }

    /// The program's file name, for a row in a list.
    public var name: String {
        let program = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        return (program as NSString).lastPathComponent
    }
}

public enum TidyParser {
    /// Lines that do not start with two numbers and a state are skipped, never guessed at.
    public static func parse(_ ps: String) -> [PsRow] {
        ps.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]), let parent = Int32(parts[1]), pid > 0, parent >= 0 else { return nil }
            return PsRow(pid: pid, parentPid: parent, state: String(parts[2]), command: parts.count == 4 ? String(parts[3]) : "")
        }
    }
}

/// The processes MacMax can offer to end for good reason: leftovers, not live work.
public enum TidyAnalysis {
    /// The same command lines the audit counts as MCP sidecars.
    public static func isMCPSidecar(_ command: String) -> Bool {
        command.contains(/supergateway|playwright-mcp|@playwright\/mcp|server-pdf|context7|mcp-remote|mcp-wrapper|npm exec/)
    }

    /// MCP servers whose coding session is gone: their parent is launchd, or no longer running. One that still has a
    /// live parent belongs to a session in use, however many there are.
    public static func staleMCP(_ rows: [PsRow]) -> [PsRow] {
        let alive = Set(rows.map(\.pid))
        return rows.filter { row in
            isMCPSidecar(row.command) && !row.state.hasPrefix("Z") && (row.parentPid == 1 || !alive.contains(row.parentPid))
        }
    }

    public static func zombies(_ rows: [PsRow]) -> [PsRow] { rows.filter { $0.state.hasPrefix("Z") } }

    /// The running parents that never collected their finished children, most zombies first. A zombie cannot be
    /// ended; ending its parent lets launchd collect it. launchd itself is never offered.
    public static func zombieParents(_ rows: [PsRow]) -> [(parent: PsRow, zombies: Int)] {
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var counts: [Int32: Int] = [:]
        for zombie in zombies(rows) where zombie.parentPid > 1 { counts[zombie.parentPid, default: 0] += 1 }
        return counts.compactMap { pid, count in byPid[pid].map { ($0, count) } }
            .sorted { ($1.zombies, $0.parent.pid) < ($0.zombies, $1.parent.pid) }
    }
}
