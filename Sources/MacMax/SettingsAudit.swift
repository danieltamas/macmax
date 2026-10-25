import MacMaxCore
import SwiftUI

struct AuditPane: View {
    let model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .audit, title: "Audit", detail: "When MacMax checks this Mac against its rules, and what it tells you.")
            if let problem = model.configProblem { ProblemText(text: problem) }
            SettingsCard(title: "Schedule", detail: "The audit also runs when you press Run audit now.") {
                HStack(spacing: 6) {
                    ForEach([0, 1, 4, 12, 24], id: \.self) { hours in
                        SegmentChip(title: hours == 0 ? "Off" : "\(hours) h", selected: model.config.auditEveryHours == hours) {
                            model.change { $0.auditEveryHours = hours }
                        }
                    }
                }
                Toggle("Also audit when memory pressure turns critical", isOn: Binding(
                    get: { model.config.auditOnCriticalPressure }, set: { value in model.change { $0.auditOnCriticalPressure = value } }))
                    .toggleStyle(.switch).tint(Theme.teal).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            SettingsCard(title: "Notify on", detail: "A notification appears when a finding is new or gets worse.") {
                HStack(spacing: 6) {
                    ForEach(NotifyLevel.allCases, id: \.self) { level in
                        SegmentChip(title: Self.title(level), selected: model.config.notifyOn == level) {
                            model.change { $0.notifyOn = level }
                        }
                    }
                }
            }
            SettingsCard(title: "Rules", detail: "Each rule can be turned off and its thresholds changed. The default is shown beside each value.") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(RuleSet.all, id: \.id) { rule in RuleRow(model: model, rule: rule) }
                }
            }
        }
    }

    private static func title(_ level: NotifyLevel) -> String {
        switch level {
        case .critOnly: "CRIT only"
        case .warnAndCrit: "WARN and CRIT"
        case .never: "Never"
        }
    }
}

private struct RuleRow: View {
    let model: PanelModel
    let rule: Rule

    private var enabled: Bool { !model.config.disabledRules.contains(rule.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { enabled }, set: { on in
                model.change { config in
                    config.disabledRules.removeAll { $0 == rule.id }
                    if !on { config.disabledRules.append(rule.id) }
                }
            })) {
                Text(rule.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            }
            .toggleStyle(.switch).tint(Theme.teal)
            if enabled {
                ForEach(rule.thresholds, id: \.key) { threshold in
                    ThresholdField(model: model, threshold: threshold)
                }
            }
        }
    }
}

private struct ThresholdField: View {
    let model: PanelModel
    let threshold: Threshold
    @State private var text = ""
    @State private var problem: String?

    private var current: Double { model.config.thresholds[threshold.key] ?? threshold.defaultValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                FieldLabel(text: threshold.key.replacingOccurrences(of: "T_", with: "").lowercased().replacingOccurrences(of: "_", with: " "))
                    .lineLimit(1)
                Spacer(minLength: 6)
                GlassField(placeholder: Self.text(threshold.defaultValue), text: $text, monospaced: true)
                    .frame(width: 90).onSubmit(commit)
                Text("\(threshold.unit), default \(Self.text(threshold.defaultValue))").font(.meta)
                    .foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize()
                if model.config.thresholds[threshold.key] != nil {
                    Button("Reset") { model.change { $0.thresholds[threshold.key] = nil }; text = Self.text(threshold.defaultValue); problem = nil }
                        .buttonStyle(PressStyle()).font(.meta).foregroundStyle(Theme.teal)
                }
            }
            if let problem { ProblemText(text: problem) }
        }
        .onAppear { text = Self.text(current) }
    }

    private func commit() {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else {
            problem = "Enter a number."
            return
        }
        guard threshold.range.contains(value) else {
            problem = "Use a value from \(Self.text(threshold.range.lowerBound)) to \(Self.text(threshold.range.upperBound))."
            return
        }
        problem = nil
        model.change { $0.thresholds[threshold.key] = value == threshold.defaultValue ? nil : value }
    }

    private static func text(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }
}
