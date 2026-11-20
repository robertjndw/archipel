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

    /// The glow's own colors: the status color, and a neighbouring hue it cools to along its tail
    /// so the light is not one flat color from end to end.
    ///
    /// In dark mode both are deeper shades than the system colors, which are tuned to be read as
    /// text and glyphs on a dark background and come out pastel as a light.
    fileprivate func glowColors(isDark: Bool) -> (tint: Color, trail: Color) {
        guard isDark else {
            return switch self {
            case .finished: (.green, .mint)
            case .needsInput: (.orange, .yellow)
            case .failed: (.red, .pink)
            }
        }
        return switch self {
        case .finished:
            (Color(hue: 0.40, saturation: 1, brightness: 0.68), Color(hue: 0.46, saturation: 0.9, brightness: 0.68))
        case .needsInput:
            (Color(hue: 0.07, saturation: 1, brightness: 0.92), Color(hue: 0.11, saturation: 1, brightness: 0.9))
        case .failed:
            (Color(hue: 0, saturation: 0.95, brightness: 0.82), Color(hue: 0.93, saturation: 0.85, brightness: 0.8))
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
    /// A small pop for the row's status glyph at the moment the glow's lap closes. The lap starts
    /// next to the glyph, so this ties the light to the status it is about.
    func statusGlowLanding(_ pulse: StatusPulseCount?) -> some View {
        modifier(StatusGlowLanding(pulse: pulse ?? StatusPulseCount()))
    }
}

private struct StatusGlowLanding: ViewModifier {
    let pulse: StatusPulseCount
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts plays only, like `StatusGlow.plays`.
    @State private var plays = 0

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: 1.0, trigger: plays) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                LinearKeyframe(1, duration: StatusGlow.landing)
                SpringKeyframe(1.3, duration: 0.14, spring: .snappy)
                SpringKeyframe(1, duration: 0.45, spring: .bouncy(extraBounce: 0.1))
            }
            .onChange(of: pulse.count) { old, new in
                // With Reduce Motion there is no lap to come back from.
                if new > old, !reduceMotion { plays += 1 }
            }
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

    private static let lapDuration = 2.0
    /// Laps per second at the start. The lap is at its fastest then and only slows from there,
    /// so the light is on its way at once instead of gathering speed in the corner.
    private static let launchSpeed = 0.7
    private static let tailDelay = 0.28
    /// When the head is as good as back where it started, which is when the outline flares.
    static let landing = 1.65

    func body(content: Content) -> some View {
        let reduceMotion = reduceMotion
        let kind = pulse.kind
        return content
            .background {
                // The animation runs here, in the row; each frame is handed to the light, which lives
                // in the list behind the rows (see BacklightHost).
                Color.clear
                    .keyframeAnimator(initialValue: BacklightFrame(), trigger: plays) { view, frame in
                        view.background { BacklightHost(frame: frame, kind: kind, still: reduceMotion) }
                    } keyframes: { current in
                        // A lap ends where it began, so a new one picks up wherever the light is. That
                        // is the start after a finished lap, and mid-lap it keeps the light from
                        // jumping back when a second change comes in.
                        let start = current.head - current.head.rounded(.down)
                        let trailing = max(current.head - current.tail, 0)
                        KeyframeTrack(\.head) {
                            LinearKeyframe(start, duration: 0.001)
                            CubicKeyframe(start + 1, duration: Self.lapDuration, startVelocity: Self.launchSpeed, endVelocity: 0)
                        }
                        // The same lap a moment later. The light spans from here to the head, so it
                        // is at its longest while it is fast and gathers again as it comes to rest,
                        // instead of standing still with its whole trail out.
                        KeyframeTrack(\.tail) {
                            LinearKeyframe(start - trailing, duration: 0.001 + Self.tailDelay)
                            CubicKeyframe(start + 1, duration: Self.lapDuration, startVelocity: Self.launchSpeed, endVelocity: 0)
                        }
                        KeyframeTrack(\.origin) {
                            LinearKeyframe(start, duration: 0.001)
                        }
                        // Gone by the time the outline has taken over, so nothing is left standing
                        // at the point where the lap ends.
                        KeyframeTrack(\.light) {
                            CubicKeyframe(1, duration: 0.2)
                            LinearKeyframe(1, duration: reduceMotion ? 0.4 : 1.45)
                            CubicKeyframe(0, duration: 0.55)
                        }
                        // What the light leaves on the outline behind it: faint while it is being
                        // drawn, flaring once when the loop closes, then let go.
                        KeyframeTrack(\.ring) {
                            CubicKeyframe(reduceMotion ? 0 : BacklightFrame.wake, duration: 0.35)
                            LinearKeyframe(reduceMotion ? 0 : BacklightFrame.wake, duration: Self.landing - 0.35)
                            CubicKeyframe(reduceMotion ? 0 : 1, duration: 0.3)
                            CubicKeyframe(0, duration: 0.9)
                        }
                        KeyframeTrack(\.card) {
                            CubicKeyframe(1, duration: 0.4)
                            LinearKeyframe(1, duration: reduceMotion ? 0.7 : 1.75)
                            CubicKeyframe(0, duration: 0.75)
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
    /// Where this lap started, in laps. The outline is lit from here to the head.
    var origin = 0.0
    /// Strength of the glow on the part of the outline the head has passed, 0...1.
    var ring = 0.0
    /// Strength of the card surface, 0...1. Gives rows that are not selected a card to light.
    var card = 0.0

    var isDark: Bool { light <= 0 && ring <= 0 && card <= 0 }

    /// How strong `ring` is while the lap is still running.
    static let wake = 0.4
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
    let kind: StatusPulse
    let still: Bool

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        // The row's color scheme, handed over: the light is hosted in a view of its own, outside
        // the row's environment.
        probe.show(Backlight(frame: frame, kind: kind, still: still, isDark: context.environment.colorScheme == .dark))
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
/// white-hot at the head and cooling along the tail, faded out before the spill area ends so
/// nothing gets clipped. The card's edge and a little of its surface pick it up as it passes.
private struct Backlight: View {
    let frame: BacklightFrame
    let kind: StatusPulse
    /// Reduce Motion: no travelling light, the whole outline glows and fades instead.
    let still: Bool
    let isDark: Bool

    /// Room around the card for the halo. Sideways it is the card's whole 10pt inset from the
    /// sidebar's edges, which is less than the halo reaches, so it is faded out over `edgeFade`.
    static let spill = CGSize(width: 10, height: 16)
    /// Matches the sidebar's selection card.
    static let cornerRadius = Chrome.controlRadius
    /// The halo: a band along the outline, blurred so it fades out within the spill. It is as wide
    /// as `haloWidth` at the head and narrows to `tailWidth`.
    private static let haloWidth: CGFloat = 10
    private static let tailWidth: CGFloat = 6
    private static let haloBlur: CGFloat = 4.5
    /// A second, wider and much fainter halo around the head, so the light does not end where
    /// the narrow one does.
    private static let bloomWidth: CGFloat = 16
    private static let bloomBlur: CGFloat = 8
    /// The light that falls on the card itself.
    private static let washWidth: CGFloat = 10
    private static let washBlur: CGFloat = 7
    private static let edgeFade: CGFloat = 4
    /// How far the light reaches ahead of the head, so its front is as soft as its sides.
    private static let lead: CGFloat = 20
    /// Brightness steps from the dim ends to the head. The blur hides the steps.
    private static let levels = 24
    /// Over what length, and in how many steps, the lit outline fades in where the lap began.
    private static let wakeFade: CGFloat = 36
    private static let wakeLevels = 8
    /// How strong the outline's glow gets when the loop closes, next to the travelling light.
    private static let ringStrength = 0.5

    var body: some View {
        let frame = frame
        let kind = kind
        let still = still
        let isDark = isDark
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let cardRect = bounds.insetBy(dx: Self.spill.width, dy: Self.spill.height)
            guard cardRect.width > 0, cardRect.height > 0 else { return }
            let outline = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).path(in: cardRect)

            // The card surface, for rows that have no selection card of their own.
            context.fill(outline, with: .color(.primary.opacity(0.05 * frame.card)))
            guard frame.light > 0 || frame.ring > 0 else { return }

            // White reads as light on a dark sidebar. On a light one it only washes the color out.
            let (tint, trail) = kind.glowColors(isDark: isDark)
            let ring = still ? 0 : Self.ringStrength * frame.ring
            let passed = still ? [] : Self.wake(on: outline, around: cardRect, from: frame.origin, to: frame.head)
            let light = still
                ? [Stretch(path: outline, opacity: 1, strength: 0.65)]
                : Self.stretches(of: outline, around: cardRect, head: frame.head, tail: frame.tail)
            // The tail's hue at the dim end, the status color through the middle, and toward white
            // over the brightest part by as much as `heat`.
            func color(of stretch: Stretch, heat: Double) -> Color {
                let core = max(0, (stretch.strength - 0.55) / 0.45)
                return trail.mix(with: tint, by: min(1, stretch.strength * 1.6))
                    .mix(with: .white, by: heat * core * core)
                    .opacity(stretch.opacity)
            }

            // On the card. Rows with a selection card of their own cover this with it.
            var surface = context
            surface.clip(to: outline)
            surface.opacity = isDark ? 0.35 : 0.12
            surface.drawBlurred(radius: Self.washBlur) { wash in
                wash.opacity = ring
                for stretch in passed {
                    wash.stroke(stretch.path, with: .color(tint.opacity(stretch.opacity)), lineWidth: Self.washWidth)
                }
                wash.opacity = frame.light
                for stretch in light {
                    wash.stroke(stretch.path, with: .color(tint.opacity(stretch.opacity)), lineWidth: Self.washWidth)
                }
            }

            // Behind the card: nothing of the halo shows inside it.
            var around = context
            var outside = Path(bounds)
            outside.addPath(outline)
            around.clip(to: outside, style: FillStyle(eoFill: true))
            around.drawLayer { halo in
                // Not on a light sidebar. Color darkens it instead of lighting it up, and the bloom
                // only shows as a haze around the head.
                if !still, isDark {
                    halo.drawBlurred(radius: Self.bloomBlur) { bloom in
                        bloom.opacity = 0.45 * frame.light
                        for stretch in light where stretch.strength > 0.3 {
                            bloom.stroke(stretch.path, with: .color(tint.opacity(stretch.opacity)), lineWidth: Self.bloomWidth)
                        }
                    }
                }
                halo.drawBlurred(radius: Self.haloBlur) { band in
                    band.opacity = ring
                    for stretch in passed {
                        band.stroke(stretch.path, with: .color(tint.opacity(stretch.opacity)), lineWidth: Self.tailWidth)
                    }
                    band.opacity = frame.light
                    for stretch in light {
                        let width = Self.tailWidth + (Self.haloWidth - Self.tailWidth) * stretch.strength
                        band.stroke(stretch.path, with: .color(color(of: stretch, heat: isDark ? 0.5 : 0.15)), lineWidth: width)
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

            // Where the light is behind it, the card's edge catches it.
            // Blurred by a hair, which is enough to run the steps of the light into each other.
            context.drawBlurred(radius: 0.8) { edge in
                edge.opacity = 0.9 * ring
                for stretch in passed {
                    edge.stroke(stretch.path, with: .color(tint.opacity(stretch.opacity)), lineWidth: 1)
                }
                edge.opacity = (still ? 0.35 : 0.8) * frame.light
                for stretch in light {
                    edge.stroke(stretch.path, with: .color(color(of: stretch, heat: isDark ? 0.4 : 0.15)), lineWidth: 1)
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

    /// The part of the outline the head has been over since `origin`, which is all of it once the
    /// lap is done. It fades in from where the lap began, or it would start there with a cut edge,
    /// and that fade shortens to nothing as the head comes back round to close the gap.
    private static func wake(on outline: Path, around card: CGRect, from origin: Double, to head: Double) -> [Stretch] {
        let perimeter = 2 * (card.width + card.height) - (8 - 2 * .pi) * cornerRadius
        let fade = min(wakeFade / perimeter, max(1 - (head - origin), 0))
        return (1...wakeLevels).map { level in
            let strength = Double(level) / Double(wakeLevels)
            return Stretch(
                path: arc(of: outline, from: origin + fade * strength, to: head),
                opacity: 1 / Double(wakeLevels - level + 1),
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

extension GraphicsContext {
    /// Draws `content` and blurs the result as one image. A blur filter set on the context that
    /// does the drawing blurs every stroke on its own instead, and each of them then ends in a
    /// faint edge where its blur is cut off. Stacked strokes show that as rings around the light.
    fileprivate func drawBlurred(radius: CGFloat, content: (inout GraphicsContext) -> Void) {
        drawLayer { blurred in
            blurred.addFilter(.blur(radius: radius))
            blurred.drawLayer(content: content)
        }
    }
}

#if DEBUG
// The glow only plays when the count goes up, so these previews need the live canvas and a click.
private struct StatusGlowPreview: View {
    @State private var pulses: [Int: StatusPulseCount] = [:]
    @State private var selection: Int? = 0

    var body: some View {
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
}

#Preview("Dark") {
    StatusGlowPreview()
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    StatusGlowPreview()
        .preferredColorScheme(.light)
}
#endif
