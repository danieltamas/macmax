import AppKit
import MacMaxCore
import SwiftUI

/// What each cleanup rule removes, in the words the pane shows.
private enum RuleText {
    static let rows: [(id: String, title: String, detail: String)] = [
        ("app_caches", "App caches", "Caches of apps that are not running."),
        ("xcode_derived", "Xcode build data", "DerivedData, when Xcode is not running."),
        ("simulator_caches", "Simulator caches", "iOS Simulator caches."),
        ("npm_cache", "npm cache", "The package download cache."),
        ("yarn_cache", "Yarn cache", "The package download cache."),
        ("pip_cache", "pip cache", "The package download cache."),
        ("homebrew_cache", "Homebrew downloads", "Downloaded bottles and sources."),
        ("old_logs", "Old logs", "Log files older than 30 days."),
    ]
}

struct CleanupPane: View {
    let model: PanelModel
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .cleanup, title: "Cleanup", detail: "Reclaim space from caches. Everything goes to the Trash, so you can put it back.")
            rules
            if !model.cleanupResults.isEmpty { results }
            LargeFoldersCard(model: model)
            ProtectedPathsCard(model: model)
            shownOnly
            history
        }
        .task { if model.cleanupPreview == nil { model.scanCleanup() } }
    }

    private var total: Int64 { model.cleanupPreview?.bytes() ?? 0 }

    private var rules: some View {
        SettingsCard(title: "Cleanup rules", detail: "What each rule removes and how big it is now.") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(RuleText.rows.enumerated()), id: \.element.id) { index, rule in
                    let items = model.cleanupPreview?.candidates.filter { $0.ruleID == rule.id } ?? []
                    let partial = model.cleanupPreview?.skipped.contains { $0.ruleID == rule.id } ?? false
                    if index > 0 { RowDivider() }
                    SettingsRow(title: rule.title, detail: rule.detail) {
                        // A rule that skipped something has no complete size: unknown if nothing was measured, a floor otherwise.
                        Text(Self.size(model.cleanupPreview?.bytes(ofRule: rule.id), items: items, partial: partial))
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                }
                if case let .loading(text) = model.cleanupState { Text(text).font(.meta).foregroundStyle(Theme.textTertiary) }
                if case let .failed(_, reason) = model.cleanupState { Text(reason).font(.meta).foregroundStyle(Theme.warn) }
                skipped
                HStack(spacing: 10) {
                    PillButton(title: "Scan again", symbol: "arrow.clockwise", prominent: false) { confirming = false; model.scanCleanup() }
                    if confirming {
                        PillButton(title: "Confirm: move to Trash", symbol: "trash") {
                            confirming = false
                            model.moveToTrash(model.cleanupPreview?.candidates ?? [])
                        }
                        ChipButton(title: "Cancel") { confirming = false }
                    } else {
                        PillButton(title: total > 0 ? "Move \(CompactFormat.bytes(UInt64(total))) to Trash" : "Nothing to move", symbol: "trash") {
                            confirming = true
                        }
                        .disabled(total <= 0 || model.cleanupMoving || model.cleanupState != .ready)
                    }
                }
                if model.cleanupMoving { Text("Moving to the Trash...").font(.meta).foregroundStyle(Theme.textSecondary) }
            }
        }
    }

    private static func size(_ bytes: Int64?, items: [CleanupCandidate], partial: Bool) -> String {
        guard let bytes, !(partial && items.isEmpty) else { return "-" }
        return CompactFormat.bytes(UInt64(bytes)) + (partial ? "+" : "")
    }

    @ViewBuilder
    private var skipped: some View {
        let skips = model.cleanupPreview?.skipped ?? []
        if !skips.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: "Left alone")
                ForEach(Array(skips.enumerated()), id: \.offset) { _, skip in
                    Text("\((skip.path as NSString).lastPathComponent): \(skip.reason)").font(.meta)
                        .foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var results: some View {
        SettingsCard(title: "Just moved", detail: "The result of the last press, item by item.") {
            VStack(alignment: .leading, spacing: 4) {
                if let problem = model.cleanupLogProblem { Text(problem).font(.meta).foregroundStyle(Theme.warn) }
                ForEach(Array(model.cleanupResults.enumerated()), id: \.offset) { _, result in
                    let (text, color) = Self.describe(result.outcome)
                    Text("\((result.path as NSString).lastPathComponent): \(text)").font(.meta).foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func describe(_ outcome: ActionOutcome) -> (String, Color) {
        switch outcome {
        case .done: ("moved to the Trash", Theme.textSecondary)
        case let .refused(reason): ("skipped, \(reason)", Theme.warn)
        case let .failed(reason): ("failed, \(reason)", Theme.crit)
        }
    }

    private var shownOnly: some View {
        SettingsCard(title: "Docker and Time Machine", detail: "MacMax shows these commands and never runs them. Copy one into a terminal if you want it.") {
            VStack(alignment: .leading, spacing: 8) {
                CommandLine(command: "docker system df")
                CommandLine(command: "docker system prune")
                CommandLine(command: "tmutil listlocalsnapshots /")
                Text("Never add --volumes to a prune: it removes data volumes.").font(.meta).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var history: some View {
        SettingsCard(title: "Last cleanups", detail: "What went to the Trash, and when.") {
            VStack(alignment: .leading, spacing: 4) {
                if model.lastCleanups.isEmpty { Text("Nothing has been cleaned yet.").font(.meta).foregroundStyle(Theme.textTertiary) }
                ForEach(Array(model.lastCleanups.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Date(timeIntervalSince1970: TimeInterval(row.ts)).formatted(date: .abbreviated, time: .shortened))
                            .font(.meta.monospacedDigit()).foregroundStyle(Theme.textTertiary).fixedSize()
                        Text("\((row.target as NSString).lastPathComponent): \(row.result)").font(.meta).foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

private struct CommandLine: View {
    let command: String

    var body: some View {
        HStack {
            Text(command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: 6)
            IconButton(symbol: "doc.on.doc", help: "Copy the command", size: 22) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }
}

private struct ProtectedPathsCard: View {
    let model: PanelModel

    var body: some View {
        SettingsCard(title: "Protected paths", detail: "Never touched, also through a link. Your documents, keys, mail, app data and anything under git are always protected.") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.config.protectedPaths, id: \.self) { path in
                    HStack {
                        Text(path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        IconButton(symbol: "minus.circle", help: "Stop protecting this folder", size: 22) {
                            model.change { $0.protectedPaths.removeAll { $0 == path } }
                            model.scanCleanup()
                        }
                    }
                }
                PillButton(title: "Add a folder", symbol: "plus", prominent: false) { choose() }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Protect"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.change { $0.protectedPaths.append(url.path) }
        model.scanCleanup()
    }
}
