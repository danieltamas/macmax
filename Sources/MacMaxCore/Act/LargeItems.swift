import Foundation

/// A big folder or file the user may want to look at, and what MacMax knows about it.
public struct LargeItem: Sendable, Equatable, Identifiable {
    public let path: String
    public let bytes: Int64
    public let modified: Date?
    /// Inside a path MacMax never touches. Showing it is fine; it is only ever revealed in Finder.
    public let isProtected: Bool
    public var id: String { path }

    public init(path: String, bytes: Int64, modified: Date?, isProtected: Bool) {
        self.path = path
        self.bytes = bytes
        self.modified = modified
        self.isProtected = isProtected
    }
}

public enum LargeItemSelection {
    /// `du -k` output (`<kilobytes>\t<path>`) as the biggest entries of at least `minBytes`, at the deepest level that is
    /// still big: a folder is dropped when something inside it is listed, so "Library" does not hide "Library/X".
    /// `root` itself is never listed.
    public static func select(du: String, root: String, minBytes: Int64, limit: Int) -> [(path: String, bytes: Int64)] {
        var entries: [(path: String, bytes: Int64)] = []
        for line in du.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let kilobytes = Int64(line[..<tab].trimmingCharacters(in: .whitespaces)),
                  kilobytes >= 0 else { continue }
            let (bytes, overflow) = kilobytes.multipliedReportingOverflow(by: 1024)
            let path = String(line[line.index(after: tab)...])
            guard !overflow, bytes >= minBytes, path != root, path.hasPrefix("/") else { continue }
            entries.append((path, bytes))
        }
        let leaves = entries.filter { entry in !entries.contains { $0.path != entry.path && $0.path.hasPrefix(entry.path + "/") } }
        return Array(leaves.sorted { ($1.bytes, $0.path) < ($0.bytes, $1.path) }.prefix(limit))
    }
}
