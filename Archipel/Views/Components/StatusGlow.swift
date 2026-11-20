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

extension View {
    /// The glow for something too small to run a light around: a soft spot of the status color
    /// behind it that swells and fades each time `pulse` goes up.
    func statusSpot(_ pulse: StatusPulseCount?, diameter: CGFloat) -> some View {
        modifier(StatusSpot(pulse: pulse ?? StatusPulseCount(), diameter: diameter))
    }
}

private struct StatusSpot: ViewModifier {
    let pulse: StatusPulseCount
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts plays only, like `StatusGlow.plays`.
    @State private var plays = 0

    func body(content: Content) -> some View {
        // Copied out because the animator's closure is Sendable and may not read the property.
        let reduceMotion = reduceMotion
        return content
            .background {
                Circle()
                    .fill(pulse.kind.color)
                    .frame(width: diameter, height: diameter)
                    .blur(radius: 5)
                    .keyframeAnimator(initialValue: Spot(), trigger: plays) { view, spot in
                        view
                            .scaleEffect(reduceMotion ? 1 : spot.scale)
                            .opacity(0.6 * spot.light)
                    } keyframes: { _ in
                        KeyframeTrack(\.light) {
                            CubicKeyframe(1, duration: 0.25)
                            LinearKeyframe(1, duration: 0.9)
                            CubicKeyframe(0, duration: 0.65)
                        }
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(0.5, duration: 0.001)
                            SpringKeyframe(1, duration: 0.5, spring: .smooth)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: pulse.count) { old, new in
                if new > old { plays += 1 }
            }
    }

    private struct Spot {
        var light = 0.0
        var scale = 0.5
    }
}

private struct StatusGlow: ViewModifier {
    let pulse: StatusPulseCount
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Separate from `pulse` so that it only ever counts plays: the keyframes start when it changes,
    /// and the view appearing with an old pulse value must not start them.
    @State private var plays = 0

