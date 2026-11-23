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

    /// Whether the glyph for `activity` is a spinner. Keep in step with the cases in `body` that
    /// show a `ProgressView`.
    static func showsSpinner(_ activity: SessionActivity) -> Bool {
        switch activity.status {
        case .starting, .working: true
        case .finished: activity.isBusy
        default: false
        }
    }

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
            case .finished where activity.isBusy:
                // The main turn ended, but background subagents are still running and the result
                // isn't final until they stop. A checkmark here would look done too early.
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Subagents running")
                    .help("Subagents running")
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
                // Nothing: a session that has not started yet is the normal state of most of them,
                // and a glyph on every one of them says nothing. Selecting it starts it.
                EmptyView()
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

#if DEBUG
private struct StatusGlyphGallery: View {
    private static let variants: [(String, SessionActivity)] = [
        ("Not started", SessionActivity(status: .notStarted)),
        ("Starting", SessionActivity(status: .starting)),
        ("Working", SessionActivity(status: .working)),
        ("Needs approval", SessionActivity(status: .needsAttention(.permission))),
        ("Question", SessionActivity(status: .needsAttention(.question))),
        ("Finished, unread", SessionActivity(status: .finished, unread: true, completedTurn: true)),
        ("Finished, read", SessionActivity(status: .finished, completedTurn: true)),
        ("At first prompt", SessionActivity(status: .finished)),
        ("Ended", SessionActivity(status: .exited(code: 0))),
        ("Exited with error", SessionActivity(status: .exited(code: 1))),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(Self.variants, id: \.0) { label, activity in
                GridRow {
                    Text(label).foregroundStyle(.secondary)
                    StatusGlyph(activity: activity)
                    StatusGlyph(activity: activity)
                        .controlSize(.mini)
                        .scaleEffect(0.85)
                }
            }
        }
        .padding()
    }
}

#Preview("Light") {
    StatusGlyphGallery()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    StatusGlyphGallery()
        .preferredColorScheme(.dark)
}
#endif
