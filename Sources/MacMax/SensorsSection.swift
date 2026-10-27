import MacMaxCore
import SwiftUI

/// The named sensors as a flat grid of groups inside the card: an icon, the group, its hottest reading and average,
/// a thin bar on the dial's scale. One group opens at a time, directly under the row of the cell that was pressed, so
/// the detail appears where the eye already is. No box of its own: the card is the box. Only catalog sensors appear;
/// an unnamed key is counted in the hottest-sensor dial, never listed.
struct SensorsSection: View {
    @ObservedObject var model: PanelModel
    let groups: [SensorGroupSummary]
    private let perRow = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sensors").font(.meta).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(groups.reduce(0) { $0 + $1.sensors.count }) named").font(.meta.monospacedDigit()).foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, 2)
            ForEach(rows, id: \.first?.group) { row in
                HStack(alignment: .top, spacing: 6) {
                    ForEach(row, id: \.group) { summary in
                        SensorCell(summary: summary, selected: model.expandedSensorGroup == summary.group) { select(summary.group) }
                    }
                    ForEach(0..<(perRow - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, minHeight: 1) }
                }
                if let open = row.first(where: { $0.group == model.expandedSensorGroup }) {
                    SensorList(summary: open).padding(.vertical, 2)
                }
            }
        }
    }

    private var rows: [[SensorGroupSummary]] {
        stride(from: 0, to: groups.count, by: perRow).map { Array(groups[$0..<min($0 + perRow, groups.count)]) }
    }

    private func select(_ group: SensorGroup) {
        withAnimation(Motion.spring) { model.expandedSensorGroup = model.expandedSensorGroup == group ? nil : group }
    }
}

private struct SensorCell: View {
    let summary: SensorGroupSummary
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { cell }
            .buttonStyle(.plain)
            .pointingHandCursor(true)
            .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
            .help(summary.group == .power ? "What the Mac draws and what each port supplies" : "Hottest reading in the group; which sensor is which core is model specific")
            .accessibilityLabel("\(summary.group.title), \(headline)\(detail.isEmpty ? "" : ", " + detail), \(summary.sensors.count) \(summary.sensors.count == 1 ? "sensor" : "sensors")")
            .accessibilityHint(selected ? "Hides the sensors in the group" : "Lists the sensors in the group")
    }

    private var cell: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: summary.group.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                Text(summary.group.title).font(.meta).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(summary.sensors.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    .help(summary.sensors.count == 1 ? "1 sensor" : "\(summary.sensors.count) sensors")
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(headline).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(headlineTint).lineLimit(1)
                Text(detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            SensorBar(fraction: fraction, tint: barTint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.control - 2, style: .continuous)
            .fill(selected ? Theme.coreHover : hovering ? Theme.coreHover.opacity(0.55) : .clear))
        .contentShape(Rectangle())
    }

    /// The power cell headlines the draw at the wall, or the system total when the wall figure does not read.
    private var watts: (sensor: NamedSensor, label: String)? {
        if let wall = summary.sensors.first(where: { $0.key == "PDTR" }) { return (wall, "in") }
        if let total = summary.sensors.first(where: { $0.key == "PSTR" }) { return (total, "total") }
        return nil
    }

    private var headline: String {
        if let hottest = summary.hottestCelsius { return SensorText.celsius(hottest, decimals: 0) }
        if let watts { return String(format: "%.0f W", watts.sensor.value) }
        return "\(summary.sensors.count)"
    }

    private var detail: String {
        if let average = summary.averageCelsius, summary.sensors.count > 1 { return "avg \(Int(average.rounded()))" }
        return watts?.label ?? ""
    }

    private var headlineTint: Color { summary.hottestCelsius.map(SensorText.tint) ?? Theme.textPrimary }

    /// Neutral until the warn and danger thresholds: a colored bar would read as a health verdict.
    private var barTint: Color {
        guard let hottest = summary.hottestCelsius, hottest >= 80 else { return Theme.textTertiary }
        return SensorText.tint(hottest)
    }

    /// The dial's scale: 20 C to 110 C. The power cell's bar is its draw against 100 W, so a heavy load reads at a glance.
    private var fraction: Double {
        if let hottest = summary.hottestCelsius { return (hottest - 20) / 90 }
        return (watts?.sensor.value ?? 0) / 100
    }
}

private struct SensorBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(tint).frame(width: geometry.size.width * min(1, max(0.03, fraction)))
            }
        }
        .frame(height: 2.5)
    }
}

/// The open group's sensors, two to a line, name left and reading right; a rail that reports volts, amps and watts
/// is one line.
private struct SensorList: View {
    let summary: SensorGroupSummary

    private var lines: [(name: String, sensors: [NamedSensor])] {
        summary.sensors.reduce(into: []) { lines, sensor in
            if let index = lines.firstIndex(where: { $0.name == sensor.name }) { lines[index].sensors.append(sensor) } else { lines.append((sensor.name, [sensor])) }
        }
    }

    var body: some View {
        let lines = lines
        let twoColumns = summary.group != .power && lines.allSatisfy { Self.shortName($0.name).count <= 16 }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: twoColumns ? 2 : 1), alignment: .leading, spacing: 3) {
            ForEach(lines, id: \.name) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.shortName(line.name)).font(.meta).foregroundStyle(Theme.textSecondary).lineLimit(1).help(line.name)
                    Spacer(minLength: 4)
                    Text(line.sensors.map(SensorText.value).joined(separator: ", ")).font(.meta.monospacedDigit())
                        .foregroundStyle(line.sensors.first.map { $0.unit == .celsius ? SensorText.tint($0.value) : Theme.textPrimary } ?? Theme.textPrimary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    /// Two columns of 404 points leave no room for "CPU performance core 10": the core rows say "P core 10".
    static func shortName(_ name: String) -> String {
        if name.hasPrefix("CPU performance core ") { return "P core " + name.dropFirst("CPU performance core ".count) }
        if name.hasPrefix("CPU efficiency core ") { return "E core " + name.dropFirst("CPU efficiency core ".count) }
        return name
    }
}

extension SensorGroup {
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .battery: "battery.75"
        case .wireless: "wifi"
        case .airflow: "wind"
        case .power: "bolt"
        }
    }
}

@MainActor
enum SensorText {
    static func tint(_ celsius: Double) -> Color { celsius >= 95 ? Theme.danger : celsius >= 80 ? Theme.warn : Theme.textPrimary }

    static func celsius(_ value: Double, decimals: Int) -> String { String(format: "%.\(decimals)f C", value) }

    static func value(_ sensor: NamedSensor) -> String {
        switch sensor.unit {
        case .celsius: celsius(sensor.value, decimals: 1)
        case .volts: String(format: "%.2f V", sensor.value)
        case .amps: String(format: "%.2f A", sensor.value)
        case .watts: String(format: "%.1f W", sensor.value)
        }
    }
}
