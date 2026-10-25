import Foundation

/// Assigns every process to an app: the outermost `.app` in its path, else its nearest ancestor
/// that has one, else it stands alone. A Claude Code session is its own group and keeps its
/// descendants (the MCP sidecars). Grouping is a pure function over rows, so it is tested on fixtures.
public enum AppGrouping {
    private static let dockerFamily = AppKey(id: "docker", name: "Docker")

    /// One `AppKey` per pid in `rows`.
    public static func group(_ rows: [ProcessRow]) -> [Int32: AppKey] {
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Int32: AppKey] = [:]
        for row in rows {
            result[row.pid] = anchor(of: row, in: byPid) ?? standalone(row)
        }
        return result
    }

    /// The app or session that owns `row` itself, or else its nearest ancestor that has one.
    private static func anchor(of row: ProcessRow, in byPid: [Int32: ProcessRow]) -> AppKey? {
        var current: ProcessRow? = row
        var visited: Set<Int32> = []
        while let process = current, visited.insert(process.pid).inserted {
            if let key = ownKey(process) { return key }
            current = byPid[process.parentPid]
        }
        return nil
    }

    private static func ownKey(_ row: ProcessRow) -> AppKey? {
        if let bundle = outermostBundle(in: row.path) { return bundle }
        // Claude Code installs versioned binaries (.../claude/versions/<version>), so the name alone is not enough.
        let isClaude = row.name == "claude" || row.path?.contains("/claude/versions/") == true
        if isClaude, row.path?.contains(".app/") != true {
            return AppKey(id: "claude-code:\(row.pid)", name: "Claude Code")
        }
        if row.name.hasPrefix("com.docker.") || row.name == "docker" || row.name == "docker-desktop" {
            return dockerFamily
        }
        return nil
    }

    /// The outermost `X.app` directory of `path`: Chrome's nested helper apps belong to Chrome.
    private static func outermostBundle(in path: String?) -> AppKey? {
        guard let path else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let bundlePath = "/" + components[...index].joined(separator: "/")
        let name = String(components[index].dropLast(".app".count))
        // Docker's app, its VM and its helpers are one family.
        return name == "Docker" ? dockerFamily : AppKey(id: bundlePath, name: name)
    }

    private static func standalone(_ row: ProcessRow) -> AppKey {
        AppKey(id: row.path ?? row.name, name: row.name)
    }
}
