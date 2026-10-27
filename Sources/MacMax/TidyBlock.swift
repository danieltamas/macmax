import MacMaxCore
import SwiftUI

/// Under the MCP-server and zombie findings: the leftovers themselves, each ended only by a press.
struct TidyBlock: View {
    @ObservedObject var model: PanelModel
    let ruleID: String
    @State private var confirming = false

    static func applies(to ruleID: String) -> Bool { ruleID == "mcp_sidecars" || ruleID == "zombies" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.tidyState {
            case let .loading(text): OperationProgress(text: text)
            case let .failed(collector, reason):
                Text("\(collector): \(reason)").font(.meta).foregroundStyle(Theme.warn)
            case .ready:
                if let scan = model.tidy { content(scan) }
            }
        }
        .onAppear { model.scanTidy() }
    }

    @ViewBuilder private func content(_ scan: TidyScan) -> some View {
        if ruleID == "mcp_sidecars" { mcp(scan) } else { zombies(scan) }
    }

    @ViewBuilder private func mcp(_ scan: TidyScan) -> some View {
        if scan.staleMCP.isEmpty {
            note("None of the \(scan.mcpTotal) MCP servers is orphaned: each still belongs to a running session. To free them, end the session in Apps.")
        } else {
            note("\(scan.staleMCP.count) of \(scan.mcpTotal) belong to no running session:")
            ForEach(scan.staleMCP.prefix(8)) { item in
                HStack(spacing: 6) {
                    Text(item.name).font(.meta.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    Text(item.detail).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            if scan.staleMCP.count > 8 { note("and \(scan.staleMCP.count - 8) more") }
            let action = PanelAction.endTidy(group: "mcp", items: scan.staleMCP)
            HStack(spacing: 8) {
                Spacer(minLength: 6)
                if let state = model.actionStates[action.key] {
                    Text(state.text).font(.meta).foregroundStyle(Theme.textSecondary)
                } else if confirming {
                    Text("End \(scan.staleMCP.count) servers?").font(.meta).foregroundStyle(Theme.textSecondary)
                    ChipButton(title: "Cancel") { confirming = false }.fixedSize()
                    ChipButton(title: "End them", destructive: true) { confirming = false; model.perform(action) }.fixedSize()
                } else {
                    ChipButton(title: "End \(scan.staleMCP.count) stale MCP servers", destructive: true) { confirming = true }.fixedSize()
                }
            }
        }
    }

    @ViewBuilder private func zombies(_ scan: TidyScan) -> some View {
        if scan.zombieParents.isEmpty {
            note("\(scan.zombieCount) finished processes are waiting, but their parent is launchd or gone. Nothing here can end them; a restart clears them.")
        } else {
            note("A finished process is cleared when its parent collects it. End the parent to clear them:")
            ForEach(scan.zombieParents) { item in
                let action = PanelAction.endTidy(group: "zombie-\(item.identity.pid)", items: [item])
                HStack(spacing: 8) {
                    Text(item.name).font(.meta.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    Text(item.detail).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    Spacer(minLength: 6)
                    if let state = model.actionStates[action.key] {
                        Text(state.text).font(.meta).foregroundStyle(Theme.textSecondary)
                    } else {
                        ChipButton(title: "End \(item.name)", destructive: true) { model.perform(action) }.fixedSize()
                    }
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
}
