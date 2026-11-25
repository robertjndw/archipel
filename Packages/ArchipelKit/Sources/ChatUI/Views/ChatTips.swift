import SwiftUI
import TipKit

/// Hints for the composer's keyboard habits, which nothing on screen gives away: Shift-Tab for
/// the next mode, Return to queue a message while the agent works, Up for the last prompt.
///
/// The chat does not configure TipKit. Its host does that once for the whole app, and with it
/// decides where the tips are stored and that UI tests see none. A host with tips of its own
/// puts `all` into its group and hands that group over as `hostGroup`: a chat tip then waits its
/// turn behind the host's, and no two popovers are ever up together.
public enum ChatTips {
    /// The chat's tips in the order they are offered.
    public static var all: [any Tip] { [ModeShortcutTip(), QueueTip(), RecallTip()] }

    /// The host's group, when the chat's tips are part of it.
    @MainActor public static var hostGroup: TipGroup?

    @MainActor static var group: TipGroup { hostGroup ?? ownGroup }

    @MainActor private static let ownGroup = TipGroup(.firstAvailable) { all }

    /// The mode was chosen from its menu, by someone who might rather have pressed a key.
    @Parameter static var hasChosenModeFromMenu: Bool = false
    // The three below say that a tip has a place to show right now. A tip without one would
    // still be the group's current tip, and hold up every tip after it for as long as it is.
    @Parameter(.transient) static var canCycleMode: Bool = false
    @Parameter(.transient) static var isWaitingOnTurn: Bool = false
    @Parameter(.transient) static var canRecall: Bool = false

    fileprivate static let promptSentEvent = Tips.Event(id: "chatPromptSent")

    /// How long a turn has to run before the queue tip comes up. Most first prompts are a
    /// greeting answered at once, and a popover that flashes by teaches nothing.
    static let turnDelay: Duration = .seconds(3)

    // Kept as functions, like the app's own tips, so the views say what happened and only this
    // file knows what a tip makes of it. Every donation is a write to TipKit's store, so none is
    // made once the tips it counts toward are gone.

    static func promptSent() {
        if case .invalidated = ModeShortcutTip().status, case .invalidated = RecallTip().status { return }
        Task { await promptSentEvent.donate() }
    }

    static func modeChosenFromMenu() {
        if case .invalidated = ModeShortcutTip().status { return }
        if !hasChosenModeFromMenu { hasChosenModeFromMenu = true }
    }

    /// Shift-Tab moved the mode on. The composer says so where it handles the key: the mode
    /// changing proves nothing, since the menu changes it too and so does the agent by itself.
    static func modeCycled() { invalidate(ModeShortcutTip()) }
    static func promptQueued() { invalidate(QueueTip()) }
    /// Up brought an earlier prompt back.
    static func promptRecalled() { invalidate(RecallTip()) }

    private static func invalidate(_ tip: some Tip) {
        if case .invalidated = tip.status { return }
        tip.invalidate(reason: .actionPerformed)
    }
}

/// Shown on the mode item. Someone who picks modes from the menu, or has sent a few prompts, is
/// here to stay and would use the key.
struct ModeShortcutTip: Tip {
    var title: Text { Text("Shift-Tab Switches Modes") }
    var message: Text? { Text("Press it while you type to move on to the next mode without leaving the keyboard.") }
    var image: Image? { Image(systemName: "keyboard") }

    var rules: [Rule] {
        #Rule(ChatTips.$canCycleMode) { $0 }
        #Rule(ChatTips.$hasChosenModeFromMenu, ChatTips.promptSentEvent) { $0 || $1.donations.count >= 3 }
    }
}

/// Shown on the empty composer while a turn runs, which is when there is something to queue or
/// stop.
struct QueueTip: Tip {
    var title: Text { Text("Keep Typing While the Agent Works") }
    var message: Text? { Text("Return queues your message for when this turn ends. Esc stops the turn.") }
    var image: Image? { Image(systemName: "return") }

    var rules: [Rule] {
        #Rule(ChatTips.$isWaitingOnTurn) { $0 }
    }

    // It leaves with the turn and would be back with every next one. The composer shows it once
    // per turn, so this is three turns.
    var options: [any TipOption] { MaxDisplayCount(3) }
}

/// Shown on the empty composer between turns, once there are prompts worth going back to.
struct RecallTip: Tip {
    var title: Text { Text("Bring Back Your Last Prompt") }
    var message: Text? { Text("Press Up in the empty composer to go back through the prompts you sent.") }
    var image: Image? { Image(systemName: "arrow.up") }

    var rules: [Rule] {
        #Rule(ChatTips.$canRecall) { $0 }
        #Rule(ChatTips.promptSentEvent) { $0.donations.count >= 5 }
    }

    // It leaves with the first character typed and would be back after every turn.
    var options: [any TipOption] { MaxDisplayCount(3) }
}

/// The views a tip could show on. Two chats side by side both have a mode item and a composer,
/// and each would put up the same popover; the first one that can show a tip is the one that does.
@MainActor @Observable
final class TipAnchors {
    enum Place {
        case mode
        case queue
        case recall
    }

    static let shared = TipAnchors()

    private var candidates: [Place: [UUID]] = [:]

    func shows(_ id: UUID, at place: Place) -> Bool {
        candidates[place]?.first == id
    }