    private static let lapDuration = 2.2
    private static let tailDelay = 0.32

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
                    } keyframes: { current in
                        // A lap ends where it began, so a new one picks up wherever the light is. That
                        // is the start after a finished lap, and mid-lap it keeps the light from
                        // jumping back when a second change comes in.
                        let start = current.head - current.head.rounded(.down)
                        let trailing = max(current.head - current.tail, 0)
                        KeyframeTrack(\.head) {
                            LinearKeyframe(start, duration: 0.001)
                            CubicKeyframe(start + 1, duration: Self.lapDuration)
                        }
                        // The same lap a moment later. The light spans from here to the head, so it
                        // grows out of a point as it picks up speed and gathers again as it comes to
                        // rest, instead of standing still with its whole trail out.
                        KeyframeTrack(\.tail) {
                            LinearKeyframe(start - trailing, duration: 0.001 + Self.tailDelay)
                            CubicKeyframe(start + 1, duration: Self.lapDuration)
                        }
                        // Lasts until the tail has caught up, so the light never goes out mid-stretch.
                        KeyframeTrack(\.light) {
                            CubicKeyframe(1, duration: 0.25)
                            LinearKeyframe(1, duration: reduceMotion ? 0.4 : 1.6)
                            CubicKeyframe(0, duration: 0.65)
                        }
                        KeyframeTrack(\.card) {
                            CubicKeyframe(1, duration: 0.4)
                            LinearKeyframe(1, duration: reduceMotion ? 0.7 : 1.5)
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
    /// Where the front of the light is along the card's outline, in laps. Only the fraction matters.
    var head = 0.0
    /// Where the light ends, in laps. Never ahead of `head`.
    var tail = 0.0
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
/// brightest at the head and thinning out along the tail, faded out before the spill area ends so
/// nothing gets clipped. The card's edge picks up a bit of it as it passes.
private struct Backlight: View {
    let frame: BacklightFrame
    let tint: Color
    /// Reduce Motion: no travelling light, the whole outline glows and fades instead.
    let still: Bool

    /// Room around the card for the halo. Sideways it is the card's whole 10pt inset from the
    /// sidebar's edges, which is less than the halo reaches, so it is faded out over `edgeFade`.
    static let spill = CGSize(width: 10, height: 16)
    /// Matches the sidebar's selection card.
    static let cornerRadius = Chrome.controlRadius
    /// The halo: a band along the outline, blurred so it fades out within the spill. It is as wide
    /// as `haloWidth` at the head and narrows to `tailWidth`.
    private static let haloWidth: CGFloat = 8
    private static let tailWidth: CGFloat = 6
    private static let haloBlur: CGFloat = 4.5
    private static let edgeFade: CGFloat = 4
    /// How far the light reaches ahead of the head, so its front is as soft as its sides.
    private static let lead: CGFloat = 20
    /// Brightness steps from the dim ends to the head. The blur hides the steps.
    private static let levels = 24

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

            let light = still
                ? [Stretch(path: outline, opacity: 1, strength: 1)]
                : Self.stretches(of: outline, around: cardRect, head: frame.head, tail: frame.tail)

            // Behind the card: nothing of the halo shows inside it.
            var around = context
            var outside = Path(bounds)
            outside.addPath(outline)
            around.clip(to: outside, style: FillStyle(eoFill: true))
            around.opacity = frame.light
            around.drawLayer { halo in
                halo.drawLayer { band in
                    band.addFilter(.blur(radius: Self.haloBlur))
                    for stretch in light {
                        let width = Self.tailWidth + (Self.haloWidth - Self.tailWidth) * stretch.strength
                        band.stroke(stretch.path, with: .color(tint.opacity(stretch.opacity)), lineWidth: width)
                    }
                }
                // The list ends where the spill does on the left and right. The halo is still
                // visible there, so without this it would end in a straight line.
                let fade = Self.edgeFade / size.width
                halo.blendMode = .destinationIn
                halo.fill(
                    Path(bounds),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: fade),
                            .init(color: .white, location: 1 - fade),
                            .init(color: .clear, location: 1),
                        ]),
                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)
                    )
                )
            }

            // Where the light is behind it, the card's edge picks up a little of it.
            var rim = context
            rim.opacity = (still ? 0.35 : 0.6) * frame.light
            rim.drawLayer { edge in
                for stretch in light {
                    edge.stroke(stretch.path, with: .color(tint.opacity(stretch.opacity)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// A piece of the outline and how much light it adds to what is drawn before it.
    private struct Stretch {
        let path: Path
        let opacity: Double
        /// 0...1, how close to the head's full brightness this piece brings the light.
        let strength: Double
    }

    /// The light as pieces of the outline, each inside the one before and drawn over it: the first
    /// spans the whole light, the last only the head. Stacked, they brighten in even steps.
    ///
    /// The light is measured along the outline, not as a distance from the head. On a low row the
    /// opposite edge is closer to the head than the tail is, and would light up with it.
    private static func stretches(of outline: Path, around card: CGRect, head: Double, tail: Double) -> [Stretch] {
        // Assumes circular corners. The continuous ones are a little longer, which does not show.
        let perimeter = 2 * (card.width + card.height) - (8 - 2 * .pi) * cornerRadius
        let lead = lead / perimeter
        // With the tail caught up there is still a spot as long behind the head as ahead of it.
        let body = max(head - tail, 0) + lead
        return (1...levels).map { level in
            let strength = Double(level) / Double(levels)
            // Fades in a nearly straight line along the tail, and faster than that ahead.
            let behind = body * (1 - pow(strength, 1 / 0.85))
            let ahead = lead * (1 - strength.squareRoot())
            return Stretch(
                path: arc(of: outline, from: head - behind, to: head + ahead),
                // What it takes on top of the levels below to reach `strength`.
                opacity: 1 / Double(levels - level + 1),
                strength: strength
            )
        }
    }

    /// The outline between two positions given in laps, across the outline's start if need be.
    private static func arc(of outline: Path, from start: Double, to end: Double) -> Path {
        let length = end - start
        guard length < 1 else { return outline }
        let from = start - start.rounded(.down)
        let to = from + max(length, 0.0001)
        guard to > 1 else { return outline.trimmedPath(from: from, to: to) }
        var path = outline.trimmedPath(from: from, to: 1)
        path.addPath(outline.trimmedPath(from: 0, to: to - 1))
        return path
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
                // The stack keeps the canvas from crashing, see SidebarView.worktreeRow.
                HStack(spacing: 0) {
                    Label(row == 0 ? "Selected row" : "Row \(row)", systemImage: "arrow.triangle.branch")
                        .padding(.vertical, 6)
                        .statusGlow(pulses[row])
                }
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
