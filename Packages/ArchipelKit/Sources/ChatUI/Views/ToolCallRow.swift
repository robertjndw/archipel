import ACPKit
import EditorUI
import SwiftUI
import UISupport

/// A run of tool calls, one line each, with nothing between them.
struct ToolCallGroup: View {
    let calls: [ToolCall]
    /// What the subagents among the calls did, by call.
    var steps: [String: [ToolCall]] = [:]
    let expanded: Set<String>
    /// What Find marks in this run while a search is on.
    var mark: RowFindMark?
    let toggle: (String) -> Void
    let openFile: (URL, Int?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(calls) { call in
                let id = ChatItem.toolCall(call).id
                ToolCallRow(call: call, steps: steps[call.toolCallId] ?? [], isExpanded: expanded.contains(id), toggle: { toggle(id) }, openFile: openFile)
                    .equatable()
                    .environment(\.textHighlight, mark?.highlight(forCall: id))
                    .background(alignment: .top) {
                        if id == mark?.currentCall {
                            FindCallMark()
                                .transition(.opacity)
                        }
                    }
            }
        }
        .animation(reduceMotion ? nil : Motion.hover, value: mark?.currentCall)
    }
}

/// Marks the whole line of the tool call Find is on. The word is marked too, but a title cut
/// short in the middle may not show it, so the line always says which call it is. It reaches
/// past the line on both sides like the hover fill does, so the text keeps the column's edge.
private struct FindCallMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: ChatMetrics.blockRadius, style: .continuous)
            .fill(TextHighlight.currentColor.opacity(0.22))
            .frame(height: ChatMetrics.activityRowHeight)
            .padding(.horizontal, -6)
            .accessibilityHidden(true)
    }
}

/// One tool call: what it is, what it is about and how it went. Opens to show the details.
///
/// Equatable on what it shows, so a sibling that streams an update leaves it alone. Hovering is
/// the header's own state, so it never re-evaluates the details below.
struct ToolCallRow: View, Equatable {
    let call: ToolCall
    /// What the subagent this call started has done so far. Empty for any other call.
    var steps: [ToolCall] = []
    let isExpanded: Bool
    let toggle: () -> Void
    let openFile: (URL, Int?) -> Void

    @Environment(\.chatWorkingDirectory) private var workingDirectory

    nonisolated static func == (lhs: ToolCallRow, rhs: ToolCallRow) -> Bool {
        lhs.call == rhs.call && lhs.steps == rhs.steps && lhs.isExpanded == rhs.isExpanded
    }

    private var hasDetails: Bool { call.hasDetails || !steps.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                ToolCallHeader(call: call, steps: steps, hasDetails: hasDetails, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)
            // Not `disabled`, which would dim the row: a call with nothing to show is as much a
            // part of the record as one with output.
            .allowsHitTesting(hasDetails)
            .accessibilityLabel(call.accessibilityLabel(relativeTo: workingDirectory))
            .accessibilityValue(hasDetails ? (isExpanded ? "Expanded" : "Collapsed") : "")
            .accessibilityIdentifier("chat.toolCall")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !steps.isEmpty { SubagentSteps(steps: steps) }
                    if call.hasDetails { ToolCallDetail(call: call, openFile: openFile) }
                }
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
    let steps: [ToolCall]
    let hasDetails: Bool
    let isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatWorkingDirectory) private var workingDirectory
    @State private var isHovered = false

    /// Next to a subagent's title: what it is doing while it runs, how much it did after.
    private var stepsNote: String? {
        guard let last = steps.last else { return nil }
        if call.isStillWorking { return last.displayTitle(relativeTo: workingDirectory) }
        return steps.count == 1 ? "1 step" : "\(steps.count) steps"
    }

    var body: some View {
        HStack(spacing: ChatMetrics.symbolSpacing) {
            Image(systemName: call.symbolName)
                .font(.system(size: 12))
                .frame(width: ChatMetrics.symbolColumn)
            SearchableText(text: call.displayTitle(relativeTo: workingDirectory))
                .lineLimit(1)
                .truncationMode(.middle)
            if let name = call.diffFileNameMissingFromTitle {
                SearchableText(text: name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.tertiary)
            }
            if let stepsNote {
                Text(stepsNote)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.tertiary)
            }
            if !call.diffs.isEmpty {
                DiffStatsBadge(diffs: call.diffs)
                    .equatable()
                    .layoutPriority(1)
            }
            if hasDetails {
                DisclosureChevron(isExpanded: isExpanded)
                    .opacity(isHovered || isExpanded ? 1 : 0)
            }
            Spacer(minLength: 8)
            ToolCallStatusGlyph(status: call.status, runsInBackground: call.isRunningInBackground)
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
                .opacity(isHovered && hasDetails ? 1 : 0)
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
    /// The call is over, but the command or subagent it started is not, so the spinner stays.
    var runsInBackground = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSpinning: Bool { !status.isFinished || runsInBackground }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
            // The spinner is a symbol too, so finishing is one symbol replacing another instead
            // of a progress view popping out and an icon popping in.
            .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: isSpinning && !reduceMotion)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .frame(width: 16, height: 16)
            .help(help)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        if runsInBackground { return "progress.indicator" }
        return switch status {
        case .pending, .inProgress: "progress.indicator"
        case .completed: "checkmark"
        case .failed: "xmark"
        case .cancelled: "slash.circle"
        }
    }

    private var help: String {
        if runsInBackground { return "Running in the background" }
        return switch status {
        case .pending: "Waiting"
        case .inProgress: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Canceled"
        }
    }
}

/// What a subagent did, one line a step, under the call that started it.
private struct SubagentSteps: View {
    let steps: [ToolCall]

    @Environment(\.chatWorkingDirectory) private var workingDirectory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { step in
                HStack(spacing: ChatMetrics.symbolSpacing) {
                    Image(systemName: step.symbolName)
                        .font(.system(size: 12))
                        .frame(width: ChatMetrics.symbolColumn)
                    Text(step.displayTitle(relativeTo: workingDirectory))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    ToolCallStatusGlyph(status: step.status)
                }
                .frame(height: ChatMetrics.activityRowHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(step.accessibilityLabel(relativeTo: workingDirectory))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
