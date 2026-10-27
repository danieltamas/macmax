import AppKit
import MacMaxCore
import SwiftUI

/// The README's screenshots: the real views over synthetic data, drawn by an offscreen window
/// (`MacMax --render-screenshots <dir>`, docs/SCREENSHOTS.md). Nothing is read from or written
/// to this Mac's ~/.macmax, and nothing reaches the screen, so no capture permission.
@MainActor
enum ScreenshotRender {
    static let flag = "--render-screenshots"
    /// `--look solidGlass` draws in another look; the saved choice is neither used nor changed.
    static let lookFlag = "--look"

    static let allLooksFlag = "--all-looks"
    static let stressFlag = "--stress"
    /// `--scale 3` renders at 3x instead of the README's 2x: plates for the launch film's close-ups.
    static let scaleFlag = "--scale"

    /// The backdrop's padding around a composite and the gap between its panels.
    private static let compositeInset: CGFloat = 48
    private static let compositeGap: CGFloat = 22

    /// Every shot of docs/SCREENSHOTS.md that the app draws, in the chosen look (or all three), optionally with the
    /// longest names and largest values to check that nothing wraps.
    static func render(to directory: URL, look: Look = .macmax, allLooks: Bool = false, stress: Bool = false,
                       scale: CGFloat = 2) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.scale = scale
        for look in allLooks ? Look.allCases : [look] {
            Appearance.shared.look = look
            let suffix = look == .macmax || !allLooks ? "" : look == .solidGlass ? "-solid-glass" : "-solid-glass-light"
            func url(_ name: String) -> URL { directory.appendingPathComponent("\(name)\(suffix).png") }
            for tab in PanelTab.allCases {
                let model = DemoStore.model(stress: stress)
                model.tab = tab
                if tab == .network { model.window = .hour }
                if tab == .history { DemoStore.history(for: model, range: .day, stress: stress) }
                try write(PanelView(model: model).frame(height: 780), to: url(tab.rawValue.lowercased()))
            }
            let mac = DemoStore.model(stress: stress)
            try write(ThisMacCard(model: mac).padding(14).frame(width: PanelView.width).background(Backdrop()), to: url("this-mac"))
            try write(PowerHealthCard(model: mac).padding(14).frame(width: PanelView.width).background(Backdrop()), to: url("battery-and-heat"))
            let cleaned = DemoStore.model(stress: stress)
            try write(VStack(spacing: 14) { JustMovedCard(model: cleaned); LastCleanupsCard(model: cleaned) }
                .padding(14).frame(width: PanelView.width).background(Backdrop()), to: url("cleanup-results"))
            try write(LargeFoldersCard(model: DemoStore.model(stress: stress)).padding(14).frame(width: PanelView.width).background(Backdrop()), to: url("large-folders"))
            try write(StartupCard(model: DemoStore.model(stress: stress)).padding(14).frame(width: PanelView.width).background(Backdrop()), to: url("background-items"))
            try write(StartupCard(model: DemoStore.model(stress: stress), open: ["/Users/example/Library/LaunchAgents/ro.example.relay.helper.plist"]).padding(14).frame(width: PanelView.width).background(Backdrop()), to: url("background-item-detail"))
            try write(AppUninstallCard(model: DemoStore.model(stress: stress), selected: "/Applications/Relay Chat.app").padding(14).frame(width: PanelView.width).background(Backdrop()), to: url("uninstall-apps"))
            try write(OldDownloadsCard(model: DemoStore.model(stress: stress)).padding(14).frame(width: PanelView.width).background(Backdrop()), to: url("old-downloads"))
            let moving = DemoStore.model(stress: stress)
            moving.cleanupMoving = true
            moving.cleanupProgress = (3, 12, "/Users/example/Library/Caches/ro.example.pixel")
            try write(CleanupPane(model: moving, place: .tab).padding(14).frame(width: PanelView.width, height: 640, alignment: .top).background(Backdrop()), to: url("cleanup-moving"))
            let asking = DemoStore.model(stress: stress)
            asking.fullDiskAccess = .unknown
            try write(AccessPrompt(model: asking).padding(14).frame(width: PanelView.width).background(Backdrop()), to: url("access-prompt"))
            try writeComposites(stress: stress, url: url)
            for range in [HistoryRange.hour, .week] {
                let model = DemoStore.model(stress: stress)
                model.tab = .history
                DemoStore.history(for: model, range: range, stress: stress)
                DemoStore.selectSpike(model, metric: .cpu)
                try write(PanelView(model: model).frame(height: 780), to: url(range == .hour ? "history-1h" : "history-7d"))
            }
            let leak = DemoStore.model(stress: stress, leak: true)
            try write(IdentityCardView(model: leak).padding(14).frame(width: PanelView.width).background(Backdrop()), to: url("leak"))
            for pane in SettingsPane.allCases {
                let model = DemoStore.model(stress: stress)
                try write(SettingsView(model: { model.settingsPane = pane; return model }()).frame(width: 760, height: 540), to: url("settings-\(pane.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))"))
            }
        }
    }

    /// The README's wide shots: two panels, or a panel and a column of cards, over the backdrop, each
    /// surface rounded and shadowed. One image per README section reads larger than a two-column table.
    private static func writeComposites(stress: Bool, url: (String) -> URL) throws {
        func panel(_ tab: PanelTab, window: TrafficWindow? = nil, history: HistoryRange? = nil) -> some View {
            let model = DemoStore.model(stress: stress)
            model.tab = tab
            if let window { model.window = window }
            if let history { DemoStore.history(for: model, range: history, stress: stress); DemoStore.selectSpike(model, metric: .cpu) }
            return surface(PanelView(model: model).frame(height: 780))
        }
        func card(_ view: some View) -> some View { surface(view.frame(width: PanelView.width)) }
        let demo = DemoStore.model(stress: stress)
        try write(composite(.top) { panel(.overview); panel(.network, window: .hour) }, to: url("hero"))
        try write(composite(.top) { panel(.findings); panel(.apps) }, to: url("findings-apps"))
        try write(composite(.top) { card(ThisMacCard(model: demo)); card(PowerHealthCard(model: demo)) }, to: url("mac-cards"))
        try write(composite(.center) { panel(.network, window: .day); card(IdentityCardView(model: DemoStore.model(stress: stress, leak: true))) },
                  to: url("network-leak"))
        let cleaned = DemoStore.model(stress: stress), asking = DemoStore.model(stress: stress)
        asking.fullDiskAccess = .unknown
        try write(composite(.top) {
            panel(.cleanup)
            VStack(spacing: compositeGap) { card(JustMovedCard(model: cleaned)); card(LastCleanupsCard(model: cleaned)); card(AccessPrompt(model: asking)) }
        }, to: url("cleanup-safety"))
        try write(composite(.top) {
            card(StartupCard(model: demo, open: ["/Users/example/Library/LaunchAgents/ro.example.relay.helper.plist"]))
            card(AppUninstallCard(model: demo, selected: "/Applications/Relay Chat.app"))
        }, to: url("background-uninstall"))
        try write(composite(.top) { card(OldDownloadsCard(model: demo)); card(LargeFoldersCard(model: demo)) }, to: url("downloads-folders"))
        try write(composite(.top) { panel(.history, history: .hour); panel(.history, history: .week) }, to: url("history-pair"))
    }

    private static func composite(_ alignment: VerticalAlignment, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: alignment, spacing: compositeGap, content: content)
            .padding(.horizontal, compositeInset).padding(.vertical, compositeInset - 8).background(Backdrop())
    }

    private static func surface(_ view: some View) -> some View {
        view.clipShape(RoundedRectangle(cornerRadius: 22)).shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    private static var scale: CGFloat = 2

    /// An offscreen window, not `ImageRenderer`: that one leaves text fields and other
    /// AppKit-backed controls as placeholders.
    private static func write(_ view: some View, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.stillImage, true).environment(\.demoNow, DemoStore.now))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.3))
        let size = host.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }
}
