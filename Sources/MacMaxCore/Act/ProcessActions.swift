import Darwin
import Foundation

public enum ActionOutcome: Sendable, Equatable {
    case done
    /// A guard said no and nothing was changed.
    case refused(String)
    /// The action was tried and the system answered with an error.
    case failed(String)
}

/// A process as it is right now, read at the moment of the action.
public struct LiveProcess: Sendable, Equatable {
    public let identity: ProcessIdentity
    public let uid: UInt32
    public let path: String?
    public let processGroup: Int32?

    public init(identity: ProcessIdentity, uid: UInt32, path: String?, processGroup: Int32?) {
        self.identity = identity
        self.uid = uid
        self.path = path
        self.processGroup = processGroup
    }
}

public protocol ProcessProbe: Sendable {
    /// nil when the process is gone or cannot be read: both refuse the action.
    func live(pid: Int32) -> LiveProcess?
}

public protocol Signaller: Sendable {
    /// 0 when sent, else the errno.
    func send(_ signal: Int32, toPid: Int32) -> Int32
    func send(_ signal: Int32, toGroup: Int32) -> Int32
}

/// End a process or a session. Every guard fails closed: a state that cannot be read is a refusal.
public struct ProcessActions: Sendable {
    private let probe: ProcessProbe
    private let signaller: Signaller
    private let currentUID: UInt32
    private let ownPid: Int32
    private let ownGroup: Int32

    /// Programs under these prefixes belong to the system.
    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/sbin/"]

    public init(probe: ProcessProbe, signaller: Signaller, currentUID: UInt32, ownPid: Int32, ownGroup: Int32) {
        self.probe = probe
        self.signaller = signaller
        self.currentUID = currentUID
        self.ownPid = ownPid
        self.ownGroup = ownGroup
    }

    /// The live system: the real process table and `kill`.
    public static func system() -> ProcessActions {
        ProcessActions(probe: SystemProbe(), signaller: SystemSignaller(), currentUID: getuid(),
                       ownPid: getpid(), ownGroup: getpgrp())
    }

    /// Why `expected` may not be ended now, or nil when every guard passes. The app asks this before a graceful quit.
    public func refusal(for expected: ProcessIdentity) -> String? {
        if case let .refused(reason) = checked(expected) { return reason }
        return nil
    }

    /// True only when the kernel says there is no such process (signal 0 answers ESRCH). Anything unclear, a reused
    /// pid included, is "not known to be gone".
    public func isGone(_ expected: ProcessIdentity) -> Bool {
        signaller.send(0, toPid: expected.pid) == ESRCH
    }

    /// SIGTERM, or SIGKILL when `force`, after re-reading the process and finding it the one the user saw.
    public func end(_ expected: ProcessIdentity, force: Bool) -> ActionOutcome {
        switch checked(expected) {
        case let .refused(reason): return .refused(reason)
        case .allowed:
            return outcome(signaller.send(force ? SIGKILL : SIGTERM, toPid: expected.pid))
        }
    }

    /// The same guards, then the signal goes to the session's process group so its sidecars end with it.
    public func endSession(_ expected: ProcessIdentity, force: Bool) -> ActionOutcome {
        let process: LiveProcess
        switch checked(expected) {
        case let .refused(reason): return .refused(reason)
        case let .allowed(live): process = live
        }
        guard let group = process.processGroup, group > 1 else { return .refused("the process group is unknown or a system group") }
        guard group != ownGroup else { return .refused("that is MacMax's own process group") }
        return outcome(signaller.send(force ? SIGKILL : SIGTERM, toGroup: group))
    }

    private enum Check {
        case allowed(LiveProcess)
        case refused(String)
    }

    private func checked(_ expected: ProcessIdentity) -> Check {
        guard let live = probe.live(pid: expected.pid) else { return .refused("the process is gone or cannot be read") }
        guard live.identity == expected else { return .refused("the process changed since it was listed") }
        guard live.uid == currentUID else { return .refused("the process belongs to another user") }
        guard expected.pid >= 100 else { return .refused("system processes cannot be ended") }
        guard expected.pid != ownPid else { return .refused("MacMax will not end itself") }
        guard let path = live.path else { return .refused("the program path is unknown") }
        guard !Self.systemPrefixes.contains(where: path.hasPrefix) else { return .refused("system processes cannot be ended") }
        return .allowed(live)
    }

    private func outcome(_ code: Int32) -> ActionOutcome {
        code == 0 ? .done : .failed("the signal failed (error \(code))")
    }
}

struct SystemProbe: ProcessProbe {
    func live(pid: Int32) -> LiveProcess? {
        guard case let .found(kernel) = Libproc.kernel(pid) else { return nil }
        let path: String?
        if case let .ok(value, _, _) = Libproc.path(pid, at: Date()) { path = value } else { path = nil }
        let group = getpgid(pid)
        return LiveProcess(identity: kernel.identity, uid: kernel.uid, path: path, processGroup: group > 0 ? group : nil)
    }
}

struct SystemSignaller: Signaller {
    func send(_ signal: Int32, toPid pid: Int32) -> Int32 { kill(pid, signal) == 0 ? 0 : errno }
    func send(_ signal: Int32, toGroup group: Int32) -> Int32 { killpg(group, signal) == 0 ? 0 : errno }
}
