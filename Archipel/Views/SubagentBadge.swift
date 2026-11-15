import SwiftUI

/// "+3" next to a session's status while its agent has subagents running. Styled after the count
/// badges in Mail's sidebar.
struct SubagentBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(verbatim: "+\(count)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: .capsule)
                .fixedSize()
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .help(Self.description(count))
                .accessibilityLabel(Self.description(count))
        }
    }

    static func description(_ count: Int) -> String {
        count == 1 ? "1 subagent running" : "\(count) subagents running"
    }
}
