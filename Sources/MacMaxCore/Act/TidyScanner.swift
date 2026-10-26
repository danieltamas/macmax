import Foundation

public struct TidyItem: Sendable, Equatable, Identifiable {
    public let identity: ProcessIdentity
    public let name: String
    /// Redacted, for the row.
    public let detail: String
    public var id: Int32 { identity.pid }

    public init(identity: ProcessIdentity, name: String, detail: String) {
        self.identity = identity
        self.name = name
        self.detail = detail
    }
}

public struct TidyScan: Sendable, Equatable {
    /// MCP servers whose session is gone.
    public let staleMCP: [TidyItem]
    /// Every MCP server running, so "none of 205 are stale" can be said.
    public let mcpTotal: Int
    /// Running parents that never collected their finished children.
    public let zombieParents: [TidyItem]
    public let zombieCount: Int

    public init(staleMCP: [TidyItem], mcpTotal: Int, zombieParents: [TidyItem], zombieCount: Int) {
        self.staleMCP = staleMCP
        self.mcpTotal = mcpTotal
        self.zombieParents = zombieParents
        self.zombieCount = zombieCount
    }
}

/// One read of the process table (`ps`) for the leftovers MacMax may offer to end. Ending them goes through
/// `ProcessActions`, which re-reads each process and refuses anything but the one listed here.
public struct TidyScanner: Sendable {
    private let runner = ProcessRunner()

    public init() {}

    public func scan() async -> Reading<TidyScan> {
        let output: ProcessOutput
        // A process that started after this moment is not the one ps listed: its pid was reused.
        let began = Int64(Date().timeIntervalSince1970 * 1_000_000)
        do {
            output = try await runner.run("/bin/ps", ["-Axo", "pid=,ppid=,stat=,command="], environment: ["LC_ALL": "C"], timeout: .seconds(10))
        } catch {
            return .failed(reason: "ps did not answer")
        }
        guard output.status == 0 else { return .failed(reason: "ps failed (exit \(output.status))") }
        let rows = TidyParser.parse(String(decoding: output.stdout, as: UTF8.self))
        guard !rows.isEmpty else { return .failed(reason: "ps listed no processes") }
        let stale = TidyAnalysis.staleMCP(rows).compactMap { row in
            item(row.pid, name: row.name, detail: Self.short(row.command), listedBefore: began)
        }
        let parents = TidyAnalysis.zombieParents(rows).compactMap { entry in
            item(entry.parent.pid, name: entry.parent.name, detail: "keeps \(entry.zombies) finished \(entry.zombies == 1 ? "child" : "children")", listedBefore: began)
        }
        return .ok(TidyScan(staleMCP: stale, mcpTotal: rows.filter { TidyAnalysis.isMCPSidecar($0.command) && !$0.state.hasPrefix("Z") }.count,
                            zombieParents: parents, zombieCount: TidyAnalysis.zombies(rows).count),
                   source: "ps", at: Date())
    }

    /// Bound to the process as it is now (pid and start time); one that ended since the listing is left out.
    private func item(_ pid: Int32, name: String, detail: String, listedBefore began: Int64) -> TidyItem? {
        guard case let .found(kernel) = Libproc.kernel(pid), kernel.identity.startTimeMicroseconds <= began else { return nil }
        return TidyItem(identity: kernel.identity, name: Redaction.sanitizeText(name), detail: detail)
    }

    /// What the process is, never its arguments in full: ps flattens the argv, so a quoted secret with spaces cannot be
    /// told from several words. Only the program and up to two leading plain words (`npm exec`, a package) are kept.
    private static func short(_ command: String) -> String {
        let words = command.split(separator: " ").map(String.init)
        guard let program = words.first else { return "" }
        var kept = [(program as NSString).lastPathComponent]
        for word in words.dropFirst() {
            if word.hasPrefix("-") { break }
            kept.append(word)
            if kept.count == 3 { break }
        }
        let redacted = Redaction.redact(kept).joined(separator: " ")
        return Redaction.sanitizeText(String(redacted.prefix(110)))
    }
}
