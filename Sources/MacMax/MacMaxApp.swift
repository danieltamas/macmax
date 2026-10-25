import AppKit
import SwiftUI

@main
struct MacMaxApp: App {
    /// Handled before anything else starts: the screenshot render needs no sampler, database or network.
    init() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: ScreenshotRender.flag), index + 1 < arguments.count {
            let look = arguments.firstIndex(of: ScreenshotRender.lookFlag)
                .flatMap { $0 + 1 < arguments.count ? Look(rawValue: arguments[$0 + 1]) : nil }
            do { try ScreenshotRender.render(to: URL(fileURLWithPath: arguments[index + 1]), look: look ?? .macmax) } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            exit(0)
        }
        LoginItem.registerOnce()
    }

    var body: some Scene {
        MenuBarExtra {
            EmptyPanel()
        } label: {
            Image(nsImage: .macMaxTemplate)
        }
        .menuBarExtraStyle(.window)

        // A Settings scene, not a Window: it never opens by itself at launch, and gets Cmd-, for free.
        Settings { SettingsView() }
    }
}

extension NSImage {
    /// The bundled template icon; `swift run` has no bundle, so it falls back to an SF Symbol.
    /// Read once: the menu bar draws it on every frame.
    static let macMaxTemplate: NSImage = {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "MacMax")!
    }()
}

extension NSApplication {
    /// Quits, then opens MacMax again once this process is gone: opening it while it still runs
    /// would only bring the running copy forward.
    func relaunch() {
        // `swift run` has no bundle to open again, and quitting would leave nothing running.
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", FileManager.default.isExecutableFile(atPath: Bundle.main.executablePath ?? "")
        else { return NSSound.beep() }
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"",
                            String(ProcessInfo.processInfo.processIdentifier), bundle.path]
        guard (try? reopen.run()) != nil else { return NSSound.beep() }
        terminate(nil)
    }
}
