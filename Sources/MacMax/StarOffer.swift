import AppKit
import MacMaxCore
import SwiftUI

/// "Star on GitHub", glowing in the panel footer until it is done. One click stars the repository through the
/// user's own `gh`; the result is remembered, so the offer never comes back.
struct StarOffer: View {
    static let gold = Color(red: 1.0, green: 0.78, blue: 0.28)
    let starring: Bool
    let star: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelVisible) private var panelVisible
    @Environment(\.stillImage) private var stillImage
    @State private var hovering = false

    var body: some View {
        Button(action: star) {
            HStack(spacing: 5) {
                if starring {
                    ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 11, height: 11)
                } else {
                    Image(systemName: "star.fill").font(.system(size: 10.5, weight: .semibold))
                }
                Text(starring ? "Starring..." : "Star on GitHub").font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Self.gold)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background { capsule }
        }
        .buttonStyle(PressStyle(scale: 0.95, hit: AnyShape(Capsule()), lift: 0.1))
        .disabled(starring)
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
        .help("Star \(RepoStar.repo) on GitHub with your gh account")
        // The capsule reaches into the footer's own padding, so the footer keeps its height when the offer shows.
        .padding(.vertical, -5)
    }

    // ImageRenderer and the screenshots draw no AppKit view: they get the capsule at rest.
    @ViewBuilder
    private var capsule: some View {
        if stillImage {
            Capsule().fill(Self.gold.opacity(0.14))
                .overlay(Capsule().strokeBorder(Self.gold.opacity(0.3), lineWidth: 0.75))
                .shadow(color: Self.gold.opacity(0.15), radius: 3)
        } else {
            GlowLayer(color: NSColor(Self.gold), hovering: hovering, pulsing: panelVisible && !reduceMotion && !hovering)
        }
    }
}

/// The capsule's fill, hairline and glow in one layer. The glow is a Core Animation loop, run by the window server:
/// a SwiftUI `repeatForever` would re-render the whole panel every frame (docs/LESSONS.md section 3).
private struct GlowLayer: NSViewRepresentable {
    let color: NSColor
    let hovering: Bool
    let pulsing: Bool

    func makeNSView(context: Context) -> GlowView { GlowView() }
    func updateNSView(_ view: GlowView, context: Context) { view.show(color: color, hovering: hovering, pulsing: pulsing) }
}

final class GlowView: NSView {
    // A plain layer's border and fill are drawn at the screen's scale; a shape layer added by hand would rasterize at 1x.
    private let capsule = CALayer()
    private var color = NSColor.clear

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        capsule.borderWidth = 0.75
        capsule.shadowOffset = .zero
        layer?.addSublayer(capsule)
    }

    required init?(coder: NSCoder) { nil }

    // Drawn under the button's label: the click belongs to the button, not to this view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsule.frame = bounds
        capsule.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }

    /// Hover brightens the capsule and holds the glow at its peak; the pulse runs only while nothing hovers.
    func show(color: NSColor, hovering: Bool, pulsing: Bool) {
        self.color = color
        capsule.shadowColor = color.cgColor
        capsule.backgroundColor = color.withAlphaComponent(hovering ? 0.26 : 0.14).cgColor
        capsule.borderColor = color.withAlphaComponent(hovering ? 0.95 : 0.3).cgColor
        capsule.shadowOpacity = hovering ? 0.7 : 0.15
        capsule.shadowRadius = hovering ? 9 : 3
        guard pulsing != (capsule.animation(forKey: "glow") != nil) else { return }
        if pulsing { capsule.add(glow, forKey: "glow") } else { capsule.removeAnimation(forKey: "glow") }
    }

    private var glow: CAAnimation {
        let border = CABasicAnimation(keyPath: "borderColor")
        border.fromValue = color.withAlphaComponent(0.3).cgColor
        border.toValue = color.withAlphaComponent(0.65).cgColor
        let opacity = CABasicAnimation(keyPath: "shadowOpacity")
        opacity.fromValue = 0.15
        opacity.toValue = 0.5
        let radius = CABasicAnimation(keyPath: "shadowRadius")
        radius.fromValue = 3
        radius.toValue = 9
        let glow = CAAnimationGroup()
        glow.animations = [border, opacity, radius]
        glow.duration = 1.8
        glow.autoreverses = true
        glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.repeatCount = .infinity
        return glow
    }
}
