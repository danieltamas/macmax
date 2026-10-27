import AppKit
import SwiftUI

@main
struct MacMaxApp: App {
    /// Handled before anything else starts: the screenshot render needs no sampler, database or network.
    @State private var controller = PanelController()

    init() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: ScreenshotRender.flag), index + 1 < arguments.count {
            let look = arguments.firstIndex(of: ScreenshotRender.lookFlag)
                .flatMap { $0 + 1 < arguments.count ? Look(rawValue: arguments[$0 + 1]) : nil }
            // `--scale` is bounded: beyond 4x the bitmaps reach hundreds of megabytes, and a stray
            // word or "inf" must stop the render, not silently fall back or trap in the pixel maths.
            var scale: CGFloat = 2
            if let scaleIndex = arguments.firstIndex(of: ScreenshotRender.scaleFlag) {
                guard scaleIndex + 1 < arguments.count, let value = Double(arguments[scaleIndex + 1]),
                      value.isFinite, (1...4).contains(value) else {
                    FileHandle.standardError.write(Data("\(ScreenshotRender.scaleFlag) needs a number from 1 to 4\n".utf8))
                    exit(2)
                }
                scale = CGFloat(value)
            }
            do { try ScreenshotRender.render(to: URL(fileURLWithPath: arguments[index + 1]), look: look ?? .macmax,
                                            allLooks: arguments.contains(ScreenshotRender.allLooksFlag),
                                            stress: arguments.contains(ScreenshotRender.stressFlag),
                                            scale: scale) } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            exit(0)
        }
        LoginItem.registerOnce()
        controller.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: controller.model)
        } label: {
            MenuBarLabel(model: controller.model)
        }
        .menuBarExtraStyle(.window)

        // A Settings scene, not a Window: it never opens by itself at launch, and gets Cmd-, for free.
        Settings { SettingsView(model: controller.model) }
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
        // Own streams, so nothing hangs on a pipe that closes with this process.
        reopen.standardInput = FileHandle.nullDevice
        reopen.standardOutput = FileHandle.nullDevice
        reopen.standardError = FileHandle.nullDevice
        reopen.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; for try in 1 2 3 4 5 6; do /usr/bin/open \"$1\" && exit 0; sleep 1; done",
                            String(ProcessInfo.processInfo.processIdentifier), bundle.path]
        guard (try? reopen.run()) != nil else { return NSSound.beep() }
        terminate(nil)
    }
}

/// The menu bar item: the icon at rest, tinted by a verdict that needs attention, plus the optional live text.
/// The model publishes every write of every tick; the label keeps only its own face and redraws when that
/// changes, so the menu bar is not drawn again for a process list.
struct MenuBarLabel: View {
    let model: PanelModel
    @State private var face: Face

    init(model: PanelModel) {
        self.model = model
        _face = State(initialValue: Face(model))
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: NSImage.menuBarIcon(tint: face.tint))
            if let text = face.text { Text(text).monospacedDigit() }
        }
        // `objectWillChange` fires before the write; the next main-queue turn reads the value after it.
        .onReceive(model.objectWillChange.receive(on: DispatchQueue.main)) { _ in
            let next = Face(model)
            if next != face { face = next }
        }
    }

    private struct Face: Equatable {
        let tint: NSColor?
        let text: String?

        @MainActor init(_ model: PanelModel) {
            tint = switch model.verdict {
            case .warn: .systemOrange
            case .crit: .systemRed
            case .unknown: .systemGray
            case .ok, nil: nil
            }
            func vital(_ kind: Vital.Kind) -> String? { model.vitals.first { $0.kind == kind }?.value }
            text = switch model.config.menuBarText {
            case .none: nil
            case .cpu: vital(.cpu)
            case .memory: vital(.memory)
            case .network: vital(.netIn)
            case .country: model.identity?.publicCountry
            }
        }
    }
}

extension NSImage {
    @MainActor private static var tinted: [String: NSImage] = [:]

    /// The template icon, or a colored copy of it: tinted images are cached because the menu bar redraws often.
    @MainActor static func menuBarIcon(tint: NSColor?) -> NSImage {
        guard let tint else { return macMaxTemplate }
        let key = tint.description
        if let cached = tinted[key] { return cached }
        let base = macMaxTemplate
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceIn)
            return true
        }
        image.isTemplate = false
        tinted[key] = image
        return image
    }
}
