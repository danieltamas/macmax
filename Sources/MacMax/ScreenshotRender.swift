import AppKit
import SwiftUI

/// The README's screenshots: the real views over synthetic data, drawn by an offscreen window
/// (`MacMax --render-screenshots <dir>`, docs/SCREENSHOTS.md). Nothing is read from or written
/// to this Mac's ~/.macmax, and nothing reaches the screen, so no capture permission.
@MainActor
enum ScreenshotRender {
    static let flag = "--render-screenshots"
    /// `--look solidGlass` draws in another look; the saved choice is neither used nor changed.
    static let lookFlag = "--look"

    static func render(to directory: URL, look: Look = .macmax) throws {
        Appearance.shared.look = look
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(EmptyPanel(), to: directory.appendingPathComponent("empty-panel.png"))
    }

    /// An offscreen window, not `ImageRenderer`: that one leaves text fields and other
    /// AppKit-backed controls as placeholders.
    private static func write(_ view: some View, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.stillImage, true))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.3))
        let size = host.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }
}

/// The panel before any tab exists (U7 replaces it): the canvas at the panel's width.
struct EmptyPanel: View {
    var body: some View {
        EmptyState(symbol: "gauge.with.dots.needle.33percent", title: "MacMax", detail: "Nothing measured yet.")
            .frame(width: 404, height: 300)
            .background(Backdrop())
    }
}
