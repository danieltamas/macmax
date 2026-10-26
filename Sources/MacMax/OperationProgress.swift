import SwiftUI

/// What MacMax shows while it does something on this Mac: a line of text and a bar. A known amount fills the bar;
/// an unknown one shows the system's moving bar, which exists only while the operation runs.
struct OperationProgress: View {
    let text: String
    var fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text).font(.meta).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            if let fraction {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.hairline)
                        Capsule().fill(Theme.teal).frame(width: geometry.size.width * min(1, max(0, fraction)))
                    }
                }
                .frame(height: 5)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small).tint(Theme.teal)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
