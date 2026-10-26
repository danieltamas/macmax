import Foundation
import MacMaxCore

/// Reads the History tab's series off the main actor and hands them to the model. One load at a time: a newer
/// range or selection cancels the older read, so a slow query never overwrites what the user picked since.
@MainActor
final class HistoryLoader {
    private let model: PanelModel
    private let database: Database?
    private var task: Task<Void, Never>?
    private var holdersTask: Task<Void, Never>?

    init(model: PanelModel, database: Database?) {
        self.model = model
        self.database = database
        model.historyChanged = { [weak self] in self?.reload() }
        model.loadHolders = { [weak self] selection in self?.loadHolders(selection) }
    }

    /// Refreshes the open tab once a minute: the charts end at "now", and nothing is drawn while another tab is open.
    func refreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if model.tab == .history { reload() }
        }
    }

    func reload() {
        task?.cancel()
        task = Task { await load() }
    }

    private func load() async {
        guard let database else {
            model.historyState = .failed(collector: "The history database", reason: "It could not be opened, so nothing is recorded.")
            return
        }
        let range = model.historyRange
        let now = Int64(Date().timeIntervalSince1970)
        do {
            var result: [HistoryMetric: [HistoryPoint]] = [:]
            var apps: [HistoryMetric: [HistoryAppSeries]] = [:]
            for metric in HistoryMetric.allCases {
                result[metric] = try await database.history(metric, range: range, now: now)
                // Only where an app's counter has the machine line's unit: swap and pressure are machine-wide, and
                // an app's network counter is bytes per sample, not a rate.
                if metric == .cpu || metric == .memory || metric == .diskIO { apps[metric] = try await database.appHistory(metric, range: range, now: now) }
            }
            guard !Task.isCancelled, model.historyRange == range else { return }
            model.history = result
            model.historyApps = apps
            model.historyState = .ready
        } catch {
            guard !Task.isCancelled, model.historyRange == range else { return }
            model.historyState = .failed(collector: "The history database", reason: "The recorded history could not be read.")
        }
    }

    private func loadHolders(_ selection: HistorySelection) {
        holdersTask?.cancel()
        guard let database else {
            model.historyHoldersState = .failed(collector: "The history database", reason: "It could not be opened.")
            return
        }
        let range = model.historyRange
        holdersTask = Task {
            do {
                let holders = try await database.holders(selection.metric, range: range, at: selection.ts)
                guard !Task.isCancelled, model.historySelection == selection else { return }
                model.historyHolders = holders
                model.historyHoldersState = .ready
            } catch {
                guard !Task.isCancelled, model.historySelection == selection else { return }
                model.historyHoldersState = .failed(collector: "The history database", reason: "The apps could not be read.")
            }
        }
    }
}
