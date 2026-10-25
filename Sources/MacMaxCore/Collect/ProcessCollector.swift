import Darwin
import Foundation

/// Reads every process the user can see. CPU % needs two samples, so the first `collect()`
/// reports `cpuPercent` as `unavailable`.
public actor ProcessCollector {
    /// What is read once per (pid, start time) and kept while the process lives, and re-read after an `exec`.
    /// The working directory is read once too: re-reading it every tick would cost a syscall per process.
    private struct Fixed {
        /// `p_comm` when this was read: an `exec` changes it, which invalidates path and argv.
        let command: String
        let name: String
        let path: Reading<String>
        let argv: Reading<[String]>
        let cwd: Reading<String>
        let tty: Reading<String>
        let isTranslated: Reading<Bool>

        var hasFailure: Bool {
            func failed<T>(_ reading: Reading<T>) -> Bool { if case .failed = reading { return true } else { return false } }
            return failed(path) || failed(argv) || failed(cwd)
        }
    }

    private var fixed: [ProcessIdentity: Fixed] = [:]
    private var previousCPU: [ProcessIdentity: (nanoseconds: UInt64, uptime: UInt64)] = [:]
    private var hasCollected = false

    public init() {}

    public func collect() async -> Reading<[ProcessSample]> {
        guard let pids = Libproc.pids() else { return .failed(reason: "proc_listallpids failed") }
        let now = Date()
        var samples: [ProcessSample] = []
        var seen: [ProcessIdentity: (nanoseconds: UInt64, uptime: UInt64)] = [:]
        for pid in pids {
            let kernel: Libproc.Kernel
            switch Libproc.kernel(pid) {
            case let .found(found): kernel = found
            case .gone: continue
            case let .failed(code):
                fixed = [:]
                return .failed(reason: "sysctl KERN_PROC_PID failed for pid \(pid) (errno \(code))")
            }
            let identity = kernel.identity
            var details = fixed[identity]
            if details?.command != kernel.command {
                details = readFixed(pid, kernel, at: now)
                // The pid may have been reused while its details were read; those details would be the new process's.
                guard case let .found(again) = Libproc.kernel(pid), again.identity == identity else { continue }
            }
            guard let details else { continue }
            // A failed read is retried next tick; only readings that settled are kept.
            fixed[identity] = details.hasFailure ? nil : details
            let usage = Libproc.usage(pid, at: now)
            // Stamped right after the read: a snapshot of 1,000 processes takes long enough to skew a shared stamp.
            let uptime = DispatchTime.now().uptimeNanoseconds
            if let cpu = usage.value?.cpuNanoseconds { seen[identity] = (cpu, uptime) }
            let sample = ProcessSample(
                identity: identity, parentPid: kernel.parentPid, uid: kernel.uid, name: details.name,
                path: details.path, footprintBytes: usage.map(\.footprintBytes),
                cpuPercent: cpuPercent(identity, usage, uptime: uptime, at: now),
                diskReadBytes: usage.map(\.diskReadBytes), diskWriteBytes: usage.map(\.diskWriteBytes),
                isTranslated: details.isTranslated, cwd: details.cwd, tty: details.tty, argv: details.argv)
            // A read that failed on a process that has since ended is a race, not a defect: leave it out.
            if sample.hasFailedField, !Self.isStillRunning(identity) { continue }
            samples.append(sample)
        }
        // Only processes seen this tick are kept, so a reused pid never inherits a dead process's state.
        let alive = Set(samples.map(\.identity))
        fixed = fixed.filter { alive.contains($0.key) }
        previousCPU = seen
        hasCollected = true
        return .ok(samples, source: "libproc", at: now)
    }

    private static func isStillRunning(_ identity: ProcessIdentity) -> Bool {
        switch Libproc.kernel(identity.pid) {
        case let .found(kernel): kernel.identity == identity
        case .gone: false
        // Unknown is not "gone": keep the sample and its failed field visible.
        case .failed: true
        }
    }

    private func readFixed(_ pid: Int32, _ kernel: Libproc.Kernel, at: Date) -> Fixed {
        let path = Libproc.path(pid, at: at)
        let name = path.value.map { URL(fileURLWithPath: $0).lastPathComponent } ?? kernel.command
        let argv = Libproc.argv(pid, at: at).map { Redaction.redact($0.map(Redaction.sanitizeText)) }
        return Fixed(command: kernel.command, name: Redaction.sanitizeText(name), path: path.map(Redaction.sanitizeText), argv: argv,
                     cwd: Libproc.cwd(pid, at: at).map(Redaction.sanitizeText), tty: Libproc.tty(kernel, at: at),
                     isTranslated: Libproc.isTranslated(kernel, at: at))
    }

    private func cpuPercent(_ identity: ProcessIdentity, _ usage: Reading<Libproc.Usage>, uptime: UInt64,
                            at: Date) -> Reading<Double> {
        guard let current = usage.value else { return usage.map { _ in 0 } }
        guard hasCollected else { return .unavailable(reason: "needs a second sample to compute a rate") }
        guard let before = previousCPU[identity] else {
            return .unavailable(reason: "this process appeared since the last sample")
        }
        guard uptime > before.uptime, current.cpuNanoseconds >= before.nanoseconds else {
            return .failed(reason: "the CPU time counter went backwards or the clock did not advance")
        }
        let percent = Double(current.cpuNanoseconds - before.nanoseconds) / Double(uptime - before.uptime) * 100
        return .ok(percent, source: "proc_pid_rusage", at: at)
    }
}
