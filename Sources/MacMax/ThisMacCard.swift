import MacMaxCore
import SwiftUI

/// The whole machine in one card: chip and cores with how many are working, the GPU, and the memory against its size.
struct ThisMacCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        if model.hardware != nil || model.live != nil {
            Bezel {
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(text: model.hardware?.chip ?? "This Mac", color: Theme.textTertiary)
                    cpu
                    gpu
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
            }
        } else {
            line("CPU cores", hardware?.totalCores.map { "\($0)" } ?? "unknown", layout.isEmpty ? nil : layout)
        }
    }

    @ViewBuilder private var gpu: some View {
        let hardware = model.hardware
        let detail = [hardware?.gpuName, hardware?.gpuCores.map { "\($0) cores" }].compactMap { $0 }.joined(separator: ", ")
        VStack(alignment: .leading, spacing: 6) {
            line("GPU", model.live?.gpuPercent.map { "\(Int($0.rounded()))% busy" } ?? "usage not reported", detail.isEmpty ? nil : detail)
            if let used = model.live?.gpuMemoryUsedBytes {
                let shared = hardware?.chip?.hasPrefix("Apple") == true ? " (shared with RAM)" : ""
                line("GPU memory", CompactFormat.bytes(used) + " in use",
                     model.live?.gpuMemoryAllocatedBytes.map { "\(CompactFormat.bytes($0)) allocated" + shared })
            }
        }
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
