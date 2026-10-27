import Foundation

/// Takes one live audit snapshot: samples the system and the processes for a few seconds (CPU needs intervals),
/// reads the network identity and the audit probes, and reduces them with `AuditSnapshotBuilder`.
public actor AuditRunner {
    private let database: Database?
    /// Why the history database could not be opened, when it exists but does not open.
    private let databaseProblem: String?
    private let ipCheckEnabled: Bool
    private let vpnShouldBeOn: @Sendable () -> Bool
    private let system = SystemCollector()
    private let processes = ProcessCollector()
    private let network: NetworkIdentityCollector
    private let probes = AuditProbes()
    /// Process samples to take, one second apart; the last three CPU values feed `translated_hot`.
    private let rounds = 3

    public init(database: Database?, databaseProblem: String? = nil, ipCheckEnabled: Bool, ipEndpoint: String? = nil,
                vpnShouldBeOn: @escaping @Sendable () -> Bool = { false }) {
        self.database = database
        self.databaseProblem = databaseProblem
        self.ipCheckEnabled = ipCheckEnabled
        network = NetworkIdentityCollector(client: ipEndpoint.map { IPEndpointClient(endpoint: $0) } ?? IPEndpointClient())
        self.vpnShouldBeOn = vpnShouldBeOn
    }

    public func collect(previous: AuditSnapshot?) async -> AuditSnapshot {
        _ = await system.collect()
        var latest = await processes.collect()
        var history: [ProcessIdentity: [Double]] = [:]
        var roundProblem: String?
        for _ in 0 ..< rounds {
            try? await Task.sleep(for: .seconds(1))
            latest = await processes.collect()
            // A round that failed leaves a gap in the CPU history that a later success must not paper over.
            if let problem = latest.problem, roundProblem == nil { roundProblem = problem }
            for process in latest.value ?? [] {
                if let cpu = process.cpuPercent.value { history[process.identity, default: []].append(cpu) }
            }
        }
        if let roundProblem { latest = .failed(reason: roundProblem) }
        let snapshot = await system.collect()
        let now = Date()
        async let identity = network.collect(checkEnabled: ipCheckEnabled)
        async let probed = probes.run(processes: latest, now: now)
        let inputs = await AuditInputs(
            now: now, system: snapshot, processes: latest, cpuHistory: history, identity: identity, probes: probed,
            previous: previous, footprintOneHourAgo: footprintsOneHourAgo(now: now), vpnShouldBeOn: vpnShouldBeOn())
        return AuditSnapshotBuilder.build(inputs)
    }

    private func footprintsOneHourAgo(now: Date) async -> Reading<[String: UInt64]> {
        guard let database else {
            return databaseProblem.map { .failed(reason: $0) } ?? .unavailable(reason: "no history database")
        }
        do {
            guard let footprints = try await database.appFootprints(near: Int64(now.timeIntervalSince1970) - 3_600,
                                                                    toleranceSeconds: 600) else {
                return .unavailable(reason: "no history from an hour ago")
            }
            return .ok(footprints, source: "history database", at: now)
        } catch {
            return .failed(reason: "the history database could not be read")
        }
    }
}
