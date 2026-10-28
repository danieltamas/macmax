import AppKit
import MacMaxCore
import SwiftUI

/// One of the owner's other open source tools, as the More apps pane shows it.
struct MoreApp: Identifiable, Sendable {
    enum Kind { case menuBar, terminal }

    let name: String
    /// The file in Support/MoreApps, copied into the bundle by scripts/bundle.sh.
    let icon: String
    /// The icon fills its square, so it is inset and rounded to sit beside the macOS-shaped ones.
    var fullBleed = false
    let kind: Kind
    let platform: String
    let pitch: String
    let detail: String
    let install: String
    /// Released when MacMax was built. Until GitHub confirms a release, an app that never had one shows no install
    /// command: a command that fails is worse than none.
    var releasedBefore = true
    /// GitHub's "owner/name", for the release check and the link.
    let repo: String
    var site: URL?
    /// Mac apps only: how the installed copy is found, and the Info.plist key a build from a checkout is stamped with.
    var bundleID: String?
    var sourceKey: String?
    let dark: UInt32
    let light: UInt32

    var id: String { repo }
    var repoURL: URL { URL(string: "https://github.com/\(repo)")! }
    @MainActor var hue: Color { Theme.hue(dark, light: light) }

    static let all: [MoreApp] = [
        MoreApp(name: "Bton", icon: "bton", kind: .menuBar, platform: "macOS",
                pitch: "Pull requests that move themselves.",
                detail: "Runs your team's review flow with coding agents, Claude Code, Codex or any CLI, from the menu bar.",
                install: "brew install --cask danieltamas/tap/bton", repo: "danieltamas/bton",
                bundleID: "ro.danieltamas.bton", sourceKey: "BtonSource", dark: 0x5EE6E0, light: 0x0B7F86),
        MoreApp(name: "RMJ", icon: "rmj", kind: .menuBar, platform: "macOS",
                pitch: "Run My Job: your builds and tests, on your boxes.",
                detail: "Sends the builds and test suites your agents start to the Linux boxes on your tailnet, and shows every run in one place.",
                install: "brew install --cask danieltamas/tap/rmj", releasedBefore: false, repo: "danieltamas/runmyjob",
                bundleID: "ro.danieltamas.rmj", sourceKey: "RMJSource", dark: 0x5AA9FF, light: 0x1F6FD1),
        MoreApp(name: "Axon", icon: "axon", kind: .terminal, platform: "macOS and Linux",
                pitch: "Your coding agents, on one bus.",
                detail: "Lets Claude Code, Codex, OpenCode and Hermes see and talk to each other, and shows what each one does and costs. Fully local.",
                install: "brew install danieltamas/tap/axon", repo: "danieltamas/axon", dark: 0x4ADE80, light: 0x15803D),
        MoreApp(name: "Run.dev", icon: "rundev", fullBleed: true, kind: .terminal, platform: "macOS and Linux",
                pitch: "Every local service, one dashboard.",
                detail: "One binary starts and watches the services of all your projects from a terminal dashboard, with no config files to babysit.",
                install: "curl -fsSL https://getrun.dev/install.sh | bash", repo: "danieltamas/run.dev",
                site: URL(string: "https://getrun.dev")!, dark: 0x45C8D4, light: 0x0A7C93),
        MoreApp(name: "Cloak", icon: "cloak", fullBleed: true, kind: .terminal, platform: "CLI and VS Code",
                pitch: "Keep .env secrets away from AI agents.",
                detail: "Agents see sandbox values, you see the real ones, and your app still runs with real credentials. Encrypted vault, Touch ID.",
                install: "curl -fsSL https://getcloak.dev/install.sh | sh", repo: "danieltamas/cloak",
                site: URL(string: "https://getcloak.dev")!, dark: 0x5B9BFF, light: 0x2457C5),
    ]
}

struct MoreAppsPane: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .moreApps, title: "More apps",
                       detail: "Other open source tools from the maker of MacMax, for a Mac that runs coding agents. All MIT, all free.")
            checkRow
            group("In the menu bar", .menuBar)
            group("In the terminal", .terminal)
        }
        .onAppear { model.refreshMoreApps(false) }
    }

    @ViewBuilder private var checkRow: some View {
        if model.moreAppsChecking {
            OperationProgress(text: "Asking GitHub for the latest releases...")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let checked = model.moreAppsCheckedAt {
                        RelativeTime(date: checked) { "Latest releases from GitHub, checked \($0) ago." }
                            .font(.meta).foregroundStyle(Theme.textTertiary)
                    } else {
                        Text("Latest releases from GitHub.").font(.meta).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    IconButton(symbol: "arrow.clockwise", help: "Check GitHub again", size: 22) { model.refreshMoreApps(true) }
                }
                if let problem = model.moreAppsProblem { ProblemText(text: problem) }
            }
        }
    }

    private func group(_ title: String, _ kind: MoreApp.Kind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: title).padding(.leading, 4)
            ForEach(MoreApp.all.filter { $0.kind == kind }) { app in
                MoreAppCard(app: app, release: model.moreAppReleases[app.repo], checking: model.moreAppsChecking,
                            installed: app.bundleID.flatMap { model.moreAppsInstalled[$0] })
            }
        }
    }
}

private struct MoreAppCard: View {
    let app: MoreApp
    /// Nil until GitHub has been asked.
    let release: LatestReleaseAnswer?
    let checking: Bool
    let installed: InstalledCopy?

    private var latest: ReleaseInfo? {
        if case let .release(info) = release { return info }
        return nil
    }

