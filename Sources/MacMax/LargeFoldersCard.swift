import AppKit
import MacMaxCore
import SwiftUI

/// The biggest folders and files under home, for the cleanup that no rule covers. Shown, never removed: the owner
/// looks in Finder and decides.
struct LargeFoldersCard: View {
    let model: PanelModel

    var body: some View {
        SettingsCard(title: "Large folders", detail: "The biggest places under your home folder. MacMax only shows them; nothing here is deleted.") {
            VStack(alignment: .leading, spacing: 8) {
                switch model.largeState {
                case let .loading(text): Text(text).font(.meta).foregroundStyle(Theme.textSecondary)
                case let .failed(collector, reason): Text("\(collector): \(reason)").font(.meta).foregroundStyle(Theme.warn)
                case .ready: EmptyView()
                }
                if let items = model.largeItems {
                    if model.largeIncomplete {
                        Text("Some folders could not be read, so this list may be missing the biggest ones. Full Disk Access (Permissions) lets MacMax read them.")
                            .font(.meta).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                    } else if items.isEmpty {
                        Text("Nothing over 500 MB was found.").font(.meta).foregroundStyle(Theme.textSecondary)
                    }
                    if model.largeSkippedPrivate {
                        Text("Desktop, Documents, Downloads, iCloud Drive and other apps' data were left out: MacMax has no access to them yet.")
                            .font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(items, id: \.path) { row($0) }
                }
                if !model.largeState.isLoading {
                    PillButton(title: model.largeItems == nil ? "Find large folders" : "Measure again", symbol: "magnifyingglass",
                               prominent: false) { model.scanLarge() }
                }
            }
        }
    }

    private func row(_ item: LargeItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text((item.path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if item.isProtected { Chip(text: "Protected", color: Theme.textTertiary, style: .outline) }
                }
                Text(Self.shortened(item.path)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                if let modified = item.modified {
                    Text("Modified \(modified.formatted(.relative(presentation: .named)))").font(.meta).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Text(CompactFormat.bytes(UInt64(max(0, item.bytes)))).font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            ChipButton(title: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }.fixedSize()
        }
    }

    private static func shortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private extension SectionState {
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