    func set(_ id: UUID, at place: Place, isCandidate: Bool) {
        var ids = candidates[place] ?? []
        guard ids.contains(id) != isCandidate else { return }
        if isCandidate { ids.append(id) } else { ids.removeAll { $0 == id } }
        candidates[place] = ids
        let hasPlace = !ids.isEmpty
        switch place {
        case .mode: if ChatTips.canCycleMode != hasPlace { ChatTips.canCycleMode = hasPlace }
        case .queue: if ChatTips.isWaitingOnTurn != hasPlace { ChatTips.isWaitingOnTurn = hasPlace }
        case .recall: if ChatTips.canRecall != hasPlace { ChatTips.canRecall = hasPlace }
        }
    }
}

extension View {
    /// The two tips that hang on the composer itself, and what the session says about when they
    /// are due: a turn that has been running a while, prompts sent and queued. The keys the tips
    /// are about go to the text view, so the composer reports those itself.
    func composerTips(for session: ChatSession) -> some View {
        modifier(ComposerTips(session: session))
    }

    /// Hangs the Shift-Tab tip on the mode item. `isCyclable` is false for a mode with nothing
    /// to move on to, where the key does nothing.
    func modeShortcutTip(isCyclable: Bool) -> some View {
        modifier(ModeTipAnchor(isCyclable: isCyclable))
    }
}

private struct ComposerTips: ViewModifier {
    let session: ChatSession

    @State private var id = UUID()
    /// The turn has run for `ChatTips.turnDelay`.
    @State private var hasWaited = false
    /// The queue tip made way during this turn, for a permission card or for typed text. Every
    /// return of the popover counts toward its `MaxDisplayCount`, and three cards in one turn
    /// would use it up, so it waits for the next turn.
    @State private var hasYieldedThisTurn = false

    /// Both tips sit over the composer's top edge, where the lists for commands and files open
    /// once something is typed. With an empty composer there is nothing for a popover to cover,
    /// and it is also the moment the hint is of use.
    ///
    /// Never while the agent asks for permission: the card is docked right where the popover
    /// would open, and answering it comes before anything a tip has to say.
    private var canQueue: Bool {
        hasWaited && !hasYieldedThisTurn && session.isTurnRunning && session.draft.isEmpty && session.permissionRequests.isEmpty
    }

    /// Up brings a prompt back only into an empty composer, and only once one was sent.
    private var canRecall: Bool {
        !session.isTurnRunning && session.draft.isEmpty && session.attachments.isEmpty
            && !PromptRecall.history(of: session.transcript.items).isEmpty
    }

    private var tip: (any Tip)? {
        switch ChatTips.group.currentTip {
        case let tip as QueueTip where TipAnchors.shared.shows(id, at: .queue): tip
        case let tip as RecallTip where TipAnchors.shared.shows(id, at: .recall): tip
        default: nil
        }
    }

    func body(content: Content) -> some View {
        let canQueue = canQueue
        let canRecall = canRecall
        content
            .popoverTip(tip, arrowEdge: .top)
            .tipViewStyle(ChatTipStyle())
            .task(id: session.isTurnRunning) {
                hasWaited = false
                hasYieldedThisTurn = false
                guard session.isTurnRunning else { return }
                try? await Task.sleep(for: ChatTips.turnDelay)
                if !Task.isCancelled { hasWaited = true }
            }
            // Not in the task above, which also starts when a chat with a running turn comes
            // back on screen: that is the same prompt, not another one.
            .onChange(of: session.isTurnRunning) {
                if session.isTurnRunning { ChatTips.promptSent() }
            }
            .onChange(of: canQueue) { old, new in
                TipAnchors.shared.set(id, at: .queue, isCandidate: new)
                if old, !new, session.isTurnRunning { hasYieldedThisTurn = true }
            }
            .onAppear { TipAnchors.shared.set(id, at: .recall, isCandidate: canRecall) }
            .onChange(of: canRecall) { TipAnchors.shared.set(id, at: .recall, isCandidate: canRecall) }
            .onChange(of: session.queuedPrompts.count) { old, new in
                if new > old { ChatTips.promptQueued() }
            }
            .onDisappear {
                TipAnchors.shared.set(id, at: .queue, isCandidate: false)
                TipAnchors.shared.set(id, at: .recall, isCandidate: false)
            }
    }
}

private struct ModeTipAnchor: ViewModifier {
    let isCyclable: Bool

    @State private var id = UUID()
    /// The popover opens upward, over the composer's first line and the place a permission card
    /// docks, so it waits for the moment the composer's own tips wait for.
    @Environment(\.composerHasRoomForTips) private var hasRoom

    func body(content: Content) -> some View {
        let isCandidate = isCyclable && hasRoom
        content
            .popoverTip(TipAnchors.shared.shows(id, at: .mode) ? ChatTips.group.currentTip as? ModeShortcutTip : nil, arrowEdge: .top)
            .tipViewStyle(ChatTipStyle())
            .onAppear { TipAnchors.shared.set(id, at: .mode, isCandidate: isCandidate) }
            .onChange(of: isCandidate) { TipAnchors.shared.set(id, at: .mode, isCandidate: isCandidate) }
            .onDisappear { TipAnchors.shared.set(id, at: .mode, isCandidate: false) }
    }
}

/// A tip at roughly the size of a help tag. The app's `CompactTipStyle` is the same; the chat is
/// a package the app's style cannot be reached from, so the two are kept in step by hand.
private struct ChatTipStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.image?
                .font(.callout)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                configuration.title
                    .font(.callout.weight(.semibold))
                configuration.message?
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                configuration.tip.invalidate(reason: .tipClosed)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("chat.tip.close")
        }
        .frame(width: 240, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
