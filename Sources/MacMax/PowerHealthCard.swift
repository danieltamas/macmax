import MacMaxCore
import SwiftUI

/// How worn the battery is and how the cooling is doing. Read while the panel is open, every few seconds (fan speed
/// moves); a reading that fails says so and is never shown as healthy.
struct PowerHealthCard: View {
    let model: PanelModel
    @State private var shown = false
    private static let refreshSeconds: UInt64 = 10

    var body: some View {
        Bezel {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "Battery and heat", color: Theme.textTertiary)
                battery
                heat
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WindowVisibility(visible: $shown))
        .task(id: shown) {
            guard shown else { return }
            while !Task.isCancelled {
                model.readPower()
                try? await Task.sleep(nanoseconds: Self.refreshSeconds * 1_000_000_000)
            }
        }
    }

    private func line(_ title: String, _ value: String, _ detail: String?, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.meta).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 6)
                Text(value).font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(warn ? Theme.warn : Theme.textPrimary)
            }
            if let detail { Text(detail).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    @ViewBuilder private var battery: some View {
        switch model.batteryHealth {
        case nil: line("Battery", "Reading...", nil)
        case let .ok(health, _, _)?:
            line("Battery health", "\(health.maximumCapacityPercent)%", PowerWording.batterySummary(health), warn: health.condition == .serviceRecommended)
            if let temperature = health.temperatureCelsius { line("Battery temperature", String(format: "%.1f C", temperature), nil) }
        case let .unavailable(reason)?: line("Battery", "None", reason.prefix(1).uppercased() + reason.dropFirst() + ".")
        case let .failed(reason)?: line("Battery", "Unknown", "It could not be read: \(reason).", warn: true)
        }
    }

    @ViewBuilder private var heat: some View {
        switch model.thermalSensors {
        case nil: line("Fans and sensors", "Reading...", nil)
        case let .ok(sensors, _, _)?:
            line("Fans", sensors.fans.isEmpty ? "None" : sensors.fans.map { "\($0.rpm) rpm" }.joined(separator: ", "), sensors.fans.isEmpty ? PowerWording.fanSummary(sensors) : nil)
            if let hottest = sensors.hottestCelsius {
                line("Hottest sensor", String(format: "%.0f C", hottest), "The warmest of the temperature sensors MacMax can read.")
            }
        case let .unavailable(reason)?: line("Fans and sensors", "None", reason)
        case let .failed(reason)?: line("Fans and sensors", "Unknown", "They could not be read: \(reason).", warn: true)
        }
    }
}
