import Foundation
import MacMaxCore

/// Synthetic History data for the screenshots: smooth deterministic curves with one gap where "MacMax was not running".
extension DemoStore {
    static func history(for model: PanelModel, range: HistoryRange, stress: Bool) {
        let end = Int64(now.timeIntervalSince1970) / range.stepSeconds * range.stepSeconds
        let start = (Int64(now.timeIntervalSince1970) - range.seconds) / range.stepSeconds * range.stepSeconds
        let count = Int((end - start) / range.stepSeconds) + 1
        model.historyRange = range
        var result: [HistoryMetric: [HistoryPoint]] = [:]
        for (index, metric) in HistoryMetric.allCases.enumerated() {
            result[metric] = (0 ..< count).map { step in
                let fraction = Double(step) / Double(max(count - 1, 1))
                let inGap = fraction > 0.42 && fraction < 0.5
                let wave = 0.5 + 0.5 * sin(fraction * 14 + Double(index)) * cos(fraction * 5 + Double(index) * 2)
                let spike = fraction > 0.78 && fraction < 0.84 ? 0.35 : 0
                return HistoryPoint(ts: start + Int64(step) * range.stepSeconds,
                                    value: inGap ? nil : value(metric, min(wave + spike, 1), stress: stress))
            }
        }
        model.history = result
        let names = ["Atlas Browser", "Docker", "Relay Chat", "Pixel Studio", "Harbor Mail"]
        model.historyApps = Dictionary(uniqueKeysWithValues: [HistoryMetric.cpu, .memory, .diskIO].map { metric in
            (metric, names.enumerated().map { appIndex, name in
                HistoryAppSeries(appKey: "ro.example.\(appIndex)", name: name, points: (result[metric] ?? []).enumerated().map { step, point in
                    HistoryPoint(ts: point.ts, value: point.value.map { $0 * (0.55 - Double(appIndex) * 0.1) * (1 + 0.15 * sin(Double(step) / 4 + Double(appIndex))) })
                })
            })
        })
        model.historyState = .ready
    }

    static func selectSpike(_ model: PanelModel, metric: HistoryMetric) {
        let points = model.history[metric] ?? []
        guard let spike = points[Int(Double(points.count) * 0.81)...].first(where: { $0.value != nil }) else { return }
        model.historySelection = HistorySelection(metric: metric, ts: spike.ts)
        let names = stress(model) ? "Northwind Integrated Development Environment" : "Atlas Browser"
        let values: [Double] = metric == .cpu ? [41, 29, 9] : [412_000_000, 290_000_000, 96_000_000]
        model.historyHolders = [HistoryHolder(appKey: "ro.example.atlas", name: names, value: values[0]),
                                HistoryHolder(appKey: "ro.example.docker", name: "Docker", value: values[1]),
                                HistoryHolder(appKey: "ro.example.relay", name: "Relay Chat", value: values[2])]
    }

    private static func stress(_ model: PanelModel) -> Bool { model.apps.contains { $0.name.hasPrefix("Northwind") } }

    private static func value(_ metric: HistoryMetric, _ unit: Double, stress: Bool) -> Double {
        switch metric {
        case .cpu: 12 + unit * 70
        case .pressure: unit > 0.9 ? 4 : unit > 0.6 ? 2 : 1
        case .memory: (8 + unit * (stress ? 120 : 7)) * 1_073_741_824
        case .swap: unit * 3.1 * 1_073_741_824
        case .diskIO: unit * 62_000_000
        case .netIn: unit * (stress ? 9_437_184 : 1_800_000)
        case .netOut: unit * 380_000
        }
    }
}
