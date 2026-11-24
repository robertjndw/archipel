import ACPKit
import Foundation

/// A key command as it reaches the composer's text view, after the input method had its turn.
enum ComposerCommand: Equatable, Sendable {
    /// Return. `modified` when Shift or Option is held.
    case newline(modified: Bool)
    case tab
    /// Shift-Tab.
    case backtab
    case escape
    case up
    case down
}

/// What the composer does with a key command.
enum ComposerAction: Equatable, Sendable {
    case send
    case insertNewline
    case cancelTurn
    case allowPermission
    case rejectPermission
    case moveCompletion(Int)
    case acceptCompletion
    case dismissCompletion
    /// Take the newest queued prompt back into the composer.
    case editQueuedPrompt
    /// Put an earlier prompt, or with `false` a later one, into the composer.
    case recallPrompt(older: Bool)
    /// Move on to the agent's next mode.
    case cycleMode
    /// Take the key and do nothing: a Return that cannot send yet must not put a line break into
    /// the prompt, and an Esc with nothing to cancel must not reach the text view.
    case swallow
    /// Leave the key to the text view.
    case passThrough
}

struct ComposerKeyContext: Equatable, Sendable {
    /// An input method is composing. Every key belongs to it until it commits.
    var hasMarkedText = false
    var isCompletionVisible = false
    var canSend = false
    var isTurnRunning = false
    var isDraftEmpty = true
    /// A permission card is showing an allow-once button.
    var canAllowPermission = false
    /// A permission card is showing a reject button.
    var canRejectPermission = false
    var hasQueuedPrompts = false
    /// Up would bring back an earlier prompt: the draft is empty, or still the recalled prompt
    /// with an earlier one left. Never while the user's own text is in the composer, where the
    /// arrows move the cursor.
    var canRecallOlder = false
    /// The draft is a recalled prompt, so Down moves back toward the present.
    var canRecallNewer = false
    var canCycleMode = false
}

enum ComposerKeys {
    static func action(for command: ComposerCommand, in context: ComposerKeyContext) -> ComposerAction {
        if context.hasMarkedText { return .passThrough }
        if case .newline(modified: true) = command { return .insertNewline }

        if context.isCompletionVisible {
            switch command {
            case .up: return .moveCompletion(-1)
            case .down: return .moveCompletion(1)
            case .newline, .tab: return .acceptCompletion
            case .escape: return .dismissCompletion
            case .backtab: break
            }
        }

        switch command {
        case .newline:
            // Only with nothing typed: someone finishing a sentence as the card appears must not
            // approve a tool call with the Return that was meant for the message.
            if context.canAllowPermission, context.isDraftEmpty { return .allowPermission }
            return context.canSend ? .send : .swallow
        case .escape:
            if context.canRejectPermission { return .rejectPermission }
            // Never left to the text view, where Esc opens the word completion list.
            return context.isTurnRunning ? .cancelTurn : .swallow
        case .up:
            // The queue comes before the history: it holds what was typed last.
            if context.isDraftEmpty, context.hasQueuedPrompts { return .editQueuedPrompt }
            return context.canRecallOlder ? .recallPrompt(older: true) : .passThrough
        case .down:
            return context.canRecallNewer ? .recallPrompt(older: false) : .passThrough
        case .backtab:
            return context.canCycleMode ? .cycleMode : .passThrough
        case .tab:
            return .passThrough
        }
    }
}

/// Completion of the agent's slash commands in the composer.
enum SlashCommands {
    /// What to filter commands by, or nil when the draft is not a command being typed: it has to
    /// start with a slash and still be one word.
    static func query(in draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let query = draft.dropFirst()
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return String(query)
    }

    /// Commands whose name starts with the query, then those that merely contain it, each in the
    /// agent's order.
    static func matches(_ commands: [AvailableCommand], query: String) -> [AvailableCommand] {
        guard !query.isEmpty else { return commands }
        let query = query.lowercased()
        var prefixed: [AvailableCommand] = []
        var containing: [AvailableCommand] = []
        for command in commands {
            let name = displayName(command).lowercased()
            if name.hasPrefix(query) {
                prefixed.append(command)
            } else if name.contains(query) {
                containing.append(command)
            }
        }
        return prefixed + containing
    }

    /// The name without a leading slash, which some agents include.
    static func displayName(_ command: AvailableCommand) -> String {
        command.name.hasPrefix("/") ? String(command.name.dropFirst()) : command.name
    }

    /// The draft after choosing a command: ready for its arguments.
    static func insertion(for command: AvailableCommand) -> String {
        "/\(displayName(command)) "
    }
}

/// Going back through the prompts already sent with the arrow keys, the way a shell does.
struct PromptRecall: Equatable {
    /// The sent prompts, oldest first, without ones repeated back to back.
    var history: [String]
    /// Which of them is in the composer, with the text put there. Editing that text ends the
    /// recall: from then on it is the user's own draft.
    var shown: (index: Int, text: String)?

    static func == (lhs: PromptRecall, rhs: PromptRecall) -> Bool {
        lhs.history == rhs.history && lhs.shown?.index == rhs.shown?.index && lhs.shown?.text == rhs.shown?.text
    }

    static func history(of items: [ChatItem]) -> [String] {
        var history: [String] = []
        for case let .userMessage(message) in items {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != history.last { history.append(text) }
        }
        return history
    }

    private func index(for draft: String) -> Int? {
        guard let shown, shown.text == draft, history.indices.contains(shown.index) else { return nil }
        return shown.index
    }

    func canRecallOlder(draft: String) -> Bool {
        if let index = index(for: draft) { return index > 0 }
        return draft.isEmpty && !history.isEmpty
    }

    func canRecallNewer(draft: String) -> Bool {
        index(for: draft) != nil
    }

    /// The draft after the key, or nil when there is nowhere to go. Past the newest prompt the
    /// composer is empty again, as it was before the first Up.
    mutating func move(older: Bool, draft: String) -> String? {
        let current = index(for: draft)
        if older {
            guard canRecallOlder(draft: draft) else { return nil }
            let index = current.map { $0 - 1 } ?? history.count - 1
            shown = (index, history[index])
            return history[index]
        }
        guard let current else { return nil }
        guard current + 1 < history.count else {
            shown = nil
            return ""
        }
        shown = (current + 1, history[current + 1])
        return history[current + 1]
    }
}
