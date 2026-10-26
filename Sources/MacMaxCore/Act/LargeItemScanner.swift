import Foundation

/// `incomplete` when du could not read some folders: the biggest one may be among them, so a short or empty list is
/// not a verdict.
public struct LargeScan: Sendable, Equatable {
    public let items: [LargeItem]
    public let incomplete: Bool
    /// The privacy-protected places were left out on purpose, because MacMax has no Full Disk Access.
    public let skippedPrivate: Bool
}

/// The biggest folders and files under the home folder, with their age, for a person deciding what to clear by hand.
/// It only reads. Nothing is offered for removal here: the list opens in Finder.
public struct LargeItemScanner: Sendable {
    private let home: URL
    private let userProtected: [String]
    private let runner = ProcessRunner()

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, userProtected: [String] = []) {
        self.home = home
        self.userProtected = userProtected
    }

    public func scan(minBytes: Int64 = 500_000_000, limit: Int = 30, skipPrivate: Bool = false) async -> Reading<LargeScan> {
        let root = CleanupPolicy.canonical(home.path) ?? home.path
        // -x stays on this volume; depth 4 reaches ~/Library/Caches/<app> and ~/Projects/<client>/<repo>. Without access to
        // the privacy-protected places, each folder around them is walked on its own so macOS has nothing to ask.
        let depth = 4
        var runs: [(depth: Int, paths: [String])] = [(depth, [root])]
        if skipPrivate {
            let byDepth = Dictionary(grouping: PrivacyFolders.walkable(home: root, depth: depth), by: \.depth)
            runs = byDepth.keys.sorted().map { ($0, byDepth[$0]!.map(\.path)) }
        }
        var text = ""
        var status: Int32 = 0
        do {
            for run in runs {
                let arguments = ["-n", "10", "/usr/bin/du", "-x", "-k", "-d", String(run.depth)] + run.paths
                let output = try await runner.run("/usr/bin/nice", arguments, environment: ["LC_ALL": "C"], timeout: .seconds(480))
                text += String(decoding: output.stdout, as: UTF8.self)
                if output.status != 0 { status = output.status }
            }
        } catch ProcessRunner.Failure.timedOut {
            return .failed(reason: "measuring the home folder took more than eight minutes")
        } catch {
            return .failed(reason: "du could not be started")
        }
        // du exits 1 for the folders it may not read (macOS privacy), still printing the rest; nothing printed is a failure.
        guard !text.isEmpty else { return .failed(reason: "du measured nothing (exit \(status))") }
        let policy = CleanupPolicy(home: home, userProtected: userProtected)
        let items = LargeItemSelection.select(du: text, root: root, minBytes: minBytes, limit: limit).map { entry in
            var info = stat()
            let modified = lstat(entry.path, &info) == 0 ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) : nil
            let isProtected = policy.protected.contains { CleanupPolicy.isInside(entry.path, $0) || CleanupPolicy.isInside($0, entry.path) }
            return LargeItem(path: entry.path, bytes: entry.bytes, modified: modified, isProtected: isProtected)
        }
        return .ok(LargeScan(items: items, incomplete: status != 0, skippedPrivate: skipPrivate), source: "du", at: Date())
    }
}
