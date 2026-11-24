import ACPKit
import SwiftUI
import UniformTypeIdentifiers
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
    @AppStorage private var recentModels: String
    @State private var textHeight = ComposerTextView.lineHeight
    @State private var completionIndex = 0
    /// The draft at which Esc closed the command list. Typing on brings the list back.
    @State private var dismissedCompletionDraft: String?
    @State private var recall = PromptRecall(history: [])
    @State private var isAttaching = false

    init(
        session: ChatSession, actions: ChatViewActions,
        allowPermission: (@MainActor () -> Void)?, rejectPermission: (@MainActor () -> Void)?
    ) {
        self.session = session
        self.actions = actions
        self.allowPermission = allowPermission
        self.rejectPermission = rejectPermission
        _recentModels = AppStorage(wrappedValue: "", RecentModels.key(agentName: session.agentName))
    }

    private var completions: [AvailableCommand] {
        guard dismissedCompletionDraft != session.draft, let query = SlashCommands.query(in: session.draft) else { return [] }
        return SlashCommands.matches(session.transcript.availableCommands, query: query)
    }

    var body: some View {
        let completions = completions

        VStack(alignment: .leading, spacing: 8) {
            if !session.queuedPrompts.isEmpty {
                QueuedPromptList(prompts: session.queuedPrompts) { id in
                    session.removeQueuedPrompt(id)
                    actions.userInteracted()
                }
                .transition(.opacity)
            }
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
                Button("Attach Files", systemImage: "paperclip") { isAttaching = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .barItem(isActive: isAttaching)
                    .padding(.leading, -BarItem.inset)
                    .help("Attach Files")
                    .accessibilityIdentifier("chat.attach")
                ChatControlsBar(
                    controls: session.controls,
                    recentModels: RecentModels.values(in: recentModels),
                    select: { id, value in
                        if session.controls.first(where: { $0.id == id })?.category == .model {
                            recentModels = RecentModels.adding(value, to: recentModels)
                        }
                        Task { await session.setControl(id, to: value) }
                    },
                    setToggle: { id, isOn in Task { await session.setControl(id, isOn: isOn) } }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                if let usage = session.transcript.usage, usage.size > 0 {
                    ContextUsageRing(usage: usage)
                }
                SendButton(
                    isTurnRunning: session.isTurnRunning, isCancelling: session.isCancelling,
                    isCancelIgnored: session.isCancelIgnored, canSend: session.canSend, canQueue: session.canQueue,
                    agentName: session.agentName,
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
        .animation(reduceMotion ? nil : Motion.disclosure, value: session.queuedPrompts)
        .onChange(of: session.draft) { completionIndex = 0 }
        .fileImporter(isPresented: $isAttaching, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            session.addAttachments(urls)
            session.requestComposerFocus()
            actions.userInteracted()
        }
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

    /// While a turn runs the placeholder says that Return queues the message.
    private var placeholder: String {
        session.isTurnRunning ? "Queue a message for \(session.agentName)" : "Message \(session.agentName)"
    }

    private var modeControl: ChatControl? {
        session.controls.first { $0.category == .mode }
    }

    // MARK: Actions

    private func handle(_ command: ComposerCommand, hasMarkedText: Bool) -> ComposerAction {
        let completions = completions
        recall.history = PromptRecall.history(of: session.transcript.items)
        let context = ComposerKeyContext(
            hasMarkedText: hasMarkedText,
            isCompletionVisible: !completions.isEmpty,
            canSend: session.canSend || session.canQueue,
            isTurnRunning: session.isTurnRunning,
            isDraftEmpty: session.draft.isEmpty && session.attachments.isEmpty,
            canAllowPermission: allowPermission != nil,
            canRejectPermission: rejectPermission != nil,
            hasQueuedPrompts: !session.queuedPrompts.isEmpty,
            canRecallOlder: session.attachments.isEmpty && recall.canRecallOlder(draft: session.draft),
            canRecallNewer: recall.canRecallNewer(draft: session.draft),
            canCycleMode: modeControl?.nextChoice != nil
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
        case .editQueuedPrompt:
            session.editLastQueuedPrompt()
            actions.userInteracted()
        case let .recallPrompt(older):
            if let text = recall.move(older: older, draft: session.draft) { session.draft = text }
        case .cycleMode:
            if let control = modeControl, let next = control.nextChoice {
                actions.userInteracted()
                Task { await session.setControl(control.id, to: next.value) }
            }
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
/// the prompt is already where stopping it is. With something typed during a turn it is Send
/// again and queues the message; Esc still stops.
private struct SendButton: View {
    let isTurnRunning: Bool
    let isCancelling: Bool
    /// The agent went on after Stop; pressing again stops the agent itself.
    let isCancelIgnored: Bool
    let canSend: Bool
    let canQueue: Bool
    let agentName: String
    let send: @MainActor () -> Void
    let stop: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsStop: Bool { isTurnRunning && !canQueue }
    private var isEnabled: Bool { showsStop ? !isCancelling || isCancelIgnored : canSend || canQueue }

    var body: some View {
        Button {
            if showsStop { stop() } else { send() }
        } label: {
            Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                .font(.system(size: showsStop ? 11 : 13, weight: .bold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: showsStop && isCancelling && !isCancelIgnored && !reduceMotion)
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
        .accessibilityIdentifier(showsStop ? "chat.stop" : "chat.send")
    }

    private var glyphStyle: AnyShapeStyle {
        isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary)
    }

    private var fillStyle: AnyShapeStyle {
        isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)
    }

    private var title: String {
        if canQueue { return "Queue Message" }
        guard isTurnRunning else { return "Send" }
        if isCancelIgnored { return "Stop \(agentName)" }
        return isCancelling ? "Stopping" : "Stop"
    }
}

/// The prompts typed while the agent was busy, in the order they will go out. Quiet, since they
/// are not part of the conversation yet.
private struct QueuedPromptList: View {
    let prompts: [QueuedPrompt]
    let remove: @MainActor (QueuedPrompt.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(prompts) { prompt in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(verbatim: Self.summary(of: prompt))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Remove from Queue", systemImage: "xmark") { remove(prompt.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Remove from Queue")
                }
                .font(.callout)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Queued: \(Self.summary(of: prompt))")
            }
        }
        .padding(.trailing, 6)
        .accessibilityIdentifier("chat.queue")
    }

    /// The first line of the text; a prompt of files alone is named after them.
    static func summary(of prompt: QueuedPrompt) -> String {
        let line = prompt.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? prompt.attachments.map(\.lastPathComponent).joined(separator: ", ") : line
    }
}
