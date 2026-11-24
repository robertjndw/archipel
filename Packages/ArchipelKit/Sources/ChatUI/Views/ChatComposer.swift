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
    @AppStorage private var favoriteModels: String
    @State private var textHeight = ComposerTextView.lineHeight
    @State private var completionIndex = 0
    /// The draft at which Esc closed the completion list. Typing on brings the list back.
    @State private var dismissedCompletionDraft: String?
    /// The selection in the draft, as the text view counts it. Says where an @ is being typed.
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var mentionMatches = MentionMatches()
    /// Return came while the list still showed the rows of an earlier keystroke. The search it
    /// was meant for accepts its own first row once it is back, instead of one of the old rows.
    @State private var pendingAccept: MentionSearch?
    /// The mode Shift-Tab asked for last, until the agent answers. Without it a second press
    /// before the answer would ask for the same mode again.
    @State private var pendingMode: String?
    /// Counts the times the file index found the worktree changed, to ask for the matches again.
    @State private var fileIndexChanges = 0
    @State private var editor = ComposerEditor()
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
        // Same key the model list stars under, so a narrow pane's shortlist shows the stars.
        _favoriteModels = AppStorage(wrappedValue: "", FavoriteModels.key(agentName: session.agentName))
    }

    /// What the list above the composer offers: commands for a draft that is a "/" word, files
    /// for an @ at the cursor. A draft is never both, since a command being typed has no space
    /// for a mention to follow.
    private var completion: Completion? {
        guard dismissedCompletionDraft != session.draft else { return nil }
        if let query = SlashCommands.query(in: session.draft) {
            let commands = SlashCommands.matches(session.transcript.availableCommands, query: query)
            return commands.isEmpty ? nil : .commands(commands)
        }
        // Matches found for another @ stay hidden until this one's arrive. With none there is no
        // list and Return sends: "@escaping" in a prompt about code matches no file.
        guard let mention, mentionMatches.location == mention.range.location, !mentionMatches.files.isEmpty else { return nil }
        return .files(mentionMatches.files, replacing: mention)
    }

    private var mention: MentionToken? {
        guard session.fileIndex != nil else { return nil }
        return FileMentions.token(in: session.draft, selection: selection)
    }

    private var mentionSearch: MentionSearch? {
        mention.map { MentionSearch(location: $0.range.location, query: $0.query, indexChanges: fileIndexChanges) }
    }

    var body: some View {
        let completion = completion
        let mentionSearch = mentionSearch
        let rows = completion?.rows ?? []
        let selectedRow = CompletionSelection.index(completionIndex, count: rows.count)
        let announcement = completion.flatMap { CompletionList.Announcement(kind: $0.kind, rows: rows, selection: selectedRow) }

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
                        AttachmentChip(item: .init(url: url, among: session.attachments)) { session.removeAttachment(url) }
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
                    .help(session.fileIndex == nil ? "Attach Files" : "Attach Files, or Type @ to Mention One")
                    .accessibilityIdentifier("chat.attach")
                ChatControlsBar(
                    controls: session.controls,
                    recentModels: RecentModels.values(in: recentModels),
                    favoriteModels: FavoriteModels.values(in: favoriteModels),
                    select: { id, value in
                        if session.controls.first(where: { $0.id == id })?.category == .model {
                            recentModels = RecentModels.adding(value, to: recentModels)
                        }
                        // Awaited by whoever asked: the effort slider holds its thumb until the
                        // agent has answered.
                        await session.setControl(id, to: value)
                    },
                    setToggle: { id, isOn in Task { await session.setControl(id, isOn: isOn) } }
                )
                // The mode's tip opens over the text, so like the composer's own two it waits
                // for an empty draft.
                .environment(\.composerHasRoomForTips, session.draft.isEmpty && session.permissionRequests.isEmpty)
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
        .composerTips(for: session)
        .overlay(alignment: .topLeading) {
            if let completion {
                CompletionList(kind: completion.kind, rows: rows, selection: selectedRow, choose: { choose($0, from: completion) })
                // Sits above the composer without taking room, so nothing moves when it opens.
                .offset(y: -(CompletionList.height(for: completion.count) + 8))
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.hover, value: completion == nil)
        .animation(reduceMotion ? nil : Motion.disclosure, value: session.attachments)
        .animation(reduceMotion ? nil : Motion.disclosure, value: session.queuedPrompts)
        .onChange(of: session.draft) {
            completionIndex = 0
            pendingAccept = nil
        }
        // Moving the cursor into an old "@State" with arrows or a click must not open the list,
        // or Up, Down and Return would stop doing their usual jobs. Typing brings it back.
        .onChange(of: CaretState(draft: session.draft, selection: selection)) { old, new in
            if old.draft == new.draft { dismissedCompletionDraft = new.draft }
        }
        // VoiceOver's cursor stays in the text, so the list announces itself.
        .onChange(of: announcement) { old, new in
            if let new { ChatAnnouncement.post(new.text(isOpening: old == nil)) }
        }
        .task(id: mentionSearch) { await findMentions(for: mentionSearch) }
        .onChange(of: mentionSearch?.location) { _, location in
            // A new @: the agent may have written files since the last one.
            guard location != nil, let index = session.fileIndex else { return }
            Task {
                if await index.refreshIfStale() { fileIndexChanges += 1 }
            }
        }
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
            editor: editor,
            onSelectionChange: { selection = $0 },
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
        let completion = completion
        recall.history = PromptRecall.history(of: session.transcript.items)
        let context = ComposerKeyContext(
            hasMarkedText: hasMarkedText,
            isCompletionVisible: completion != nil,
            isFindVisible: session.viewState.find.isPresented,
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
            completionIndex = CompletionSelection.index(completionIndex, movedBy: step, count: completion?.count ?? 0)
        case .acceptCompletion:
            if case .files = completion, mentionMatches.query != mention?.query {
                // The rows are still the last keystroke's. The key is taken all the same, and
                // the search under way chooses for it.
                pendingAccept = mentionSearch
            } else if let completion {
                choose(CompletionSelection.index(completionIndex, count: completion.count), from: completion)
            }
        case .dismissCompletion:
            dismissedCompletionDraft = session.draft
        case .dismissFind:
            session.dismissFind()
        case .editQueuedPrompt:
            session.editLastQueuedPrompt()
            dismissedCompletionDraft = session.draft
            actions.userInteracted()
        case let .recallPrompt(older):
            if let text = recall.move(older: older, draft: session.draft) {
                session.draft = text
                // A recalled prompt is not being typed. If it opened the list for its "/review" or
                // "@State", the next Up would move through the list and not on to the older prompt.
                dismissedCompletionDraft = text
                if older { ChatTips.promptRecalled() }
            }
        case .cycleMode:
            if let control = modeControl, let next = control.nextChoice(after: pendingMode) {
                actions.userInteracted()
                ChatTips.modeCycled()
                pendingMode = next.value
                Task {
                    await session.setControl(control.id, to: next.value)
                    // Whatever the answer: a mode the agent refused must not stay the one the
                    // next press goes on from.
                    if pendingMode == next.value { pendingMode = nil }
                }
            }
        case .insertNewline, .swallow, .passThrough:
            break
        }
        return action
    }

    private func choose(_ index: Int, from completion: Completion) {
        switch completion {
        case let .commands(commands):
            if commands.indices.contains(index) { choose(commands[index]) }
        case let .files(files, token):
            if files.indices.contains(index) { attach(files[index], replacing: token) }
        }
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

    /// The mention becomes the file's name in the text, and the file an attachment.
    private func attach(_ file: FileMention, replacing token: MentionToken) {
        guard let root = session.fileIndex?.root else { return }
        let file = FileMentions.resolved(file, in: root)
        let edit = FileMentions.edit(choosing: file, for: token, in: session.draft)
        let url = file.url(in: root)
        // A file that is attached already only gets its name written. Undoing that must leave
        // the attachment, which the first mention of the file still needs.
        let isNew = !session.attachments.contains(url)
        let attachment = ComposerNSTextView.SideEffect(
            undo: { [weak session] in session?.removeAttachment(url) },
            redo: { [weak session] in session?.addAttachments([url]) }
        )
        // Through the text view and not the draft, so the cursor stays put and the undo history
        // survives. Refused while an input method composes, and then nothing is attached.
        guard editor.replace(edit.range, with: edit.text, alongside: isNew ? attachment : nil) else { return }
        session.addAttachments([url])
        session.requestComposerFocus()
        actions.userInteracted()
        ChatAnnouncement.post("Attached \(FileMentions.inlineText(for: file))")
    }

    /// Asks the file index for the mention's matches. The next keystroke cancels the task,
    /// which stops the ranking too.
    private func findMentions(for search: MentionSearch?) async {
        guard let search, let index = session.fileIndex else {
            mentionMatches = MentionMatches()
            return
        }
        let root = index.root
        let recent = search.query.isEmpty ? FileMentions.recentIDs(in: session.transcript.items, root: root) : []
        let files = await index.matches(query: search.query, recent: recent)
        guard !Task.isCancelled else { return }
        // Other files under a selection that was moved would select something nobody picked.
        if files != mentionMatches.files { completionIndex = 0 }
        mentionMatches = MentionMatches(location: search.location, query: search.query, files: files)
        let accepts = pendingAccept == search
        pendingAccept = nil
        if accepts, let first = files.first, let mention, dismissedCompletionDraft != session.draft {
            attach(first, replacing: mention)
        }
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

/// What the list above the composer is completing.
private enum Completion {
    case commands([AvailableCommand])
    /// Files for the mention `replacing`, which choosing one replaces.
    case files([FileMention], replacing: MentionToken)

    var kind: CompletionList.Kind {
        switch self {
        case .commands: .commands
        case .files: .files
        }
    }

    var count: Int {
        switch self {
        case let .commands(commands): commands.count
        case let .files(files, _): files.count
        }
    }

    var rows: [CompletionRow] {
        switch self {
        case let .commands(commands): commands.map(CompletionRow.init(command:))
        case let .files(files, _): files.map(CompletionRow.init(file:))
        }
    }
}

/// Everything the matches for a mention depend on. A change of any of it asks again.
private struct MentionSearch: Equatable {
    /// Where the @ is in the draft.
    var location: Int
    var query: String
    var indexChanges: Int
}

/// The files found for the mention whose @ is at `location`. They stay up while the next
/// keystroke's are being found, so the list does not blink with every letter; `query` says
/// which keystroke they answer.
private struct MentionMatches: Equatable {
    var location: Int?
    var query = ""
    var files: [FileMention] = []
}

/// The draft and where the cursor is in it, to tell a cursor that moved from text that changed.
private struct CaretState: Equatable {
    var draft: String
    var selection: NSRange
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
