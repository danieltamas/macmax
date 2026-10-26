import Darwin
import Foundation

/// The cleanup rules and the paths they may never touch. Paths are compared in canonical form (symlinks resolved,
/// `/private` prefix dropped the way Foundation does), so a symlink cannot smuggle a protected folder in.
struct CleanupRule: Sendable {
    let id: String
    /// Relative to home.
    let root: String
    /// Candidates are the direct children of `root` rather than `root` itself.
    let children: Bool
    /// Name of the program that must not be running, as `Running.names` spells it.
    let blockedBy: String?
}

struct CleanupPolicy: Sendable {
    static let rules: [CleanupRule] = [
        CleanupRule(id: "app_caches", root: "Library/Caches", children: true, blockedBy: nil),
        CleanupRule(id: "xcode_derived", root: "Library/Developer/Xcode/DerivedData", children: true, blockedBy: "Xcode"),
        CleanupRule(id: "simulator_caches", root: "Library/Developer/CoreSimulator/Caches", children: false, blockedBy: "Simulator"),
        CleanupRule(id: "npm_cache", root: ".npm/_cacache", children: false, blockedBy: "npm"),
        CleanupRule(id: "yarn_cache", root: "Library/Caches/Yarn", children: false, blockedBy: "yarn"),
        CleanupRule(id: "pip_cache", root: "Library/Caches/pip", children: false, blockedBy: "pip"),
        CleanupRule(id: "homebrew_cache", root: "Library/Caches/Homebrew", children: false, blockedBy: "brew"),
        CleanupRule(id: "old_logs", root: "Library/Logs", children: false, blockedBy: nil),
        CleanupRule(id: "chrome_cache", root: "Library/Caches/Google/Chrome", children: false, blockedBy: "Google Chrome"),
        CleanupRule(id: "firefox_cache", root: "Library/Caches/Firefox", children: false, blockedBy: "firefox"),
        CleanupRule(id: "edge_cache", root: "Library/Caches/Microsoft Edge", children: false, blockedBy: "Microsoft Edge"),
        CleanupRule(id: "brave_cache", root: "Library/Caches/BraveSoftware", children: false, blockedBy: "Brave Browser"),
        CleanupRule(id: "mail_downloads", root: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads", children: true, blockedBy: "Mail"),
    ]
    /// Caches with a rule of their own are not also listed as app caches.
    static let dedicatedCacheNames: Set<String> = ["Yarn", "pip", "Homebrew"]

    private static let homeProtected = [
        "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library/Mobile Documents",
        "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Containers", "Library/Group Containers",
        "Library/Application Support", ".ssh", ".gnupg", ".aws", ".config", ".macmax",
    ]
    private static let systemProtected = ["/System", "/Library", "/usr", "/bin", "/sbin", "/Applications"]

    let home: String
    let protected: [String]
    /// The same list without the built-in Containers entry, for the one rule that works inside it. An entry the owner added
    /// for Containers (or anything in it) stays here and still applies.
    private let protectedForMail: [String]

    init(home: URL, userProtected: [String]) {
        let resolved = Self.canonical(home.path) ?? home.standardizedFileURL.path
        self.home = resolved
        let fixed = Self.homeProtected.map { resolved + "/" + $0 } + Self.systemProtected
        protected = (fixed + userProtected).compactMap { Self.canonical($0) ?? Self.lexical($0) }
        protectedForMail = (fixed.filter { $0 != resolved + "/Library/Containers" } + userProtected).compactMap { Self.canonical($0) ?? Self.lexical($0) }
    }

    func rule(_ id: String) -> CleanupRule? { Self.rules.first { $0.id == id } }

    func rootPath(_ rule: CleanupRule) -> String { Self.canonical(home + "/" + rule.root) ?? home + "/" + rule.root }

    /// Why `path` (already canonical) may not be touched for `rule`, or nil when it may.
    func violation(of path: String, rule: CleanupRule) -> String? {
        let root = rootPath(rule)
        // A root that is a link leads somewhere else, and everything under it would pass as "inside the root".
        guard root == home + "/" + rule.root else { return "the allowed folder is a link" }
        if rule.id == "app_caches", !Self.isBundleID((path as NSString).lastPathComponent) { return "it is not an app's bundle id" }
        if rule.id == "app_caches", Self.dedicatedCacheNames.contains((path as NSString).lastPathComponent) {
            return "it has its own cleanup rule"
        }
        if rule.children {
            guard (path as NSString).deletingLastPathComponent == root, path != root else { return "it is outside the allowed folder" }
        } else {
            guard Self.isInside(path, root) else { return "it is outside the allowed folder" }
        }
        if rule.id == "old_logs", Self.isInside(path, root + "/DiagnosticReports") { return "crash reports are never removed" }
        // Mail's attachment cache sits inside the protected Containers folder; only that one rule may look in, and the
        // root and children checks above already confine it to that folder's direct children.
        for entry in rule.id == "mail_downloads" ? protectedForMail : protected where Self.isInside(path, entry) || Self.isInside(entry, path) {
            return "it is, or contains, a protected path"
        }
        // A git work tree between the path and the rule root is the user's code.
        var parent = (path as NSString).deletingLastPathComponent
        while Self.isInside(parent, root), parent != root {
            if exists(parent + "/.git") { return "it is inside a git repository" }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return nil
    }

    // MARK: - Path helpers

    /// `~/Library/Caches/<bundle id>`: reverse-DNS names only. A folder called "work" is not an app's cache.
    static func isBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return parts.count >= 2 && parts.allSatisfy { part in
            // Each label starts with a letter or digit, as in a reverse-DNS name.
            guard let first = part.unicodeScalars.first, first.properties.isAlphabetic || ("0"..."9").contains(Character(first)) else { return false }
            return !part.hasSuffix("-") && part.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// `realpath`, with the `/private/var`, `/private/tmp`, `/private/etc` prefix shown the way Foundation shows it.
    static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let text = String(cString: resolved)
        for stripped in ["/private/var", "/private/tmp", "/private/etc"] where isInside(text, stripped) {
            return String(text.dropFirst("/private".count))
        }
        return text
    }

    /// For a protected path that does not exist yet: its lexical form with the parent resolved when possible.
    private static func lexical(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let parent = canonical(url.deletingLastPathComponent().path) else { return url.path }
        return parent == "/" ? "/" + url.lastPathComponent : parent + "/" + url.lastPathComponent
    }

    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

/// What a candidate measures, walking without following symlinks.
struct Measurement: Sendable {
    let bytes: Int64
    let hasGit: Bool
    let device: Int64
    let inode: UInt64
    /// False when the walk stopped at the deadline or could not read part of the tree: a partial size must never pass
    /// for the real one.
    let complete: Bool
    /// Modification time of a regular file; nil for a folder.
    let modified: Date?

    /// Device and inode of `path` itself (a symlink is not followed), with size and age when it is a regular file;
    /// nil when it is not there.
    static func identity(of path: String) -> (device: Int64, inode: UInt64, file: (bytes: Int64, modified: Date)?)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let file: (bytes: Int64, modified: Date)? = info.st_mode & S_IFMT == S_IFREG
            ? (Int64(info.st_size), Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9))
            : nil
        return (Int64(info.st_dev), UInt64(info.st_ino), file)
    }

    /// nil when the path cannot be read at all.
    static func of(_ path: String, deadline: Date) -> Measurement? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let device = Int64(info.st_dev), inode = UInt64(info.st_ino)
        if info.st_mode & S_IFMT == S_IFREG {
            return Measurement(bytes: Int64(info.st_size), hasGit: false, device: device, inode: inode, complete: true,
                               modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return nil }
        let problems = WalkErrors()
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [], errorHandler: { _, _ in problems.record(); return true }) else { return nil }
        var bytes: Int64 = 0, hasGit = false, complete = true, visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited % 16 == 0, Date() > deadline { complete = false; break }
            if url.lastPathComponent == ".git" { hasGit = true }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { problems.record(); continue }
            guard values.isRegularFile == true else { continue }
            bytes = saturatingAdd(bytes, Int64(values.fileSize ?? 0))
        }
        // An unreadable subtree may hold a `.git` or more data: a size that skipped it is not the size.
        return Measurement(bytes: bytes, hasGit: hasGit, device: device, inode: inode, complete: complete && !problems.occurred, modified: nil)
    }
}

/// A sum of untrusted sizes never traps: it stops at the largest value, which no growth limit will accept.
func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
    let (sum, overflow) = left.addingReportingOverflow(right)
    return overflow ? Int64.max : sum
}

/// Collects directory read errors from the enumerator's callback.
final class WalkErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() { lock.withLock { count += 1 } }
    var occurred: Bool { lock.withLock { count > 0 } }
}
