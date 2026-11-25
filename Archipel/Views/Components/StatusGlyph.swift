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

    /// Whether the glyph for `activity` is a spinner: the same test that counts a session as
    /// working in the status bar and the menu bar, so a spinner never disagrees with those counts.
    static func showsSpinner(_ activity: SessionActivity) -> Bool {
        activity.showsProgress
    }

    var body: some View {
        Group {
            if Self.showsSpinner(activity) {
                // Past `.starting` and `.working` this is a main turn that ended with background
                // subagents still running. The result isn't final until they stop, and a checkmark
                // would look done too early.
                let label = activity.status == .starting || activity.status == .working ? "Working" : "Subagents running"
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(label)
                    .help(label)
            } else {
                settled
            }
        }
        .frame(width: 18)
        // Opacity only: scaling a spinner by a fractional amount crashes AppKit's layout, see `statusGlowLanding`.
        .transition(.opacity)
    }

    @ViewBuilder
    private var settled: some View {
        switch activity.status {
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
        case .notStarted, .starting, .working:
            // Nothing for a session that has not started yet: that is the normal state of most
            // of them, and a glyph on every one of them says nothing. Selecting it starts it.
            // The other two always spin.
            EmptyView()
        }
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
