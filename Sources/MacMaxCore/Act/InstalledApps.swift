import Foundation

public struct InstalledApp: Sendable, Equatable, Identifiable {
    public let path: String
    public let name: String
    public let bundleID: String
    public let version: String?
    /// nil when the bundle could not be fully measured.
    public let bytes: Int64?
    /// Device and inode of the bundle folder when it was listed; the move checks them again. Not part of equality.
    public let identity: FileIdentity?
    public var id: String { path }

    public init(path: String, name: String, bundleID: String, version: String?, bytes: Int64?, identity: FileIdentity? = nil) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.bytes = bytes
        self.identity = identity
    }

    /// The same app with its size filled in.
    public func withBytes(_ bytes: Int64?) -> InstalledApp {
        InstalledApp(path: path, name: name, bundleID: bundleID, version: version, bytes: bytes, identity: identity)
    }

    public static func == (left: InstalledApp, right: InstalledApp) -> Bool {
        left.path == right.path && left.name == right.name && left.bundleID == right.bundleID && left.version == right.version && left.bytes == right.bytes
    }
}

/// Which file a path was when it was previewed: a folder swapped in since has another inode.
public struct FileIdentity: Sendable, Equatable {
    public let device: Int64
    public let inode: UInt64

    public init(device: Int64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    static func of(_ path: String) -> FileIdentity? {
        Measurement.identity(of: path).map { FileIdentity(device: $0.device, inode: $0.inode) }
    }
}

public enum LeftoverKind: Sendable, Equatable {
    case applicationSupport, caches, preferences, container, logs, savedState, httpStorage, webKit, cookies, launchAgent
}

public enum LeftoverMatch: Sendable, Equatable { case bundleID, name }

public struct Leftover: Sendable, Equatable, Identifiable {
    public let path: String
    public let kind: LeftoverKind
    public let match: LeftoverMatch
    public let bytes: Int64?
    /// Set by `LeftoverFinder.find`; a leftover without it was not previewed and is not moved. Not part of equality.
    public let identity: FileIdentity?
    public var id: String { path }

    public init(path: String, kind: LeftoverKind, match: LeftoverMatch, bytes: Int64?, identity: FileIdentity? = nil) {
        self.path = path
        self.kind = kind
        self.match = match
        self.bytes = bytes
        self.identity = identity
    }

    /// The same leftover with its size filled in.
    public func withBytes(_ bytes: Int64?) -> Leftover {
        Leftover(path: path, kind: kind, match: match, bytes: bytes, identity: identity)
    }

    public static func == (left: Leftover, right: Leftover) -> Bool {
        left.path == right.path && left.kind == right.kind && left.match == right.match && left.bytes == right.bytes
    }
}

/// Lists the apps in the folders it is given. It only reads.
public enum AppLister {
    private static let measureBudget: TimeInterval = 5

