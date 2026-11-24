import ACPKit
import SwiftUI
import UISupport

/// A run of tool calls, one line each, with nothing between them.
struct ToolCallGroup: View {
    let calls: [ToolCall]
    let expanded: Set<String>
    let toggle: (String) -> Void
    let openFile: (URL, Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(calls) { call in
                let id = ChatItem.toolCall(call).id
                ToolCallRow(call: call, isExpanded: expanded.contains(id), toggle: { toggle(id) }, openFile: openFile)
                    .equatable()
            }
        }
    }
}

/// One tool call: what it is, what it is about and how it went. Opens to show the details.
///
/// Equatable on what it shows, so a sibling that streams an update leaves it alone. Hovering is
/// the header's own state, so it never re-evaluates the details below.
struct ToolCallRow: View, Equatable {
    let call: ToolCall
    let isExpanded: Bool
    let toggle: () -> Void
    let openFile: (URL, Int?) -> Void

    @Environment(\.chatWorkingDirectory) private var workingDirectory

    nonisolated static func == (lhs: ToolCallRow, rhs: ToolCallRow) -> Bool {
        lhs.call == rhs.call && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                ToolCallHeader(call: call, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)
            // Not `disabled`, which would dim the row: a call with nothing to show is as much a
            // part of the record as one with output.
            .allowsHitTesting(call.hasDetails)
            .accessibilityLabel(call.accessibilityLabel(relativeTo: workingDirectory))
            .accessibilityValue(call.hasDetails ? (isExpanded ? "Expanded" : "Collapsed") : "")
            .accessibilityIdentifier("chat.toolCall")

            if isExpanded {
                ToolCallDetail(call: call, openFile: openFile)
                    .padding(.leading, ChatMetrics.detailIndent)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
    }
}

private struct ToolCallHeader: View {
    let call: ToolCall
    let isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatWorkingDirectory) private var workingDirectory
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: ChatMetrics.symbolSpacing) {
            Image(systemName: call.kind.symbolName)
                .font(.system(size: 12))
                .frame(width: ChatMetrics.symbolColumn)
            Text(verbatim: call.displayTitle(relativeTo: workingDirectory))
                .lineLimit(1)
                .truncationMode(.middle)
            if let name = call.diffFileNameMissingFromTitle {
                Text(verbatim: name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.tertiary)
            }
            if !call.diffs.isEmpty {
                DiffStatsBadge(diffs: call.diffs)
                    .equatable()
                    .layoutPriority(1)
            }
            if call.hasDetails {
                DisclosureChevron(isExpanded: isExpanded)
                    .opacity(isHovered || isExpanded ? 1 : 0)
            }
            Spacer(minLength: 8)
            ToolCallStatusGlyph(status: call.status)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(height: ChatMetrics.activityRowHeight)
        .contentShape(.rect)
        .background {
            // Reaches past the text on both sides, so the highlight has room around the row
            // while the row's content stays on the column's edges.
            RoundedRectangle(cornerRadius: ChatMetrics.blockRadius, style: .continuous)
                .fill(.quinary)
                .padding(.horizontal, -6)
                .opacity(isHovered && call.hasDetails ? 1 : 0)
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : Motion.hover, value: isHovered)
    }
}

/// The small chevron of rows that open in place.
struct DisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .accessibilityHidden(true)
    }
}

/// A spinner while the call runs, turning into its outcome.
struct ToolCallStatusGlyph: View {
    let status: ToolCallStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
            // The spinner is a symbol too, so finishing is one symbol replacing another instead
            // of a progress view popping out and an icon popping in.
            .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: !status.isFinished && !reduceMotion)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .frame(width: 16, height: 16)
            .help(help)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch status {
        case .pending, .inProgress: "progress.indicator"
        case .completed: "checkmark"
        case .failed: "xmark"
        case .cancelled: "slash.circle"
        }
    }

    private var help: String {
        switch status {
        case .pending: "Waiting"
        case .inProgress: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Canceled"
        }
    }
}
