import Foundation

/// Whether an app may be uninstalled from MacMax. Fails closed: when what runs cannot be read, nothing is moved.
public enum AppUninstallPolicy {
    public static func refusal(for app: InstalledApp, home: String, running: Running?) -> String? {
        guard let running else { return "it could not be checked what is running" }
        let folderName = ((app.path as NSString).lastPathComponent as NSString).deletingPathExtension
        if running.bundleIDs.contains(app.bundleID) { return "\(app.name) is open: quit it first" }
        // Closing the window often leaves helpers behind (updaters, daemons): they are in the process list by the app's name.
        if running.names.contains(folderName) || running.names.contains(app.name) {
            return "\(app.name) is closed but still has programs running in the background. Stop them in the Apps tab, then try again"
        }
        if app.bundleID.hasPrefix("com.apple.") { return "it is an Apple app" }
        if app.bundleID.hasPrefix("ro.danieltamas.macmax") { return "it is MacMax itself" }
        guard CleanupPolicy.isBundleID(app.bundleID) else { return "its bundle id is not a normal app id" }
        guard app.path.hasSuffix(".app") else { return "it is not an app folder" }
        let parent = (app.path as NSString).deletingLastPathComponent
        let allowed = ["/Applications", (CleanupPolicy.canonical(home) ?? home) + "/Applications"]
        guard allowed.contains(CleanupPolicy.canonical(parent) ?? parent) else { return "it is not directly in an Applications folder" }
        return nil
    }
}

/// Moves an app and the leftovers the user chose to the Trash, one by one, re-checking each right before it moves.
public struct AppUninstaller: Sendable {
    private let home: String
    private let trasher: Trasher
    private let running: @Sendable () -> Running?

    public init(home: URL, trasher: Trasher, running: @escaping @Sendable () -> Running? = { Running() }) {
        self.home = CleanupPolicy.canonical(home.path) ?? home.standardizedFileURL.path
        self.trasher = trasher
        self.running = running
    }

    /// The app moves first. If it does not, its leftovers stay: an app that is still there would just write them again.
    public func uninstall(_ app: InstalledApp, leftovers: [Leftover],
                          progress: (@Sendable (_ done: Int, _ total: Int, _ next: String?) -> Void)? = nil) -> [CleanupResult] {
        let total = 1 + leftovers.count
        progress?(0, total, app.path)
        let appOutcome = moveApp(app)
        var results = [CleanupResult(path: app.path, outcome: appOutcome)]
        let allowed = Set(LeftoverFinder.candidates(for: app, home: home).map(\.path))
        for (index, leftover) in leftovers.enumerated() {
            progress?(index + 1, total, leftover.path)
            let outcome: ActionOutcome = appOutcome == .done ? move(leftover, allowed: allowed) : .refused("the app was not moved")
            results.append(CleanupResult(path: leftover.path, outcome: outcome))
        }
        progress?(total, total, nil)
        return results
    }

    private func moveApp(_ app: InstalledApp) -> ActionOutcome {
        if let reason = AppUninstallPolicy.refusal(for: app, home: home, running: running()) { return .refused(reason) }
        guard let canonical = CleanupPolicy.canonical(app.path) else { return .refused("the app is no longer there") }
        guard canonical == app.path else { return .refused("the app path now resolves somewhere else") }
        // The bundle at this path must still be the app that was previewed.
        guard let data = StartupScanner.readPlist(at: canonical + "/Contents/Info.plist"),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == app.bundleID else { return .refused("the app was replaced since the preview") }
        // What runs is read again as late as possible (the read is slow): an app opened while the checks above ran is
        // not moved, and the folder's identity is looked at once more after it. A path-based Trash call cannot be bound
        // to an inode, so this narrows the window rather than closing it.
        if let reason = AppUninstallPolicy.refusal(for: app, home: home, running: running()) { return .refused(reason) }
        guard CleanupPolicy.canonical(app.path) == canonical else { return .refused("the app path now resolves somewhere else") }
        if let expected = app.identity, FileIdentity.of(canonical) != expected { return .refused("the app was replaced since the preview") }
        return trash(canonical, failure: "the Trash refused the app")
    }

    private func move(_ leftover: Leftover, allowed: Set<String>) -> ActionOutcome {
        guard allowed.contains(leftover.path) else { return .refused("it does not belong to this app") }
        guard let canonical = CleanupPolicy.canonical(leftover.path) else { return .refused("it is no longer there") }
        guard canonical == leftover.path else { return .refused("it now resolves somewhere else") }
        guard let expected = leftover.identity else { return .refused("it was not part of the preview") }
        guard FileIdentity.of(canonical) == expected else { return .refused("it was replaced since the preview") }
        return trash(canonical, failure: "the Trash refused it")
    }

    private func trash(_ path: String, failure: String) -> ActionOutcome {
        do {
            try trasher.trash(URL(fileURLWithPath: path))
            return .done
        } catch {
            return .failed("\(failure): \(error.localizedDescription)")
        }
    }
}
