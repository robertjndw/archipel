import ArchipelCore
import SwiftUI

/// The strongest signal of a group of sessions, in the space of a small glyph: an orange count while
/// something waits for the user, a green dot for unread results, a small spinner while agents work.
/// The colors are the status colors used everywhere else (sidebar glow, menu bar), not the island's. Collapsed project headers and the island switcher use it, so the same thing always
/// looks the same.
struct SidebarAttentionBadge: View {
    let signal: AttentionSummary.Signal
    /// The island switcher animates its symbol instead of showing a spinner.
    var showsWorking = true

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
                if showsWorking {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .transition(.scale.combined(with: .opacity))
        .accessibilityHidden(true)
    }
}
