import AppKit
import MacMaxCore
import ServiceManagement
import SwiftUI

/// The panes of the Settings window, in the order of docs/DESIGN.md. A unit adds its pane here.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        }
    }

    @MainActor var color: Color {
        switch self {
        case .general: Theme.teal
        }
    }
}

/// MacMax's settings window: every setting is edited in place and saved as it changes.
struct SettingsView: View {
    @State private var selection = SettingsPane.general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.hairline).frame(width: 0.5)
            ScrollView {
                pane.padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
            .id(selection)
            .transition(.opacity)
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(Backdrop())
        .preferredColorScheme(Theme.scheme)
        .animation(Motion.spring, value: selection)
    }

    @ViewBuilder private var pane: some View {
        switch selection {
        case .general: GeneralPane()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(text: "Settings").padding(.horizontal, 10).padding(.bottom, 8)
            ForEach(SettingsPane.allCases) { pane in
                let selected = selection == pane
                Button {
                    withAnimation(Motion.spring) { selection = pane }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: pane.symbol)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(selected ? pane.color : Theme.textTertiary)
                            .frame(width: 24, height: 24)
                            .background(pane.color.opacity(selected ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(pane.rawValue).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.core)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.98))
            }
            Spacer()
            AppControls().padding(.horizontal, 10)
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 196)
        .background(Theme.canvas.opacity(0.55))
    }
}

private struct GeneralPane: View {
    @State private var problem: String?
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    private let home = MacMaxHome()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .general, title: "General", detail: "How MacMax looks and when it opens.")
            SettingsCard(title: "Theme", detail: "How the panel and this window look. A colour means the same in each.") {
                HStack(spacing: 6) {
                    ForEach(Look.allCases) { look in
                        SegmentChip(title: look.title, selected: Appearance.shared.look == look) {
                            withAnimation(Motion.gentle) { Appearance.shared.choose(look) }
                        }
                    }
                }
            }
            SettingsCard(title: "Open at login", detail: "MacMax only measures while it runs.") {
                Toggle("Open MacMax when you log in", isOn: Binding(get: { opensAtLogin }, set: { setOpensAtLogin($0) }))
                    .toggleStyle(.switch).tint(Theme.teal)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            SettingsCard(title: "Data folder", detail: "History and logs on this Mac.") {
                HStack {
                    Text(home.url.path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    PillButton(title: "Show in Finder", symbol: "arrow.up.right", prominent: false) {
                        try? home.prepare()
                        NSWorkspace.shared.activateFileViewerSelecting([home.url])
                    }
                }
            }
            if let problem { ProblemText(text: problem) }
        }
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            problem = nil
        } catch {
            problem = "macOS refused: \(error.localizedDescription) MacMax must run from an Applications folder."
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
