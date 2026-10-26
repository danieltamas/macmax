import MacMaxCore
import SwiftUI

/// The battery drawn as a battery (charge, wear, cycles) and the cooling as gauges (each fan turning at its speed, the
/// hottest sensor on a dial). Read while the panel is open, every few seconds; a reading that fails says so and is
/// never drawn as healthy.
struct PowerHealthCard: View {
    let model: PanelModel
    @Environment(\.panelVisible) private var panelVisible
    private static let refreshSeconds: UInt64 = 10

    var body: some View {
        Bezel {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "Battery and heat", color: Theme.textTertiary)
                battery
                heat
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: panelVisible) {
            guard panelVisible else { return }
            while !Task.isCancelled {
                model.readPower()
                try? await Task.sleep(nanoseconds: Self.refreshSeconds * 1_000_000_000)
            }
        }
    }

    // MARK: Battery

    @ViewBuilder private var battery: some View {
        switch model.batteryHealth {
        case nil: Text("Reading the battery...").font(.meta).foregroundStyle(Theme.textSecondary)
        case let .unavailable(reason)?: Text(reason.prefix(1).uppercased() + reason.dropFirst() + ".").font(.meta).foregroundStyle(Theme.textSecondary)
        case let .failed(reason)?: Text("Battery: unknown. It could not be read: \(reason).").font(.meta).foregroundStyle(Theme.warn)
        case let .ok(health, _, _)?:
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    charge
                    Spacer(minLength: 0)
                    healthDial(health)
                }
                cycles(health)
                if health.condition == .serviceRecommended {
                    Text("The battery reports a fault: have it checked at service.").font(.meta).foregroundStyle(Theme.warn)
                }
            }
        }
    }

    private var status: BatteryStatus? { model.batteryStatus?.value }

    private var charge: some View {
        HStack(spacing: 12) {
            BatteryGlyph(percent: status?.chargePercent, charging: status?.isCharging == true, tint: chargeTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.map { "\($0.chargePercent)%" } ?? "Unknown").font(.statValue).foregroundStyle(Theme.textPrimary)
                Text(chargeCaption).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var chargeTint: Color {
        guard let status else { return Theme.textTertiary }
        if status.isCharging || status.powerSource == .ac { return Theme.success }
        return status.chargePercent <= 10 ? Theme.danger : status.chargePercent <= 20 ? Theme.warn : Theme.success
    }

    private var chargeCaption: String {
        guard let status else { return "The charge could not be read" }
        if status.isCharging { return "Charging" }
        return status.powerSource == .ac ? "On power, not charging" : "On battery"
    }

    private func healthDial(_ health: BatteryHealth) -> some View {
        VStack(spacing: 3) {
            ZStack {
                ArcGauge(fraction: Double(health.maximumCapacityPercent) / 100, tint: healthTint(health))
                Text("\(health.maximumCapacityPercent)%").font(.statSmall).foregroundStyle(Theme.textPrimary)
            }.frame(width: 62, height: 62)
            Text("Health").font(.meta).foregroundStyle(Theme.textTertiary)
        }
        .help("How much of its original capacity the battery still holds")
    }

    private func healthTint(_ health: BatteryHealth) -> Color {
        health.condition == .serviceRecommended || health.maximumCapacityPercent < 70 ? Theme.danger : health.maximumCapacityPercent < 80 ? Theme.warn : Theme.success
    }

    @ViewBuilder private func cycles(_ health: BatteryHealth) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Charge cycles").font(.meta).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text(verbatim: health.designCycleCount.map { "\(health.cycleCount) of \($0)" } ?? "\(health.cycleCount)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
            }
            if let rated = health.designCycleCount {
                Capsule().fill(Theme.hairline).frame(height: 5).overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(cycleTint(health.cycleCount, rated)).frame(width: proxy.size.width * min(1, Double(health.cycleCount) / Double(rated)))
                    }
                }
            }
            if let temperature = health.temperatureCelsius {
                Text(String(format: "Battery temperature %.1f C", temperature)).font(.meta).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func cycleTint(_ used: Int, _ rated: Int) -> Color {
        Double(used) / Double(rated) >= 0.9 ? Theme.warn : Theme.teal
    }

    // MARK: Heat

    @ViewBuilder private var heat: some View {
        switch model.thermalSensors {
        case nil: Text("Reading the fans and sensors...").font(.meta).foregroundStyle(Theme.textSecondary)
        case let .unavailable(reason)?: Text(reason.prefix(1).uppercased() + reason.dropFirst() + ".").font(.meta).foregroundStyle(Theme.textSecondary)
        case let .failed(reason)?: Text("Fans and sensors: unknown. They could not be read: \(reason).").font(.meta).foregroundStyle(Theme.warn)
        case let .ok(sensors, _, _)?:
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10, alignment: .top)], alignment: .leading, spacing: 12) {
                    if let hottest = sensors.hottestCelsius { temperatureDial(hottest) }
                    ForEach(sensors.fans, id: \.index) { fanDial($0) }
                }
                if sensors.fans.isEmpty { Text(PowerWording.fanSummary(sensors)).font(.meta).foregroundStyle(Theme.textTertiary) }
            }
        }
    }

    private func temperatureDial(_ celsius: Double) -> some View {
        let tint: Color = celsius >= 95 ? Theme.danger : celsius >= 80 ? Theme.warn : Theme.success
        return dial(label: "Hottest sensor", tint: tint, fraction: (celsius - 20) / 90, help: "The warmest of the temperature sensors MacMax can read") {
            Text(String(format: "%.0f C", celsius)).font(.statSmall).foregroundStyle(Theme.textPrimary)
        }
    }

    private func fanDial(_ fan: Fan) -> some View {
        let low = Double(fan.minimumRPM ?? 0), high = Double(fan.maximumRPM ?? max(fan.rpm, 6_000))
        let fraction = high > low ? (Double(fan.rpm) - low) / (high - low) : 0
        return dial(label: "Fan \(fan.index + 1)", detail: "\(fan.rpm) rpm", tint: Theme.teal, fraction: fraction,
                    help: "Drawn turning slower than the real fan, but faster when it is faster") {
            FanRotor(rpm: fan.rpm, tint: Theme.teal)
        }
    }

    private func dial<Center: View>(label: String, detail: String? = nil, tint: Color, fraction: Double, help: String,
                                    @ViewBuilder center: () -> Center) -> some View {
        VStack(spacing: 3) {
            ZStack {
                ArcGauge(fraction: fraction, tint: tint)
                center()
            }.frame(width: 62, height: 62)
            Text(detail ?? label).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
            if detail != nil { Text(label).font(.meta).foregroundStyle(Theme.textTertiary) }
        }
        .frame(maxWidth: .infinity)
        .help(help)
    }
}
