import MacMaxCore
import SwiftUI

/// One hue per meaning (docs/DESIGN.md). A verdict color never marks a resource and a resource color never
/// signals health.
extension Theme {
    static var ok: Color { success }
    static var warn: Color { unassigned }
    static var crit: Color { danger }
    static var unknown: Color { neutral }
    static var cpu: Color { hue(0x5AA9FF, light: 0x1F6FD1) }
    static var memory: Color { hue(0xB38CFF, light: 0x6B3FD0) }
    static var disk: Color { hue(0xE0B15A, light: 0x8A5F0B) }
    static var netIn: Color { hue(0x4FD1E8, light: 0x0A7C93) }
    static var netOut: Color { hue(0xF58FB8, light: 0xB4306B) }

    static func color(_ verdict: Verdict?) -> Color {
        switch verdict {
        case .ok: ok
        case .warn: warn
        case .crit: crit
        case .unknown, nil: unknown
        }
    }

    static func color(_ severity: Severity) -> Color {
        switch severity {
        case .crit: crit
        case .warn: warn
        case .info: unknown
        }
    }

    static func color(_ kind: Vital.Kind) -> Color {
        switch kind {
        case .cpu: cpu
        case .memory, .swap: memory
        case .disk: disk
        case .netIn: netIn
        case .netOut: netOut
        }
    }
}

/// A small line over a series; empty series draw nothing (no data is not a flat line).
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            if values.count > 1, let low = values.min(), let high = values.max() {
                let span = max(high - low, 0.000001)
                Path { path in
                    for (index, value) in values.enumerated() {
                        let point = CGPoint(x: proxy.size.width * CGFloat(index) / CGFloat(values.count - 1),
                                            y: proxy.size.height * (1 - CGFloat((value - low) / span)) * 0.85 + proxy.size.height * 0.075)
                        index == 0 ? path.move(to: point) : path.addLine(to: point)
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// The state line every list shows instead of an empty box (docs/DESIGN.md, States).
struct SectionStateView: View {
    let state: SectionState
    let emptySymbol: String
    let emptyTitle: String
    var emptyDetail: String?
    var isEmpty = false

    var body: some View {
        switch state {
        case let .loading(text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.meta).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case let .failed(collector, reason):
            VStack(spacing: 6) {
                GlyphDisc(symbol: "exclamationmark.triangle", color: Theme.unknown)
                Text("\(collector) is unavailable").font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(reason).font(.meta).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        case .ready:
            if isEmpty { EmptyState(symbol: emptySymbol, title: emptyTitle, detail: emptyDetail).frame(height: 180) }
        }
    }
}
