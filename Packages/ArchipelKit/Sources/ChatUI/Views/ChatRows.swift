import ACPKit
import Foundation

/// One row of the transcript as it is drawn. Consecutive tool calls share a row, so a run of ten
/// reads is one quiet block instead of ten separate things.
enum ChatRow: Identifiable, Equatable, Sendable {
    case user(ChatMessage)
    /// `endsTurn` marks the reply the turn closed with, which is the one worth a Copy button.
    case agent(ChatMessage, isStreaming: Bool, endsTurn: Bool)
    case thought(ChatMessage, isStreaming: Bool)
    case tools(id: String, calls: [ToolCall])

    /// Stable while the row grows: a tool group is named after its first call.
    var id: String {
        switch self {
        case let .user(message), let .agent(message, _, _), let .thought(message, _): message.id
        case let .tools(id, _): id
        }
    }

    static func rows(for items: [ChatItem], isTurnRunning: Bool) -> [ChatRow] {
        var rows: [ChatRow] = []
        rows.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let isLast = index == items.count - 1
            let isStreaming = isLast && isTurnRunning
            switch item {
            case let .userMessage(message):
                rows.append(.user(message))
            case let .agentMessage(message):
                guard !message.text.isEmpty || !message.attachments.isEmpty else { continue }
                let nextIsPrompt = if !isLast, case .userMessage = items[index + 1] { true } else { false }
                rows.append(.agent(message, isStreaming: isStreaming, endsTurn: nextIsPrompt || (isLast && !isTurnRunning)))
            case let .agentThought(message):
                rows.append(.thought(message, isStreaming: isStreaming))
            case let .toolCall(call):
                if case let .tools(id, calls) = rows.last {
                    rows[rows.count - 1] = .tools(id: id, calls: calls + [call])
                } else {
                    rows.append(.tools(id: item.id, calls: [call]))
                }
            }
        }
        return rows
    }

    /// Whether to show that the agent is busy although nothing on screen moves: after the prompt
    /// and between steps. A streaming message, a running tool call and a permission card each
    /// show it themselves.
    static func showsWorking(items: [ChatItem], isTurnRunning: Bool, isAwaitingPermission: Bool) -> Bool {
        guard isTurnRunning, !isAwaitingPermission else { return false }
        switch items.last {
        case nil, .userMessage: return true
        case .agentMessage, .agentThought: return false
        case let .toolCall(call): return call.status.isFinished
        }
    }

    private enum Family {
        case user, agent, activity
    }

    private var family: Family {
        switch self {
        case .user: .user
        case .agent: .agent
        case .thought, .tools: .activity
        }
    }

    /// The room above this row. Rows of one turn sit close, a new prompt starts further down, and
    /// thoughts and tool calls run together as one stretch of activity.
    func spacing(after previous: ChatRow?) -> CGFloat {
        guard let previous else { return 0 }
        switch (previous.family, family) {
        case (_, .user):
            // The reply that ended the turn already keeps a line free under it for its Copy button.
            if case .agent(_, _, endsTurn: true) = previous { return 10 }
            return 28
        case (.user, _): return 20
        case (.activity, .activity): return 0
        default: return 14
        }
    }
}

/// Where a scroll view is, reduced to what following the newest content needs.
struct ScrollMetrics: Equatable, Sendable {
    var offset: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat

    var distanceFromBottom: CGFloat {
        max(0, contentHeight - offset - viewportHeight)
    }
}

/// Whether the transcript keeps its newest line in view as it grows.
enum ScrollFollowing {
    /// Within this distance of the end counts as being at the end.
    static let threshold: CGFloat = 40

    /// Following stops only when the reader moves up, and starts again at the bottom. Growth alone
    /// never stops it: new content moves the end away without the offset changing, and that is
    /// exactly when the view should follow rather than conclude the reader left.
    static func isFollowing(was: Bool, old: ScrollMetrics, new: ScrollMetrics) -> Bool {
        if new.distanceFromBottom <= threshold { return true }
        let movedUp = new.offset < old.offset - 1
        let contentShrank = new.contentHeight < old.contentHeight - 1
        if movedUp, !contentShrank { return false }
        return was
    }
}
