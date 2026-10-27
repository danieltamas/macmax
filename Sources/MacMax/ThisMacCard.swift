import MacMaxCore
import SwiftUI

/// The whole machine in one card: the cores and how they split their time, then a grid of small stats (clusters,
/// load, uptime, GPU) in the same cell idiom as the sensor groups, then the memory against its size. No box inside
/// the card: a cell is an icon, a label, a figure and one line of detail.
struct ThisMacCard: View {
    @ObservedObject var model: PanelModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        if model.hardware != nil || model.live != nil {
            Bezel {
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(text: model.hardware?.chip ?? "This Mac", color: Theme.textTertiary)
                    cpu
                    let stats = stats
                    if !stats.isEmpty {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(stats, id: \.label) { stat in StatCell(stat: stat) }
                        }
                    }
                    memory
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func line(_ title: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.meta).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 6)
                Text(value).font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
            }
            if let detail { Text(detail).font(.meta).foregroundStyle(Theme.textTertiary) }
        }
    }

    @ViewBuilder private var cpu: some View {
        let hardware = model.hardware
        let layout = [hardware?.performanceCores.map { "\($0) performance" }, hardware?.efficiencyCores.map { "\($0) efficiency" }]
            .compactMap { $0 }.joined(separator: ", ")
        if let live = model.live {
            VStack(alignment: .leading, spacing: 6) {
                line("CPU cores", "\(live.busyCores()) of \(live.coreBusyPercent.count) busy", layout.isEmpty ? nil : layout)
                CoreBars(values: live.coreBusyPercent)
                if let split = live.cpuSplit { CPUTimeBar(split: split) }
            }
        } else {
            line("CPU cores", hardware?.totalCores.map { "\($0)" } ?? "unknown", layout.isEmpty ? nil : layout)
        }
    }

    /// Only what read this tick: a stat without a reading is left out, never shown as zero.
    private var stats: [Stat] {
        let hardware = model.hardware
        var stats: [Stat] = []
        if let live = model.live {
            let clusters = live.clusterBusy(efficiencyCores: hardware?.efficiencyCores)
            if let efficiency = clusters.efficiency, let performance = clusters.performance, let count = hardware?.efficiencyCores {
                stats.append(Stat(symbol: "leaf", label: "Efficiency", value: "\(Int(efficiency.rounded()))%", detail: "\(count) cores"))
                stats.append(Stat(symbol: "hare", label: "Performance", value: "\(Int(performance.rounded()))%",
                                  detail: "\(live.coreBusyPercent.count - count) cores"))
            }
            if let averages = live.loadAverages {
                let cores = live.coreBusyPercent.count
                stats.append(Stat(symbol: "gauge.with.needle", label: "Load", value: String(format: "%.1f", averages.one),
                                  detail: String(format: "5 min %.1f, 15 min %.1f", averages.five, averages.fifteen),
                                  help: "Load average over 1, 5 and 15 minutes" + (cores > 0 ? "; above \(cores) means work is queueing" : "")))
            }
            if let uptime = live.uptimeSeconds { stats.append(Stat(symbol: "clock", label: "Uptime", value: Self.uptimeText(uptime), detail: nil)) }
        }
        let gpuCores = hardware?.gpuCores.map { "\($0) cores" }
        if let gpu = model.live?.gpuPercent {
            stats.append(Stat(symbol: "square.stack.3d.up", label: "GPU", value: "\(Int(gpu.rounded()))% busy", detail: gpuCores ?? hardware?.gpuName))
        } else if let gpuCores {
            stats.append(Stat(symbol: "square.stack.3d.up", label: "GPU", value: gpuCores, detail: "busy not reported"))
        }
        if let used = model.live?.gpuMemoryUsedBytes {
            let shared = hardware?.chip?.hasPrefix("Apple") == true
            stats.append(Stat(symbol: "memorychip", label: "GPU memory", value: CompactFormat.bytes(used),
                              detail: model.live?.gpuMemoryAllocatedBytes.map { "of \(CompactFormat.bytes($0))" + (shared ? " shared" : "") },
                              help: shared ? "Graphics memory in use, out of what macOS allocated; on Apple silicon it is carved from RAM" : "Graphics memory in use, out of what the GPU allocated"))
        }
        return stats
    }

    /// Compact so it fits a third of the card: "123 d 22 h", "46 h 12 min", "8 min".
    static func uptimeText(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        let days = minutes / 1_440, hours = minutes % 1_440 / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes % 60) min" }
        return "\(minutes) min"
    }

    @ViewBuilder private var memory: some View {
        let total = model.live?.memoryTotalBytes ?? model.hardware?.memoryBytes
        if let used = model.live?.memoryUsedBytes, let total, total > 0 {
            VStack(alignment: .leading, spacing: 6) {
                line("Memory", "\(CompactFormat.bytes(used)) of \(CompactFormat.bytes(total))", nil)
                ProgressBar(fraction: Double(used) / Double(total), color: Theme.color(.memory))
            }
        } else if let total {
            line("Memory", CompactFormat.bytes(total), "usage not reported")
        }
    }
}

private struct Stat {
    let symbol: String
    let label: String
    let value: String
    let detail: String?
    var help: String? = nil
}

private struct StatCell: View {
    let stat: Stat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: stat.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                Text(stat.label).font(.meta).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Text(stat.value).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary).lineLimit(1)
            if let detail = stat.detail { Text(detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textTertiary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(stat.help ?? stat.label)
    }
}

/// How the CPU spent the tick, as one bar: user, then system in the same hue but fainter, the idle rest unfilled.
private struct CPUTimeBar: View {
    let split: CPUSplit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                HStack(spacing: 1) {
                    Capsule().fill(Theme.color(.cpu)).frame(width: width * share(split.userPercent))
                    Capsule().fill(Theme.color(.cpu).opacity(0.45)).frame(width: width * share(split.systemPercent))
                    Capsule().fill(Theme.hairline)
                }
            }
            .frame(height: 4)
            HStack(spacing: 10) {
                legend(Theme.color(.cpu), "\(Int(split.userPercent.rounded()))% user")
                legend(Theme.color(.cpu).opacity(0.45), "\(Int(split.systemPercent.rounded()))% system")
                legend(Theme.hairline, "\(Int(split.idlePercent.rounded()))% idle")
            }
        }
        .help("Share of all CPU time spent in apps (user), in the kernel (system) and waiting (idle)")
    }

    private func share(_ percent: Double) -> Double { min(1, max(0, percent / 100)) }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.meta.monospacedDigit()).foregroundStyle(Theme.textTertiary)
        }
    }
}

/// One thin bar per logical core, as tall as it is busy: drawn once per tick, no animation.
private struct CoreBars: View {
    let values: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Theme.hairline)
                    Capsule().fill(Theme.color(.cpu)).frame(height: max(2, 22 * value / 100))
                }
            }
        }
        .frame(height: 22)
    }
}

private struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 5)
    }
}
