import AppKit
import MacMaxCore
import SwiftUI

struct NetworkPane: View {
    let model: PanelModel
    @State private var endpoint = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .network, title: "Network", detail: "Your public address and whether your VPN carries your traffic.")
            if let problem = model.configProblem { ProblemText(text: problem) }
            SettingsCard(title: "Public IP check",
                         detail: "When on, MacMax asks the endpoint below for your public address, about once a minute. It sends no data about you beyond the request itself.") {
                SwitchRow(title: "Check my public IP", isOn: Binding(get: { model.config.ipCheckEnabled },
                                                                     set: { value in model.change { $0.ipCheckEnabled = value } }))
            }
            SettingsCard(title: "Endpoint", detail: "Any https address that answers with your IP. Default: Cloudflare's trace.") {
                GlassField(placeholder: IPEndpointClient.defaultEndpoint, text: $endpoint, monospaced: true).onSubmit(commit)
                HStack {
                    if let problem { ProblemText(text: problem) }
                    Spacer()
                    if model.config.ipEndpoint != nil {
                        ChipButton(title: "Use the default") { model.change { $0.ipEndpoint = nil }; endpoint = ""; problem = nil }
                    }
                }
            }
            SettingsCard(title: "Interface for the ISP IP", detail: "The interface used to see your address outside the VPN.") {
                SettingsRow(title: "Interface") {
                    Text(model.physicalInterface.map { "Automatic (\($0))" } ?? "Automatic")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                }
            }
            SettingsCard(title: "VPN services found", detail: "Network Extension VPNs macOS knows about.") {
                if model.vpnServices.isEmpty {
                    Text("None found.").font(.meta).foregroundStyle(Theme.textTertiary)
                }
                ForEach(Array(model.vpnServices.enumerated()), id: \.offset) { index, service in
                    if index > 0 { RowDivider() }
                    SettingsRow(title: service.name) { Chip(text: service.state, style: .outline) }
                }
            }
        }
        .onAppear { endpoint = model.config.ipEndpoint ?? "" }
    }

    private func commit() {
        let text = endpoint.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { model.change { $0.ipEndpoint = nil }; problem = nil; return }
        let url = URL(string: text)
        guard url?.scheme?.lowercased() == "https", url?.host?.isEmpty == false, url?.user == nil, url?.password == nil else {
            problem = "Use an https address without a user name or password."
            return
        }
        problem = nil
        model.change { $0.ipEndpoint = text }
    }
}

struct AgentPane: View {
    static let command = "claude mcp add macmax -- ~/.local/bin/macmax mcp"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .agent, title: "Agent access", detail: "Let a coding agent read what MacMax measures. Read-only.")
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
                Text("The MCP server is not built yet; the command works once it ships. Every tool will be read-only.")
                    .font(.meta).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct PermissionsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .permissions, title: "Permissions", detail: "What macOS lets MacMax see.")
            SettingsCard(title: "Full Disk Access", detail: "Lets MacMax measure and clean protected caches. Optional.") {
                PillButton(title: "Open System Settings", symbol: "arrow.up.right", prominent: false) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }
            SettingsCard(title: "Notifications", detail: "Lets MacMax tell you when a finding is new or gets worse.") {
                PillButton(title: "Open System Settings", symbol: "arrow.up.right", prominent: false) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            }
        }
    }
}

struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return (info?["MacMaxSource"] as? String) ?? (info?["CFBundleShortVersionString"] as? String) ?? "development build"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .about, title: "About", detail: "Why your Mac is slow, and what to do about it.")
            SettingsCard(title: "MacMax", detail: "Open source, MIT licensed. Made by Daniel Tamas.") {
                Text(version).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                LinkButton(title: "github.com/danieltamas/macmax") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/danieltamas/macmax")!)
                }.padding(.leading, -6)
            }
        }
    }
}
