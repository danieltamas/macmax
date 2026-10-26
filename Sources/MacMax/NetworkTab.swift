import MacMaxCore
import SwiftUI

struct NetworkTab: View {
    let model: PanelModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(TrafficWindow.allCases) { window in
                    SegmentChip(title: window.rawValue, selected: model.window == window) { model.window = window }
                }
                Spacer(minLength: 0)
            }
            interfaces
            IdentityCardView(model: model)
            rows
        }
    }

    @ViewBuilder
    private var interfaces: some View {
        if !model.interfaces.isEmpty, !model.samplerFailed { InterfacesCard(lines: model.interfaces) }
    }

    @ViewBuilder
    private var rows: some View {
        if model.trafficState != .ready || model.traffic.isEmpty {
            SectionStateView(state: model.trafficState, emptySymbol: "network", emptyTitle: emptyTitle,
                             emptyDetail: "Apps appear here as soon as they send or receive data.", isEmpty: model.traffic.isEmpty)
        }
        let top = model.traffic.map { $0.bytesIn + $0.bytesOut }.max() ?? 1
        VStack(spacing: 8) {
            ForEach(Array((model.trafficState == .ready ? model.traffic : []).enumerated()), id: \.element.id) { index, line in
                TrafficRow(model: model, line: line, top: top).riseIn(index)
            }
        }
    }

    private var emptyTitle: String {
        switch model.window {
        case .now: "No app is using the network right now"
        case .hour: "No app used the network in the last hour"
        case .day: "No app used the network in the last 24 hours"
        }
    }
}

struct TrafficRow: View {
    let model: PanelModel
    let line: TrafficLine
    let top: Double

    private var expanded: Bool { model.expandedApp == line.id }

    var body: some View {
        HoverCard(action: {
            withAnimation(Motion.spring) { model.expandedApp = expanded ? nil : line.id }
            if !expanded { model.loadConnections(line.id) }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(line.name).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    Spacer(minLength: 6)
                    Text(format(line.bytesIn)).foregroundStyle(Theme.netIn)
                    Text(format(line.bytesOut)).foregroundStyle(Theme.netOut)
                }
                .font(.system(size: 11.5, weight: .medium).monospacedDigit()).lineLimit(1)
                bar
                if expanded { connections }
            }
        }
    }

    private func format(_ value: Double) -> String {
        model.window == .now ? CompactFormat.rate(value) : CompactFormat.bytes(UInt64(max(0, min(value, 1.8e19))))
    }

    private var bar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 2) {
                Capsule().fill(Theme.netIn).frame(width: max(2, width * line.bytesIn / max(top, 1)))
                Capsule().fill(Theme.netOut).frame(width: max(2, width * line.bytesOut / max(top, 1)))
                Spacer(minLength: 0)
            }
        }
        .frame(height: 4)
    }

    @ViewBuilder
    private var connections: some View {
        HStack {
            Eyebrow(text: "Connections")
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Read the connections again", size: 22) { model.loadConnections(line.id) }
        }
        if model.connectionsLoading.contains(line.id) {
            Text("Reading connections...").font(.meta).foregroundStyle(Theme.textSecondary)
        } else if let lines = model.connections[line.id] {
            if lines.isEmpty {
                // Traffic with no visible socket is a system program: macOS hides another user's connections, which is not "none".
                Text(line.bytesIn + line.bytesOut > 0
                     ? "None visible to MacMax. This program is moving data, but it runs as another user (the system), and macOS does not show their connections."
                     : "No open connections.")
                    .font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(lines) { Text($0.text).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
        }
    }
}

/// The total, then the interfaces moving data now by what they are; the idle ones stay folded until asked for.
private struct InterfacesCard: View {
    let lines: [InterfaceLine]
    @State private var showIdle = false

    var body: some View {
        let active = lines.filter { $0.bsd != nil && $0.isActive }
        let idle = lines.filter { $0.bsd != nil && !$0.isActive }
        Bezel {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Interfaces")
                ForEach(lines.filter { $0.bsd == nil }) { row($0) }
                if !active.isEmpty { RowDivider() }
                ForEach(active) { row($0) }
                if active.isEmpty { Text("No interface is moving data.").font(.meta).foregroundStyle(Theme.textTertiary) }
                if !idle.isEmpty {
                    if showIdle { RowDivider(); ForEach(idle) { row($0) } }
                    ChipButton(title: showIdle ? "Hide idle interfaces" : "Show \(idle.count) idle interfaces") {
                        withAnimation(Motion.snappy) { showIdle.toggle() }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ line: InterfaceLine) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(line.name).font(.rowTitle).lineLimit(2)
                    .foregroundStyle(line.bsd == nil || line.isActive ? Theme.textPrimary : Theme.textTertiary)
                if let bsd = line.bsd { Text(bsd).font(.meta).foregroundStyle(Theme.textTertiary) }
            }
            Spacer(minLength: 6)
            Label(CompactFormat.rate(line.inPerSecond), systemImage: "arrow.down").foregroundStyle(Theme.netIn)
            Label(CompactFormat.rate(line.outPerSecond), systemImage: "arrow.up").foregroundStyle(Theme.netOut)
        }
        .font(.meta.monospacedDigit()).lineLimit(1)
    }
}
