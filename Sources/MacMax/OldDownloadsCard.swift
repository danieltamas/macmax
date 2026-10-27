import MacMaxCore
import SwiftUI

/// Files and folders in Downloads that nothing has touched for a while. Nothing is chosen for you: pick what goes.
struct OldDownloadsCard: View {
    @ObservedObject var model: PanelModel
    @State private var chosen: Set<String> = []
    @State private var confirming = false

    private static let ages = [30, 90, 180, 365]
    private static let shown = 40

    var body: some View {
        SettingsCard(title: "Old downloads", detail: "Things in Downloads you have not touched for a while. They go to the Trash, where you can put them back.") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Older than").font(.meta).foregroundStyle(Theme.textSecondary)
                    ForEach(Self.ages, id: \.self) { days in
                        Button { model.oldDownloadsDays = days; chosen = []; model.oldDownloads = nil } label: {
                            Chip(text: days == 365 ? "1 year" : "\(days) days", color: model.oldDownloadsDays == days ? Theme.teal : Theme.textTertiary,
                                 style: model.oldDownloadsDays == days ? .filled : .outline)
                        }.buttonStyle(.plain)
                    }
                }
                state
                if let items = model.oldDownloads { list(items) }
                if let progress = model.oldDownloadsProgress {
                    OperationProgress(text: progress.next.map { "Moving \(($0 as NSString).lastPathComponent)" } ?? "Finishing...",
                                      fraction: progress.total > 0 ? Double(progress.done) / Double(progress.total) : nil)
                }
                if let problem = model.cleanupLogProblem, !model.oldDownloadsResults.isEmpty { Text(problem).font(.meta).foregroundStyle(Theme.warn) }
                results
                if !model.oldDownloadsState.isLoading, !model.oldDownloadsMoving, !confirming {
                    PillButton(title: model.oldDownloads == nil ? "Find old downloads" : "Scan again", symbol: "magnifyingglass",
                               prominent: false) { chosen = []; model.scanOldDownloads() }
                    if model.oldDownloads == nil, case .ready = model.oldDownloadsState {
                        Text("macOS may ask to let MacMax look in Downloads.").font(.meta).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .onChange(of: model.oldDownloads) { _ in
            // A new list may not hold what was chosen, and a confirmation belongs to the list it was asked about.
            confirming = false
            chosen.formIntersection(Set(model.oldDownloads?.map(\.path) ?? []))
        }
    }

    @ViewBuilder private var state: some View {
        switch model.oldDownloadsState {
        case let .loading(text): OperationProgress(text: text)
        case let .failed(collector, reason): Text("\(collector): \(reason)").font(.meta).foregroundStyle(Theme.warn)
        case .ready: EmptyView()
        }
    }

    @ViewBuilder private func list(_ items: [OldDownload]) -> some View {
        let visible = Array(items.prefix(Self.shown))
        let picked = visible.filter { chosen.contains($0.path) }
        if items.isEmpty {
            Text("Nothing in Downloads is that old.").font(.meta).foregroundStyle(Theme.textSecondary)
        } else {
            Text("\(items.count) \(items.count == 1 ? "item" : "items"), \(CompactFormat.bytes(UInt64(items.reduce(Int64(0)) { saturatingAddBytes($0, $1.bytes) }))) in all")
                .font(.meta).foregroundStyle(Theme.textSecondary)
            ForEach(visible) { row($0) }
            if items.count > visible.count {
                Text("and \(items.count - visible.count) smaller ones. Move these, then scan again.").font(.meta).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 10) {
                if confirming {
                    PillButton(title: "Confirm: move to Trash", symbol: "trash") {
                        confirming = false
                        chosen = []
                        model.moveOldDownloads(picked)
                    }
                    ChipButton(title: "Cancel") { confirming = false }
                } else if !model.oldDownloadsMoving {
                    PillButton(title: picked.isEmpty ? "Choose what to move" : "Move \(picked.count) (\(CompactFormat.bytes(UInt64(picked.reduce(Int64(0)) { saturatingAddBytes($0, $1.bytes) })))) to Trash",
                               symbol: "trash", disabled: picked.isEmpty) { confirming = true }
                    ChipButton(title: picked.count == visible.count ? "Choose none" : "Choose all") {
                        chosen = picked.count == visible.count ? [] : Set(visible.map(\.path))
                    }
                }
            }
        }
    }

    private func row(_ item: OldDownload) -> some View {
        Button {
            if chosen.contains(item.path) { chosen.remove(item.path) } else { chosen.insert(item.path) }
            confirming = false
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: chosen.contains(item.path) ? "checkmark.square.fill" : "square").font(.system(size: 13))
                    .foregroundStyle(chosen.contains(item.path) ? Theme.teal : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                    Text("\(item.isDirectory ? "Folder, last" : "Last") changed \(item.modified.formatted(.relative(presentation: .named)))")
                        .font(.meta).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                Text(CompactFormat.bytes(UInt64(max(0, item.bytes)))).font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.oldDownloadsMoving)
    }

    @ViewBuilder private var results: some View {
        let done = model.oldDownloadsResults.filter { $0.outcome == .done }.count
        let left = model.oldDownloadsResults.count - done
        if !model.oldDownloadsResults.isEmpty, !model.oldDownloadsMoving {
            Text("Moved \(done) to the Trash" + (left > 0 ? ", \(left) left where they were (changed or refused)." : "."))
                .font(.meta).foregroundStyle(left > 0 ? Theme.warn : Theme.textSecondary)
        }
    }

    private func saturatingAddBytes(_ left: Int64, _ right: Int64) -> Int64 {
        let (sum, overflow) = left.addingReportingOverflow(max(right, 0))
        return overflow ? Int64.max : sum
    }
}
