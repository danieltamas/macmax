import Foundation

/// Cumulative or per-interval bytes, in and out.
public struct NetworkCounters: Sendable, Equatable {
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(bytesIn: UInt64, bytesOut: UInt64) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// One interface's traffic rate over the last interval.
public struct InterfaceRate: Sendable, Equatable {
    public let name: String
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double

    public init(name: String, bytesInPerSecond: Double, bytesOutPerSecond: Double) {
        self.name = name
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
    }
}

/// One tick of network readings.
public struct NetworkSnapshot: Sendable {
    /// Bytes in and out during the last interval, per process; each process has its own `Reading`.
    public let processes: Reading<[ProcessIdentity: Reading<NetworkCounters>]>
    /// nettop rows that did not parse. They are skipped and counted, never read as zero traffic.
    public let skippedRows: Int
    /// Per interface (loopback excluded), from the kernel's 64-bit interface counters, so traffic of
    /// processes that ended between ticks still shows.
    public let interfaces: Reading<[InterfaceRate]>

    /// What a collection that was queued when the collector stopped returns.
    static let stopped = NetworkSnapshot(processes: .failed(reason: "the network collector was stopped"), skippedRows: 0,
                                         interfaces: .failed(reason: "the network collector was stopped"))

    public init(processes: Reading<[ProcessIdentity: Reading<NetworkCounters>]>, skippedRows: Int,
                interfaces: Reading<[InterfaceRate]>) {
        self.processes = processes
        self.skippedRows = skippedRows
        self.interfaces = interfaces
    }
}

/// One socket of one process, read on demand.
public struct NetworkConnection: Sendable, Equatable {
    public let transport: String
    public let localAddress: String
    public let localPort: Int
    /// nil for a listening socket.
    public let remoteAddress: String?
    public let remotePort: Int?
    public let interface: String
    public let state: String

    public init(transport: String, localAddress: String, localPort: Int, remoteAddress: String?, remotePort: Int?,
                interface: String, state: String) {
        self.transport = transport
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.interface = interface
        self.state = state
    }
}
