import Foundation

/// Everything MacMax keeps on this Mac: the history database, config and logs. `MACMAX_HOME`
/// moves it, so a second instance shares nothing local with the first.
public struct MacMaxHome: Sendable {
    public let url: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        if let path = environment["MACMAX_HOME"], !path.isEmpty {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            url = homeDirectory.appendingPathComponent(".macmax", isDirectory: true)
        }
    }

    /// Mode 0700, also on a directory that already exists: history and logs are this user's alone.
    public func prepare() throws {
        let files = FileManager.default
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
