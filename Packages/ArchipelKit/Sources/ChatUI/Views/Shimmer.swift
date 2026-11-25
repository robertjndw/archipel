import SwiftUI

/// Where the band of light is on its way across the text, worked out from the time alone.
///
/// Every shimmer on screen reads the same clock, so two of them move together, and one whose
/// view is rebuilt carries on where it was instead of starting over.
enum ShimmerSweep {
    /// One pass and the pause after it. The pause is what keeps the sweep from reading as a
    /// progress bar that never fills.
    static let period: TimeInterval = 2.2
    /// The part of a period the band is on its way.
    static let travel: TimeInterval = 1.5
    /// Half the band's width, in widths of the text. Wide enough for a soft swell, not a line.
    static let halfWidth = 0.35

    /// The band's middle in widths of the text: from just before the first glyph to just past
    /// the last, where it waits out the rest of the period.
    static func center(at time: TimeInterval) -> Double {
        let elapsed = time.truncatingRemainder(dividingBy: period)
        let progress = min(max(elapsed / travel, 0), 1)
        return -halfWidth + progress * (1 + 2 * halfWidth)
    }
}

/// Lets a soft band of light pass over text again and again, the way the system shows that
/// something is at work, with no shape next to the text.
///
/// It sets the text's color, from `base` to `highlight` inside the band, so the text must not set
/// one itself. Stands still under Reduce Motion and while scrolled out of view, and redraws
/// thirty times a second while it moves.
private struct Shimmer: ViewModifier {
    let isActive: Bool
    let base: Color
    let highlight: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Assumed until a scroll view says otherwise: outside one nothing ever reports.
    @State private var isOnScreen = true

    func body(content: Content) -> some View {
        let moves = isActive && !reduceMotion
        // One structure whether it moves or not, so turning the shimmer off never rebuilds the
        // text and drops a transition it is in the middle of.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moves || !isOnScreen)) { context in
            content.foregroundStyle(moves ? style(at: context.date) : AnyShapeStyle(base))
        }
        .onScrollVisibilityChange(threshold: 0.01) { isOnScreen = $0 }
    }

    private func style(at date: Date) -> AnyShapeStyle {
        let center = ShimmerSweep.center(at: date.timeIntervalSinceReferenceDate)
        // Nothing to turn around for a right-to-left layout: a gradient's unit points are
        // mirrored with it, so the band already goes the way the text is read.
        return AnyShapeStyle(LinearGradient(
            colors: [base, highlight, base],
            startPoint: UnitPoint(x: center - ShimmerSweep.halfWidth, y: 0.5),
            endPoint: UnitPoint(x: center + ShimmerSweep.halfWidth, y: 0.5)
        ))
    }
}

extension View {
    /// Shows that the text stands for work going on, with a band of light passing over it while
    /// `isActive`. The text is drawn in `base` and reaches `highlight` inside the band.
    func shimmer(isActive: Bool = true, base: Color = .secondary, highlight: Color = .primary) -> some View {
        modifier(Shimmer(isActive: isActive, base: base, highlight: highlight))
    }
}

#if DEBUG
#Preview("Shimmer") {
    VStack(alignment: .leading, spacing: 14) {
        Text("Working").shimmer()
        Text("Reading ChatTranscriptView.swift").shimmer()
        Text("Standing still").shimmer(isActive: false)
    }
    .font(.callout)
    .padding(30)
    .frame(width: 320, alignment: .leading)
    .background(Color(nsColor: .textBackgroundColor))
}

#Preview("Shimmer, Dark") {
    VStack(alignment: .leading, spacing: 14) {
        Text("Working").shimmer()
        Text("Reading ChatTranscriptView.swift").shimmer()
    }
    .font(.callout)
    .padding(30)
    .frame(width: 320, alignment: .leading)
    .background(Color(nsColor: .textBackgroundColor))
    .preferredColorScheme(.dark)
}
#endif
