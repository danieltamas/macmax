import Charts
import MacMaxCore
import SwiftUI

/// What a chart shows for one metric: its words, its hue and how a value reads.
struct HistoryStyle {
    let metric: HistoryMetric
    let title: String
    let kind: Vital.Kind

    static let all: [HistoryStyle] = [
        HistoryStyle(metric: .cpu, title: "CPU", kind: .cpu),
        HistoryStyle(metric: .memory, title: "Memory used", kind: .memory),
        HistoryStyle(metric: .pressure, title: "Memory pressure", kind: .memory),
        HistoryStyle(metric: .swap, title: "Swap", kind: .swap),
        HistoryStyle(metric: .diskIO, title: "Disk IO", kind: .disk),
        HistoryStyle(metric: .netIn, title: "Download", kind: .netIn),
        HistoryStyle(metric: .netOut, title: "Upload", kind: .netOut),
    ]

    func format(_ value: Double) -> String {
        switch metric {
        case .cpu: CompactFormat.percent(value)
        case .memory, .swap: CompactFormat.bytes(UInt64(max(value, 0)))
        case .diskIO, .netIn, .netOut: CompactFormat.rate(value)
        case .pressure:
            // The stored level is a mean over the bucket: the nearest level is the honest word for it.
            [1.0: "Normal", 2.0: "Warning", 4.0: "Critical"].min { abs($0.key - value) < abs($1.key - value) }?.value ?? "-"
        }
    }
}

extension HistoryRange {
    var title: String {
        switch self {
        case .hour: "1 hour"
        case .day: "24 hours"
        case .week: "7 days"
        case .quarter: "90 days"
        }
    }
}

struct HistoryTab: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(HistoryRange.allCases, id: \.self) { range in
                    SegmentChip(title: range.title, selected: model.historyRange == range) { model.historyRange = range }
                }
                Spacer(minLength: 0)
            }
            if model.historyState != .ready || model.history.values.allSatisfy({ $0.allSatisfy { $0.value == nil } }) {
                SectionStateView(state: model.historyState, emptySymbol: "chart.xyaxis.line", emptyTitle: "No history yet",
                                 emptyDetail: "Charts fill in as MacMax samples this Mac. Gaps mean MacMax was not running.",
                                 isEmpty: model.historyState == .ready)
            } else {
                ForEach(HistoryStyle.all, id: \.metric) { style in
                    HistoryCard(model: model, style: style, points: model.history[style.metric] ?? [])
                }
            }
        }
    }
}

struct HistoryCard: View {
    @ObservedObject var model: PanelModel
    let style: HistoryStyle
    let points: [HistoryPoint]

    /// Where the pointer is over this chart: a local readout that moves with it. Only a click (the selection) loads the apps behind a moment.
    @State private var hoverTS: Int64?
    /// When the readout last moved: a 90-day chart has a bucket per pixel, so moves are paced to keep the chart from redrawing every frame.
    @State private var lastHoverMove = HoverClock()

    private var selection: HistorySelection? { model.historySelection?.metric == style.metric ? model.historySelection : nil }
    private var latest: Double? { points.last(where: { $0.value != nil })?.value }
    private var peak: Double? { points.compactMap(\.value).max() }

