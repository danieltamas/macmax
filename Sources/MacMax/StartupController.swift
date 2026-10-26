import Foundation
import MacMaxCore

/// Background items: the scan, and turning one of the user's own agents off or on. Which items may be touched and
/// the exact commands are decided in MacMaxCore (StartupControl); this only runs them after a press and logs them.
extension ActionController {
    /// `force` starts a scan even while another runs (after an action): the older answer is then dropped.
    func scanStartup(force: Bool = false) {
        if case .loading = model.startupState, !force { return }
        model.startupState = .loading("Reading the background items...")
        model.startupGeneration += 1
        let generation = model.startupGeneration
        Task {
            let reading = await StartupScanner().scan()
            guard generation == model.startupGeneration else { return }
            switch reading {
            case let .ok(result, _, _):
                model.startupItems = result.items
                model.startupUnreadable = result.unreadable
                model.startupState = .ready
            case let .unavailable(reason), let .failed(reason):
                model.startupState = .failed(collector: "launchd", reason: reason)
            }
        }
    }

    /// Reads the plist and, for a running item, its sockets. Run again on every open, so the connections are current.
    func inspectStartup(_ item: StartupItem) {
        guard !model.startupInspecting.contains(item.path) else { return }
        model.startupInspecting.insert(item.path)
        Task {
            let inspection = await StartupInspector().inspect(item)
            model.startupInspections[item.path] = inspection
            model.startupInspecting.remove(item.path)
        }
    }

    func setStartup(_ item: StartupItem, enabled: Bool) {
        let key = "startup-\(item.path)"
        guard model.actionStates[key]?.isWorking != true else { return }
        // A press acts on what the last full read showed: an item gone since, or a read that failed, is not acted on.
        guard case .ready = model.startupState, model.startupItems?.contains(where: { $0.path == item.path && $0.label == item.label && $0.scope == item.scope }) == true else {
            set(key, .refused("The list is out of date. Read again first."))
            return
        }
        // Two plists with one label (in any folder) are one launchd service: a press on either would change both.
        let sameLabel = (model.startupItems ?? []).filter { $0.label == item.label }.count
        let commands = sameLabel > 1 ? nil : enabled ? StartupControl.enableCommands(for: item, uid: getuid()) : StartupControl.disableCommands(for: item, uid: getuid())
        guard let commands else {
            set(key, .refused("MacMax cannot change this one."))
            record(kind: "startup", target: item.label, result: "refused", detail: enabled ? "on" : "off", key: key)
            return
        }
        set(key, .working(enabled ? "Turning on..." : "Turning off..."))
        Task {
            let done = await StartupScanner().run(commands)
            // Disable then stop: an agent that was not running has nothing to stop, so a failed stop is not a problem.
            let worked = done == commands.count || (!enabled && done == 1 && !item.isRunning)
            let partial = !enabled && done == 1 && item.isRunning
            set(key, worked ? .done(enabled ? "On again. It starts at your next login." : "Off. It will not start at login.")
                : partial ? .failed("Turned off for the next login, but it could not be stopped now. Log out or restart to stop it.")
                : .failed("launchctl refused. Nothing was changed that MacMax can confirm."))
            record(kind: "startup", target: item.label, result: worked ? (enabled ? "enabled" : "disabled") : partial ? "disabled_not_stopped" : "failed", key: key)
            scanStartup(force: true)
        }
    }
}
