import MacMaxCore
import SwiftUI

/// Under the swap finding: swap cannot be emptied on demand, so say what does help and who holds the memory.
struct SwapNote: View {
    @ObservedObject var model: PanelModel

    static func applies(to ruleID: String) -> Bool { ruleID == "swap_used" }

    private var holders: [AppRow] {
        Array(AppListing.sorted(model.apps, by: .memory).filter { $0.footprintBytes != nil }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Swap cannot be emptied safely on demand. macOS gives it back by itself when the apps that filled it close, so closing them (or restarting) is what frees it. It is harmless while memory pressure stays normal.")
                .font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if !holders.isEmpty {
                Text("Using the most memory now").font(.meta).foregroundStyle(Theme.textTertiary)
                ForEach(holders) { app in
                    HStack {
                        Text(app.name).font(.meta).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(CompactFormat.bytes(app.footprintBytes ?? 0)).font(.meta.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }
}
