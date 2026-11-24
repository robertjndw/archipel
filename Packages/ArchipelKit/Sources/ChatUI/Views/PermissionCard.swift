import ACPKit
import EditorUI
import SwiftUI
import UISupport

/// The agent asking before it does something, docked above the composer. Not a sheet: the
/// transcript stays readable and the composer stays usable while the question is open.
struct PermissionCard: View {
    let request: ChatPermissionRequest
    let agentName: String
    /// How many requests are waiting, this one included.
    let queued: Int
    let respond: @MainActor (PermissionChoice) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatWorkingDirectory) private var workingDirectory
    @State private var showsPreview = true

    private var call: ToolCall { request.toolCall }

    var body: some View {
        let choices = PermissionChoices(options: request.options)

        VStack(alignment: .leading, spacing: 10) {
            header
            if let planText {
                CappedHeight(maximum: 280) {
                    ScrollView {
                        MarkdownText(planText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if hasPreview, showsPreview {
                diffs
                    .transition(.opacity)
            }
            PermissionButtons(choices: choices, respond: respond)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: ChatMetrics.surfaceRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agentName) \(call.kind.permissionPhrase)")
        .accessibilityIdentifier("chat.permission")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: ChatMetrics.symbolSpacing) {
                Image(systemName: call.kind.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: ChatMetrics.symbolColumn)
                Text(verbatim: "\(agentName) \(call.kind.permissionPhrase)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if queued > 1 {
                    Text("1 of \(queued)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(queued - 1) more waiting")
                }
            }
            Group {
                if let command = call.command {
                    commandText(command)
                } else if let summary = call.permissionSummary(relativeTo: workingDirectory) {
                    summaryLine(summary)
                }
            }
            .padding(.leading, ChatMetrics.detailIndent)
        }
    }

    /// The command is what is being approved, so it is shown whole: wrapped rather than cut,
    /// and scrolling only when it is a script of its own.
    @ViewBuilder private func commandText(_ command: String) -> some View {
        let lines = LineDiff.splitLines(command).count
        if lines <= 8, command.count <= 600 {
            Text(verbatim: command)
                .font(ChatMetrics.codeFont)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            CappedHeight(maximum: 140) {
                ScrollView {
                    Text(verbatim: command)
                        .font(ChatMetrics.codeFont)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func summaryLine(_ summary: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : Motion.disclosure) { showsPreview.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: summary)
                    .font(ChatMetrics.codeFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !call.diffs.isEmpty {
                    DiffStatsBadge(diffs: call.diffs)
                        .equatable()
                        .layoutPriority(1)
                }
                if hasPreview {
                    DisclosureChevron(isExpanded: showsPreview)
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Not `disabled`, which would dim the one line that says what is being asked for.
        .allowsHitTesting(hasPreview)
        .help(summary)
        .accessibilityLabel(summary)
        .accessibilityValue(hasPreview ? (showsPreview ? "Preview shown" : "Preview hidden") : "")
    }

    private var hasPreview: Bool {
        !call.diffs.isEmpty
    }

    /// The plan the agent wants approved, which it sends as the content of a mode switch.
    private var planText: String? {
        guard call.kind == .switchMode else { return nil }
        let text = call.textContent.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    private var diffs: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(call.diffs) { diff in
                InlineDiffView(oldText: diff.oldText, newText: diff.newText, maximumHeight: 180, showsBackground: false)
                    .equatable()
            }
        }
    }
}

/// The answers, built from the options' kinds and names. The agent's own wording when there is
/// room for it, in one row or two; in a narrow pane short titles, with the wordy options in a
/// menu. Never a title cut off in the middle.
private struct PermissionButtons: View {
    let choices: PermissionChoices
    let respond: @MainActor (PermissionChoice) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                rejecting(compact: false)
                allowing(compact: false)
            }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) { allowing(compact: false) }
                HStack(spacing: 8) { rejecting(compact: false) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                rejecting(compact: true)
                allowing(compact: true)
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder private func rejecting(compact: Bool) -> some View {
        let overflow = compact ? choices.compactOverflow : choices.overflow
        if !overflow.isEmpty {
            Menu {
                ForEach(overflow) { choice in
                    Button(choice.name) { respond(choice) }
                        .accessibilityIdentifier(choice.accessibilityIdentifier)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .fixedSize()
            .help("More Options")
            .accessibilityLabel("More Options")
            .accessibilityIdentifier("chat.permission.more")
        }
        if let reject = choices.reject {
            button(reject, compact: compact)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder private func allowing(compact: Bool) -> some View {
        ForEach(compact ? choices.compactSecondary : choices.secondary) { choice in
            button(choice, compact: compact)
                .buttonStyle(.bordered)
        }
        if let primary = choices.primary {
            button(primary, compact: compact)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func button(_ choice: PermissionChoice, compact: Bool) -> some View {
        let title = compact ? (choice.compactTitle ?? choice.name) : choice.name
        return Button(title) { respond(choice) }
            .buttonBorderShape(.capsule)
            .fixedSize()
            .help(title == choice.name ? "" : choice.name)
            .accessibilityLabel(choice.name)
            .accessibilityIdentifier(choice.accessibilityIdentifier)
    }
}
