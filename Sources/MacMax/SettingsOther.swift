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
