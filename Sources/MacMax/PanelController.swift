import AppKit
import MacMaxCore
import SwiftUI

/// Drives the live panel: the sampler, the scheduled audit and the identity check feed `PanelModel`. Nothing here
/// draws; the views read the model. One controller lives for the whole run.
@MainActor
final class PanelController {
    let model = PanelModel()
    private let home = MacMaxHome()
    private var database: Database?
    private var sampler: Sampler?
    private var auditService: AuditService?
    private var auditConfigKey = ""
    private var tasks: [Task<Void, Never>] = []
    private var series: [Vital.Kind: [Double]] = [:]
    private let connectionsCollector = NetworkCollector()
    private let identityCollector = NetworkIdentityCollector()
    private var lastIdentity: IdentityCard?
    private var nowTraffic: [TrafficLine] = []
    private var windowTask: Task<Void, Never>?
    private var historyLoader: HistoryLoader?
    private var actions: ActionController?
    /// The audit reads its thresholds off the main actor; this carries them across.
    private let settings = SettingsBox()

    init() {
        model.configStore = ConfigStore(home: home)
        model.runAudit = { [weak self] in self?.auditNow() }
        model.snooze = { [weak self] id in self?.snooze(id) }
        model.loadConnections = { [weak self] id in self?.loadConnections(appKey: id) }
        model.clearHistory = { [weak self] in self?.clearHistory() }
        actions = ActionController(model: model, database: { [weak self] in self?.database })
        model.windowChanged = { [weak self] in self?.showWindowTraffic() }
        model.openSettings = { [model] pane in
            model.settingsPane = pane
            NSApp.activate(ignoringOtherApps: true)
            model.showSettingsWindow()
        }
    }

    func start() {
        loadSnoozes()
        switch ConfigStore(home: home).load() {
        case let .ok(config): model.config = config
        case let .malformed(reason):
            model.configProblem = "\(reason). Using defaults; nothing will be saved until it is fixed or removed."
        }
        if let name = model.config.lookName, let look = Look(rawValue: name) { Appearance.shared.look = look }
        do {
            try home.prepare()
            let database = try Database.open(at: home.url.appendingPathComponent("macmax.db"), mode: .readWrite)
            self.database = database
            sampler = Sampler(database: database)
            Task { model.historyBytes = await database.fileSizeBytes() }
            model.loadLastCleanups()
        } catch {
            model.samplerFailed = true
            model.samplerNote = "History is unavailable: the database could not be opened."
            let failure = SectionState.failed(collector: "The history database", reason: "It could not be opened, so nothing is recorded.")
            model.vitalsState = failure
            model.appsState = failure
            model.trafficState = failure
        }
        let loader = HistoryLoader(model: model, database: database)
        historyLoader = loader
        tasks = [Task { await loader.refreshLoop() }, Task { await sampleLoop() }, Task { await auditLoop() }, Task { await identityLoop() }, Task { await maintenanceLoop() }]
    }

    // MARK: - Sampling

    private func sampleLoop() async {
        guard let sampler else { return }
        let clock = ContinuousClock()
        await preloadSeries()
        while !Task.isCancelled {
            let seconds = model.config.samplingSeconds
            let started = clock.now
            do {
                let rows = try await sampler.tick()
                await apply(rows, interval: seconds)
            } catch is CancellationError {
                return
            } catch {
                model.samplerFailed = true
                model.samplerNote = "A reading failed; trying again in \(seconds) s."
                let failure = SectionState.failed(collector: "The sampler", reason: "The last reading failed, so these numbers are not current.")
                model.vitalsState = failure
                model.appsState = failure
                if model.window == .now { model.trafficState = failure }
            }
            try? await clock.sleep(until: started + .seconds(seconds))
        }
    }

    private func preloadSeries() async {
        guard let database else { return }
        let since = Int64(Date().timeIntervalSince1970) - 3_600
        guard let rows = try? await database.systemSeries(since: since, limit: 360) else { return }
        for row in rows { record(row) }
    }

    private func record(_ row: SystemSampleRow) {
        func add(_ kind: Vital.Kind, _ value: Double?) {
            guard let value, value.isFinite else { return }
            series[kind, default: []].append(value)
            if series[kind]!.count > 360 { series[kind]!.removeFirst() }
        }
        add(.cpu, row.cpuUser.flatMap { user in row.cpuSystem.map { user + $0 } })
        add(.memory, row.memUsed.map(Double.init))
        add(.swap, row.swapUsed.map(Double.init))
        add(.disk, row.diskFree.map(Double.init))
        add(.netIn, row.netInBps)
        add(.netOut, row.netOutBps)
    }

