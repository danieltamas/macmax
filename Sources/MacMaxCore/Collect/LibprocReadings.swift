import Darwin
import Foundation

/// The per-process reads behind `ProcessCollector`. A read the kernel denies for another user's
/// process is `unavailable`; a process that ended mid-read is `unavailable` too; anything else
/// that should have worked is `failed`.
enum Libproc {
    static func pids() -> [Int32]? {
        var capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return nil }
        // Processes can start between the two calls; a full buffer may be a truncated list, so grow and retry.
        for _ in 0 ..< 4 {
            capacity = capacity * 2 + 64
            var buffer = [Int32](repeating: 0, count: capacity)
            let count = Int(proc_listallpids(&buffer, Int32(capacity * MemoryLayout<Int32>.size)))
            guard count > 0 else { return nil }
            if count < capacity { return buffer.prefix(count).filter { $0 > 0 } }
        }
        return nil
    }

    /// What `sysctl KERN_PROC_PID` says about a process. Unlike `proc_pidinfo(PROC_PIDTBSDINFO)` it
    /// answers for root-owned processes too, so launchd is in the list.
    struct Kernel: Sendable {
        let identity: ProcessIdentity
        let parentPid: Int32
        let uid: UInt32
        let command: String
        let flags: Int32
        /// `e_tdev`: -1 (NODEV) when there is no controlling terminal.
        let terminalDevice: Int32
    }

    enum KernelLookup: Sendable {
        case found(Kernel)
        /// The process ended between listing and reading: left out of the snapshot.
        case gone
        case failed(errno: Int32)
    }

    static func kernel(_ pid: Int32) -> KernelLookup {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        errno = 0
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return errno == ESRCH || errno == ENOENT ? .gone : .failed(errno: errno) }
        // A pid that does not exist answers with success and no data.
        if size == 0 || info.kp_proc.p_pid != pid { return size == 0 ? .gone : .failed(errno: EINVAL) }
        guard size == MemoryLayout<kinfo_proc>.size else { return .failed(errno: EINVAL) }
        let start = info.kp_proc.p_starttime
        let command = withUnsafeBytes(of: info.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let terminal = info.kp_eproc.e_tdev
        return .found(Kernel(
            identity: ProcessIdentity(pid: pid, startTimeMicroseconds: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)),
            parentPid: info.kp_eproc.e_ppid, uid: info.kp_eproc.e_ucred.cr_uid, command: command,
            flags: info.kp_proc.p_flag, terminalDevice: terminal))
    }

    /// The controlling terminal's device name (`ttys003`), or `unavailable` for a process without one.
    static func tty(_ kernel: Kernel, at: Date) -> Reading<String> {
        guard kernel.terminalDevice != -1, let name = devname(kernel.terminalDevice, S_IFCHR) else {
            return .unavailable(reason: "this process has no controlling terminal")
        }
        return .ok(String(cString: name), source: "sysctl KERN_PROC_PID", at: at)
    }

    /// `P_TRANSLATED` in `p_flag`: set for a process running under Rosetta.
    static func isTranslated(_ kernel: Kernel, at: Date) -> Reading<Bool> {
        .ok(kernel.flags & 0x0002_0000 != 0, source: "sysctl KERN_PROC_PID", at: at)
    }

    static func path(_ pid: Int32, at: Date) -> Reading<String> {
        read("path", source: "proc_pidpath", at: at) {
            var buffer = [CChar](repeating: 0, count: 4096)
            return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(nulTerminated: buffer) : nil
        }
    }

    static func cwd(_ pid: Int32, at: Date) -> Reading<String> {
        read("working directory", source: "proc_pidinfo", at: at) {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
            let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return path.isEmpty ? nil : path
        }
    }

    struct Usage: Sendable {
        let footprintBytes: UInt64
        /// User plus system CPU time in nanoseconds.
        let cpuNanoseconds: UInt64
        let diskReadBytes: UInt64
        let diskWriteBytes: UInt64
    }

    /// `ri_user_time` and `ri_system_time` count Mach absolute-time ticks, not nanoseconds: on Apple
    /// silicon the timebase is not 1:1.
    static func usage(_ pid: Int32, at: Date) -> Reading<Usage> {
        read("resource usage", source: "proc_pid_rusage", at: at) {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            // Some libproc calls return the error code instead of setting errno.
            if status > 0 { errno = status }
            guard status == 0 else { return nil }
            return Usage(footprintBytes: info.ri_phys_footprint,
                         cpuNanoseconds: toNanoseconds(info.ri_user_time) &+ toNanoseconds(info.ri_system_time),
                         diskReadBytes: info.ri_diskio_bytesread, diskWriteBytes: info.ri_diskio_byteswritten)
        }
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? mach_timebase_info_data_t(numer: 1, denom: 1) : info
    }()

    private static func toNanoseconds(_ ticks: UInt64) -> UInt64 {
        let (high, low) = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        return UInt64(timebase.denom).dividingFullWidth((high, low)).quotient
    }

    /// The argument vector from `KERN_PROCARGS2`: argc, the executable path, padding, then argc
    /// strings. The environment that follows is never read.
    static func argv(_ pid: Int32, at: Date) -> Reading<[String]> {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return failure("arguments", source: "sysctl KERN_PROCARGS2") }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return failure("arguments", source: "sysctl KERN_PROCARGS2") }
        guard let arguments = parseProcArgs(buffer.prefix(size)) else {
            return .failed(reason: "the argument vector is cut off or not understood")
        }
        return .ok(arguments, source: "sysctl KERN_PROCARGS2", at: at)
    }

    static func parseProcArgs(_ bytes: ArraySlice<UInt8>) -> [String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.prefix(4).enumerated().reduce(Int32(0)) { $0 | Int32($1.element) << (8 * Int32($1.offset)) }
        guard argc >= 0 else { return nil }
        var rest = bytes.dropFirst(4)
        rest = rest.drop(while: { $0 != 0 })   // the executable path
        rest = rest.drop(while: { $0 == 0 })   // its padding
        var result: [String] = []
        while result.count < Int(argc) {
            guard !rest.isEmpty, let end = rest.firstIndex(of: 0) else { return nil }
            result.append(String(decoding: rest[rest.startIndex ..< end], as: UTF8.self))
            rest = rest[(end + 1)...]
        }
        return result
    }

    // MARK: Errno to reading

    private static func read<T: Sendable>(_ what: String, source: String, at: Date, _ body: () -> T?) -> Reading<T> {
        errno = 0
        if let value = body() { return .ok(value, source: source, at: at) }
        return failure(what, source: source)
    }

    private static func failure<T: Sendable>(_ what: String, source: String) -> Reading<T> {
        switch errno {
        case ENOENT: .unavailable(reason: "the process or its executable disappeared while the \(what) was read")
        case EPERM, EACCES: .unavailable(reason: "the system does not allow reading the \(what) of this process")
        case ESRCH: .unavailable(reason: "the process ended before its \(what) was read")
        case EINVAL where what == "arguments": .unavailable(reason: "the system does not publish the arguments of this process")
        default: .failed(reason: "\(source) failed for the \(what) (errno \(errno))")
        }
    }
}
