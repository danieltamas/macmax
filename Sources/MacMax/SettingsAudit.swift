import MacMaxCore
import SwiftUI

struct AuditPane: View {
    @ObservedObject var model: PanelModel

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
                RowDivider()
                SwitchRow(title: "Also audit when memory pressure turns critical", isOn: Binding(
                    get: { model.config.auditOnCriticalPressure }, set: { value in model.change { $0.auditOnCriticalPressure = value } }))
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
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(RuleSet.all.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { RowDivider() }
                        RuleRow(model: model, rule: rule)
                    }
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
    @ObservedObject var model: PanelModel
    let rule: Rule

    private var enabled: Bool { !model.config.disabledRules.contains(rule.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SwitchRow(title: rule.title, isOn: Binding(get: { enabled }, set: { on in
                model.change { config in
                    config.disabledRules.removeAll { $0 == rule.id }
                    if !on { config.disabledRules.append(rule.id) }
                }
            }))
            if enabled {
                ForEach(rule.thresholds, id: \.key) { threshold in
                    ThresholdField(model: model, threshold: threshold)
                }
            }
        }
    }
}

private struct ThresholdField: View {
    @ObservedObject var model: PanelModel
    let threshold: Threshold
    @State private var text = ""
    @State private var problem: String?

    private var current: Double { model.config.thresholds[threshold.key] ?? threshold.defaultValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(Self.label(threshold.key)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    .padding(.leading, 14).frame(maxWidth: .infinity, alignment: .leading)
                GlassField(placeholder: Self.text(threshold.defaultValue), text: $text, monospaced: true)
                    .frame(width: SettingsMetrics.fieldWidth).onSubmit(commit)
                Text("\(threshold.unit), default \(Self.text(threshold.defaultValue))").font(.meta)
                    .foregroundStyle(Theme.textTertiary).lineLimit(1)
                    .frame(width: SettingsMetrics.unitWidth, alignment: .leading)
                Group {
                    if model.config.thresholds[threshold.key] != nil {
                        ChipButton(title: "Reset") {
                            model.change { $0.thresholds[threshold.key] = nil }
                            text = Self.text(threshold.defaultValue)
                            problem = nil
                        }
                    }
                }
                .frame(width: SettingsMetrics.resetWidth, alignment: .trailing)
            }
            .frame(minHeight: SettingsMetrics.rowHeight)
            if let problem { ProblemText(text: problem).padding(.leading, 14) }
        }
        .onAppear { text = Self.text(current) }
    }

    /// "T_UPTIME_CRIT_D" reads "Uptime critical": the prefix and the one-letter unit suffix go, the words are spelled out.
    static func label(_ key: String) -> String {
        let words: [String: String] = ["CRIT": "critical", "WARN": "warning", "PCT": "percent", "MB": "size", "PROC": "process",
                                       "RSS": "memory", "CPU": "CPU", "RAM": "RAM"]
        var tokens = key.hasPrefix("T_") ? key.dropFirst(2).split(separator: "_").map(String.init) : key.split(separator: "_").map(String.init)
        if tokens.count > 1, tokens.last?.count == 1 { tokens.removeLast() }
        let text = tokens.map { words[$0] ?? $0.lowercased() }.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
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
