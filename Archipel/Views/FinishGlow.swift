import ArchipelCore
import SwiftUI

extension AppModel {
    /// Changes whenever one of the worktree's sessions finishes a turn out of sight. Only meant to be
    /// watched for increases; a removed session can make the sum drop.
    func finishPulse(for worktree: Worktree) -> Int {
        worktree.sessions.reduce(0) { $0 + (finishPulses[$1.id] ?? 0) }
    }
}

extension View {
    /// One soft light sweep across the view each time `pulse` goes up.
    func finishGlow(pulse: Int, tint: Color) -> some View {
        modifier(FinishGlow(pulse: pulse, tint: tint))
    }
}

private struct FinishGlow: ViewModifier {
    let pulse: Int
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Separate from `pulse` so that it only ever counts plays: the keyframes start when it changes,
    /// and the view appearing with an old pulse value must not start them.
    @State private var plays = 0

    private struct Frame {
        var sweep = 0.0
        var opacity = 0.0
    }

    func body(content: Content) -> some View {
        let reduceMotion = reduceMotion
        return content
            .overlay {
                shape
                    .keyframeAnimator(initialValue: Frame(), trigger: plays) { shape, frame in
                        shape.opacity(frame.opacity)
                            .mask { Self.glow(at: frame.sweep, reduceMotion: reduceMotion) }
                    } keyframes: { _ in
                        KeyframeTrack(\.sweep) {
                            LinearKeyframe(0, duration: 0.001)
                            CubicKeyframe(1, duration: reduceMotion ? 0.001 : 1.2)
                        }
                        KeyframeTrack(\.opacity) {
                            CubicKeyframe(1, duration: reduceMotion ? 0.3 : 0.35)
                            CubicKeyframe(0, duration: reduceMotion ? 0.9 : 0.85)
                        }
                    }
                    .padding(.vertical, -3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: pulse) { old, new in
                if new > old { plays += 1 }
            }
    }

    private var shape: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(tint.opacity(0.16))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(tint.opacity(0.55), lineWidth: 1)
            }
    }

    /// A soft band that travels from the leading to the trailing edge. With Reduce Motion it stays
    /// put and covers the whole row, so the glow only fades in and out.
    nonisolated private static func glow(at sweep: Double, reduceMotion: Bool) -> LinearGradient {
        if reduceMotion {
            return LinearGradient(colors: [.white], startPoint: .leading, endPoint: .trailing)
        }
        let start = -0.9 + 1.9 * sweep
        return LinearGradient(
            colors: [.clear, .white, .clear],
            startPoint: UnitPoint(x: start, y: 0.4),
            endPoint: UnitPoint(x: start + 0.9, y: 0.6)
        )
    }
}
