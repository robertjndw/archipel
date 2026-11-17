import AppKit
import ArchipelCore
import SwiftUI

/// How often a worktree row has glowed and what for. The count only ever goes up, which is what
/// starts the animation; the kind picks its color.
struct StatusPulseCount: Equatable {
    private(set) var count = 0
    private(set) var kind = StatusPulse.finished

    mutating func play(_ kind: StatusPulse) {
        self.kind = kind
        count += 1
    }
}

extension StatusPulse {
    var color: Color {
        switch self {
        case .finished: .green
        case .needsInput: .orange
        case .failed: .red
        }
    }
}

extension View {
    /// One lap of light around the row's selection card each time `pulse` goes up.
    func statusGlow(_ pulse: StatusPulseCount?) -> some View {
        modifier(StatusGlow(pulse: pulse ?? StatusPulseCount()))
    }
}

private struct StatusGlow: ViewModifier {
    let pulse: StatusPulseCount
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Separate from `pulse` so that it only ever counts plays: the keyframes start when it changes,
    /// and the view appearing with an old pulse value must not start them.
    @State private var plays = 0

    func body(content: Content) -> some View {
        let reduceMotion = reduceMotion
        let tint = pulse.kind.color
        return content
            .background {
                // The animation runs here, in the row; each frame is handed to the light, which lives
                // in the list behind the rows (see BacklightHost).
                Color.clear
                    .keyframeAnimator(initialValue: BacklightFrame(), trigger: plays) { view, frame in
                        view.background { BacklightHost(frame: frame, tint: tint, still: reduceMotion) }
                    } keyframes: { _ in
                        KeyframeTrack(\.lap) {
                            LinearKeyframe(0, duration: 0.001)
                            // Eases out so the light slows down toward the end of the lap.
                            CubicKeyframe(1, duration: reduceMotion ? 0.001 : 2.2)
                        }
                        KeyframeTrack(\.light) {
                            CubicKeyframe(1, duration: 0.25)
                            LinearKeyframe(1, duration: reduceMotion ? 0.4 : 1.5)
                            CubicKeyframe(0, duration: 0.5)
                        }
                        KeyframeTrack(\.card) {
                            CubicKeyframe(1, duration: 0.4)
                            LinearKeyframe(1, duration: reduceMotion ? 0.7 : 1.4)
                            CubicKeyframe(0, duration: 0.7)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: pulse.count) { old, new in
                if new > old { plays += 1 }
            }
    }
}

struct BacklightFrame {
    /// Where the light is along the card's outline, 0...1 for one lap.
    var lap = 0.0
    /// Strength of the light, 0...1.
    var light = 0.0
    /// Strength of the card surface, 0...1. Gives rows that are not selected a card to light.
    var card = 0.0

    var isDark: Bool { light <= 0 && card <= 0 }
}

/// Puts the light behind the row instead of in it. The list's row view clips at the card, so light
/// drawn inside the row can never reach past the card's edge. This adds a view to the list's table,
/// below every row view, placed at the row's selection card and a little beyond. Rows are
/// transparent apart from the card, so the light shows around the card and under its neighbours.
///
/// The card is the row view's selection view: inset 10pt from the row's sides on macOS 27, with 8pt
/// continuous corners. Rows that are not selected have none, so the same inset is applied to them.
private struct BacklightHost: NSViewRepresentable {
    let frame: BacklightFrame
    let tint: Color
    let still: Bool

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.show(Backlight(frame: frame, tint: tint, still: still))
    }

    static func dismantleNSView(_ probe: Probe, coordinator: ()) {
        probe.removeLight()
    }

    final class Probe: NSView {
        private static let cardInset: CGFloat = 10
        private var light: LightView?
        private var pending: Backlight?

        func show(_ backlight: Backlight) {
            pending = backlight
            place()
        }

        func removeLight() {
            light?.removeFromSuperview()
            light = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { removeLight() } else { place() }
        }

        override func layout() {
            super.layout()
            place()
        }

        private func place() {
            guard let backlight = pending else { return }
            // Nothing to draw between animations; a hidden view costs nothing.
            if backlight.frame.isDark {
                light?.isHidden = true
                return
            }
            guard
                let row = sequence(first: superview, next: { $0?.superview }).first(where: { $0 is NSTableRowView }) ?? nil,
                let table = row.superview
            else { return }

            let host: LightView
            if let light, light.superview === table {
                host = light
                host.rootView = backlight
            } else {
                removeLight()
                host = LightView(rootView: backlight)
                // Below every row view, so the card and the row's content stay on top of the light.
                table.addSubview(host, positioned: .below, relativeTo: nil)
                light = host
            }
            let selection = row.subviews.first { $0 is NSVisualEffectView }
            let card = table.convert(selection?.frame ?? row.bounds.insetBy(dx: Self.cardInset, dy: 0), from: row)
            host.frame = card.insetBy(dx: -Backlight.spill.width, dy: -Backlight.spill.height)
            host.isHidden = false
        }
    }
}

/// Only ever drawn, never clicked: it sits in the list's table, and clicks between rows belong to
/// the list.
private final class LightView: NSHostingView<Backlight> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A colored light that runs around behind the card. Only a soft halo just outside the card shows,
/// lit near the light and faded out before the spill area ends so nothing gets clipped. The card's
/// edge picks up a bit of it as it passes.
private struct Backlight: View {
    let frame: BacklightFrame
    let tint: Color
    /// Reduce Motion: no travelling light, the whole outline glows and fades instead.
    let still: Bool

