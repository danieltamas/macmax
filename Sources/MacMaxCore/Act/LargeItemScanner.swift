import Foundation

/// The biggest folders and files under the home folder, with their age, for a person deciding what to clear by hand.
/// It only reads. Nothing is offered for removal here: the list opens in Finder.
/// `incomplete` when du could not read some folders: the biggest one may be among them, so a short or empty list is
/// not a verdict.
public struct LargeScan: Sendable, Equatable {
    public let items: [LargeItem]
    public let incomplete: Bool
}

public struct LargeItemScanner: Sendable {
    private let home: URL
    private let userProtected: [String]
    private let runner = ProcessRunner()

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, userProtected: [String] = []) {
        self.home = home
        self.userProtected = userProtected
    }

    public func scan(minBytes: Int64 = 500_000_000, limit: Int = 30) async -> Reading<LargeScan> {
        let root = CleanupPolicy.canonical(home.path) ?? home.path
        let output: ProcessOutput
        do {
            // -x stays on this volume; depth 4 reaches ~/Library/Caches/<app> and ~/Projects/<client>/<repo>.
            output = try await runner.run("/usr/bin/nice", ["-n", "10", "/usr/bin/du", "-x", "-k", "-d", "4", root], environment: ["LC_ALL": "C"], timeout: .seconds(480))
        } catch ProcessRunner.Failure.timedOut {
            return .failed(reason: "measuring the home folder took more than eight minutes")
        } catch {
            return .failed(reason: "du could not be started")
        }
        let text = String(decoding: output.stdout, as: UTF8.self)
        // du exits 1 for the folders it may not read (macOS privacy), still printing the rest; nothing printed is a failure.
        guard !text.isEmpty else { return .failed(reason: "du measured nothing (exit \(output.status))") }
        let policy = CleanupPolicy(home: home, userProtected: userProtected)
        let items = LargeItemSelection.select(du: text, root: root, minBytes: minBytes, limit: limit).map { entry in
            var info = stat()
            let modified = lstat(entry.path, &info) == 0 ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) : nil
            let isProtected = policy.protected.contains { CleanupPolicy.isInside(entry.path, $0) || CleanupPolicy.isInside($0, entry.path) }
            return LargeItem(path: entry.path, bytes: entry.bytes, modified: modified, isProtected: isProtected)
        }
        return .ok(LargeScan(items: items, incomplete: output.status != 0), source: "du", at: Date())
    }
}