    /// `unreadable` counts the apps that could not be used (no usable Info.plist, a link), so a short list is not
    /// taken for a complete one.
    /// `measure: false` leaves `bytes` nil so a long list comes back at once; `measuredBytes(of:)` fills the sizes in.
    public static func list(folders: [String], measure: Bool = true) -> (apps: [InstalledApp], unreadable: Int) {
        var apps: [InstalledApp] = []
        var unreadable = 0
        for folder in folders {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: folder)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            } catch {
                unreadable += 1
                continue
            }
            for name in names.sorted() where name.hasSuffix(".app") {
                let path = folder + "/" + name
                if let app = read(path: path, folderName: String(name.dropLast(4)), measure: measure) { apps.append(app) } else { unreadable += 1 }
            }
        }
        apps.sort { left, right in
            let order = left.name.caseInsensitiveCompare(right.name)
            return order == .orderedSame ? left.path < right.path : order == .orderedAscending
        }
        return (apps, unreadable)
    }

    /// The size of a folder, nil when it could not be fully measured in the time allowed.
    public static func measuredBytes(of path: String) -> Int64? {
        Measurement.of(path, deadline: Date().addingTimeInterval(measureBudget)).flatMap { $0.complete ? $0.bytes : nil }
    }

    private static func read(path: String, folderName: String, measure: Bool) -> InstalledApp? {
        var info = stat()
        // A link is not followed: it could lead anywhere, and what would be moved is the link's target.
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, let canonical = CleanupPolicy.canonical(path),
              let data = StartupScanner.readPlist(at: path + "/Contents/Info.plist"),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty, bundleID.count <= StartupParser.maxLabelLength,
              !bundleID.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        else { return nil }
        func text(_ key: String) -> String? { (plist[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        // Without the folder's identity the move could not tell it from a replacement: not listed.
        guard let identity = FileIdentity.of(canonical) else { return nil }
        let bytes = measure ? measuredBytes(of: canonical) : nil
        // Shown in the UI: invisible or control characters in a name must not reach it.
        return InstalledApp(path: canonical, name: Redaction.sanitizeText(text("CFBundleDisplayName") ?? text("CFBundleName") ?? folderName), bundleID: bundleID,
                            version: text("CFBundleShortVersionString").map(Redaction.sanitizeText), bytes: bytes, identity: identity)
    }
}

/// The only places an app's leftovers are looked for, all inside the user's Library.
public enum LeftoverFinder {
    public static func candidates(for app: InstalledApp, home: String) -> [(path: String, kind: LeftoverKind, match: LeftoverMatch)] {
        let library = home + "/Library/"
        let id = app.bundleID
        var found: [(path: String, kind: LeftoverKind, match: LeftoverMatch)] = [
            (library + "Application Support/" + id, .applicationSupport, .bundleID),
            (library + "Caches/" + id, .caches, .bundleID),
            (library + "Preferences/" + id + ".plist", .preferences, .bundleID),
            (library + "Containers/" + id, .container, .bundleID),
            (library + "Logs/" + id, .logs, .bundleID),
            (library + "Saved Application State/" + id + ".savedState", .savedState, .bundleID),
            (library + "HTTPStorages/" + id, .httpStorage, .bundleID),
            (library + "WebKit/" + id, .webKit, .bundleID),
            (library + "Cookies/" + id + ".binarycookies", .cookies, .bundleID),
            (library + "LaunchAgents/" + id + ".plist", .launchAgent, .bundleID),
        ]
        // A short or path-like name would match other apps' folders: names are used only when they are specific.
        let name = app.name
        if name.count >= 4, !name.contains("/"), name != ".", name != "..", name != id {
            found.append((library + "Application Support/" + name, .applicationSupport, .name))
            found.append((library + "Logs/" + name, .logs, .name))
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.path).inserted }
    }

    /// `measure: false` leaves every `bytes` nil so the list comes back at once; `measured(_:)` fills one in.
    public static func find(for app: InstalledApp, home: String, measure: Bool = true) -> [Leftover] {
        let root = CleanupPolicy.canonical(home) ?? home
        var leftovers: [Leftover] = []
        for candidate in candidates(for: app, home: root) {
            // Not followed: a link in the Library is someone's pointer, not this app's data.
            var info = stat()
            guard lstat(candidate.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { continue }
            leftovers.append(Leftover(path: candidate.path, kind: candidate.kind, match: candidate.match,
                                      bytes: measure ? AppLister.measuredBytes(of: candidate.path) : nil,
                                      identity: FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))))
        }
        return measure ? sorted(leftovers) : leftovers
    }

    /// Biggest first, unmeasured last, ties by path.
    public static func sorted(_ leftovers: [Leftover]) -> [Leftover] {
        leftovers.sorted { left, right in
            switch (left.bytes, right.bytes) {
            case let (a?, b?): a == b ? left.path < right.path : a > b
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): left.path < right.path
            }
        }
    }
}