    var body: some View {
        Bezel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Eyebrow(text: style.title)
                    Spacer(minLength: 6)
                    if let peak {
                        Text("peak \(style.format(peak))").font(.meta.monospacedDigit()).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                chart.frame(height: 96)
                readout
                if !appSeries.isEmpty { legend }
                if let selection { holders(selection) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var appSeries: [HistoryAppSeries] { model.historyApps[style.metric] ?? [] }
    private static let appOpacities: [Double] = [0.8, 0.62, 0.48, 0.36, 0.26]

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 2) {
            ForEach(Array(appSeries.enumerated()), id: \.element.appKey) { index, app in
                HStack(spacing: 6) {
                    Circle().fill(Theme.color(style.kind).opacity(Self.appOpacities[min(index, 4)])).frame(width: 6, height: 6)
                    Text(app.name).font(.meta).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
            }
        }
    }

    private static func time(_ point: HistoryPoint) -> Date { Date(timeIntervalSince1970: TimeInterval(point.ts)) }

    @ChartContentBuilder
    private func appLines(_ color: Color) -> some ChartContent {
        ForEach(Array(appSeries.enumerated()), id: \.element.appKey) { index, app in
            ForEach(Self.segments(app.points), id: \.first?.ts) { segment in
                ForEach(segment, id: \.ts) { point in
                    LineMark(x: .value("Time", Self.time(point)), y: .value(app.name, point.value ?? 0),
                             series: .value("App run", "\(app.appKey)#\(segment.first?.ts ?? 0)"))
                        .foregroundStyle(color.opacity(Self.appOpacities[min(index, 4)])).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
        }
    }

    @ChartContentBuilder
    private func totalLine(_ color: Color) -> some ChartContent {
        ForEach(Self.segments(points), id: \.first?.ts) { segment in
            ForEach(segment, id: \.ts) { point in
                LineMark(x: .value("Time", Self.time(point)), y: .value(style.title, point.value ?? 0),
                         series: .value("Run", "total#\(segment.first?.ts ?? 0)"))
                    .foregroundStyle(color).interpolationMethod(.monotone)
            }
            // A run of one reading has no line to draw: it is a dot, never joined to its neighbors.
            if segment.count == 1, let point = segment.first {
                PointMark(x: .value("Time", Self.time(point)), y: .value(style.title, point.value ?? 0)).foregroundStyle(color)
            }
        }
    }

    private var chart: some View {
        let color = Theme.color(style.kind)
        return Chart {
            appLines(color)
            totalLine(color)
            if let marked = hoverTS ?? selection?.ts {
                RuleMark(x: .value("Selected", Date(timeIntervalSince1970: TimeInterval(marked))))
                    .foregroundStyle(Theme.textTertiary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(style.format(number)).font(.system(size: 9.5)).foregroundStyle(Theme.textTertiary) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: model.historyRange.axisFormat).font(.system(size: 9.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .chartXScale(range: .plotDimension(startPadding: 6, endPadding: 30))
        // The readout follows the pointer without changing the card's height (it always has its row), so nothing under a
        // scrolling pointer moves; a click pins the moment and opens the apps behind it.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard lastHoverMove.allows(), let ts = Self.bucket(proxy, geometry, location.x, model.historyRange), ts != hoverTS
                            else { return }
                            hoverTS = ts
                        case .ended: hoverTS = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { tap in
                        guard let ts = Self.bucket(proxy, geometry, tap.location.x, model.historyRange) else { return }
                        model.selectHistory(HistorySelection(metric: style.metric, ts: ts))
                    })
                    .pointingHandCursor()
            }
        }
    }

    private static func bucket(_ proxy: ChartProxy, _ geometry: GeometryProxy, _ x: CGFloat, _ range: HistoryRange) -> Int64? {
        let frame = proxy.plotAreaFrame
        guard let date: Date = proxy.value(atX: x - geometry[frame].origin.x) else { return nil }
        let step = range.stepSeconds
        return Int64(date.timeIntervalSince1970) / step * step
    }

    /// The moment under the pointer (or the pinned one) and its value; a fixed row, so the card keeps its height.
    private var readout: some View {
        let ts = hoverTS ?? selection?.ts
        return HStack {
            if let ts {
                Text(Date(timeIntervalSince1970: TimeInterval(ts)), format: model.historyRange.pointFormat)
                    .font(.meta).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 6)
                Text(points.first { $0.ts == ts }?.value.map(style.format) ?? "no reading")
                    .font(.meta.monospacedDigit()).foregroundStyle(Theme.textPrimary)
            } else {
                Text("Hover for a value, click for the apps behind it.").font(.meta).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
            }
        }
        .lineLimit(1).frame(height: 14)
    }

    @ViewBuilder
    private func holders(_ selection: HistorySelection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            let value = points.first { $0.ts == selection.ts }?.value
            if case let .failed(collector, reason) = model.historyHoldersState {
                Text("\(collector) is unavailable: \(reason)").font(.meta).foregroundStyle(Theme.unknown)
            } else if case let .loading(text) = model.historyHoldersState {
                Text(text).font(.meta).foregroundStyle(Theme.textTertiary)
            } else if model.historyHolders.isEmpty {
                Text(value == nil ? "MacMax was not running then." : "No app stands out at that moment.")
                    .font(.meta).foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(model.historyHolders, id: \.appKey) { holder in
                    HStack {
                        Text(holder.name).font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        Spacer(minLength: 6)
                        Text(Self.holderValue(style, holder.value)).font(.meta.monospacedDigit()).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
            }
        }
    }

    /// Network holders are bytes per sample, not a rate: label them as the amount moved.
    private static func holderValue(_ style: HistoryStyle, _ value: Double) -> String {
        switch style.metric {
        case .netIn, .netOut: CompactFormat.bytes(UInt64(max(value, 0)))
        case .pressure: CompactFormat.bytes(UInt64(max(value, 0)))
        default: style.format(value)
        }
    }

    /// Runs of consecutive readings: a missing bucket ends a run, so no line is drawn across a gap.
    static func segments(_ points: [HistoryPoint]) -> [[HistoryPoint]] {
        var runs: [[HistoryPoint]] = []
        var current: [HistoryPoint] = []
        for point in points {
            if point.value != nil { current.append(point) } else if !current.isEmpty { runs.append(current); current = [] }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}

extension HistoryRange {
    var axisFormat: Date.FormatStyle {
        switch self {
        case .hour, .day: .dateTime.hour().minute()
        case .week: .dateTime.weekday(.abbreviated)
        case .quarter: .dateTime.month(.abbreviated).day()
        }
    }

    var pointFormat: Date.FormatStyle {
        switch self {
        case .hour, .day: .dateTime.hour().minute()
        case .week, .quarter: .dateTime.month(.abbreviated).day().hour().minute()
        }
    }
}

/// Lets a hover update through at most every 40 ms.
private final class HoverClock {
    private var last = Date.distantPast

    func allows() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.04 else { return false }
        last = now
        return true
    }
}
