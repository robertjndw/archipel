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

    /// The room between the last row and the status line under it. After tool calls and thoughts
    /// the line stands a little apart. Under a reply it takes exactly the room the Copy button gets
    /// once the turn is over, since the transcript rests on its last line and any difference would
    /// move everything at the end of every turn.
    static func statusSpacing(after last: ChatRow?) -> CGFloat {
        switch last?.family {
        case nil: 0
        case .user: 20
        case .agent: ChatMetrics.replyFooterHeight - ChatMetrics.activityRowHeight
        case .activity: 6
        }
    }

    // MARK: Find

    /// Whether the transcript item `itemID` is drawn in this row.
    func contains(itemID: String) -> Bool {
        switch self {
        case let .user(message), let .agent(message, _, _), let .thought(message, _):
            message.id == itemID
        case let .tools(_, calls):
            calls.contains { ChatItem.toolCall($0).id == itemID }
        }
    }

    /// Roughly where in this row `match` sits, from 0 at the row's top to 1 at its bottom. Nil
    /// when the hit is in another row.
    func position(of match: ChatFindMatch) -> Double? {
        switch self {
        case let .user(message), let .agent(message, _, _), let .thought(message, _):
            return message.id == match.itemID ? match.position : nil
        case let .tools(_, calls):
            // The calls of a group are taken as equally tall, which is right until one is opened
            // and close enough after.
            guard let index = calls.firstIndex(where: { ChatItem.toolCall($0).id == match.itemID }) else { return nil }
            return (Double(index) + match.position) / Double(calls.count)
        }
    }

    /// Where to scroll for `match`: the row it is in, and how far down that row the hit sits,
    /// from 0 at its top to 1 at its end.
    static func scrollTarget(for match: ChatFindMatch, in rows: [ChatRow]) -> (rowID: String, position: Double)? {
        for row in rows {
            if let position = row.position(of: match) {
                return (row.id, min(max(position, 0), 1))
            }
        }
        return nil
    }

    /// The anchor that makes `scrollTo` bring the part of a row at `position` to rest inside the pane.
    ///
    /// A message can be several panes tall, so bringing the row into view is not enough. The hit
    /// lands as far down the pane as it is down its row. The outer tenths of the pane are left out,
    /// where the find bar and Jump to Latest float.
    ///
    /// `scrollTo` lines up the same unit point of the row and of the pane, so the hit comes to rest
    /// at `a * pane + hit - a * row` for an anchor `a`, and this solves for `a`. A fixed anchor would
    /// put the first and last lines of a row taller than the pane outside it. The result can lie
    /// outside 0...1, which `scrollTo` accepts. Without a height (the lazy stack never built the
    /// row) the anchor is the position itself, which lands inside the pane whatever the height is.
    ///
    /// `spacingAbove` is the room above the row that the view being scrolled to includes.
    static func scrollAnchor(position: Double, rowHeight: CGFloat?, paneHeight: CGFloat, spacingAbove: CGFloat = 0) -> Double {
        let position = min(max(position, 0), 1)
        guard let rowHeight, rowHeight > 0, paneHeight > 0 else { return position }
        let hit = spacingAbove + position * max(0, rowHeight - spacingAbove)
        // A row as tall as the pane fills it whatever the anchor.
        guard abs(paneHeight - rowHeight) >= 1 else { return hit / rowHeight }
        let rest = (0.12 + 0.76 * position) * paneHeight
        return (rest - hit) / (paneHeight - rowHeight)
    }

    /// Whether a row is on screen from its first line to its last, clear of the `covered` points
    /// at the pane's top that the find bar floats over. Stepping to a hit in such a row needs no
    /// scrolling: the mark moves, and the page should not.
    static func isInView(top: CGFloat, height: CGFloat, metrics: ScrollMetrics, covered: CGFloat) -> Bool {
        top - metrics.offset >= covered && top + height - metrics.offset <= metrics.viewportHeight
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

    /// Where to scroll so the text stays where it is on screen while the room above the first row
    /// changes by `change`. Nil at the conversation's very start, where the text is meant to move: it
    /// rests below the find bar and comes back up when the bar goes.
    static func offset(keepingTextAt offset: CGFloat, whenTopInsetChangesBy change: CGFloat) -> CGFloat? {
        guard offset > 0 else { return nil }
        return max(0, offset + change)
    }
}