    /// GitHub answered "no release yet". Spelled out: a bare `.none` on the optional answer would mean "not asked".
    private var unreleased: Bool {
        if case .some(LatestReleaseAnswer.none) = release { return true }
        return false
    }

    private var showsInstall: Bool {
        if latest != nil { return true }
        return !unreleased && app.releasedBefore
    }

    var body: some View {
        Bezel(glow: app.hue) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    MoreAppIcon(app: app, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(app.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                                .lineLimit(1).fixedSize()
                            Chip(text: app.platform, color: app.hue)
                            Spacer(minLength: 8)
                            if let installed { LinkChip(title: "Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(installed.url) } }
                            if let site = app.site { LinkChip(title: "Website", url: site) }
                            LinkChip(title: "GitHub", url: app.repoURL)
                        }
                        Text(app.pitch).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        Text(app.detail).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        statusLine
                    }
                }
                // Full width, so a curl line reads whole instead of cut in the middle.
                if showsInstall {
                    InstallLine(command: app.install)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var releaseChip: some View {
        switch release {
        case let .release(info): Chip(text: "v\(info.version)", color: app.hue, style: .outline).help("The latest release on GitHub")
        case .some(LatestReleaseAnswer.none): Chip(text: "In development", color: Theme.textTertiary, style: .dashed).help("No release on GitHub yet")
        case let .failed(reason): Chip(text: "Version unknown", color: Theme.textTertiary, style: .outline).help(reason)
        case .rateLimited: Chip(text: "Version unknown", color: Theme.textTertiary, style: .outline).help("GitHub asked MacMax to wait.")
        case nil:
            if checking { Chip(text: "Checking...", color: Theme.textTertiary, style: .outline) }
        }
    }

    /// The latest release and when it came out, and how the copy on this Mac compares with it.
    @ViewBuilder private var statusLine: some View {
        let standing = installed.map { InstalledStanding.compare(isInstalled: true, installedVersion: $0.version, latestTag: latest?.tag) }
        if release != nil || checking || installed != nil {
            HStack(spacing: 6) {
                releaseChip
                if let installed, let standing { installedChip(installed, standing) }
                if let published = latest?.publishedAt {
                    RelativeTime(date: published) { "Released \($0) ago" }.font(.meta).foregroundStyle(Theme.textTertiary)
                } else if unreleased, installed == nil {
                    Text("No release yet: watch the repository for the first one.").font(.meta).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private func installedChip(_ installed: InstalledCopy, _ standing: InstalledStanding) -> some View {
        let version = installed.version.map { " \($0)" } ?? ""
        if installed.version == nil, let source = installed.source {
            Chip(text: "Built from source", color: Theme.neutral, style: .outline).help("\(source): not a release, so MacMax makes no claim about updates.")
        } else if installed.version == nil {
            Chip(text: "Installed, version unknown", color: Theme.neutral, style: .outline).help("Its Info.plist names no version MacMax could read.")
        } else {
            versionedChip(version, standing)
        }
    }

    @ViewBuilder private func versionedChip(_ version: String, _ standing: InstalledStanding) -> some View {
        switch standing {
        case .current: Chip(text: "Installed\(version), up to date", symbol: "checkmark", color: Theme.success)
        case let .behind(latest): Chip(text: "Installed\(version), \(latest) is out", symbol: "arrow.down.circle", color: Theme.warn)
        case .ahead, .unknown, .notInstalled: Chip(text: "Installed\(version)", color: Theme.neutral)
        }
    }
}

/// A small outlined link; the arrow says it leaves the app.
private struct LinkChip: View {
    let title: String
    var symbol = "arrow.up.right"
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    init(title: String, url: URL) {
        self.title = title
        help = url.absoluteString
        action = { NSWorkspace.shared.open(url) }
    }

    init(title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Chip(text: title, symbol: symbol, color: hovering ? Theme.textPrimary : Theme.textSecondary, style: .outline)
        }
        .buttonStyle(PressStyle(scale: 0.95, hit: AnyShape(Capsule()), lift: 0))
        .pointingHandCursor()
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
        .help(help ?? title)
    }
}

/// The install command in a well, with a copy button that answers the press.
private struct InstallLine: View {
    let command: String

    var body: some View {
        HStack(spacing: 6) {
            Text("$").font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textTertiary)
            Text(command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 6)
            CopyButton(text: command, help: "Copy the install command")
        }
        .padding(.leading, 10).padding(.trailing, 3).padding(.vertical, 3)
        .background(Theme.wash.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// The app's own icon from the bundle, or a glyph in its hue when the bundle has none (a build run from the scratch path).
private struct MoreAppIcon: View {
    let app: MoreApp
    let size: CGFloat

    /// Read once per icon: the lookup reads the disk and must not run on every redraw.
    @MainActor private static var cache: [String: NSImage?] = [:]

    var body: some View {
        if let image = Self.image(app.icon) {
            let inset = app.fullBleed ? size * 0.1 : 0
            let corner = (size - inset * 2) * 0.225
            Image(nsImage: image).resizable().interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: app.fullBleed ? corner : 0, style: .continuous))
                .padding(inset)
                .frame(width: size, height: size)
                .shadow(color: app.hue.opacity(0.35), radius: 10, y: 4)
        } else {
            GlyphDisc(symbol: app.kind == .menuBar ? "menubar.rectangle" : "terminal", color: app.hue, size: size)
        }
    }

    @MainActor private static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let image = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "MoreApps").flatMap(NSImage.init(contentsOf:))
        cache[name] = .some(image)
        return image
    }
}
