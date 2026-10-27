import AppKit
import MacMaxCore
import SwiftUI

/// The settings that say what other programs may see: agents through MCP, and what macOS lets MacMax itself see.
struct AgentPane: View {
    @ObservedObject var model: PanelModel
    static let command = "claude mcp add macmax -- ~/.local/bin/macmax mcp"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .agent, title: "Agent access", detail: "Let a coding agent read what MacMax measures. Read-only.")
            SettingsCard(title: "Allow agents", detail: "Off, a connected agent can list the tools and gets no data. It takes effect at the next call.") {
                SwitchRow(title: "Let agents read MacMax data", detail: "Through the macmax mcp server. Nothing an agent asks can end, quit or delete anything.",
                          isOn: Binding(get: { model.config.agentAccess }, set: { value in model.change { $0.agentAccess = value } }))
                if let problem = model.configProblem { ProblemText(text: problem) }
            }
            SettingsCard(title: "MCP command", detail: "Run this once in a terminal to add MacMax to Claude Code.") {
                HStack {
                    Text(Self.command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    IconButton(symbol: "doc.on.doc", help: "Copy the command", size: 22) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.command, forType: .string)
                    }
                }
                Text("The server runs under your terminal's permissions, not MacMax's: an agent never reads more through MacMax than it could read itself.")
                    .font(.meta).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct PermissionsPane: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .permissions, title: "Permissions", detail: "What macOS lets MacMax see.")
            SettingsCard(title: "Full Disk Access", detail: "Lets MacMax measure and clean protected caches. Optional.") {
                HStack(spacing: 10) {
                    status(fullDisk)
                    Spacer(minLength: 6)
                    PillButton(title: "Open System Settings", symbol: "arrow.up.right", prominent: false) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
            }
            SettingsCard(title: "Notifications", detail: "Lets MacMax tell you when a finding is new or gets worse.") {
                HStack(spacing: 10) {
                    status(notifications)
                    Spacer(minLength: 6)
                    if model.notifications == .notAsked {
                        PillButton(title: "Allow", symbol: "bell", prominent: false) { model.requestNotifications() }
                    }
                    PillButton(title: "Open System Settings", symbol: "arrow.up.right", prominent: false) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            }
            Text("MacMax checks again when you come back to this window.").font(.meta).foregroundStyle(Theme.textTertiary)
        }
        .onAppear { model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
    }

    private var fullDisk: (String, String, Color) {
        switch model.fullDiskAccess {
        case .granted: ("Granted", "checkmark.circle.fill", Theme.success)
        case .denied: ("Not granted", "xmark.circle", Theme.warn)
        case .unknown: ("Could not be checked", "questionmark.circle", Theme.textTertiary)
        }
    }

    private var notifications: (String, String, Color) {
        switch model.notifications {
        case .allowed: ("Allowed", "checkmark.circle.fill", Theme.success)
        case .denied: ("Not allowed", "xmark.circle", Theme.warn)
        case .notAsked: ("Not asked yet", "bell.badge", Theme.textTertiary)
        case .unknown: ("Could not be checked", "questionmark.circle", Theme.textTertiary)
        }
    }

    private func status(_ value: (String, String, Color)) -> some View {
        Label(value.0, systemImage: value.1).font(.system(size: 12, weight: .semibold)).foregroundStyle(value.2)
    }
}

/// Who made MacMax and why, its repo, and which build this is.
struct AboutPane: View {
    @ObservedObject var model: PanelModel
    private static let repo = URL(string: "https://github.com/danieltamas/macmax")!

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .about, title: "About MacMax", detail: "Who makes it, where it lives, and which build this is.")
            Bezel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 16) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MacMax").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Text(Self.versionLine).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                            Text(standingText).font(.system(size: 11.5)).foregroundStyle(standingColor)
                        }
                        Spacer()
                    }
                    if let note = updateNote { Text(note).font(.meta).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true) }
                    HStack(spacing: 8) {
                        if let version = model.updateVersion {
                            PillButton(title: model.updateState.isUpdating ? "Updating..." : "Update to \(version)", symbol: "arrow.down.circle",
                                       prominent: true, disabled: model.updateState.isUpdating) { model.installUpdate() }
                        }
                        PillButton(title: "Check again", symbol: "arrow.clockwise", prominent: false,
                                   disabled: model.releaseCheck.isChecking) { model.checkForUpdate() }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsCard(title: "Why it exists", detail: nil) {
                Text("""
                    A Mac that feels slow rarely says why. MacMax shows what is using the CPU, memory, disk and \
                    network right now and over time, checks the Mac on a schedule, and tells you which app to deal \
                    with and what to do. It lives in the menu bar, keeps its history on this Mac, and never ends or \
                    deletes anything without your press.
                    """)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsCard(title: "Made by Daniel Tamas", detail: "Open source under the MIT license.") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        link("Repository", Self.repo)
                        link("Report an issue", Self.repo.appendingPathComponent("issues"))
                    }
                    HStack(spacing: 8) {
                        link("danieltamas.com", URL(string: "https://danieltamas.com")!)
                        link("Daniel on GitHub", URL(string: "https://github.com/danieltamas")!)
                    }
                }
            }
        }
    }

    /// `v0.1.0 + 3 commits (abc1234), built from source, uncommitted changes`, from the bundle's version and the
    /// `git describe` the installer stamps into Info.plist.
    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        var source = info?["MacMaxSource"] as? String
        let dirty = source?.hasSuffix("-dirty") ?? false
        if dirty { source?.removeLast("-dirty".count) }
        var line = "v\(version)"
        if let source, let match = source.wholeMatch(of: /v?(\d+\.\d+\.\d+)(?:-(\d+)-g([0-9a-f]+))?/) {
            line = "v\(match.1)"
            if let commits = match.2.flatMap({ Int($0) }), commits > 0 { line += " + \(commits) commit\(commits == 1 ? "" : "s")" }
            if let commit = match.3 { line += " (\(commit))" }
        } else if let source, !source.isEmpty {
            line += " (\(source))"
        }
        if info?["MacMaxSource"] != nil { line += ", built from source" }
        if dirty { line += ", uncommitted changes" }
        return line
    }

    private var standingText: String {
        if case .loading = model.releaseCheck { return "Checking for updates..." }
        if case let .failed(_, reason) = model.releaseCheck { return reason }
        guard let latest = model.latestRelease else { return "No release has been published yet." }
        switch model.standing {
        case .behind: return "MacMax \(latest.version) is available."
        case .latest: return "This is the latest release."
        case .ahead: return "Newer than the latest release (\(latest.version))."
        case .unknown: return "Could not compare this build with \(latest.version)."
        }
    }

    private var standingColor: Color {
        if case .failed = model.releaseCheck { return Theme.warn }
        return model.standing == .behind ? Theme.teal : Theme.textTertiary
    }

    /// Why Update is not offered, or why the last one did not finish.
    private var updateNote: String? {
        if case let .failed(message) = model.updateState { return "The update did not start: \(message)" }
        if model.newerRelease, model.updateVersion == nil {
            return "This copy is not in Applications, so it cannot update itself. Install the new version from the release page."
        }
        return nil
    }

    private func link(_ title: String, _ url: URL) -> some View {
        PillButton(title: title, symbol: "arrow.up.right", prominent: false) { NSWorkspace.shared.open(url) }
    }
}

private extension UpdateState {
    var isUpdating: Bool {
        if case .updating = self { return true }
        return false
    }
}

private extension SectionState {
    var isChecking: Bool {
        if case .loading = self { return true }
        return false
    }
}
