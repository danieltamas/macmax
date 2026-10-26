import Darwin
import Foundation

/// The programs that keep running from inside an app's own bundle after its windows are closed (updaters, helper
/// daemons). An uninstall must end them first, or the app is refused as "running" with nothing the user can see.
public struct AppBackgroundProcesses: Sendable {
    public enum Outcome: Sendable, Equatable {
        case nothingRunning
        case stopped(Int)
        case failed(String)
    }

    private let probe: ProcessProbe
    private let actions: ProcessActions
    private let pids: @Sendable () -> [Int32]?
    private let ownUID: UInt32

    public init(probe: ProcessProbe, actions: ProcessActions, ownUID: UInt32, pids: @escaping @Sendable () -> [Int32]?) {
        self.probe = probe
        self.actions = actions
        self.ownUID = ownUID
        self.pids = pids
    }

    public static func system() -> AppBackgroundProcesses {
        AppBackgroundProcesses(probe: SystemProbe(), actions: .system(), ownUID: getuid(), pids: { Libproc.pids() })
    }

    /// The user's own processes whose program file lives inside `appPath`. nil when the process table cannot be read:
    /// "cannot tell" is not "nothing runs".
    public func find(in appPath: String) -> [LiveProcess]? {
        guard let all = pids() else { return nil }
        let prefix = appPath.hasSuffix("/") ? appPath : appPath + "/"
        return all.compactMap { probe.live(pid: $0) }.filter { $0.uid == ownUID && ($0.path?.hasPrefix(prefix) ?? false) }
    }

    /// Asks each to end (SIGTERM), gives them `grace` seconds, then forces what is left. The guards of ProcessActions
    /// apply to every one: a process that changed since it was listed is not touched.
    public func stop(in appPath: String, grace: TimeInterval = 3) -> Outcome {
        guard let found = find(in: appPath) else { return .failed("the running programs could not be read") }
        guard !found.isEmpty else { return .nothingRunning }
        var refusal: String?
        for process in found {
            if case let .refused(reason) = actions.end(process.identity, force: false) { refusal = refusal ?? reason }
        }
        let remaining = waitUntilGone(found.map(\.identity), for: grace)
        for identity in remaining {
            if case let .refused(reason) = actions.end(identity, force: true) { refusal = refusal ?? reason }
        }
        let stuck = waitUntilGone(remaining, for: 1)
        if !stuck.isEmpty {
            return .failed("\(stuck.count) program\(stuck.count == 1 ? "" : "s") would not stop" + (refusal.map { " (\($0))" } ?? ""))
        }
        return .stopped(found.count)
    }

    private func waitUntilGone(_ identities: [ProcessIdentity], for seconds: TimeInterval) -> [ProcessIdentity] {
        let deadline = Date().addingTimeInterval(seconds)
        var left = identities.filter { !actions.isGone($0) }
        while !left.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            left = left.filter { !actions.isGone($0) }
        }
        return left
    }
}
