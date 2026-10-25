import Foundation

/// A process is (pid, start time), never pid alone: the kernel reuses pids.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    /// Start time as microseconds since the epoch (`pbi_start_tvsec` and `pbi_start_tvusec`).
    public let startTimeMicroseconds: Int64

    public init(pid: Int32, startTimeMicroseconds: Int64) {
        self.pid = pid
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

/// The app a process belongs to. `id` is the bundle id when known, else the executable path,
/// else the process name; `name` is what the UI shows.
public struct AppKey: Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One process at one tick. Fields that the kernel denies for another user's process are
/// `unavailable` (never zero, never `failed`); `failed` is for a read that should have worked.
public struct ProcessSample: Sendable {
    public let identity: ProcessIdentity
    public let parentPid: Int32
    public let uid: UInt32
    /// Control characters, terminal escapes and invisible Unicode removed.
    public let name: String
    public let path: Reading<String>
    /// `ri_phys_footprint`: the number Activity Monitor shows as Memory.
    public let footprintBytes: Reading<UInt64>
    /// Percent of one core over the interval since the previous `collect()`; above 100 on several cores.
    public let cpuPercent: Reading<Double>
    /// Cumulative bytes since the process started.
    public let diskReadBytes: Reading<UInt64>
    public let diskWriteBytes: Reading<UInt64>
    public let isTranslated: Reading<Bool>
    public let cwd: Reading<String>
    /// Controlling terminal device name; `unavailable` for a process without one.
    public let tty: Reading<String>
    /// Command line after `Redaction`; the environment is never read.
    public let argv: Reading<[String]>

    public init(identity: ProcessIdentity, parentPid: Int32, uid: UInt32, name: String, path: Reading<String>,
                footprintBytes: Reading<UInt64>, cpuPercent: Reading<Double>, diskReadBytes: Reading<UInt64>,
                diskWriteBytes: Reading<UInt64>, isTranslated: Reading<Bool>, cwd: Reading<String>,
                tty: Reading<String>, argv: Reading<[String]>) {
        self.identity = identity
        self.parentPid = parentPid
        self.uid = uid
        self.name = name
        self.path = path
        self.footprintBytes = footprintBytes
        self.cpuPercent = cpuPercent
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.isTranslated = isTranslated
        self.cwd = cwd
        self.tty = tty
        self.argv = argv
    }
}

/// The columns app grouping needs; a pure input so grouping is testable on fixtures.
public struct ProcessRow: Sendable, Equatable {
    public let pid: Int32
    public let parentPid: Int32
    public let path: String?
    public let name: String

    public init(pid: Int32, parentPid: Int32, path: String?, name: String) {
        self.pid = pid
        self.parentPid = parentPid
        self.path = path
        self.name = name
    }
}

extension ProcessSample {
    /// True when any per-process reading is `failed` (not merely `unavailable`).
    public var hasFailedField: Bool {
        func failed<T>(_ reading: Reading<T>) -> Bool { if case .failed = reading { return true } else { return false } }
        return failed(path) || failed(footprintBytes) || failed(cpuPercent) || failed(diskReadBytes)
            || failed(diskWriteBytes) || failed(isTranslated) || failed(cwd) || failed(tty) || failed(argv)
    }
}
