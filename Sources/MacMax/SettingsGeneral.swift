import AppKit
import MacMaxCore
import ServiceManagement
import SwiftUI

struct GeneralPane: View {
    @ObservedObject var model: PanelModel
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmClear = false
    private let home = MacMaxHome()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .general, title: "General", detail: "How MacMax measures, looks and when it opens.")
            if let problem = model.configProblem { ProblemText(text: problem) }
            SettingsCard(title: "Sampling interval", detail: "How often MacMax reads the Mac. Shorter is livelier and costs a little more.") {
                HStack(spacing: 6) {
                    ForEach(SamplerInterval.allCases, id: \.self) { interval in
                        SegmentChip(title: "\(interval.rawValue) s", selected: model.config.samplingSeconds == interval.rawValue) {
                            model.change { $0.samplingSeconds = interval.rawValue }
                        }
                    }
                }
            }
            SettingsCard(title: "Menu bar text", detail: "A live number next to the icon. It changes only when its text changes.") {
                HStack(spacing: 6) {
                    ForEach(MenuBarText.allCases, id: \.self) { text in
                        SegmentChip(title: Self.title(text), selected: model.config.menuBarText == text) {
                            model.change { $0.menuBarText = text }
                        }
                    }
                }
            }
            SettingsCard(title: "Theme", detail: "How the panel and this window look. A colour means the same in each.") {
                HStack(spacing: 6) {
                    ForEach(Look.allCases) { look in
                        SegmentChip(title: look.title, selected: Appearance.shared.look == look) {
                            withAnimation(Motion.gentle) { Appearance.shared.choose(look) }
                            model.change { $0.lookName = look.rawValue }
                        }
                    }
                }
            }
            SettingsCard(title: "Open at login", detail: "MacMax only measures while it runs.") {
                SwitchRow(title: "Open MacMax when you log in", isOn: Binding(get: { opensAtLogin }, set: { setOpensAtLogin($0) }))
                if let loginProblem = model.loginProblem { ProblemText(text: loginProblem) }
            }
            SettingsCard(title: "Data folder", detail: "History and logs on this Mac. Nothing leaves it.") {
                SettingsRow(title: home.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    PillButton(title: "Show in Finder", symbol: "arrow.up.right", prominent: false) {
                        try? home.prepare()
                        NSWorkspace.shared.activateFileViewerSelecting([home.url])
                    }
                }
                RowDivider()
                SettingsRow(title: model.historyBytes.map { "History uses \(CompactFormat.bytes(UInt64(max($0, 0))))" } ?? "History size not read yet") {
                    PillButton(title: model.clearing ? "Clearing..." : confirmClear ? "Press again to clear" : "Clear history",
                               symbol: "trash", prominent: false) {
                        guard !model.clearing else { return }
                        if confirmClear { model.clearHistory(); confirmClear = false } else { confirmClear = true }
                    }
                }
                if model.clearError == nil, let cleared = model.lastCleared {
                    HStack(spacing: 4) {
                        Text("History cleared").font(.meta).foregroundStyle(Theme.ok)
                        RelativeTime(date: cleared).font(.meta).foregroundStyle(Theme.textTertiary)
                    }
                }
                if let problem = model.clearError {
                    Text(problem).font(.meta).foregroundStyle(Theme.crit)
                }
            }
        }
    }

    static func title(_ text: MenuBarText) -> String {
        switch text {
        case .none: "None"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .country: "Country"
        }
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            model.loginProblem = nil
        } catch {
            model.loginProblem = "macOS refused: \(error.localizedDescription) MacMax must run from an Applications folder."
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
