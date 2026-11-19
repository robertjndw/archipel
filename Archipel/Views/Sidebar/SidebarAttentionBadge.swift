import ArchipelCore
import SwiftUI

/// The strongest signal of a group of sessions, in the space of a small glyph: an orange count while
/// something waits for the user, a green dot for unread results, a small spinner while agents work.
/// The colors are the status colors used everywhere else (sidebar glow, menu bar), not the island's.
/// Collapsed project headers use it; the island switcher has a dot of the same colors, without the count.
struct SidebarAttentionBadge: View {
    let signal: AttentionSummary.Signal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch signal {
            case .needsAttention(let count):
                Text(count, format: .number)
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(.orange, in: .capsule)
                    .contentTransition(.numericText(value: Double(count)))
            case .unread:
                Circle()
                    .fill(StatusPulse.finished.color)
                    .frame(width: 7, height: 7)
            case .working:
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
        .accessibilityHidden(true)
    }
}

#if DEBUG
private struct SidebarAttentionBadgeGallery: View {
    private static let variants: [(String, AttentionSummary.Signal)] = [
        ("1 waiting", .needsAttention(1)),
        ("12 waiting", .needsAttention(12)),
        ("128 waiting", .needsAttention(128)),
        ("Unread", .unread),
        ("Working", .working),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(Self.variants, id: \.0) { label, signal in
                GridRow {
                    Text(label).foregroundStyle(.secondary)
                    SidebarAttentionBadge(signal: signal)
                }
            }
        }
        .padding()
    }
}

#Preview("Light") {
    SidebarAttentionBadgeGallery()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SidebarAttentionBadgeGallery()
        .preferredColorScheme(.dark)
}
#endif