    private func apply(_ rows: TickRows, interval: Int) async {
        record(rows.system)
        model.samplerFailed = false
        model.samplerNote = "Sampling every \(interval) s"
        model.vitals = PanelData.vitals(rows.system, series: series, edges: edges())
        model.vitalsState = .ready
        if model.config.auditOnCriticalPressure, let raw = rows.system.pressureLevel,
           let level = MemoryPressureLevel(rawValue: raw) {
            let service = makeAuditService()
            Task { if let result = await service.memoryPressureChanged(to: level) { show(result) } }
        }
        let names = Dictionary(rows.appInfo.map { ($0.appKey, $0.name) }, uniquingKeysWith: { first, _ in first })
        let pids = Dictionary(grouping: rows.processes, by: \.appKey).mapValues { $0.map(\.pid) }
        model.apps = rows.apps.map { PanelData.appRow($0, name: names[$0.appKey], interval: Double(interval), pids: pids[$0.appKey] ?? []) }
        model.appsState = .ready
        model.processes = PanelData.processes(rows.processes)
        model.topConsumers = PanelData.topConsumers(model.apps)
        model.interfaces = PanelData.interfaces(rows.system, each: rows.interfaces)
        model.live = rows.live
        if model.hardware == nil { model.hardware = HardwareProfile.read() }
        nowTraffic = PanelData.nowTraffic(rows.apps, names: names, interval: Double(interval))
        if model.window == .now {
            model.traffic = nowTraffic
            model.trafficState = .ready
        } else {
            await loadWindowTraffic()
        }
    }

    private func edges() -> [Vital.Kind: Severity] {
        var result: [Vital.Kind: Severity] = [:]
        for finding in model.findings {
            guard let kind = PanelData.vital(forRule: finding.ruleID) else { continue }
            if result[kind].map({ finding.severity < $0 }) ?? true { result[kind] = finding.severity }
        }
        return result
    }

    private func showWindowTraffic() {
        if model.window == .now {
            model.traffic = nowTraffic
            model.trafficState = model.samplerFailed
                ? .failed(collector: "The sampler", reason: "The last reading failed, so these numbers are not current.")
                : .ready
        } else {
            model.trafficState = .loading("Reading network usage...")
            windowTask?.cancel()
            windowTask = Task { await loadWindowTraffic() }
        }
    }

    func loadWindowTraffic() async {
        guard let seconds = model.window.seconds else { return }
        guard let database else {
            model.trafficState = .failed(collector: "The history database", reason: "It could not be opened, so no totals exist.")
            return
        }
        do {
            let since = Int64(Date().timeIntervalSince1970) - seconds
            let lines = try await database.appTraffic(since: since).map {
                TrafficLine(id: $0.appKey, name: $0.name, bytesIn: Double($0.bytesIn), bytesOut: Double($0.bytesOut))
            }
            // A newer window choice may have arrived while the query ran: its rows must not be overwritten.
            guard !Task.isCancelled, model.window.seconds == seconds else { return }
            model.traffic = lines
            model.trafficState = .ready
        } catch {
            guard !Task.isCancelled, model.window.seconds == seconds else { return }
            model.trafficState = .failed(collector: "The history database", reason: "Traffic totals could not be read.")
        }
    }

    // MARK: - Audit

    private func auditLoop() async {
        while !Task.isCancelled {
            let hours = model.config.auditEveryHours
            if hours == 0 {
                // Off means no scheduled work: the panel waits for a press or for the schedule to change.
                if model.auditState != .ready { model.auditState = .ready }
                try? await Task.sleep(for: .seconds(10))
                continue
            }
            let result = await makeAuditService().runNow(.scheduled)
            show(result)
            for _ in 0 ..< hours * 360 {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { return }
                if model.config.auditEveryHours != hours { break }
            }
        }
    }

    /// One service per audit-relevant setting set: the runner reads the IP check and endpoint when it is built.
    private func makeAuditService() -> AuditService {
        let config = model.config
        settings.value = AuditSettings(thresholds: config.thresholds, disabled: Set(config.disabledRules))
        let key = "\(config.ipCheckEnabled)|\(config.ipEndpoint ?? "")"
        if let auditService, key == auditConfigKey { return auditService }
        let runner = AuditRunner(database: database, ipCheckEnabled: config.ipCheckEnabled, ipEndpoint: config.ipEndpoint)
        let service = AuditService(database: database, collect: { await runner.collect(previous: $0) },
                                   settings: { [settings] in settings.value })
        auditService = service
        auditConfigKey = key
        return service
    }

