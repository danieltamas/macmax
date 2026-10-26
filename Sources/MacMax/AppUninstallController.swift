import Foundation
import MacMaxCore

/// Apps and their leftovers: the scan, and the move to the Trash after one confirmation in the card. Which paths may
/// move is decided in MacMaxCore (AppUninstallPolicy, LeftoverFinder); this runs the move after a press and logs it.
extension ActionController {
    func scanInstalledApps() {
        if case .loading = model.installedAppsState { return }
        model.installedAppsState = .loading("Reading the apps...")
        model.installedAppsGeneration += 1
        let generation = model.installedAppsGeneration
        Task {
            let home = NSHomeDirectory()
            // The list comes back at once; sizes follow one by one, so a big app does not hold up the others.
            let found = await Task.detached(priority: .utility) { AppLister.list(folders: ["/Applications", home + "/Applications"], measure: false) }.value
            // Sizes already measured stay: a refresh must not blank the list again.
            let known = Dictionary(model.installedApps?.compactMap { app in app.bytes.map { (app.path, $0) } } ?? [], uniquingKeysWith: { first, _ in first })
            let apps = found.apps.map { app in known[app.path].map(app.withBytes) ?? app }
            model.installedApps = apps
            model.installedAppsAt = .now
            model.installedAppsUnreadable = found.unreadable
            model.installedAppsState = .ready
            model.measuringApps = Set(apps.filter { $0.bytes == nil }.map(\.path))
            let paths = found.apps.map(\.path)
            model.appLastOpened = await Task.detached(priority: .utility) { Dictionary(uniqueKeysWithValues: paths.map { ($0, AppLastOpened.read(path: $0)) }) }.value
            await withTaskGroup(of: (String, Int64?).self) { group in
                var pending = apps.filter { $0.bytes == nil }.makeIterator()
                func next() { if let app = pending.next() { group.addTask(priority: .utility) { (app.path, AppLister.measuredBytes(of: app.path)) } } }
                for _ in 0 ..< 4 { next() }
                for await (path, bytes) in group {
                    guard generation == model.installedAppsGeneration else { group.cancelAll(); break }
                    model.installedApps = model.installedApps?.map { $0.path == path ? $0.withBytes(bytes) : $0 }
                    model.measuringApps.remove(path)
                    next()
                }
            }
        }
    }

    func loadLeftovers(_ app: InstalledApp) {
        guard !model.leftoversLoading.contains(app.path) else { return }
        model.leftoversLoading.insert(app.path)
        model.leftoversGeneration[app.path, default: 0] += 1
        let generation = model.leftoversGeneration[app.path]
        Task {
            let home = NSHomeDirectory()
            let found = await Task.detached(priority: .utility) { LeftoverFinder.find(for: app, home: home, measure: false) }.value
            model.appLeftovers[app.path] = found
            model.leftoversLoading.remove(app.path)
            model.measuringLeftovers.formUnion(found.map { "\(app.path)\n\($0.path)" })
            await withTaskGroup(of: (String, Int64?).self) { group in
                for leftover in found { group.addTask(priority: .utility) { (leftover.path, AppLister.measuredBytes(of: leftover.path)) } }
                for await (path, bytes) in group {
                    guard generation == model.leftoversGeneration[app.path] else { group.cancelAll(); break }
                    model.appLeftovers[app.path] = model.appLeftovers[app.path]?.map { $0.path == path ? $0.withBytes(bytes) : $0 }
                    model.measuringLeftovers.remove("\(app.path)\n\(path)")
                }
            }
            if generation == model.leftoversGeneration[app.path] { model.appLeftovers[app.path] = model.appLeftovers[app.path].map(LeftoverFinder.sorted) }
        }
    }

    func uninstall(_ app: InstalledApp, leftovers: [Leftover]) {
        guard model.uninstalling == nil else { return }
        model.uninstalling = app.path
        model.uninstallProgress = (0, 1 + leftovers.count, app.path)
        model.uninstallResults = []
        model.uninstalledName = app.name
        Task {
            let results = await Task.detached(priority: .utility) { [model] () -> [CleanupResult] in
                // A closed app often leaves updaters and daemons running from inside its bundle. They are ended first,
                // by this same press; an app that is still open is left to the policy, which refuses it.
                if let blocked = Self.stopBackgroundPrograms(of: app, model: model) {
                    return [CleanupResult(path: app.path, outcome: .refused(blocked))]
                        + leftovers.map { CleanupResult(path: $0.path, outcome: .refused("the app was not moved")) }
                }
                return AppUninstaller(home: FileManager.default.homeDirectoryForCurrentUser, trasher: FileManagerTrasher(), running: { Self.running() })
                    .uninstall(app, leftovers: leftovers) { done, total, next in
                        Task { @MainActor in model.uninstallProgress = (done, total, next) }
                    }
            }.value
            for result in results {
                switch result.outcome {
                case .done: record(kind: "uninstall", target: result.path, result: "trashed", detail: app.bundleID)
                case let .refused(reason): record(kind: "uninstall", target: result.path, result: "skipped", detail: reason)
                case let .failed(reason): record(kind: "uninstall", target: result.path, result: "failed", detail: reason)
                }
            }
            model.uninstallResults = results
            model.uninstalling = nil
            model.uninstallProgress = nil
            model.appLeftovers[app.path] = nil
            scanInstalledApps()
        }
    }

    /// A reason to stop the uninstall, or nil when nothing runs from the bundle any more.
    nonisolated private static func stopBackgroundPrograms(of app: InstalledApp, model: PanelModel) -> String? {
        guard let running = running(), !running.bundleIDs.contains(app.bundleID) else { return nil }
        let processes = AppBackgroundProcesses.system()
        guard processes.find(in: app.path)?.isEmpty == false else { return nil }
        Task { @MainActor in model.uninstallStopping = true }
        defer { Task { @MainActor in model.uninstallStopping = false } }
        switch processes.stop(in: app.path) {
        case .nothingRunning, .stopped: return nil
        case let .failed(reason): return "\(app.name) still has programs running in the background: \(reason)"
        }
    }
}
