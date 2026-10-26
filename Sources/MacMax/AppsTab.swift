import MacMaxCore
import SwiftUI

struct AppsTab: View {
    let model: PanelModel

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(AppSort.allCases, id: \.self) { sort in
                    SegmentChip(title: Self.title(sort), selected: model.sort == sort) { model.sort = sort }
                }
                Spacer(minLength: 0)
            }
            GlassField(placeholder: "Search name, bundle id or pid", text: $model.query)
            filterRow
            list
        }
    }

    static func title(_ sort: AppSort) -> String {
        switch sort {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        }
    }

    private static func title(_ filter: AppFilter) -> String {
        switch filter {
        case .all: "All"
        case .apps: "Apps"
        case .background: "Background"
        case .claudeCode: "Claude Code"
        case .docker: "Docker"
        }
    }

    private var filterRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(AppFilter.allCases, id: \.self) { filter in
                    SegmentChip(title: Self.title(filter), selected: model.filter == filter) { model.filter = filter }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var list: some View {
        let rows = model.visibleApps
        let page = AppListing.page(rows, shown: model.shown)
        if model.appsState != .ready || rows.isEmpty {
            SectionStateView(state: model.appsState, emptySymbol: "square.grid.2x2",
                             emptyTitle: model.apps.isEmpty ? "No apps measured yet" : "No app matches",
                             emptyDetail: model.apps.isEmpty ? nil : "Clear the search or pick another filter.", isEmpty: rows.isEmpty)
        }
        VStack(spacing: 8) {
            ForEach(Array((model.appsState == .ready ? page.visible : []).enumerated()), id: \.element.id) { index, row in
                AppRowView(model: model, row: row).riseIn(index)
            }
            if page.remaining > 0 {
                Button("Show \(min(page.remaining, AppListing.pageSize)) more") { model.shown += AppListing.pageSize }
                    .buttonStyle(PressStyle()).font(.meta).foregroundStyle(Theme.teal)
            }
        }
    }
}

struct AppRowView: View {
    let model: PanelModel
    let row: AppRow

    private var expanded: Bool { model.expandedApp == row.id }

    var body: some View {
        HoverCard(action: { withAnimation(Motion.spring) { model.expandedApp = expanded ? nil : row.id } }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    AppIcon(bundleID: row.bundleID, fallback: symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        Text("\(row.processCount) process\(row.processCount == 1 ? "" : "es")").font(.meta)
                            .foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(CompactFormat.percent(row.cpuPercent)).foregroundStyle(Theme.cpu)
                        Text(row.footprintBytes.map(CompactFormat.bytes) ?? "-").foregroundStyle(Theme.memory)
                    }
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit()).lineLimit(1).fixedSize()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(row.diskBytesPerSecond.map(CompactFormat.rate) ?? "-").foregroundStyle(Theme.disk)
                        Text(row.networkBytesPerSecond.map(CompactFormat.rate) ?? "-").foregroundStyle(Theme.netIn)
                    }
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit()).lineLimit(1).fixedSize()
                }
                if expanded { details }
            }
        }
    }

    private var symbol: String {
        switch row.kind {
        case .app: "app"
        case .background: "gearshape"
        case .claudeCode: "terminal"
        case .docker: "shippingbox"
        }
    }

    @ViewBuilder
    private var details: some View {
        if row.name.contains("Chrome") {
            Text("Chrome's own Task Manager (Window > Task Manager) shows memory per tab; macOS does not expose it to other apps.")
                .font(.meta).foregroundStyle(Theme.textTertiary)
        }
        let lines = model.processes[row.id] ?? []
        if lines.isEmpty {
            Text("No process detail kept for this app.").font(.meta).foregroundStyle(Theme.textTertiary)
        }
        ForEach(lines) { line in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text("\(CompactFormat.percent(line.cpuPercent))  \(line.footprintBytes.map(CompactFormat.bytes) ?? "-")")
                        .font(.meta.monospacedDigit()).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
                }
                HStack(spacing: 8) {
                    Text("pid \(line.pid)").font(.meta.monospacedDigit()).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    if line.isTranslated { Chip(text: "Rosetta", color: Theme.warn, style: .outline) }
                }
                if let command = line.commandLine {
                    Text(command).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
