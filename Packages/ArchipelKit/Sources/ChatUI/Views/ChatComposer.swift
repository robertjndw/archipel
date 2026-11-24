import ACPKit
import SwiftUI
import UISupport

/// Where the user writes: one glass field holding the attachments, the text, the agent's
/// settings and the send button.
struct ChatComposer: View {
    let session: ChatSession
    let actions: ChatViewActions
    /// Answers the permission card with its default button, when a card with one is showing.
    let allowPermission: (@MainActor () -> Void)?
    /// Answers the permission card with its reject button, when a card with one is showing.
    let rejectPermission: (@MainActor () -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textHeight = ComposerTextView.lineHeight
    @State private var completionIndex = 0
    /// The draft at which Esc closed the command list. Typing on brings the list back.
    @State private var dismissedCompletionDraft: String?

    private var completions: [AvailableCommand] {
        guard dismissedCompletionDraft != session.draft, let query = SlashCommands.query(in: session.draft) else { return [] }
        return SlashCommands.matches(session.transcript.availableCommands, query: query)
    }

    var body: some View {
        let completions = completions

        VStack(alignment: .leading, spacing: 8) {
            if !session.attachments.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(session.attachments, id: \.self) { url in
                        AttachmentChip(item: .init(url: url)) { session.removeAttachment(url) }
                            .help(url.path(percentEncoded: false))
                    }
                }
                .transition(.opacity)
            }
            textView
            HStack(spacing: 8) {
                ChatControlsBar(
                    controls: session.controls,
                    select: { id, value in Task { await session.setControl(id, to: value) } },
                    setToggle: { id, isOn in Task { await session.setControl(id, isOn: isOn) } }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                if let usage = session.transcript.usage, usage.size > 0 {
                    ContextUsageRing(usage: usage)
                }
                SendButton(
                    isTurnRunning: session.isTurnRunning, isCancelling: session.isCancelling,
                    isCancelIgnored: session.isCancelIgnored, canSend: session.canSend, agentName: session.agentName,
                    send: send, stop: stop
                )
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: ChatMetrics.surfaceRadius))
        .overlay(alignment: .topLeading) {
            if !completions.isEmpty {
                SlashCommandList(commands: completions, selection: min(completionIndex, completions.count - 1), choose: choose)
                    // Sits above the composer without taking room, so nothing moves when it opens.
                    .offset(y: -(SlashCommandList.height(for: completions.count) + 8))
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.hover, value: completions.isEmpty)
        .animation(reduceMotion ? nil : Motion.disclosure, value: session.attachments)
        .onChange(of: session.draft) { completionIndex = 0 }
    }

    private var textView: some View {
        ComposerTextView(
            text: Binding(
                get: { session.draft },
                set: { newValue in
                    session.draft = newValue
                    actions.userInteracted()
                }
            ),
            height: $textHeight,
            focusRequests: session.composerFocusRequests,
            accessibilityLabel: placeholder,
            onCommand: handle,
            onFiles: { session.addAttachments($0) }
        )
        .frame(height: textHeight)
        .overlay(alignment: .topLeading) {
            if session.draft.isEmpty {
                Text(verbatim: placeholder)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.trailing, 6)
    }

    private var placeholder: String { "Message \(session.agentName)" }

    // MARK: Actions

    private func handle(_ command: ComposerCommand, hasMarkedText: Bool) -> ComposerAction {
        let completions = completions
        let context = ComposerKeyContext(
            hasMarkedText: hasMarkedText,
            isCompletionVisible: !completions.isEmpty,
            canSend: session.canSend,
            isTurnRunning: session.isTurnRunning,
            isDraftEmpty: session.draft.isEmpty,
            canAllowPermission: allowPermission != nil,
            canRejectPermission: rejectPermission != nil
        )
        let action = ComposerKeys.action(for: command, in: context)
        switch action {
        case .send: send()
        case .cancelTurn: stop()
        case .allowPermission: allowPermission?()
        case .rejectPermission: rejectPermission?()
        case let .moveCompletion(step):
            // Wraps around, like the system's own completion lists.
            let count = completions.count
            completionIndex = (min(completionIndex, count - 1) + step + count) % count
        case .acceptCompletion:
            choose(completions[min(completionIndex, completions.count - 1)])
        case .dismissCompletion:
            dismissedCompletionDraft = session.draft
        case .insertNewline, .swallow, .passThrough:
            break
        }
        return action
    }

    private func choose(_ command: AvailableCommand) {
        let insertion = SlashCommands.insertion(for: command)
        session.draft = insertion
        // The inserted text ends in a space, so the list closes by itself; this covers a command
        // whose name the agent sent with one.
        dismissedCompletionDraft = insertion
        session.requestComposerFocus()
        actions.userInteracted()
    }

    private func send() {
        session.send()
        actions.userInteracted()
    }

    private func stop() {
        actions.userInteracted()
        Task { await session.cancel() }
    }
}

/// Send, which turns into Stop while a turn runs. One button in one place, so the hand that sent
/// the prompt is already where stopping it is.
private struct SendButton: View {
    let isTurnRunning: Bool
    let isCancelling: Bool
    /// The agent went on after Stop; pressing again stops the agent itself.
    let isCancelIgnored: Bool
    let canSend: Bool
    let agentName: String
    let send: @MainActor () -> Void
    let stop: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isEnabled: Bool { isTurnRunning ? !isCancelling || isCancelIgnored : canSend }

    var body: some View {
        Button {
            if isTurnRunning { stop() } else { send() }
        } label: {
            Image(systemName: isTurnRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: isTurnRunning ? 11 : 13, weight: .bold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: isCancelling && !isCancelIgnored && !reduceMotion)
                .foregroundStyle(glyphStyle)
                .frame(width: 28, height: 28)
                .background {
                    // Only the fill is animated here. An animation on the whole button would
                    // also take over its position, and on the first send, when the composer
                    // travels down the pane, the glyph and its circle would part ways.
                    Circle()
                        .fill(fillStyle)
                        .animation(reduceMotion ? nil : Motion.hover, value: isEnabled)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // On the first send the composer travels down the pane in the same transaction that
        // swaps the glyph. As one group the button moves as a whole; without it the glyph being
        // replaced and its circle each take their own path.
        .geometryGroup()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(isTurnRunning ? "chat.stop" : "chat.send")
    }

    private var glyphStyle: AnyShapeStyle {
        isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary)
    }

    private var fillStyle: AnyShapeStyle {
        isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)
    }

    private var title: String {
        guard isTurnRunning else { return "Send" }
        if isCancelIgnored { return "Stop \(agentName)" }
        return isCancelling ? "Stopping" : "Stop"
    }
}
