import AppKit
import MacMaxCore
import SwiftUI

/// The shared release check and the one installer run. About and the panel header read the model; nothing else asks GitHub.
@MainActor
final class UpdateController {
    private static let endpoint = URL(string: "https://api.github.com/repos/danieltamas/macmax/releases/latest")!
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
        model.checkForUpdate = { [weak self] in self?.check() }
        model.installUpdate = { [weak self] in self?.install() }
    }

    /// At launch and every 24 hours; a "Check again" press goes through the same schedule, so it can never hammer GitHub.
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

    private func check() {
        let now = Date()
        guard !checking, schedule.mayCheck(at: now) else { return }
        checking = true
        schedule.recordAttempt(at: now)
        model.releaseCheck = .loading("Checking for updates...")
        Task {
            await fetch()
            checking = false
        }
    }

    private func fetch() async {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacMax/\(model.runningVersion)", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        do {
            let (data, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let http = response as? HTTPURLResponse else { return fail("The answer was not HTTP.") }
            switch http.statusCode {
            case 200:
                switch ReleaseParser.parse(data) {
                case let .ok(info, _, _):
                    schedule.recordSuccess(at: Date())
                    model.latestRelease = info
                    model.releaseCheck = .ready
                    announce(info)
                case let .unavailable(reason), let .failed(reason): fail(reason)
                }
            case 404:
                // No release published yet: the honest answer is "none", not a failure.
                schedule.recordSuccess(at: Date())
                model.latestRelease = nil
                model.releaseCheck = .ready
            case 403, 429:
                schedule.recordRateLimit(at: Date(), retryAfter: Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
                fail("GitHub asked MacMax to wait before checking again.")
            default: fail("GitHub answered \(http.statusCode).")
            }
        } catch {
            fail("GitHub could not be reached.")
        }
    }

    /// Retry-After is whole seconds or an HTTP date.
    private static func retryDelay(_ header: String?) -> TimeInterval? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = TimeInterval(text) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text).map { $0.timeIntervalSinceNow }
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
