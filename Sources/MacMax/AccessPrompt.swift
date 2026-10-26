import AppKit
import MacMaxCore
import SwiftUI

/// MacMax's own word before macOS has any: which protected places it would read, and the one grant that covers them,
/// so there is one switch to flip instead of a prompt per folder.
struct AccessPrompt: View {
    let model: PanelModel

    var body: some View {
        if model.fullDiskAccess != .granted {
            SettingsCard(title: "MacMax needs access to these folders",
                         detail: "To measure and clean them. macOS would ask for each one separately; Full Disk Access covers them all in one step.") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(PrivacyFolders.names.joined(separator: ", ") + ".")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        PillButton(title: "Allow access", symbol: "lock.open", prominent: true) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        Text("Turn MacMax on, then come back.").font(.meta).foregroundStyle(Theme.textTertiary)
                    }
                    Text("Until then MacMax leaves these folders alone and never triggers a macOS prompt for them.")
                        .font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
