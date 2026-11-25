import ArchipelCore
import SwiftUI

/// Next to a session's status while its agent has shells or other tasks running in the background.
/// Looks like `SubagentBadge` with a symbol in front, so the two read as a pair when both show.
struct BackgroundTaskBadge: View {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if count > 0 {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .bold))
                Text(verbatim: "\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
            .fixedSize()
            .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            .help(Self.description(count))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.description(count))
        }
    }

    static func description(_ count: Int) -> String {
        count == 1 ? "1 background task running" : "\(count) background tasks running"
    }
}

#if DEBUG
#Preview {
    // Laid out like a session row: title, badges, then the status glyph.
    let rows: [(title: String, activity: SessionActivity, tasks: Int, subagents: Int)] = [
        ("Run the test suite", SessionActivity(status: .finished, unread: true, completedTurn: true), 1, 0),
        ("Start the dev server", SessionActivity(status: .finished, completedTurn: true), 1, 0),
        ("Refactor the importer", SessionActivity(status: .working), 2, 3),
        ("Bump dependencies", SessionActivity(status: .finished, completedTurn: true), 0, 0),
    ]
    VStack(alignment: .leading, spacing: 10) {
        ForEach(rows, id: \.title) { row in
            HStack(spacing: 7) {
                Image(systemName: "sparkle").foregroundStyle(.secondary).frame(width: 16)
                Text(row.title).font(.callout).lineLimit(1)
                Spacer(minLength: 4)
                BackgroundTaskBadge(count: row.tasks)
                SubagentBadge(count: row.subagents)
                StatusGlyph(activity: row.activity)
            }
        }
    }
    .padding()
    .frame(width: 320)
}
#endif
