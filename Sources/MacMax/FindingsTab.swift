import MacMaxCore
import SwiftUI

struct FindingsTab: View {
    let model: PanelModel

    var body: some View {
        VStack(spacing: 10) {
            if model.auditedAt == nil && model.auditState == .ready {
                EmptyState(symbol: "checkmark.seal", title: "No audit has run yet",
                           detail: "Press Run audit now on the Overview tab, or turn the schedule on in Settings.").frame(height: 180)
            } else if model.auditState != .ready || (model.openFindings.isEmpty && model.unknowns.isEmpty) {
                SectionStateView(state: model.auditState, emptySymbol: "checkmark.seal", emptyTitle: "Nothing to fix",
                                 emptyDetail: "Every rule that could be checked passed.", isEmpty: model.openFindings.isEmpty && model.unknowns.isEmpty)
            }
            ForEach(Array(model.openFindings.enumerated()), id: \.element.ruleID) { index, finding in
                FindingCard(model: model, finding: finding).riseIn(index)
            }
            if !model.unknowns.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Could not check")
                    ForEach(model.unknowns, id: \.ruleID) { unknown in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(unknown.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Text(unknown.reason).font(.meta).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }
        }
    }
}

struct FindingCard: View {
    let model: PanelModel
    let finding: Finding

    var body: some View {
        HoverCard(accent: Theme.color(finding.severity), action: nil) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Chip(text: finding.severity.label, color: Theme.color(finding.severity), style: .filled)
                    Text(finding.title).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                }
                ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.key).font(.meta).foregroundStyle(Theme.textTertiary)
                        Text(item.value).font(.meta.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                }
                if !finding.why.isEmpty {
                    Text(finding.why).font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let action = finding.action {
                        Text("Next: \(action)").font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.teal).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    if let pill = FindingPill.of(finding.ruleID) {
                        PillButton(title: pill.title, symbol: pill.symbol, prominent: false) { pill.run(model) }
                    }
                    Button("Snooze 24 h") { model.snooze(finding.ruleID) }
                        .buttonStyle(PressStyle()).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// An action pill acts inside the app: it takes the user to where the finding can be dealt with.
struct FindingPill {
    let title: String
    let symbol: String
    let run: @MainActor (PanelModel) -> Void

    static func of(_ ruleID: String) -> FindingPill? {
        switch ruleID {
        case "claude_stale":
            FindingPill(title: "Show sessions", symbol: "terminal") { $0.show(.claudeCode) }
        case "docker_hot_containers", "docker_vm_compressed":
            FindingPill(title: "Show containers", symbol: "shippingbox") {
                $0.show(.docker)
                $0.loadContainers()
            }
        case "disk_free":
            FindingPill(title: "Review cache cleanup", symbol: "trash") { $0.openSettings(.cleanup) }
        default: nil
        }
    }
}

extension PanelModel {
    /// Takes the user to the Apps tab with the first app of that kind open, so what the finding is about is on screen.
    func show(_ kind: AppKind) {
        filter = kind == .docker ? .docker : .claudeCode
        tab = .apps
        query = ""
        shown = AppListing.pageSize
        // The first row as the list shows it, so it is on the first page.
        expandedApp = visibleApps.first { $0.kind == kind }?.id
    }
}
