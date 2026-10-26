import Foundation

public protocol Trasher: Sendable {
    func trash(_ url: URL) throws
}

/// The only way anything leaves the disk: the Trash, where the user can put it back.
public struct FileManagerTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

public struct CleanupResult: Sendable, Equatable {
    public let path: String
    public let outcome: ActionOutcome

    public init(path: String, outcome: ActionOutcome) {
        self.path = path
        self.outcome = outcome
    }
}

/// Moves previewed candidates to the Trash, re-checking each one right before it moves.
public struct CleanupMover: Sendable {
    private let policy: CleanupPolicy
    private let trasher: Trasher
    private let running: @Sendable () -> Running?
    private let now: Date
    private let timeBudget: TimeInterval = 30

    /// `running` is asked again for every candidate: something that started after the preview is not cleaned.
    public init(home: URL, userProtected: [String] = [], trasher: Trasher, running: @escaping @Sendable () -> Running? = { Running() },
                now: Date = Date()) {
        policy = CleanupPolicy(home: home, userProtected: userProtected)
        self.trasher = trasher
        self.running = running
        self.now = now
    }

    public func move(_ candidates: [CleanupCandidate]) -> [CleanupResult] {
        candidates.map { CleanupResult(path: $0.path, outcome: move($0)) }
    }

    /// At most 10 percent above the previewed size, without multiplying (a sparse file can report an enormous size).
    private static func withinGrowthLimit(_ current: Int64, previewed: Int64) -> Bool {
        guard current >= 0, previewed >= 0 else { return false }
        let (limit, overflow) = previewed.addingReportingOverflow(previewed / 10)
        return overflow || current <= limit
    }

    private func move(_ candidate: CleanupCandidate) -> ActionOutcome {
        guard let rule = policy.rule(candidate.ruleID) else { return .refused("unknown cleanup rule") }
        guard let canonical = CleanupPolicy.canonical(candidate.path) else { return .refused("the path no longer exists") }
        guard canonical == candidate.path else { return .refused("the path now resolves somewhere else") }
        if let reason = policy.violation(of: canonical, rule: rule) { return .refused(reason) }
        guard let now = Measurement.of(canonical, deadline: Date().addingTimeInterval(timeBudget)), now.complete else {
            return .refused("it could not be re-measured")
        }
        guard now.device == candidate.device, now.inode == candidate.inode else { return .refused("it was replaced since the preview") }
        if rule.id == "old_logs", !(now.modified.map { $0 < self.now.addingTimeInterval(-30 * 86_400) } ?? false) {
            return .refused("it was written to since the preview")
        }
        guard !now.hasGit else { return .refused("it contains a git repository") }
        guard Self.withinGrowthLimit(now.bytes, previewed: candidate.bytes) else {
            return .refused("it grew by more than 10 percent since the preview")
        }
        // What runs is read after the walk, which can take a while: a program that started meanwhile blocks its cache.
        guard let busy = running() else { return .refused("it could not be checked what is running") }
        if let program = rule.blockedBy, busy.names.contains(program) { return .refused("\(program) is running") }
        if rule.id == "app_caches", busy.bundleIDs.contains((canonical as NSString).lastPathComponent) { return .refused("the app is running") }
        // The walk above takes time: look once more, as late as possible, at what the path is now. A path-based Trash
        // call cannot be bound to an inode, so this narrows the window rather than closing it.
        guard let last = Measurement.identity(of: canonical), last.device == candidate.device, last.inode == candidate.inode,
              CleanupPolicy.canonical(candidate.path) == canonical else { return .refused("it was replaced just before the move") }
        // For a file the late look also covers its size and age; a folder was walked a moment ago.
        if let file = last.file {
            guard Self.withinGrowthLimit(file.bytes, previewed: candidate.bytes) else { return .refused("it grew by more than 10 percent since the preview") }
            if rule.id == "old_logs", file.modified >= self.now.addingTimeInterval(-30 * 86_400) { return .refused("it was written to since the preview") }
        }
        do {
            try trasher.trash(URL(fileURLWithPath: canonical))
            return .done
        } catch {
            return .failed("the Trash refused it: \(error.localizedDescription)")
        }
    }
}
