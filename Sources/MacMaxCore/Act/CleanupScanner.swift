import Foundation

public struct CleanupCandidate: Sendable, Equatable {
    public let ruleID: String
    public let path: String
    public let bytes: Int64
    public let device: Int64
    public let inode: UInt64

    public init(ruleID: String, path: String, bytes: Int64, device: Int64, inode: UInt64) {
        self.ruleID = ruleID
        self.path = path
        self.bytes = bytes
        self.device = device
        self.inode = inode
    }
}

public struct CleanupSkip: Sendable, Equatable {
    public let path: String
    public let reason: String
    /// The rule that was looking at it, so the size shown for that rule is known to be incomplete.
    public let ruleID: String?

    public init(path: String, reason: String, ruleID: String? = nil) {
        self.path = path
        self.reason = reason
        self.ruleID = ruleID
    }
}

public struct CleanupPreview: Sendable, Equatable {
    public let candidates: [CleanupCandidate]
    public let skipped: [CleanupSkip]

    public init(candidates: [CleanupCandidate], skipped: [CleanupSkip]) {
        self.candidates = candidates
        self.skipped = skipped
    }

    /// The size of what one rule would move (all rules when nil), never overflowing.
    public func bytes(ofRule ruleID: String? = nil) -> Int64 {
        candidates.filter { ruleID == nil || $0.ruleID == ruleID }.reduce(0) { saturatingAdd($0, max($1.bytes, 0)) }
    }
}

/// What is running now, so a cache in use is left alone.
public struct Running: Sendable {
    public var names: Set<String>
    public var bundleIDs: Set<String>

    public init(names: Set<String> = [], bundleIDs: Set<String> = []) {
        self.names = names
        self.bundleIDs = bundleIDs
    }
}

/// Finds what the cleanup rules would move to the Trash, with sizes. It reads and never changes anything.
public struct CleanupScanner: Sendable {
    private let policy: CleanupPolicy
    private let running: Running
    private let now: Date
    /// Sizing a huge cache must not hang the panel.
    private let timeBudget: TimeInterval = 30

    public init(home: URL, userProtected: [String] = [], running: Running = Running(), now: Date = Date()) {
        policy = CleanupPolicy(home: home, userProtected: userProtected)
        self.running = running
        self.now = now
    }

    public func scan() -> CleanupPreview {
        let deadline = Date().addingTimeInterval(timeBudget)
        var candidates: [CleanupCandidate] = [], skipped: [CleanupSkip] = []
        for rule in CleanupPolicy.rules {
            let root = policy.home + "/" + rule.root
            guard FileManager.default.fileExists(atPath: root) || isLink(root) else { continue }
            // Nothing is read through a link: it could lead into a protected folder.
            guard CleanupPolicy.canonical(root) == root else {
                skipped.append(CleanupSkip(path: root, reason: "the allowed folder is a link", ruleID: rule.id))
                continue
            }
            if let program = rule.blockedBy, running.names.contains(program) {
                skipped.append(CleanupSkip(path: root, reason: "\(program) is running", ruleID: rule.id))
                continue
            }
            guard let paths = entries(of: rule, root: root, deadline: deadline) else {
                skipped.append(CleanupSkip(path: root, reason: "it could not be fully read in time", ruleID: rule.id))
                continue
            }
            for path in paths {
                consider(path, rule: rule, deadline: deadline, into: &candidates, skipped: &skipped)
            }
        }
        candidates.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        return CleanupPreview(candidates: candidates, skipped: skipped)
    }

    /// nil when the root could not be read: that is "unknown", not an empty folder.
    private func entries(of rule: CleanupRule, root: String, deadline: Date) -> [String]? {
        switch rule.id {
        case "old_logs": return oldLogs(under: root, deadline: deadline)
        default:
            guard rule.children else { return [root] }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
            // The caches with a rule of their own are listed under it, not twice.
            return names.sorted().filter { rule.id != "app_caches" || !CleanupPolicy.dedicatedCacheNames.contains($0) }.map { root + "/" + $0 }
        }
    }

    private func consider(_ path: String, rule: CleanupRule, deadline: Date,
                          into candidates: inout [CleanupCandidate], skipped: inout [CleanupSkip]) {
        if rule.id == "app_caches", running.bundleIDs.contains((path as NSString).lastPathComponent) {
            skipped.append(CleanupSkip(path: path, reason: "the app is running", ruleID: rule.id))
            return
        }
        guard let canonical = CleanupPolicy.canonical(path) else {
            skipped.append(CleanupSkip(path: path, reason: "it cannot be resolved", ruleID: rule.id))
            return
        }
        if let reason = policy.violation(of: canonical, rule: rule) {
            skipped.append(CleanupSkip(path: path, reason: reason, ruleID: rule.id))
            return
        }
        guard let measured = Measurement.of(canonical, deadline: deadline), measured.complete else {
            skipped.append(CleanupSkip(path: path, reason: "its size could not be measured in time", ruleID: rule.id))
            return
        }
        if measured.hasGit {
            skipped.append(CleanupSkip(path: path, reason: "it contains a git repository", ruleID: rule.id))
            return
        }
        candidates.append(CleanupCandidate(ruleID: rule.id, path: canonical, bytes: measured.bytes,
                                           device: measured.device, inode: measured.inode))
    }

    /// Regular files older than 30 days; a symlink is not a regular file and is never followed.
    private func oldLogs(under root: String, deadline: Date) -> [String]? {
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let problems = WalkErrors()
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [], errorHandler: { _, _ in problems.record(); return true }) else { return nil }
        var found: [String] = [], visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited % 16 == 0, Date() > deadline { return nil }
            if url.lastPathComponent == "DiagnosticReports" { walker.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]) else {
                problems.record()
                continue
            }
            guard values.isRegularFile == true, let modified = values.contentModificationDate, modified < cutoff else { continue }
            found.append(url.path)
        }
        return problems.occurred ? nil : found.sorted()
    }

    private func isLink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
