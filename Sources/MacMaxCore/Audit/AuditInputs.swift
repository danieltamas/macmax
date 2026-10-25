import Foundation

/// What the audit-time probes found: things the per-tick collectors do not read.
public struct AuditProbeResults: Sendable {
    public var zombies: Reading<Int>
    public var kernelTaskCPU: Reading<Double>
    /// fseventsd, WindowServer, Finder and mds_stores resident MB.
    public var daemonResidentMB: Reading<[NamedValue]>
    public var dockerVMCompressedGB: Reading<Double>
    public var containerCPU: Reading<[NamedValue]>
    public var crashReports7d: Reading<Int>
    public var jetsam7d: Reading<Int>
    public var launchItems: Reading<Int>
    public var appleSilicon: Reading<Bool>
    public var brew: Reading<BrewInstalls>

    public init(zombies: Reading<Int>, kernelTaskCPU: Reading<Double>, daemonResidentMB: Reading<[NamedValue]>,
                dockerVMCompressedGB: Reading<Double>, containerCPU: Reading<[NamedValue]>,
                crashReports7d: Reading<Int>, jetsam7d: Reading<Int>, launchItems: Reading<Int>,
                appleSilicon: Reading<Bool>, brew: Reading<BrewInstalls>) {
        self.zombies = zombies
        self.kernelTaskCPU = kernelTaskCPU
        self.daemonResidentMB = daemonResidentMB
        self.dockerVMCompressedGB = dockerVMCompressedGB
        self.containerCPU = containerCPU
        self.crashReports7d = crashReports7d
        self.jetsam7d = jetsam7d
        self.launchItems = launchItems
        self.appleSilicon = appleSilicon
        self.brew = brew
    }
}

/// Everything `AuditSnapshotBuilder` turns into an `AuditSnapshot`.
public struct AuditInputs: Sendable {
    public var now: Date
    public var system: SystemSnapshot
    public var processes: Reading<[ProcessSample]>
    /// The last CPU percents per process, oldest first; only translated processes are read.
    public var cpuHistory: [ProcessIdentity: [Double]]
    /// Nil when the identity collector did not run.
    public var identity: NetworkIdentity?
    public var probes: AuditProbeResults
    /// The previous stored audit's snapshot, nil for the first audit.
    public var previous: AuditSnapshot?
    /// Footprint per app key one hour ago, from the store.
    public var footprintOneHourAgo: Reading<[String: UInt64]>
    public var vpnShouldBeOn: Bool

    public init(now: Date, system: SystemSnapshot, processes: Reading<[ProcessSample]>,
                cpuHistory: [ProcessIdentity: [Double]], identity: NetworkIdentity?, probes: AuditProbeResults,
                previous: AuditSnapshot?, footprintOneHourAgo: Reading<[String: UInt64]>, vpnShouldBeOn: Bool) {
        self.now = now
        self.system = system
        self.processes = processes
        self.cpuHistory = cpuHistory
        self.identity = identity
        self.probes = probes
        self.previous = previous
        self.footprintOneHourAgo = footprintOneHourAgo
        self.vpnShouldBeOn = vpnShouldBeOn
    }
}

