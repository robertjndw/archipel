import ACPKit
import Foundation

/// A key command as it reaches the composer's text view, after the input method had its turn.
enum ComposerCommand: Equatable, Sendable {
    /// Return. `modified` when Shift or Option is held.
    case newline(modified: Bool)
    case tab
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
        case .tab, .up, .down:
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
