import AppKit
import SwiftUI

/// The app's own icon when macOS knows its bundle, else a glyph. Icons are cached per bundle id: the lookup reads
/// the disk and must not run on every redraw.
struct AppIcon: View {
    let bundleID: String?
    let fallback: String

    @MainActor private static var cache: [String: NSImage?] = [:]

    var body: some View {
        if let image = Self.icon(bundleID) {
            Image(nsImage: image).resizable().frame(width: 28, height: 28)
        } else {
            GlyphDisc(symbol: fallback, color: Theme.textSecondary, size: 28)
        }
    }

    @MainActor private static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = .some(image)
        return image
    }
}
