import Foundation

public enum StartupScope: Sendable, Equatable { case userAgent, globalAgent, globalDaemon }

/// One launchd property list: something that starts by itself on this Mac.
public struct StartupItem: Sendable, Equatable, Identifiable {
    public let label: String
    public let path: String
    public let scope: StartupScope
    public let program: String?
    /// RunAtLoad, or KeepAlive in any form: launchd starts it without being asked.
    public let runsAtLoad: Bool
    public let isDisabled: Bool
    public let isRunning: Bool
    public var id: String { path }

    public init(label: String, path: String, scope: StartupScope, program: String?, runsAtLoad: Bool,
                isDisabled: Bool = false, isRunning: Bool = false) {
        self.label = label
        self.path = path
        self.scope = scope
        self.program = program
        self.runsAtLoad = runsAtLoad
        self.isDisabled = isDisabled
        self.isRunning = isRunning
    }
}

public enum StartupParser {
    static let maxLabelLength = 256

    /// A plist that is not a dictionary with a usable Label is a failure, never a guessed item.
    public static func parse(_ plist: Data, path: String, scope: StartupScope) -> Reading<StartupItem> {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil),
              let dictionary = object as? [String: Any]
        else { return .failed(reason: "\(URL(fileURLWithPath: path).lastPathComponent) is not a launchd property list.") }
        guard let label = dictionary["Label"] as? String, !label.isEmpty, label.count <= maxLabelLength,
              !label.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { return .failed(reason: "\(URL(fileURLWithPath: path).lastPathComponent) has no usable Label.") }
        // A Program that is not a string is invalid: it does not fall back to the arguments.
        let program = dictionary["Program"].map { $0 as? String } ?? (dictionary["ProgramArguments"] as? [Any])?.first as? String
        let keepAlive = dictionary["KeepAlive"]
        let runs = (dictionary["RunAtLoad"] as? Bool) == true || (keepAlive as? Bool) == true || keepAlive is [String: Any]
        let item = StartupItem(label: label, path: path, scope: scope, program: program, runsAtLoad: runs)
        return .ok(item, source: path, at: Date())
    }
}

/// The output of `launchctl list` and `launchctl print-disabled gui/<uid>`.
public enum LaunchctlList {
    /// Labels whose PID column is a positive number.
    public static func running(_ text: String) -> Set<String> {
        var labels = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 3, let pid = Int32(columns[0]), pid > 0, !columns[2].isEmpty else { continue }
            labels.insert(String(columns[2]))
        }
        return labels
    }

    /// Labels listed as disabled (`=> disabled`, or `=> true` on macOS versions that print booleans).
    public static func disabled(_ text: String) -> Set<String> {
        var labels = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " => ")
            guard parts.count == 2, parts[0].count > 2, parts[0].hasPrefix("\""), parts[0].hasSuffix("\"") else { continue }
            guard ["disabled", "true"].contains(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            labels.insert(String(parts[0].dropFirst().dropLast()))
        }
        return labels
    }
}

public enum StartupAnalysis {
    /// Running first, then enabled, then turned off; each group by label. A path is listed once.
    public static func items(_ parsed: [StartupItem], running: Set<String>, disabled: Set<String>) -> [StartupItem] {
        var seen = Set<String>()
        let marked = parsed.filter { seen.insert($0.path).inserted }.map { item in
            StartupItem(label: item.label, path: item.path, scope: item.scope, program: item.program, runsAtLoad: item.runsAtLoad,
                        isDisabled: item.scope == .userAgent && disabled.contains(item.label), isRunning: running.contains(item.label))
        }
        func rank(_ item: StartupItem) -> Int { item.isRunning ? 0 : item.isDisabled ? 2 : 1 }
        return marked.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            let order = $0.label.caseInsensitiveCompare($1.label)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }
}

/// The only commands MacMax ever runs on a startup item, and only for the user's own agents.
public enum StartupControl {
    public static func disableCommands(for item: StartupItem, uid: UInt32) -> [[String]]? {
        guard let target = target(item, uid: uid) else { return nil }
        return [["/bin/launchctl", "disable", target], ["/bin/launchctl", "bootout", target]]
    }

    /// Enabling does not start the agent: it runs at the next login.
    public static func enableCommands(for item: StartupItem, uid: UInt32) -> [[String]]? {
        target(item, uid: uid).map { [["/bin/launchctl", "enable", $0]] }
    }

    private static func target(_ item: StartupItem, uid: UInt32) -> String? {
        guard item.scope == .userAgent, !item.label.isEmpty,
              item.label.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0)) || "._-".unicodeScalars.contains($0)) }),
              !item.label.hasPrefix("com.apple."), !item.label.hasPrefix("ro.danieltamas.macmax")
        else { return nil }
        return "gui/\(uid)/\(item.label)"
    }
}
