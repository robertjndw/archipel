import ACPKit
import SwiftUI
import UISupport

/// In the composer's bar while the agent has shells or subagents running. Their rows in the
/// conversation say so too, but those scroll away, and a shell left running matters most once
/// the turn that started it is long over.
struct BackgroundWorkButton: View {
    /// The calls whose command or subagent is still running, oldest first.
    let work: [ToolCall]
    /// What each subagent among them has done so far, by call.
    let steps: [String: [ToolCall]]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "progress.indicator")
                    .font(.system(size: 11, weight: .medium))
                    .symbolEffect(.variableColor.iterative, options: .repeat(.continuous), isActive: !reduceMotion)
                Text(verbatim: "\(work.count)")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(work.count)))
            }
        }
        .buttonStyle(.plain)
        .barItem(isActive: isOpen)
        .font(.callout)
        .foregroundStyle(.secondary)
        .help(Self.summary(of: work))
        .accessibilityLabel(Self.summary(of: work))
        .accessibilityIdentifier("chat.backgroundWork")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            BackgroundWorkList(work: work, steps: steps)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: work.count)
    }

    /// "1 command and 2 subagents running in the background".
    static func summary(of work: [ToolCall]) -> String {
        let subagents = work.count { $0.startsSubagent }
        let commands = work.count - subagents
        let parts = [
            commands == 0 ? nil : commands == 1 ? "1 command" : "\(commands) commands",
            subagents == 0 ? nil : subagents == 1 ? "1 subagent" : "\(subagents) subagents",
        ].compactMap(\.self)
        return parts.joined(separator: " and ") + " running in the background"
    }
}

private struct BackgroundWorkList: View {
    let work: [ToolCall]
    let steps: [String: [ToolCall]]

    @Environment(\.chatWorkingDirectory) private var workingDirectory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Running in the Background")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(work) { call in
                    row(call)
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private func row(_ call: ToolCall) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ChatMetrics.symbolSpacing) {
            Image(systemName: call.symbolName)
                .font(.system(size: 12))
                .frame(width: ChatMetrics.symbolColumn)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.displayTitle(relativeTo: workingDirectory))
                    .lineLimit(2)
                    .truncationMode(.middle)
                // What a subagent is busy with; a shell has nothing to add to its command.
                if let step = steps[call.toolCallId]?.last {
                    Text(step.displayTitle(relativeTo: workingDirectory))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
