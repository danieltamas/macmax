import Foundation
import MacMaxCore

/// Apps and their leftovers: the scan, and the move to the Trash after one confirmation in the card. Which paths may
/// move is decided in MacMaxCore (AppUninstallPolicy, LeftoverFinder); this runs the move after a press and logs it.
extension ActionController {
    func scanInstalledApps() {
        if case .loading = model.installedAppsState { return }
        model.installedAppsState = .loading("Reading the apps...")
        Task {
            let home = NSHomeDirectory()
            let found = await Task.detached(priority: .utility) { AppLister.list(folders: ["/Applications", home + "/Applications"]) }.value
            model.installedApps = found.apps
            model.installedAppsUnreadable = found.unreadable
            model.installedAppsState = .ready
        }
    }

    func loadLeftovers(_ app: InstalledApp) {
        guard !model.leftoversLoading.contains(app.path) else { return }
        model.leftoversLoading.insert(app.path)
        Task {
            let home = NSHomeDirectory()
            let found = await Task.detached(priority: .utility) { LeftoverFinder.find(for: app, home: home) }.value
            model.appLeftovers[app.path] = found
            model.leftoversLoading.remove(app.path)
        }
    }

    func uninstall(_ app: InstalledApp, leftovers: [Leftover]) {
        guard model.uninstalling == nil else { return }
        model.uninstalling = app.path
        model.uninstallProgress = (0, 1 + leftovers.count, app.path)
        model.uninstallResults = []
        model.uninstalledName = app.name
        Task {
            let results = await Task.detached(priority: .utility) { [model] in
                AppUninstaller(home: FileManager.default.homeDirectoryForCurrentUser, trasher: FileManagerTrasher(), running: { Self.running() })
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
}
