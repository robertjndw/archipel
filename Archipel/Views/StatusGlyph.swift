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
            case .needsAttention(.permission):
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Needs your approval")
            case .needsAttention:
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Waiting for you")
            case .finished:
                if activity.unread {
                    Circle()
                        .fill(.tint)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Finished, unread")
                }
            case .exited(let code):
                Image(systemName: code == 0 ? "stop.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(code == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red))
                    .accessibilityLabel(code == 0 ? "Ended" : "Exited with an error")
            case .notStarted:
                Image(systemName: "moon.zzz")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Not running")
            }
        }
        .frame(width: 18)
    }
}
