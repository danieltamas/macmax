import MacMaxCore
import SwiftUI

/// What starts by itself on this Mac. The user's own agents can be turned off and on again; the system-wide ones are
/// only listed, because changing them needs an administrator and MacMax never asks for that.
struct StartupCard: View {
    let model: PanelModel
    @State private var showAll = false
    private static let preview = 8

    var body: some View {
        SettingsCard(title: "Background items", detail: "Programs macOS starts by itself, from your Launch Agents and the system's. Turning one off is undone with one press.") {
            VStack(alignment: .leading, spacing: 8) {
                switch model.startupState {
                case let .loading(text): OperationProgress(text: text)
                case let .failed(collector, reason): Text("\(collector): \(reason)").font(.meta).foregroundStyle(Theme.warn)
                case .ready: EmptyView()
                }
                if let items = model.startupItems {
                    if model.startupUnreadable > 0 {
                        Text("\(model.startupUnreadable) item\(model.startupUnreadable == 1 ? "" : "s") could not be read, so this list may be incomplete.")
                            .font(.meta).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                    }
                    if items.isEmpty { Text("Nothing starts in the background from these folders.").font(.meta).foregroundStyle(Theme.textSecondary) }
                    ForEach(showAll ? items : Array(items.prefix(Self.preview))) { row($0) }
                    if items.count > Self.preview {
                        Button(showAll ? "Show fewer" : "Show all \(items.count)") { showAll.toggle() }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.teal)
                    }
                }
                if !model.startupState.isReading {
                    PillButton(title: model.startupItems == nil ? "Look at background items" : "Read again", symbol: "magnifyingglass",
                               prominent: false) { model.scanStartup() }
                }
            }
        }
        .onAppear { if model.startupItems == nil { model.scanStartup() } }
    }

    private func row(_ item: StartupItem) -> some View {
        let state = model.actionStates["startup-\(item.path)"]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Redaction.sanitizeText(Redaction.redact([item.label]).joined(separator: " "))).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                    if let program = item.program {
                        Text(Self.shortened(Redaction.sanitizeText(Redaction.redact([program]).joined(separator: " ")))).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if item.isRunning { Chip(text: "Running", color: Theme.success, style: .tinted) }
                if item.isDisabled { Chip(text: "Off", color: Theme.textTertiary, style: .outline) }
                control(item, busy: state?.isWorking == true)
            }
            if let state, state.isWorking { OperationProgress(text: state.text) }
            else if let state { Text(state.text).font(.meta).foregroundStyle(state.isProblem ? Theme.warn : Theme.textSecondary) }
        }
    }

    @ViewBuilder private func control(_ item: StartupItem, busy: Bool) -> some View {
        if (model.startupItems ?? []).filter({ $0.label == item.label }).count > 1 {
            Chip(text: "Same name twice", color: Theme.textTertiary, style: .outline)
        } else if StartupControl.disableCommands(for: item, uid: getuid()) == nil {
            Chip(text: item.scope == .userAgent ? "Protected" : "Needs admin", color: Theme.textTertiary, style: .outline)
        } else {
            ChipButton(title: item.isDisabled ? "Turn on" : "Turn off") { model.setStartupEnabled(item, item.isDisabled) }
                .fixedSize().disabled(busy || !isReady)
        }
    }

    /// Only a list that was just read in full may be acted on: while it reloads, or after a failed read, it is stale.
    private var isReady: Bool {
        if case .ready = model.startupState { return model.startupItems != nil }
        return false
    }

    private static func shortened(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private extension SectionState {
    var isReading: Bool {
        if case .loading = self { return true }
        return false
    }
}

private extension ActionState {
    var isProblem: Bool {
        switch self {
        case .refused, .failed: true
        default: false
        }
    }
}
