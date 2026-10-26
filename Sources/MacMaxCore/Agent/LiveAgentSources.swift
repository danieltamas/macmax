import Foundation

/// The collectors behind the CLI and `macmax mcp`. They live as long as the process: the first reading of a rate
/// (CPU, network) needs two samples, so the first call takes one short interval; later calls reuse a reading younger
/// than a second, so one tool call that asks for processes and network twice samples once.
public actor LiveCollectors {
    private let processCollector = ProcessCollector()
    private let systemCollector = SystemCollector()
    private let networkCollector = NetworkCollector()
    private var processes: (at: Date, reading: Reading<[ProcessSample]>)?
    private var network: (at: Date, snapshot: NetworkSnapshot)?
    private let warmUp: Duration

    public init(warmUp: Duration = .seconds(2)) { self.warmUp = warmUp }

    public func system() async -> SystemSnapshot { await systemCollector.collect() }

    public func processReading() async -> Reading<[ProcessSample]> {
        if let processes, Date().timeIntervalSince(processes.at) < 1 { return processes.reading }
        if processes == nil {
            // Prime both collectors together, then wait one interval, so CPU and traffic are measured over the same time.
            let first = await processCollector.collect()
            _ = await networkCollector.collect(processes: first.value ?? [])
            try? await Task.sleep(for: warmUp)
        }
        let reading = await processCollector.collect()
        processes = (Date(), reading)
        network = nil
        return reading
    }

    public func networkSnapshot(_ list: [ProcessSample]) async -> NetworkSnapshot {
        if let network, Date().timeIntervalSince(network.at) < 1 { return network.snapshot }
        let snapshot = await networkCollector.collect(processes: list)
        network = (Date(), snapshot)
        return snapshot
    }
}

public enum LiveAgentSources {
    /// The sources over this Mac. The history database is opened read-only; it counts as kept current only while its
    /// newest sample is under two minutes old (the app samples at least every minute), which is how "MacMax is
    /// running" is told without looking for a process by name.
    public static func make(home: MacMaxHome, ipCheckAllowed: Bool = true) async -> AgentSources {
        let databaseURL = home.url.appendingPathComponent("macmax.db")
        var database: Database?
        var databaseProblem: String?
        do {
            if try ReportCounter.exists(databaseURL.path) { database = try Database.open(at: databaseURL, mode: .readOnly) }
        } catch { databaseProblem = "the history database could not be opened" }
        var running = false
        if let database {
            // A freshness read that fails counts as running, so the tool's own read fails loudly instead of claiming "not running".
            let newest = try? await database.systemSeries(since: Int64(Date().timeIntervalSince1970) - 120, limit: 1)
            running = newest.map { !$0.isEmpty } ?? true
        }
        let collectors = LiveCollectors()
        let identity = NetworkIdentityCollector()
        // A config that cannot be read means the protected paths are unknown, so no cleanup is proposed.
        var protected: [String]?
        if case let .ok(config) = ConfigStore(home: home).load() { protected = config.protectedPaths }
        let userProtected = protected
        let runner = AuditRunner(database: database, databaseProblem: databaseProblem, ipCheckEnabled: false)
        let service = AuditService(database: nil, collect: { previous in await runner.collect(previous: previous) })
        return AgentSources(
            database: database, appRunning: running,
            processes: { await collectors.processReading() },
            system: { await collectors.system() },
            network: { await collectors.networkSnapshot($0) },
            identity: { await identity.collect(checkEnabled: $0 && ipCheckAllowed) },
            audit: { await service.runNow(.onDemand) },
            cleanup: {
                guard let userProtected else {
                    return CleanupPreview(candidates: [], skipped: [CleanupSkip(path: "", reason: "the settings file could not be read, so the protected folders are unknown")])
                }
                guard let programs = RunningPrograms.names() else {
                    return CleanupPreview(candidates: [], skipped: [CleanupSkip(path: "", reason: "the running programs could not be read")])
                }
                return CleanupScanner(home: FileManager.default.homeDirectoryForCurrentUser, userProtected: userProtected,
                                      running: Running(names: programs, bundleIDs: [])).scan()
            },
            now: { Date() })
    }
}
