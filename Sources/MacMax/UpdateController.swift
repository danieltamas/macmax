import AppKit
import MacMaxCore
import SwiftUI

/// The shared release check and the one installer run. About and the panel header read the model; nothing else asks GitHub.
@MainActor
final class UpdateController {
    private static let repo = "danieltamas/macmax"
    private static let notifiedKey = "updateNotifiedVersion"

    private let model: PanelModel
    private let home: MacMaxHome
    private var schedule = ReleaseCheckSchedule(now: Date())
    private var checking = false
    private var loop: Task<Void, Never>?
    private lazy var coordinator: UpdateCoordinator = {
        let stopped: @Sendable (String) -> Void = { [weak self] reason in
            Task { @MainActor in await self?.installerStopped(reason: reason) }
        }
        let root = Self.installRoot()
        let home = home
        return UpdateCoordinator { version in
            try Self.launchInstaller(version: version, home: home, root: root, stopped: stopped)
        }
    }()

    init(model: PanelModel, home: MacMaxHome) {
        self.model = model
        self.home = home
        model.checkForUpdate = { [weak self] in self?.check(byPress: true) }
        model.installUpdate = { [weak self] in self?.install() }
    }

    /// At launch and every 24 hours; a "Check again" press skips the 15-minute floor but still waits out a GitHub pause.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.schedule.nextAutomatic <= Date() { self.check() }
                try? await Task.sleep(for: .seconds(900))
            }
        }
    }

    private func check(byPress: Bool = false) {
        let now = Date()
        guard !checking else { return }
        guard byPress ? schedule.mayCheckByPress(at: now) : schedule.mayCheck(at: now) else {
            if byPress { fail("GitHub asked MacMax to wait before checking again.") }
            return
        }
        checking = true
        schedule.recordAttempt(at: now)
        model.releaseCheck = .loading("Checking for updates...")
        Task {
            await fetch()
            checking = false
        }
    }

    private func fetch() async {
        switch await GitHubReleases.latest(repo: Self.repo, userAgent: "MacMax/\(model.runningVersion)") {
        case let .release(info):
            schedule.recordSuccess(at: Date())
            model.latestRelease = info
            model.releaseCheck = .ready
            announce(info)
        case .none:
            // No release published yet: the honest answer is "none", not a failure.
            schedule.recordSuccess(at: Date())
            model.latestRelease = nil
            model.releaseCheck = .ready
        case let .rateLimited(retryAfter):
            schedule.recordRateLimit(at: Date(), retryAfter: retryAfter)
            fail("GitHub asked MacMax to wait before checking again.")
        case let .failed(reason): fail(reason)
        }
    }

    /// A failed check is not "still the same release": no update is offered from the earlier answer.
    private func fail(_ reason: String) {
        model.latestRelease = nil
        model.releaseCheck = .failed(collector: "The release check", reason: reason)
    }

    /// One notification per new version, however often it is checked.
    private func announce(_ info: ReleaseInfo) {
        guard model.standing == .behind, UserDefaults.standard.string(forKey: Self.notifiedKey) != info.version else { return }
        UserDefaults.standard.set(info.version, forKey: Self.notifiedKey)
        Task { await SystemNotifications.post(title: "MacMax \(info.version) is available", body: "Open About to update.") }
    }

    private func install() {
        guard let version = model.updateVersion else { return }
        model.updateState = .updating(version)
        Task { model.updateState = await coordinator.start(version: version) }
    }

    /// The bundled installer, outliving this app: it stops MacMax, swaps the copy and opens the new one.
    private func installerStopped(reason: String) async {
        model.updateState = await coordinator.installerStopped(reason: reason)
    }

    /// The folder holding the running copy, which the installer replaces.
    private static func installRoot() -> String {
        URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().path
    }

    private nonisolated static func launchInstaller(
        version: String, home: MacMaxHome, root: String, stopped: @escaping @Sendable (String) -> Void
    ) throws {
        guard let script = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            throw UpdateLog.Failure(reason: "The installer is not part of this build.")
        }
        try home.prepare()
        let descriptor = try UpdateLog.open(at: home.url.appendingPathComponent("update.log"))
        let log = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = [
            "MACMAX_VERSION": version, "MACMAX_INSTALL_ROOT": root, "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        // A successful install quits this app, so reaching here with the installer gone means it failed.
        process.terminationHandler = { _ in
            stopped(lastLogLine(home: home) ?? "The installer stopped without saying why.")
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
    }

    /// Why the last update did not finish, from the log.
    nonisolated static func lastLogLine(home: MacMaxHome) -> String? {
        let url = home.url.appendingPathComponent("update.log")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UpdateLog.lastLine(of: String(decoding: data.suffix(4_000), as: UTF8.self))
    }
}
