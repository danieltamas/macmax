import AppKit
import MacMaxCore
import SwiftUI

/// A three-quarter ring: a track with a filled arc over it, opening at the bottom.
struct ArcGauge: View {
    let fraction: Double
    let tint: Color
    var width: CGFloat = 6

    var body: some View {
        ZStack {
            Arc(fraction: 1).stroke(Theme.hairline, style: StrokeStyle(lineWidth: width, lineCap: .round))
            Arc(fraction: min(max(fraction, 0), 1)).stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    private struct Arc: Shape {
        var fraction: Double
        var animatableData: Double {
            get { fraction }
            set { fraction = newValue }
        }

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let radius = min(rect.width, rect.height) / 2
            guard fraction > 0 else { return path }
            // Opens at the bottom: from 135 degrees clockwise through 270 degrees.
            path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius - 3, startAngle: .degrees(135),
                        endAngle: .degrees(135 + 270 * fraction), clockwise: false)
            return path
        }
    }
}

/// The battery as it looks: an outline with a terminal, filled to the charge, a bolt while it charges.
struct BatteryGlyph: View {
    let percent: Int?
    let charging: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hairline.opacity(0.5))
                RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.textTertiary.opacity(0.7), lineWidth: 1.5)
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient)
                        .frame(width: max(0, (proxy.size.width - 8) * Double(percent ?? 0) / 100))
                        .padding(4)
                }
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 2).frame(maxWidth: .infinity)
                } else if percent == nil {
                    Text("?").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity)
                }
            }
            .frame(width: 92, height: 44)
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Theme.textTertiary.opacity(0.7)).frame(width: 4, height: 16)
        }
    }
}

/// A fan that turns. The turning is a Core Animation loop run by the window server, only while the panel is visible,
/// and slower than the real fan (1 turn a second per 1000 rpm: a screen cannot draw 40 turns a second), in proportion to its rpm.
struct FanRotor: View {
    @Environment(\.panelVisible) private var panelVisible
    @Environment(\.stillImage) private var stillImage
    let rpm: Int
    let tint: Color

    var body: some View {
        if stillImage {
            Image(systemName: "fan.fill").font(.system(size: 22)).foregroundStyle(tint)
        } else {
            RotorLayer(rpm: rpm, tint: NSColor(tint), spinning: panelVisible && rpm > 0).frame(width: 24, height: 24)
        }
    }
}

private struct RotorLayer: NSViewRepresentable {
    let rpm: Int
    let tint: NSColor
    let spinning: Bool

    func makeNSView(context: Context) -> RotorView { RotorView() }
    func updateNSView(_ view: RotorView, context: Context) { view.show(rpm: rpm, tint: tint, spinning: spinning) }
}

/// One turn a second at speed 1, always attached: the fan's rate is the layer's `speed`, so a new rpm changes how fast it
/// turns from where it is, instead of restarting the blades at angle zero.
final class RotorView: NSView {
    private let blades = CALayer()
    private var wanted: Float = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(blades)
        blades.add(Self.turn, forKey: "turn")
        blades.speed = 0
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blades.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        blades.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    /// AppKit drops running animations when a view leaves its window: the rate is set again on arrival.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if blades.animation(forKey: "turn") == nil { blades.add(Self.turn, forKey: "turn") }
        retime(to: wanted, force: true)
    }

    private static var turn: CABasicAnimation {
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 1
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        return turn
    }

    /// Turns per second: the fan's real speed shown at a thousandth, because a screen cannot draw 40 turns a second.
    func show(rpm: Int, tint: NSColor, spinning: Bool) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular).applying(.init(paletteColors: [tint]))
        let image = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blades.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        blades.contentsGravity = .resizeAspect
        blades.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        wanted = spinning ? Float(rpm) / 1000 : 0
        retime(to: wanted, force: false)
    }

    /// Changes the rate and keeps the angle: freeze at the current animation time, then start again from it.
    private func retime(to speed: Float, force: Bool) {
        guard force || blades.speed != speed else { return }
        let now = CACurrentMediaTime()
        let local = blades.convertTime(now, from: nil)
        blades.speed = 0
        blades.timeOffset = local
        guard speed > 0 else { return }
        // The layer's time is (parent time - beginTime) * speed + timeOffset: pick beginTime so it is `local` right now.
        let parentNow = blades.superlayer?.convertTime(now, from: nil) ?? now
        blades.timeOffset = 0
        blades.speed = speed
        blades.beginTime = parentNow - CFTimeInterval(Double(local) / Double(speed))
    }
}
