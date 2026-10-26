import AppKit
import MacMaxCore

/// Runs what a press asks for and records it. Every guard lives in MacMaxCore; this only reads the press, shows
/// where it got to, and writes the action log. Nothing here is reachable from the CLI or the MCP server.
@MainActor
final class ActionController {
    let model: PanelModel
    private let database: () -> Database?
    private let processes = ProcessActions.system()

    init(model: PanelModel, database: @escaping () -> Database?) {
        self.model = model
        self.database = database
        model.perform = { [weak self] in self?.perform($0) }
        model.loadContainers = { [weak self] in self?.loadContainers() }
        model.scanCleanup = { [weak self] in self?.scanCleanup() }
        model.moveToTrash = { [weak self] in self?.moveToTrash($0) }
        model.loadLastCleanups = { [weak self] in self?.loadLastCleanups() }
        model.scanTidy = { [weak self] in self?.scanTidy() }
        model.scanLarge = { [weak self] in self?.scanLarge() }
        model.scanStartup = { [weak self] in self?.scanStartup() }
        model.setStartupEnabled = { [weak self] in self?.setStartup($0, enabled: $1) }
        model.inspectStartup = { [weak self] in self?.inspectStartup($0) }
        model.scanInstalledApps = { [weak self] in self?.scanInstalledApps() }
        model.readPower = { [weak self] in self?.readPower() }
        model.loadLeftovers = { [weak self] in self?.loadLeftovers($0) }
        model.uninstallApp = { [weak self] in self?.uninstall($0, leftovers: $1) }
        model.refreshPermissions = { [weak self] in self?.refreshPermissions() }
        model.requestNotifications = { [weak self] in self?.requestNotifications() }
    }

    private static let cleanupKey = "cleanup"

    /// Actions whose log write failed: their line keeps saying so, whatever it shows next.
    private var unlogged: Set<String> = []
    private static let unloggedNote = " (not recorded in the log)"

    func set(_ key: String, _ state: ActionState) {
        let state = unlogged.contains(key) && !state.text.hasSuffix(Self.unloggedNote) ? state.noted(Self.unloggedNote) : state
        model.actionStates[key] = state
        // A finished action is news for a few seconds, not a verdict on the row: the same app or container may be back.
        guard case .done = state else { return }
        Task {
            try? await Task.sleep(for: .seconds(10))
            if model.actionStates[key] == state { model.actionStates[key] = nil }
        }
    }

    /// Processes that were sent the polite request: only they may be forced. A force press on anything else is sent as
    /// the polite request, so a stale button never kills what was never asked.
    private var asked: Set<ProcessIdentity> = []

    /// Every outcome is logged, refusals too. When the log cannot be written the action's own line says so.
    func record(kind: String, target: String, result: String, detail: String? = nil, key: String? = nil) {
        let now = Int64(Date().timeIntervalSince1970)
        let database = database()
        Task {
            do {
                guard let database else { throw StoreError.readOnly }
                try await database.logAction(ts: now, kind: kind, target: target, result: result, detail: detail)
            } catch {
                guard let key else { return }
                if key == Self.cleanupKey { model.cleanupLogProblem = "Some results could not be written to the log." }
                else {
                    unlogged.insert(key)
                    if let state = model.actionStates[key] { set(key, state) }
                }
            }
        }
    }

    // MARK: - Processes

    func perform(_ action: PanelAction) {
        let key = action.key
        guard model.actionStates[key]?.isWorking != true else { return }
        unlogged.remove(key)
        switch action {
        case let .endProcess(line, force): end(line, force: force, session: false, key: key)
        case let .endSession(line, force): end(line, force: force, session: true, key: key)
        case let .quit(row, force): quit(row, force: force, key: key)
        case let .stopContainer(container): stop(container, key: key)
        case let .endTidy(group, items): endTidy(group, items, key: key)
        }
    }

    private func end(_ line: ProcessLine, force: Bool, session: Bool, key: String) {
        let kind = session ? "end_session" : "end_process"
        let target = "\(line.name) (pid \(line.pid))"
        guard let start = line.startUs else {
            record(kind: kind, target: target, result: "refused", detail: "not identified", key: key)
            return set(key, .refused("This process is not identified yet."))
        }
        let identity = ProcessIdentity(pid: line.pid, startTimeMicroseconds: start)
        let force = force && asked.contains(identity)
        let outcome = session ? processes.endSession(identity, force: force) : processes.end(identity, force: force)
        switch outcome {
        case .done:
            record(kind: kind, target: target, result: force ? "kill_sent" : "term_sent", key: key)
            if force {
                asked.remove(identity)
                set(key, .done("Sent the kill signal."))
            } else {
                asked.insert(identity)
                set(key, .asked("Asked to end. Press again to force."))
                // A session's leader may go while a sidecar stays: only a single process is declared ended.
                if !session { settle(identity, key: key, kind: kind, target: target) }
            }
        case let .refused(reason):
            record(kind: kind, target: target, result: "refused", detail: reason, key: key)
            set(key, .refused(reason))
        case let .failed(reason):
            record(kind: kind, target: target, result: "failed", detail: reason, key: key)
            set(key, .failed(reason))
        }
    }

