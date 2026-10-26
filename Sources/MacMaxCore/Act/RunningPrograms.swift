import Foundation

public enum RunningPrograms {
    private static let shells: Set<String> = ["sh", "bash", "zsh"]
    /// Versioned names too: python3.12, ruby3.2.
    private static let interpreterPrefixes = ["node", "python", "ruby", "perl"]

    private static func isInterpreter(_ names: Set<String>) -> Bool {
        names.contains { shells.contains($0) || interpreterPrefixes.contains(where: $0.hasPrefix) }
    }

    /// The names of every process right now (the kernel's short name and the program file's name), read from the
    /// process table. nil when the table or a process could not be read: "cannot tell" must not read as "not
    /// running", so the caller refuses to clean. A process that ended mid-read is simply gone, and a path the kernel
    /// will not show for another user's process is fine, the short name is still there.
    public static func names() -> Set<String>? {
        guard let pids = Libproc.pids() else { return nil }
        var names = Set<String>()
        for pid in pids {
            var own = Set<String>()
            switch Libproc.kernel(pid) {
            case let .found(kernel): own.insert(kernel.command)
            case .gone: continue
            case .failed: return nil
            }
            if case let .ok(path, _, _) = Libproc.path(pid, at: Date()) { own.insert((path as NSString).lastPathComponent) }
            // npm, yarn, pip and brew run as an interpreter: their name is in the arguments, not in the program.
            if isInterpreter(own) {
                switch Libproc.argv(pid, at: Date()) {
                case let .ok(arguments, _, _):
                    for argument in arguments.dropFirst().prefix(4) where !argument.hasPrefix("-") {
                        for component in argument.split(separator: "/") {
                            own.insert(String(component))
                            let stem = (String(component) as NSString).deletingPathExtension
                            own.insert(stem)
                            // npm-cli.js is npm, yarn-1.22.js is yarn.
                            if let first = stem.split(separator: "-").first { own.insert(String(first)) }
                        }
                    }
                // Another user's process cannot touch our caches; a failed read of any other is "cannot tell".
                case .unavailable: break
                case .failed: return nil
                }
            }
            names.formUnion(own)
        }
        return names
    }
}
