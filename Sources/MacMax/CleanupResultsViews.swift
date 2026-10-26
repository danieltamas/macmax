import MacMaxCore
import SwiftUI

/// A summary first; the item-by-item list opens on a press and stops at a page, so a long cleanup never fills the panel.
private struct Details<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    Text(open ? "Hide details" : title).font(.meta.weight(.medium))
                }
                .foregroundStyle(Theme.teal)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content }
        }
    }
}

@MainActor private func itemLine(_ name: String, _ note: String, color: Color = Theme.textSecondary) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(name).font(.meta).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 6)
        Text(note).font(.meta.monospacedDigit()).foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize()
    }
}

private let pageSize = 40

private func items(_ count: Int) -> String { "\(count) item\(count == 1 ? "" : "s")" }

/// The last press: how much went, grouped by rule, with the skipped and failed ones counted apart.
struct JustMovedCard: View {
    let model: PanelModel

    private struct Moved { let name: String; let rule: String; let bytes: Int64 }

    private var moved: [Moved] {
        zip(model.cleanupMovedFrom, model.cleanupResults).compactMap { candidate, result in
            guard case .done = result.outcome else { return nil }
            return Moved(name: (result.path as NSString).lastPathComponent, rule: candidate.ruleID, bytes: max(candidate.bytes, 0))
        }
    }

    private var others: [(name: String, reason: String, failed: Bool)] {
        model.cleanupResults.compactMap { result in
            switch result.outcome {
            case .done: nil
            case let .refused(reason): ((result.path as NSString).lastPathComponent, reason, false)
            case let .failed(reason): ((result.path as NSString).lastPathComponent, reason, true)
            }
        }
    }

    var body: some View {
        let moved = moved, others = others
        let bytes = moved.reduce(Int64(0)) { $0 + $1.bytes }
        SettingsCard(title: "Just moved", detail: "To the Trash, so you can put it back.") {
            VStack(alignment: .leading, spacing: 8) {
                if let problem = model.cleanupLogProblem { Text(problem).font(.meta).foregroundStyle(Theme.warn) }
                Text(moved.isEmpty ? "Nothing was moved." : "\(items(moved.count)), \(CompactFormat.bytes(UInt64(bytes)))")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                ForEach(RuleText.rows.filter { rule in moved.contains { $0.rule == rule.id } }, id: \.id) { rule in
                    let group = moved.filter { $0.rule == rule.id }
                    itemLine(rule.title, "\(items(group.count)), \(CompactFormat.bytes(UInt64(group.reduce(Int64(0)) { $0 + $1.bytes })))")
                }
                if !others.isEmpty {
                    let failed = others.filter(\.failed).count
                    Text("\(others.count - failed) skipped" + (failed > 0 ? ", \(failed) failed" : ""))
                        .font(.meta).foregroundStyle(failed > 0 ? Theme.crit : Theme.warn)
                }
                if moved.count + others.count > 0 {
                    Details(title: "Show \(items(moved.count + others.count))") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(others.prefix(pageSize).enumerated()), id: \.offset) { _, item in
                                itemLine(item.name, item.reason, color: item.failed ? Theme.crit : Theme.warn)
                            }
                            ForEach(Array(moved.prefix(pageSize).enumerated()), id: \.offset) { _, item in
                                itemLine(item.name, CompactFormat.bytes(UInt64(item.bytes)))
                            }
                            if moved.count > pageSize { Text("and \(moved.count - pageSize) more moved").font(.meta).foregroundStyle(Theme.textTertiary) }
                        }
                    }
                }
            }
        }
    }
}

/// Earlier cleanups, one row per press: when, how many, and the items on request.
struct LastCleanupsCard: View {
    let model: PanelModel

    /// Rows logged within two minutes of each other came from one press.
    private var runs: [[ActionRow]] {
        var result: [[ActionRow]] = []
        for row in model.lastCleanups {
            if let last = result.last?.last, last.ts - row.ts <= 120 { result[result.count - 1].append(row) } else { result.append([row]) }
        }
        return result
    }

    var body: some View {
        SettingsCard(title: "Last cleanups", detail: "What went to the Trash, and when.") {
            VStack(alignment: .leading, spacing: 10) {
                if model.lastCleanups.isEmpty { Text("Nothing has been cleaned yet.").font(.meta).foregroundStyle(Theme.textTertiary) }
                ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                    if index > 0 { RowDivider() }
                    RunRow(run: run)
                }
            }
        }
    }

    private struct RunRow: View {
        let run: [ActionRow]

        var body: some View {
            let trashed = run.filter { $0.result == "trashed" }.count
            let failed = run.filter { $0.result == "failed" }.count
            let skipped = run.count - trashed - failed
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Date(timeIntervalSince1970: TimeInterval(run[0].ts)).formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 6)
                    Text("\(trashed) moved" + (skipped > 0 ? ", \(skipped) skipped" : "") + (failed > 0 ? ", \(failed) failed" : ""))
                        .font(.meta).foregroundStyle(failed > 0 ? Theme.crit : Theme.textSecondary)
                }
                Details(title: "Show \(items(run.count))") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(run.prefix(pageSize).enumerated()), id: \.offset) { _, row in
                            itemLine((row.target as NSString).lastPathComponent, row.detail ?? row.result,
                                     color: row.result == "trashed" ? Theme.textSecondary : Theme.warn)
                        }
                        if run.count > pageSize { Text("and \(run.count - pageSize) more").font(.meta).foregroundStyle(Theme.textTertiary) }
                    }
                }
            }
        }
    }
}
