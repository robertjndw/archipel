import ArchipelCore
import SwiftUI

extension SessionStatus {
    /// How a session's state is worded wherever it is spelled out: tooltips, the peek, notifications.
    var label: String {
        switch self {
        case .notStarted: "Not running"
        case .starting: "Starting"
        case .working: "Working"
        case .needsAttention(.permission): "Needs your approval"
        case .needsAttention: "Waiting for you"
        case .finished: "Finished"
        case .exited(let code): code == 0 ? "Ended" : "Exited with code \(code)"
        }
    }
}

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
                attention("hand.raised.fill", label: activity.status.label)
            case .needsAttention:
                attention("questionmark.bubble.fill", label: activity.status.label)
            case .finished:
                // The dot is for a result you have not seen yet. Once seen, a quiet check stays until
                // the next prompt, so a done session does not look like one that never ran.
                if activity.unread {
                    Circle()
                        .fill(StatusPulse.finished.color)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Finished, unread")
                        .help("Finished, unread")
                } else if activity.completedTurn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Finished")
                        .help("Finished")
                }
            case .exited(let code):
                Image(systemName: code == 0 ? "stop.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(code == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red))
                    .accessibilityLabel(code == 0 ? "Ended" : "Exited with an error")
                    .help(activity.status.label)
            case .notStarted:
                Image(systemName: "moon.zzz")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(activity.status.label)
                    .help(activity.status.label)
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
