import Darwin
import Foundation

/// One direct child of ~/Downloads that nothing has touched for a long time.
public struct OldDownload: Sendable, Equatable, Identifiable {
    public let path: String
    public let name: String
    public let bytes: Int64
    /// For a folder: the newest modification time of the folder and everything inside it.
    public let modified: Date
    public let isDirectory: Bool
    public let device: Int64
    public let inode: UInt64
    public var id: String { path }

    public init(path: String, name: String, bytes: Int64, modified: Date, isDirectory: Bool, device: Int64, inode: UInt64) {
        self.path = path
        self.name = name
        self.bytes = bytes
        self.modified = modified
        self.isDirectory = isDirectory
        self.device = device
        self.inode = inode
    }
}

public enum OldDownloads {
    public static let defaultDays = 90
    private static let timeBudget: TimeInterval = 30
    /// A browser still writing these would lose its download.
    private static let unfinishedSuffixes = [".download", ".crdownload", ".part", ".partial", ".opdownload"]

    /// Items in the user's Downloads folder not modified for `days` days, biggest first (ties by name, plain `<`).
    public static func scan(home: URL, userProtected: [String] = [], olderThanDays days: Int, now: Date) -> Reading<[OldDownload]> {
        guard days >= 1 else { return .failed(reason: "the age limit must be at least one day") }
        guard let folder = downloadsFolder(home: home) else {
            return lstatKind(home.path + "/Downloads") == nil
                ? .unavailable(reason: "there is no Downloads folder")
                : .failed(reason: "the Downloads folder is a link or cannot be resolved")
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            return .failed(reason: "the Downloads folder could not be read")
        }
        let cutoff = cutoff(now: now, days: days)
        let protectedEntries = canonicalEntries(userProtected)
        let deadline = Date().addingTimeInterval(timeBudget)
        var found: [OldDownload] = []
        for name in names where !isExcluded(name) {
            if Date() > deadline { return .failed(reason: "the Downloads folder took too long to read") }
            let path = folder + "/" + name
            guard let seen = inspect(path, deadline: deadline), seen.complete, !seen.hasGit, !seen.hidden, seen.modified <= cutoff,
                  !isProtected(path, by: protectedEntries) else { continue }
            found.append(OldDownload(path: path, name: name, bytes: seen.bytes, modified: seen.modified, isDirectory: seen.isDirectory,
                                     device: seen.device, inode: seen.inode))
        }
        found.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        return .ok(found, source: "Downloads", at: now)
    }

    /// The owner's protected paths in canonical form (a path that does not exist yet keeps its given form).
    static func canonicalEntries(_ paths: [String]) -> [String] {
        paths.map { CleanupPolicy.canonical($0) ?? URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    /// A protected folder inside an item, or an item inside one, keeps the item where it is.
    static func isProtected(_ path: String, by entries: [String]) -> Bool {
        entries.contains { CleanupPolicy.isInside(path, $0) || CleanupPolicy.isInside($0, path) }
    }

    static func cutoff(now: Date, days: Int) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }

    /// Hidden files and unfinished downloads are never offered and never moved.
    static func isExcluded(_ name: String) -> Bool {
        let lower = name.lowercased()
        return name.hasPrefix(".") || unfinishedSuffixes.contains { lower.hasSuffix($0) }
    }

    /// The canonical Downloads folder, nil when it is missing or is a link (a link could lead anywhere).
    static func downloadsFolder(home: URL) -> String? {
        guard let canonicalHome = CleanupPolicy.canonical(home.path) else { return nil }
        let folder = canonicalHome + "/Downloads"
        guard lstatKind(folder) == S_IFDIR, CleanupPolicy.canonical(folder) == folder else { return nil }
        return folder
    }

    struct Inspection {
        let bytes: Int64
        let modified: Date
        let isDirectory: Bool
        let device: Int64
        let inode: UInt64
        /// The item itself carries Finder's hidden flag.
        let hidden: Bool
        let hasGit: Bool
        /// False when part of a folder could not be read or the walk ran out of time: a partial answer is not the answer.
        let complete: Bool
    }

    /// A regular file or a folder, walked without following links; nil for a link or anything else.
    static func inspect(_ path: String, deadline: Date) -> Inspection? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let device = Int64(info.st_dev), inode = UInt64(info.st_ino), hidden = info.st_flags & UInt32(UF_HIDDEN) != 0
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            return Inspection(bytes: Int64(info.st_size), modified: modified(info), isDirectory: false, device: device, inode: inode,
                              hidden: hidden, hasGit: false, complete: true)
        case S_IFDIR:
            let problems = WalkErrors()
            guard let walker = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil, options: [],
                errorHandler: { _, _ in problems.record(); return true }) else { return nil }
            var bytes: Int64 = 0, newest = modified(info), hasGit = false, complete = true, visited = 0
            for case let url as URL in walker {
                visited += 1
                if visited % 16 == 0, Date() > deadline { complete = false; break }
                if url.lastPathComponent == ".git" { hasGit = true }
                var inner = stat()
                guard lstat(url.path, &inner) == 0 else { problems.record(); continue }
                newest = max(newest, modified(inner))
                if inner.st_mode & S_IFMT == S_IFREG { bytes = saturatingAdd(bytes, Int64(inner.st_size)) }
            }
            return Inspection(bytes: bytes, modified: newest, isDirectory: true, device: device, inode: inode, hidden: hidden, hasGit: hasGit,
                              complete: complete && !problems.occurred)
        default:
            return nil
        }
    }

    private static func modified(_ info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }

    private static func lstatKind(_ path: String) -> mode_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & S_IFMT : nil
    }
}

