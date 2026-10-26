import MacMaxCore
import SwiftUI

struct OverviewTab: View {
    let model: PanelModel

    var body: some View {
        VStack(spacing: 12) {
            verdictCard
            vitalsGrid
            ThisMacCard(model: model)
            PowerHealthCard(model: model)
            IdentityCardView(model: model)
            if model.appsState == .ready { consumers }
        }
    }

    private var headline: String {
        guard let verdict = model.verdict else { return "Checking this Mac..." }
        let count = model.openFindings.count
        switch verdict {
        case .ok: return "Nothing is slowing this Mac"
        case .unknown: return "This Mac could not be fully checked"
        case .warn, .crit: return count == 1 ? "1 thing is slowing this Mac" : "\(count) things are slowing this Mac"
        }
    }

    private var verdictCard: some View {
        Bezel(glow: model.verdict.map { Theme.color($0) }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    GlyphDisc(symbol: symbol, color: Theme.color(model.verdict), size: 30)
                    Text(headline).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                }
                if case let .failed(collector, reason) = model.auditState {
                    Text("\(collector): \(reason)").font(.meta).foregroundStyle(Theme.textTertiary)
                } else if case let .loading(text) = model.auditState {
                    Text(text).font(.meta).foregroundStyle(Theme.textSecondary)
                }
                ForEach(Array(model.openFindings.prefix(3)), id: \.ruleID) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.color(finding.severity)).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(finding.title).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let action = finding.action {
                                Text(action).font(.meta).foregroundStyle(Theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                HStack {
                    PillButton(title: model.auditRunning ? "Auditing..." : "Run audit now", symbol: "play.fill") { model.runAudit() }
                        .disabled(model.auditRunning)
                    if let note = model.storageNote {
                        Text(note).font(.meta).foregroundStyle(Theme.warn).lineLimit(1)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var symbol: String {
        switch model.verdict {
        case .ok: "checkmark.seal"
        case .warn, .crit: "exclamationmark.triangle"
        default: "questionmark.circle"
        }
    }

    @ViewBuilder
    private var vitalsGrid: some View {
        if model.vitals.isEmpty || model.vitalsState != .ready {
            SectionStateView(state: model.vitalsState, emptySymbol: "gauge", emptyTitle: "No readings yet", isEmpty: model.vitals.isEmpty)
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(model.vitals) { vital in
                    VitalTile(vital: vital) { model.select(destination(vital.kind), sort: sort(vital.kind)) }
                }
            }
        }
    }

    private func destination(_ kind: Vital.Kind) -> PanelTab {
        kind == .netIn || kind == .netOut ? .network : .apps
    }

    private func sort(_ kind: Vital.Kind) -> AppSort? {
        switch kind {
        case .cpu: .cpu
        case .memory, .swap: .memory
        case .disk: .disk
        case .netIn, .netOut: .network
        }
    }

    private var consumers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Heaviest right now")
            if model.topConsumers.isEmpty {
                Text("Waiting for the first readings...").font(.meta).foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(model.topConsumers.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.label).font(.meta).foregroundStyle(Theme.textTertiary).frame(width: 64, alignment: .leading).lineLimit(1)
                    Text(row.app).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(row.value).font(.meta.monospacedDigit()).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

struct VitalTile: View {
    let vital: Vital
    let action: () -> Void

    var body: some View {
        HoverCard(accent: vital.edge.map { Theme.color($0) }, action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: vital.kind.rawValue, color: Theme.color(vital.kind))
                Text(vital.value).font(.statSmall.monospacedDigit()).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(vital.detail).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
                Sparkline(values: vital.series, color: Theme.color(vital.kind)).frame(height: 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct IdentityCardView: View {
    let model: PanelModel

    var body: some View {
        Bezel(glow: model.identity.map { color($0.verdict) }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Eyebrow(text: "Network identity")
                    Spacer()
                    if let card = model.identity { Chip(text: chipText(card), color: color(card.verdict), style: .tinted) }
                }
                if let card = model.identity { details(card) } else {
                    SectionStateView(state: model.identityState, emptySymbol: "network", emptyTitle: "No identity yet")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func details(_ card: IdentityCard) -> some View {
        if !card.checkEnabled {
            HStack {
                Text("The public IP check is off. Turn it on in Settings to see your address and detect leaks.")
                    .font(.meta).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 6)
                LinkButton(title: "Turn on") { model.openSettings(.network) }
            }
        }
        if let ip = card.publicIP { addressRow("Public IP", ip, card.publicCountry) }
        if let ip = card.ispIP, !card.vpnLines.isEmpty { addressRow("ISP IP", ip, card.ispCountry) }
        ForEach(Array(card.vpnLines.enumerated()), id: \.offset) { _, line in
            Text(line).font(.meta).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        if let reason = card.reason { Text(reason).font(.meta).foregroundStyle(Theme.textTertiary) }
        if let note = card.changeNote { Text(note).font(.meta).foregroundStyle(Theme.textTertiary) }
    }

    private func addressRow(_ label: String, _ ip: String, _ country: String?) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.meta).foregroundStyle(Theme.textTertiary).frame(width: 56, alignment: .leading)
            Text(ip).font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textPrimary).lineLimit(1)
            if let country { Chip(text: country, style: .outline) }
            Spacer(minLength: 4)
            IconButton(symbol: "doc.on.doc", help: "Copy \(ip)", size: 22) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ip, forType: .string)
            }
        }
    }

    private func color(_ verdict: LeakVerdict) -> Color {
        switch verdict {
        case .tunnelOK: Theme.ok
        case .leak: Theme.crit
        case .splitTunnel: Theme.warn
        case .noVPN, .off: Theme.neutral
        case .unknown: Theme.unknown
        }
    }

    private func chipText(_ card: IdentityCard) -> String {
        switch card.verdict {
        case .tunnelOK: card.vpnName.map { "Traffic goes through \($0)" } ?? "Traffic goes through a VPN"
        case .leak: "Traffic is leaving outside the VPN"
        case .splitTunnel: "Only some traffic uses the VPN"
        case .noVPN: "No VPN"
        case .off: "Check off"
        case .unknown: "Unknown"
        }
    }
}