    private func auditNow() {
        guard !model.auditRunning else { return }
        model.auditRunning = true
        Task {
            let result = await makeAuditService().runNow(.onDemand)
            show(result)
        }
    }

    private func show(_ result: AuditResult) {
        model.auditRunning = false
        model.verdict = result.report.verdict
        model.findings = result.report.findings
        model.unknowns = result.report.unknowns
        model.auditedAt = Date(timeIntervalSince1970: TimeInterval(result.report.timestamp))
        model.auditState = .ready
        model.storageNote = result.storageError
        model.vitals = PanelData.vitals(nil, series: series, edges: edges(), keeping: model.vitals)
    }

    /// Snoozes survive a restart: the expiry per rule is kept in the app's defaults.
    private static let snoozeKey = "snoozedUntil"

    private func loadSnoozes() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.snoozeKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        for (id, until) in stored where until > now { holdSnooze(id, until: until) }
    }

    private func snooze(_ ruleID: String) {
        let until = Date().timeIntervalSince1970 + 86_400
        var stored = UserDefaults.standard.dictionary(forKey: Self.snoozeKey) as? [String: Double] ?? [:]
        stored[ruleID] = until
        UserDefaults.standard.set(stored, forKey: Self.snoozeKey)
        holdSnooze(ruleID, until: until)
    }

    private func holdSnooze(_ ruleID: String, until: Double) {
        model.snoozed.insert(ruleID)
        Task {
            try? await Task.sleep(for: .seconds(max(until - Date().timeIntervalSince1970, 0)))
            model.snoozed.remove(ruleID)
        }
    }

    // MARK: - Network identity

    private func identityLoop() async {
        while !Task.isCancelled {
            let config = model.config
            let collector = config.ipEndpoint.map { NetworkIdentityCollector(client: IPEndpointClient(endpoint: $0)) } ?? identityCollector
            let identity = await collector.collect(checkEnabled: config.ipCheckEnabled)
            model.identity = PanelData.identityCard(identity, checkEnabled: config.ipCheckEnabled, previous: lastIdentity)
            lastIdentity = model.identity
            model.identityState = .ready
            model.vpnServices = (identity.vpnServices.value ?? []).map { ($0.label, $0.state.rawValue) }
            model.physicalInterface = identity.physicalInterface.value
            if let database {
                let now = Int64(Date().timeIntervalSince1970)
                _ = try? await database.writeIdentityIfChanged(PanelData.identityRow(identity, ts: now))
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    // MARK: - On demand

    private func loadConnections(appKey: String) {
        guard let pid = model.processes[appKey]?.first?.pid else {
            model.connections[appKey] = []
            return
        }
        guard !model.connectionsLoading.contains(appKey) else { return }
        model.connectionsLoading.insert(appKey)
        Task {
            let reading = await connectionsCollector.connections(ofPid: pid)
            model.connectionsLoading.remove(appKey)
            switch reading {
            case let .ok(connections, _, _):
                model.connections[appKey] = connections.enumerated().map { index, connection in
                    ConnectionLine(id: index, text: PanelData.describe(connection))
                }
            case let .unavailable(reason), let .failed(reason):
                model.connections[appKey] = [ConnectionLine(id: 0, text: "Connections could not be read: \(reason)")]
            }
        }
    }

    private func clearHistory() {
        guard let database else {
            model.clearError = "History is unavailable: the database could not be opened."
            return
        }
        guard !model.clearing else { return }
        model.clearing = true
        Task {
            defer { model.clearing = false }
            do {
                try await database.clearHistory()
                model.clearError = nil
                model.lastCleared = Date()
            } catch {
                model.clearError = "History could not be cleared."
            }
            model.historyBytes = await database.fileSizeBytes()
        }
    }

    private func maintenanceLoop() async {
        while !Task.isCancelled {
            if let database {
                let now = Int64(Date().timeIntervalSince1970)
                _ = try? await database.rollup(now: now - 60, maxBuckets: 500)
                _ = try? await database.retain(now: now, maxRowsPerTable: 50_000)
                model.historyBytes = await database.fileSizeBytes()
            }
            try? await Task.sleep(for: .seconds(300))
        }
    }
}

final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = AuditSettings()

    var value: AuditSettings {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