/// Moves old downloads to the Trash, re-checking each one right before it moves.
public struct OldDownloadsMover: Sendable {
    private let home: URL
    private let userProtected: [String]
    private let trasher: Trasher
    private let now: @Sendable () -> Date
    private let timeBudget: TimeInterval = 30

    public init(home: URL, userProtected: [String] = [], trasher: Trasher, now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.userProtected = userProtected
        self.trasher = trasher
        self.now = now
    }

    /// `progress(done, total, next)` is called before each item (`next` is the path about to be moved) and once at the end.
    public func move(_ items: [OldDownload], olderThanDays days: Int,
                     progress: (@Sendable (_ done: Int, _ total: Int, _ next: String?) -> Void)? = nil) -> [CleanupResult] {
        var results: [CleanupResult] = []
        for (index, item) in items.enumerated() {
            progress?(index, items.count, item.path)
            results.append(CleanupResult(path: item.path, outcome: move(item, days: days)))
        }
        progress?(items.count, items.count, nil)
        return results
    }

    private func move(_ item: OldDownload, days: Int) -> ActionOutcome {
        guard days >= 1 else { return .refused("the age limit must be at least one day") }
        guard let folder = OldDownloads.downloadsFolder(home: home) else { return .refused("the Downloads folder is missing or is a link") }
        let name = (item.path as NSString).lastPathComponent
        guard !OldDownloads.isExcluded(name), !OldDownloads.isExcluded(item.name) else {
            return .refused("it is hidden or an unfinished download")
        }
        guard let canonical = CleanupPolicy.canonical(item.path) else { return .refused("the path no longer exists") }
        guard canonical == item.path else { return .refused("the path now resolves somewhere else") }
        guard (canonical as NSString).deletingLastPathComponent == folder, canonical != folder else {
            return .refused("it is not directly inside Downloads")
        }
        // One look, as late as possible: the identity, the age of everything inside and the path as it is now. A path-based
        // Trash call cannot be bound to an inode, so this narrows the window rather than closing it.
        guard let seen = OldDownloads.inspect(canonical, deadline: Date().addingTimeInterval(timeBudget)), seen.complete else {
            return .refused("it could not be re-checked")
        }
        guard seen.device == item.device, seen.inode == item.inode else { return .refused("it was replaced since the scan") }
        guard !seen.hasGit else { return .refused("it contains a git repository") }
        guard !seen.hidden else { return .refused("it is hidden") }
        guard !OldDownloads.isProtected(canonical, by: OldDownloads.canonicalEntries(userProtected)) else {
            return .refused("it is, or contains, a protected path")
        }
        guard seen.modified <= OldDownloads.cutoff(now: now(), days: days) else { return .refused("it was used since the scan") }
        guard CleanupPolicy.canonical(item.path) == canonical else { return .refused("it was replaced just before the move") }
        do {
            try trasher.trash(URL(fileURLWithPath: canonical))
            return .done
        } catch {
            return .failed("the Trash refused it: \(error.localizedDescription)")
        }
    }
}
