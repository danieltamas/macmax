import MacMaxCore
import SwiftUI

/// What starts by itself on this Mac, in two groups: the user's own agents, which can be turned off and on again, and
/// everything else, which is only listed (changing it needs an administrator and MacMax never asks for that).
struct StartupCard: View {
    @ObservedObject var model: PanelModel
    @State private var showOthers = false
    @State private var open: Set<String>
    init(model: PanelModel, open: Set<String> = []) {
        self.model = model
        _open = State(initialValue: open)
    }
    private static let statusWidth: CGFloat = 64
    private static let actionWidth: CGFloat = 72

    var body: some View {
        SettingsCard(title: "Background items", detail: "Programs that start by themselves when you log in or when the Mac starts. You can turn off your own; one press undoes it.") {
            VStack(alignment: .leading, spacing: 10) {
                switch model.startupState {
                case let .loading(text): OperationProgress(text: text)
                case let .failed(collector, reason): Text("\(collector): \(reason)").font(.meta).foregroundStyle(Theme.warn)
                case .ready: EmptyView()
                }
                if let items = model.startupItems { list(items) }
                if !model.startupState.isReading {
                    PillButton(title: model.startupItems == nil ? "Look at background items" : "Read again", symbol: "magnifyingglass",
                               prominent: false) { model.scanStartup() }
                }
            }
        }
        .onAppear { if model.startupItems == nil { model.scanStartup() } }
    }

    @ViewBuilder private func list(_ items: [StartupItem]) -> some View {
        let yours = items.filter { isControllable($0, in: items) }
        let others = items.filter { item in !yours.contains { $0.id == item.id } }
        if model.startupUnreadable > 0 {
            Text("\(model.startupUnreadable) file\(model.startupUnreadable == 1 ? "" : "s") in the launch folders could not be read, so this list may miss some.")
                .font(.meta).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
        }
        if items.isEmpty { Text("Nothing starts in the background from these folders.").font(.meta).foregroundStyle(Theme.textSecondary) }
        if !yours.isEmpty {
            groupTitle("Yours: you can turn these off", count: yours.count)
            ForEach(yours) { row($0, action: true) }
        }
        if !others.isEmpty {
            Button { showOthers.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: showOthers ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text("Installed for everyone, view only (\(others.count))").font(.system(size: 12, weight: .medium))
                }.foregroundStyle(Theme.teal).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHandCursor()
            if showOthers {
                Text("These belong to apps and macOS for all users of this Mac. Changing them needs an administrator, so MacMax only shows them.")
                    .font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                ForEach(others) { row($0, action: false) }
            }
        }
    }

    private func groupTitle(_ text: String, count: Int) -> some View {
        Text("\(text) (\(count))").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
    }

    private func row(_ item: StartupItem, action: Bool) -> some View {
        let state = model.actionStates["startup-\(item.path)"]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                Button { toggle(item) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open.contains(item.path) ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary).frame(width: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.title(item)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.tail)
                            Text(Redaction.sanitizeText(item.label)).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(RowPressStyle())
                .help("Click for details")
                Spacer(minLength: 4)
                status(item).frame(width: Self.statusWidth, alignment: .leading)
                if action {
                    ChipButton(title: item.isDisabled ? "Turn on" : "Turn off") { model.setStartupEnabled(item, item.isDisabled) }
                        .fixedSize().disabled(state?.isWorking == true || !isReady)
                        .frame(width: Self.actionWidth, alignment: .trailing)
                }
            }
            if open.contains(item.path) {
                StartupDetailView(item: item, inspection: model.startupInspections[item.path], isReading: model.startupInspecting.contains(item.path))
            }
            if let state, state.isWorking { OperationProgress(text: state.text) }
            else if let state { Text(state.text).font(.meta).foregroundStyle(state.isProblem ? Theme.warn : Theme.textSecondary) }
        }
    }

    private func toggle(_ item: StartupItem) {
        if open.remove(item.path) == nil {
            open.insert(item.path)
            model.inspectStartup(item)
        }
    }

    private func status(_ item: StartupItem) -> some View {
        let (text, color) = item.isRunning ? ("Running", Theme.success) : item.isDisabled ? ("Off", Theme.textTertiary) : ("Idle", Theme.textSecondary)
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
        }
    }

    /// Only the user's own agents that MacMax may touch, and whose name is unique, get a button.
    private func isControllable(_ item: StartupItem, in items: [StartupItem]) -> Bool {
        StartupControl.disableCommands(for: item, uid: getuid()) != nil && items.filter { $0.label == item.label }.count == 1
    }

    /// Only a list that was just read in full may be acted on: while it reloads, or after a failed read, it is stale.
    private var isReady: Bool {
        if case .ready = model.startupState { return model.startupItems != nil }
        return false
    }

    /// A readable name: the app the program lives in, else the label without its domain prefix ("com.adobe.GC.AGM" -> "Adobe GC AGM").
    static func title(_ item: StartupItem) -> String {
        if let app = item.program?.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            return Redaction.sanitizeText(String(app.dropLast(4)))
        }
        var parts = item.label.split(separator: ".").map(String.init)
        if parts.count > 2, ["com", "org", "net", "io", "ro", "eu", "app", "co"].contains(parts[0].lowercased()) { parts.removeFirst() }
        let name = parts.joined(separator: " ")
        return Redaction.sanitizeText(name.prefix(1).uppercased() + name.dropFirst())
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
