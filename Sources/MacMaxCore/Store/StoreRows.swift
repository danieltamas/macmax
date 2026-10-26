import Foundation

/// A column that is nil was not readable (unavailable or failed); it is stored as NULL, never as zero.
public struct SystemSampleRow: Sendable, Equatable {
    public var ts: Int64
    public var cpuUser: Double?
    public var cpuSystem: Double?
    public var memUsed: Int64?
    public var memCompressed: Int64?
    public var swapUsed: Int64?
    public var swapinsPerSecond: Double?
    public var pressureLevel: Int?
    public var diskFree: Int64?
    public var diskReadBps: Double?
    public var diskWriteBps: Double?
    public var netInBps: Double?
    public var netOutBps: Double?
    public var thermal: Int?

    public init(ts: Int64, cpuUser: Double? = nil, cpuSystem: Double? = nil, memUsed: Int64? = nil,
                memCompressed: Int64? = nil, swapUsed: Int64? = nil, swapinsPerSecond: Double? = nil,
                pressureLevel: Int? = nil, diskFree: Int64? = nil, diskReadBps: Double? = nil,
                diskWriteBps: Double? = nil, netInBps: Double? = nil, netOutBps: Double? = nil, thermal: Int? = nil) {
        self.ts = ts
        self.cpuUser = cpuUser
        self.cpuSystem = cpuSystem
        self.memUsed = memUsed
        self.memCompressed = memCompressed
        self.swapUsed = swapUsed
        self.swapinsPerSecond = swapinsPerSecond
        self.pressureLevel = pressureLevel
        self.diskFree = diskFree
        self.diskReadBps = diskReadBps
        self.diskWriteBps = diskWriteBps
        self.netInBps = netInBps
        self.netOutBps = netOutBps
        self.thermal = thermal
    }
}

public struct AppSampleRow: Sendable, Equatable {
    public var ts: Int64
    public var appKey: String
    public var cpu: Double?
    public var footprint: Int64?
    public var diskReadBps: Double?
    public var diskWriteBps: Double?
    /// Bytes during this tick's interval, so a rollup sums them.
    public var netInBytes: Int64?
    public var netOutBytes: Int64?
    public var procs: Int

    public init(ts: Int64, appKey: String, cpu: Double? = nil, footprint: Int64? = nil, diskReadBps: Double? = nil,
                diskWriteBps: Double? = nil, netInBytes: Int64? = nil, netOutBytes: Int64? = nil, procs: Int = 1) {
        self.ts = ts
        self.appKey = appKey
        self.cpu = cpu
        self.footprint = footprint
        self.diskReadBps = diskReadBps
        self.diskWriteBps = diskWriteBps
        self.netInBytes = netInBytes
        self.netOutBytes = netOutBytes
        self.procs = procs
    }
}

public struct ProcSampleRow: Sendable, Equatable {
    public var ts: Int64
    public var pid: Int32
    public var startUs: Int64
    public var appKey: String
    public var name: String
    public var cpu: Double?
    public var footprint: Int64?

    public init(ts: Int64, pid: Int32, startUs: Int64, appKey: String, name: String, cpu: Double? = nil,
                footprint: Int64? = nil) {
        self.ts = ts
        self.pid = pid
        self.startUs = startUs
        self.appKey = appKey
        self.name = name
        self.cpu = cpu
        self.footprint = footprint
    }
}

public struct AppInfo: Sendable, Equatable {
    public var appKey: String
    public var name: String
    public var bundleID: String?
    public var path: String?
    public var firstSeen: Int64

    public init(appKey: String, name: String, bundleID: String? = nil, path: String? = nil, firstSeen: Int64) {
        self.appKey = appKey
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.firstSeen = firstSeen
    }
}

/// Everything one sampler tick writes, in one transaction.
public struct TickRows: Sendable, Equatable {
    public var system: SystemSampleRow
    public var apps: [AppSampleRow]
    public var processes: [ProcSampleRow]
    public var appInfo: [AppInfo]
    /// Per-interface rates of this tick for the panel; they are not stored (the system row holds their sum).
    public var interfaces: [InterfaceRate]

    public init(system: SystemSampleRow, apps: [AppSampleRow] = [], processes: [ProcSampleRow] = [], appInfo: [AppInfo] = [],
                interfaces: [InterfaceRate] = []) {
        self.interfaces = interfaces
        self.system = system
        self.apps = apps
        self.processes = processes
        self.appInfo = appInfo
    }
}

public struct IdentityRow: Sendable, Equatable {
    public var ts: Int64
    public var publicIP: String?
    public var publicCC: String?
    public var ispIP: String?
    public var ispCC: String?
    public var vpnService: String?
    public var vpnState: String?
    public var routeTunnel: Bool?
    public var verdict: String

    public init(ts: Int64, publicIP: String? = nil, publicCC: String? = nil, ispIP: String? = nil, ispCC: String? = nil,
                vpnService: String? = nil, vpnState: String? = nil, routeTunnel: Bool? = nil, verdict: String) {
        self.ts = ts
        self.publicIP = publicIP
        self.publicCC = publicCC
        self.ispIP = ispIP
        self.ispCC = ispCC
        self.vpnService = vpnService
        self.vpnState = vpnState
        self.routeTunnel = routeTunnel
        self.verdict = verdict
    }
}
