import MacMaxCore
import SwiftUI

/// Two rows of the same dial: the battery (charge, health, cycles) and the cooling (the hottest sensor, each fan turning
/// at its speed), then the named sensors in groups. Read while the panel is open, every few seconds; a reading that fails says so and is
/// never drawn as healthy.
struct PowerHealthCard: View {
    @ObservedObject var model: PanelModel
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10, alignment: .top)], alignment: .leading, spacing: 12) {
                    chargeDial
                    healthDial(health)
                    cyclesDial(health)
                }
                // The battery's own figure from IOKit; once the SMC names the cell sensors, the grid's Battery group has it.
                if let temperature = health.temperatureCelsius, !hasNamedBatterySensor {
                    Text(String(format: "Battery temperature %.1f C", temperature)).font(.meta).foregroundStyle(Theme.textTertiary)
                }
                if health.condition == .serviceRecommended {
                    Text("The battery reports a fault: have it checked at service.").font(.meta).foregroundStyle(Theme.warn)
                }
            }
        }
    }

    private var status: BatteryStatus? { model.batteryStatus?.value }

    /// The charge as a dial like the five beside it; a bolt in place of the figure while charging says so at a glance.
    private var chargeDial: some View {
        dial(label: chargeCaption, tint: chargeTint, fraction: Double(status?.chargePercent ?? 0) / 100,
             help: status.map { "\($0.chargePercent)% charged, \(chargeCaption.lowercased())" } ?? "The charge could not be read") {
            HStack(spacing: 2) {
                if status?.isCharging == true { Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(chargeTint) }
                Text(status.map { "\($0.chargePercent)%" } ?? "?").font(.statSmall).foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private var chargeTint: Color {
        guard let status else { return Theme.textTertiary }
        if status.isCharging || status.powerSource == .ac { return Theme.success }
        return status.chargePercent <= 10 ? Theme.danger : status.chargePercent <= 20 ? Theme.warn : Theme.success
    }

    private var chargeCaption: String {
        guard let status else { return "Charge unknown" }
        if status.isCharging { return "Charging" }
        return status.powerSource == .ac ? "On power" : "On battery"
    }

    private func healthDial(_ health: BatteryHealth) -> some View {
        dial(label: "Health", tint: healthTint(health), fraction: Double(health.maximumCapacityPercent) / 100,
             help: "How much of its original capacity the battery still holds") {
            Text("\(health.maximumCapacityPercent)%").font(.statSmall).foregroundStyle(Theme.textPrimary)
        }
    }

    /// Cycles used against the rated number; without a rated number the arc stays empty and the label says "cycles".
    private func cyclesDial(_ health: BatteryHealth) -> some View {
        let rated = health.designCycleCount
        return dial(label: rated.map { "of \($0) cycles" } ?? "cycles", tint: cycleTint(health),
                    fraction: rated.map { Double(health.cycleCount) / Double($0) } ?? 0,
                    help: "Charge cycles used" + (rated.map { " against the \($0) the battery is rated for" } ?? "")) {
            Text("\(health.cycleCount)").font(.statSmall.monospacedDigit()).foregroundStyle(Theme.textPrimary)
        }
    }

    private func healthTint(_ health: BatteryHealth) -> Color {
        health.condition == .serviceRecommended || health.maximumCapacityPercent < 70 ? Theme.danger : health.maximumCapacityPercent < 80 ? Theme.warn : Theme.success
    }

    private var hasNamedBatterySensor: Bool {
        if case let .ok(sensors, _, _)? = model.thermalSensors { return sensors.named.contains { $0.group == .battery } }
        return false
    }

    /// The gauge hue until nine tenths of the rated cycles are used, then warn: the figure is wear, not health.
    private func cycleTint(_ health: BatteryHealth) -> Color {
        guard let rated = health.designCycleCount, rated > 0 else { return Theme.teal }
        return Double(health.cycleCount) / Double(rated) >= 0.9 ? Theme.warn : Theme.teal
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
                    if let hottest = sensors.hottestCelsius {
                        temperatureDial(hottest, named: sensors.named.contains { $0.key == sensors.hottestSensor })
                    }
                    ForEach(sensors.fans, id: \.index) { fanDial($0) }
                }
                if sensors.fans.isEmpty { Text(PowerWording.fanSummary(sensors)).font(.meta).foregroundStyle(Theme.textTertiary) }
                let groups = SensorCatalog.groups(sensors.named)
                if !groups.isEmpty { SensorsSection(model: model, groups: groups).padding(.top, 6) }
            }
        }
    }

    private func temperatureDial(_ celsius: Double, named: Bool) -> some View {
        let tint: Color = celsius >= 95 ? Theme.danger : celsius >= 80 ? Theme.warn : Theme.teal
        let help = named ? "The warmest of the sensors MacMax can name; the SMC limit keys are left out"
            : "The warmest temperature key the SMC reports; MacMax cannot name this Mac's sensors, so a limit key may be among them"
        return dial(label: "Hottest sensor", tint: tint, fraction: (celsius - 20) / 90, help: help) {
            Text(String(format: "%.0f C", celsius)).font(.statSmall).foregroundStyle(Theme.textPrimary)
        }
    }

    private func fanDial(_ fan: Fan) -> some View {
        let low = Double(fan.minimumRPM ?? 0), high = Double(fan.maximumRPM ?? max(fan.rpm, 6_000))
        let fraction = high > low ? (Double(fan.rpm) - low) / (high - low) : 0
        return dial(label: "Fan \(fan.index + 1)", detail: "\(fan.rpm) rpm", tint: Theme.teal, fraction: fraction,
                    help: "Turns in proportion to the real speed: one turn a second per 1000 rpm") {
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
