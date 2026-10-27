import AppKit
import MacMaxCore
import SwiftUI

/// The menu bar panel: header, tab island, the open tab, footer (docs/DESIGN.md, The panel).
struct PanelView: View {
    static let width: CGFloat = 404
    /// Tall enough for a full tab, never taller than the screen can show under the menu bar.
    static var height: CGFloat { min(780, (NSScreen.main?.visibleFrame.height ?? 820) - 40) }
    @ObservedObject var model: PanelModel
    @Namespace private var tabSpace
    /// Follows the window: everything that moves or refreshes on its own pauses while the panel is closed.
    @State private var panelVisible = true
    /// `Theme` reads the look through a static, which nothing observes: the root watches it and rebuilds the
    /// tree (`.id`). The look is only chosen in the Settings window, which takes focus and so closes this panel,
    /// so the rebuild happens while it is hidden; ticks and a scroll position on a hidden panel are the cost.
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            tabIsland
            ScrollView {
                content.padding(.horizontal, 14).padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .background(Backdrop())
        .environment(\.colorScheme, Theme.scheme)
        .environment(\.panelVisible, panelVisible)
        .background(WindowVisibility(visible: $panelVisible))
        .background { if #available(macOS 14, *) { SettingsOpener(model: model) } }
        .id(appearance.look)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.brand)
            Text("MacMax").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Chip(text: model.verdict?.label ?? "WAITING", color: Theme.color(model.verdict), style: .filled)
            Spacer(minLength: 8)
            if let date = model.auditedAt {
                RelativeTime(date: date) { "Audited \($0) ago" }
                    .font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize()
            }
            if model.newerRelease, let latest = model.latestRelease {
                IconButton(symbol: "arrow.up.circle.fill", help: "MacMax \(latest.version) is available") { model.openSettings(.about) }
            }
            IconButton(symbol: "gearshape", help: "Open Settings") { model.openSettings(model.settingsPane) }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
    }

    private var tabIsland: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                let active = model.tab == tab
                Button { model.select(tab) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 11, weight: .medium))
                        // Five labels do not fit the panel width: only the open tab keeps its name.
                        if active { Text(tab.rawValue).font(.system(size: 11.5, weight: .semibold)).lineLimit(1) }
                        if tab == .findings, !model.openFindings.isEmpty, active {
                            Text("\(model.openFindings.count)").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.color(model.verdict))
                        }
                    }
                    .fixedSize()
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .frame(maxWidth: active ? nil : .infinity)
                    .foregroundStyle(active ? Theme.canvas : Theme.textSecondary)
                    .background {
                        if active {
                            ZStack {
                                Capsule().fill(Theme.brand)
                                CapsuleRing(width: 1).fill(Color.white.opacity(0.28))
                            }
                            .matchedGeometryEffect(id: "active-tab", in: tabSpace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle(scale: 0.97, hit: AnyShape(Capsule()), lift: 0.08))
                .help(tab.rawValue)
                .accessibilityLabel(tab.rawValue)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.core))
        // A filled shape hit-tests as a solid capsule: without this the ring lay over the tabs and took every click.
        .overlay(CapsuleRing(width: 0.5).fill(Theme.hairline).allowsHitTesting(false))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .overview: OverviewTab(model: model)
        case .apps: AppsTab(model: model)
        case .network: NetworkTab(model: model)
        case .findings: FindingsTab(model: model)
        case .cleanup: CleanupPane(model: model, place: .tab)
        case .history: HistoryTab(model: model)
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                Circle().fill(model.samplerFailed ? Theme.crit : Theme.ok).frame(width: 6, height: 6)
                Text(model.samplerNote).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            AppControls()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }
}

/// `showSettingsWindow:` does nothing from a menu bar item on macOS 14 and later; the `openSettings` action does,
/// and it exists only there, so it is read in a view that only macOS 14 builds. macOS 13 keeps the selector.
@available(macOS 14, *)
private struct SettingsOpener: View {
    let model: PanelModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.onAppear { model.showSettingsWindow = { openSettings() } }
    }
}