    /// Room around the card for the halo. Sideways it is the card's whole 10pt inset from the
    /// sidebar's edges; the halo has faded out by then, so the list's edge does not cut it off.
    static let spill = CGSize(width: 10, height: 16)
    /// Matches the sidebar's selection card.
    static let cornerRadius: CGFloat = 8
    /// The halo: a band along the outline, blurred so it fades out within the spill.
    private static let haloWidth: CGFloat = 8
    private static let haloBlur: CGFloat = 4.5
    /// The light source: soft spots along the outline that decide where the halo is lit.
    private static let spotRadius: CGFloat = 34
    private static let trail = 14
    private static let trailSpacing = 0.017

    var body: some View {
        let frame = frame
        let tint = tint
        let still = still
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let cardRect = bounds.insetBy(dx: Self.spill.width, dy: Self.spill.height)
            guard cardRect.width > 0, cardRect.height > 0 else { return }
            let outline = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).path(in: cardRect)

            // The card surface, for rows that have no selection card of their own.
            context.fill(outline, with: .color(.primary.opacity(0.05 * frame.card)))
            guard frame.light > 0 else { return }

            // Behind the card: nothing of the halo shows inside it.
            var around = context
            around.clip(to: Path(bounds).subtracting(outline))
            around.opacity = frame.light
            around.drawLayer { halo in
                halo.drawLayer { band in
                    band.addFilter(.blur(radius: Self.haloBlur))
                    band.stroke(outline, with: .color(tint), lineWidth: Self.haloWidth)
                }
                guard !still else { return }
                // Keeps only the part of the band near the light.
                halo.blendMode = .destinationIn
                halo.drawLayer { spots in
                    for step in (0..<Self.trail).reversed() {
                        let fade = 1 - Double(step) / Double(Self.trail)
                        let center = Self.point(on: outline, at: frame.lap - Double(step) * Self.trailSpacing)
                        let radius = Self.spotRadius * (0.5 + 0.5 * fade)
                        spots.fill(
                            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                            with: .radialGradient(
                                Gradient(colors: [.white.opacity(fade), .white.opacity(0)]),
                                center: center, startRadius: 0, endRadius: radius
                            )
                        )
                    }
                }
            }

            // Where the light passes behind it, the card's edge picks up a little of it.
            let rim: GraphicsContext.Shading = still
                ? .color(tint.opacity(0.35 * frame.light))
                : .radialGradient(
                    Gradient(colors: [tint.opacity(0.55 * frame.light), tint.opacity(0)]),
                    center: Self.point(on: outline, at: frame.lap), startRadius: 0, endRadius: Self.spotRadius
                )
            context.stroke(outline, with: rim, lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    /// The point `fraction` of the way along the outline, wrapping around for values outside 0...1.
    private static func point(on outline: Path, at fraction: Double) -> CGPoint {
        let wrapped = fraction - fraction.rounded(.down)
        return outline.trimmedPath(from: 0, to: max(wrapped, 0.0001)).currentPoint ?? .zero
    }
}

#if DEBUG
// The glow only plays when the count goes up, so this preview needs the live canvas and a click.
#Preview {
    @Previewable @State var pulses: [Int: StatusPulseCount] = [:]
    @Previewable @State var selection: Int? = 0
    VStack(spacing: 0) {
        List(selection: $selection) {
            ForEach(0..<4, id: \.self) { row in
                Label(row == 0 ? "Selected row" : "Row \(row)", systemImage: "arrow.triangle.branch")
                    .padding(.vertical, 6)
                    .statusGlow(pulses[row])
                    .tag(row)
            }
        }
        .listStyle(.sidebar)
        HStack {
            ForEach([(StatusPulse.finished, "Finished"), (.needsInput, "Needs Input"), (.failed, "Failed")], id: \.0) { kind, title in
                Button(title) {
                    for row in 0..<4 { pulses[row, default: StatusPulseCount()].play(kind) }
                }
                .tint(kind.color)
            }
        }
        .padding()
    }
    .frame(width: 260, height: 300)
}
#endif