    /// After a polite request, say so when the process really went away.
    private func settle(_ identity: ProcessIdentity, key: String, kind: String, target: String) {
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard case .asked = model.actionStates[key], processes.isGone(identity) else { return }
            record(kind: kind, target: target, result: "not_running", key: key)
            asked.remove(identity)
            set(key, .done("No longer running."))
        }
    }

    private func quit(_ row: AppRow, force: Bool, key: String) {
        guard let bundleID = row.bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { row.pids.contains($0.processIdentifier) }),
              let start = model.processes[row.id]?.first(where: { $0.pid == app.processIdentifier })?.startUs else {
            record(kind: "quit_app", target: row.name, result: "refused", detail: "not identified", key: key)
            return set(key, .refused("This app is not identified yet."))
        }
        let identity = ProcessIdentity(pid: app.processIdentifier, startTimeMicroseconds: start)
        if let reason = processes.refusal(for: identity) {
            record(kind: "quit_app", target: row.name, result: "refused", detail: reason, key: key)
            return set(key, .refused(reason))
        }
        let force = force && asked.contains(identity)
        let sent = force ? app.forceTerminate() : app.terminate()
        record(kind: "quit_app", target: row.name, result: sent ? (force ? "force_quit" : "quit_requested") : "failed", key: key)
        guard sent else { return set(key, .failed("The app did not accept the request.")) }
        if !force { asked.insert(identity) }
        set(key, .working(force ? "Force quitting..." : "Quitting..."))
        Task {
            for _ in 0 ..< 20 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(500)) }
            if app.isTerminated { asked.remove(identity) }
            set(key, app.isTerminated ? .done("Quit.") : .asked("Still running. Press again to force quit."))
        }
    }

    // MARK: - Tidy

    private func scanTidy() {
        guard model.tidyState != .loading("Reading the process table...") else { return }
        model.tidyState = .loading("Reading the process table...")
        Task {
            switch await TidyScanner().scan() {
            case let .ok(scan, _, _):
                model.tidy = scan
                model.tidyState = .ready
            case let .unavailable(reason), let .failed(reason):
                model.tidy = nil
                model.tidyState = .failed(collector: "The process table", reason: reason)
            }
        }
    }

    /// The polite request, once for each listed process, each re-read and checked by `ProcessActions` first.
    private func endTidy(_ group: String, _ items: [TidyItem], key: String) {
        var sent = 0, refused = 0
        for item in items {
            let target = "\(item.name) (pid \(item.identity.pid))"
            switch processes.end(item.identity, force: false) {
            case .done:
                sent += 1
                record(kind: "end_process", target: target, result: "term_sent", detail: "tidy \(group)", key: key)
            case let .refused(reason):
                refused += 1
                record(kind: "end_process", target: target, result: "refused", detail: reason, key: key)
            case let .failed(reason):
                refused += 1
                record(kind: "end_process", target: target, result: "failed", detail: reason, key: key)
            }
        }
        set(key, refused == 0 ? .done("Asked \(sent) to end.") : sent == 0 ? .refused("None could be ended (\(refused) refused).")
            : .done("Asked \(sent) to end, \(refused) refused."))
        // What really went away shows in the rescan, not in this line; the press is offered again for what is left.
        Task {
            try? await Task.sleep(for: .seconds(3))
            model.actionStates[key] = nil
            scanTidy()
        }
    }

    // MARK: - Large folders

    private func scanLarge() {
        guard model.largeState != .loading("Measuring your home folder. This takes a few minutes...") else { return }
        guard let protected = protectedPaths() else {
            model.largeState = .failed(collector: "The settings file", reason: "It could not be read, so MacMax cannot tell what is protected.")
            return
        }
        model.largeState = .loading("Measuring your home folder. This takes a few minutes...")
        // Only a confirmed grant walks the protected places: unknown or denied leaves them alone, so macOS asks nothing.
        let skipPrivate = model.fullDiskAccess != .granted
        Task {
            switch await LargeItemScanner(userProtected: protected).scan(skipPrivate: skipPrivate) {
            case let .ok(scan, _, _):
                model.largeItems = scan.items
                model.largeIncomplete = scan.incomplete
                model.largeSkippedPrivate = scan.skippedPrivate
                model.largeState = .ready
            case let .unavailable(reason), let .failed(reason):
                model.largeState = .failed(collector: "The disk", reason: reason)
            }
        }
    }

    // MARK: - Permissions

    private func refreshPermissions() {
        Task {
            model.fullDiskAccess = await Task.detached { PermissionProbe.fullDiskAccess() }.value
            model.notifications = await SystemNotifications.current()
        }
    }

    private func requestNotifications() {
        Task {
            model.notifications = await SystemNotifications.request()
        }
    }

    // MARK: - Docker

    private func loadContainers() {
        guard let docker = Executables.resolve("docker") else {
            model.containersState = .failed(collector: "Docker", reason: "The docker command was not found.")
            return
        }
        model.containersState = .loading("Reading containers...")
        Task {
            let result = await ProcessCommandRunner().run(docker, ["ps", "--no-trunc", "--format", "{{.ID}}\t{{.Names}}"])
            guard result.status == 0 else {
                model.containersState = .failed(collector: "Docker", reason: "Docker did not answer. Is it running?")
                return
            }
            model.containers = result.output.split(whereSeparator: \.isNewline).compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return ContainerLine(id: parts[0], name: Redaction.sanitizeText(parts[1]))
            }
            model.containersState = .ready
        }
    }

    private func stop(_ container: ContainerLine, key: String) {
        guard let docker = Executables.resolve("docker") else {
            record(kind: "stop_container", target: container.name, result: "failed", detail: "docker not found", key: key)
            return set(key, .failed("The docker command was not found."))
        }
        set(key, .working("Stopping..."))
        Task {
            let outcome = await DockerActions(runner: ProcessCommandRunner(), docker: docker).stop(containerID: container.id)
            switch outcome {
            case .done:
                record(kind: "stop_container", target: container.name, result: "stopped", key: key)
                set(key, .done("Stopped."))
                loadContainers()
            case let .refused(reason):
                record(kind: "stop_container", target: container.name, result: "refused", detail: reason, key: key)
                set(key, .refused(reason))
            case let .failed(reason):
                record(kind: "stop_container", target: container.name, result: "failed", detail: reason, key: key)
                set(key, .failed(reason))
            }
        }
    }

    // MARK: - Cleanup

    /// Read from the live process table and the running apps each time it is asked, never from a snapshot.
    nonisolated static func running() -> Running? {
        guard let programs = RunningPrograms.names() else { return nil }
        let apps = NSWorkspace.shared.runningApplications
        return Running(names: programs.union(apps.compactMap(\.localizedName)),
                       bundleIDs: Set(apps.compactMap(\.bundleIdentifier)))
    }

    /// The user's protected folders as the file says now: a hand edit since launch counts. Nil when the file cannot be
    /// read, because then nothing is known about what is protected.
    private func protectedPaths() -> [String]? {
        guard case let .ok(config) = ConfigStore(home: MacMaxHome()).load() else { return nil }
        model.config.protectedPaths = config.protectedPaths
        return config.protectedPaths
    }

    private func scanCleanup() {
        guard model.cleanupState != .loading("Measuring caches...") else { return }
        guard let protected = protectedPaths() else {
            model.cleanupPreview = nil
            model.cleanupState = .failed(collector: "The settings file", reason: "It could not be read, so MacMax cannot tell what is protected and will not clean.")
            return
        }
        model.cleanupState = .loading("Measuring caches...")
        Task {
            let preview = await Task.detached(priority: .utility) { () -> CleanupPreview? in
                guard let running = Self.running() else { return nil }
                return CleanupScanner(home: FileManager.default.homeDirectoryForCurrentUser, userProtected: protected, running: running).scan()
            }.value
            guard let preview else {
                model.cleanupPreview = nil
                model.cleanupState = .failed(collector: "The process list", reason: "It could not be read, so MacMax cannot tell what is running and will not clean.")
                return
            }
            model.cleanupPreview = preview
            model.cleanupState = .ready
        }
    }

    private func moveToTrash(_ candidates: [CleanupCandidate]) {
        guard !model.cleanupMoving, !candidates.isEmpty else { return }
        guard let protected = protectedPaths() else {
            model.cleanupState = .failed(collector: "The settings file", reason: "It could not be read, so MacMax cannot tell what is protected and will not clean.")
            return
        }
        model.cleanupMoving = true
        model.cleanupProgress = (0, candidates.count, nil)
        model.cleanupLogProblem = nil
        Task {
            let results = await Task.detached(priority: .utility) { [model] in
                CleanupMover(home: FileManager.default.homeDirectoryForCurrentUser, userProtected: protected,
                             trasher: FileManagerTrasher(), running: { Self.running() })
                    .move(candidates) { done, total, next in
                        Task { @MainActor in model.cleanupProgress = (done, total, next) }
                    }
            }.value
            for (candidate, result) in zip(candidates, results) {
                switch result.outcome {
                case .done: record(kind: "cleanup", target: result.path, result: "trashed", detail: "\(candidate.ruleID), \(CompactFormat.bytes(UInt64(max(candidate.bytes, 0))))", key: Self.cleanupKey)
                case let .refused(reason): record(kind: "cleanup", target: result.path, result: "skipped", detail: reason, key: Self.cleanupKey)
                case let .failed(reason): record(kind: "cleanup", target: result.path, result: "failed", detail: reason, key: Self.cleanupKey)
                }
            }
            model.cleanupResults = results
            model.cleanupMovedFrom = candidates
            model.cleanupMoving = false
            model.cleanupProgress = nil
            scanCleanup()
            try? await Task.sleep(for: .milliseconds(300))
            loadLastCleanups()
        }
    }

    private func loadLastCleanups() {
        guard let database = database() else { return }
        Task { model.lastCleanups = (try? await database.recentActions(kind: "cleanup", limit: 20)) ?? [] }
    }
}
