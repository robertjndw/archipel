import ArchipelCore
import SwiftUI

/// The trailing indicator on a session row.
struct StatusGlyph: View {
    let activity: SessionActivity

    var body: some View {
        Group {
            switch activity.status {
            case .starting, .working:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
                    .help("Working")
            case .needsAttention(.permission):
                attention("hand.raised.fill", label: "Needs your approval")
            case .needsAttention:
                attention("questionmark.bubble.fill", label: "Waiting for you")
            case .finished:
                if activity.unread {
                    Circle()
                        .fill(.tint)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Finished, unread")
                        .help("Finished, unread")
                }
            case .exited(let code):
                Image(systemName: code == 0 ? "stop.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(code == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red))
                    .accessibilityLabel(code == 0 ? "Ended" : "Exited with an error")
                    .help(code == 0 ? "Ended" : "Exited with code \(code)")
            case .notStarted:
                Image(systemName: "moon.zzz")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Not running")
                    .help("Not running")
            }
        }
        .frame(width: 18)
        .transition(.opacity.combined(with: .scale(scale: 0.6)))
    }

    /// Bounces once when it appears or the reason changes, which is what draws the eye to a row in a
    /// long sidebar without animating forever.
    private func attention(_ symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(.orange)
            .symbolEffect(.bounce, options: .nonRepeating, value: activity.status)
            .accessibilityLabel(label)
            .help(label)
    }
}
