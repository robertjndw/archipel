import ACPKit
import SwiftUI
import UISupport

/// The conversation: a reading column that follows the newest content until the reader scrolls up.
struct ChatTranscriptView: View {
    let session: ChatSession
    let actions: ChatViewActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isFollowing = true
    /// Open tool calls and thoughts, by item id. Kept here rather than in the rows, which a lazy
    /// stack throws away and rebuilds as they scroll out and in.
    @State private var expanded: Set<String>

    /// Previews pass the items that start out open in `expanded`.
    init(session: ChatSession, actions: ChatViewActions, expanded: Set<String> = []) {
        self.session = session
        self.actions = actions
        _expanded = State(initialValue: expanded)
    }

    @State private var columnWidth: CGFloat = ChatMetrics.columnWidth

    var body: some View {
        let items = session.transcript.items
        let rows = PlacedRow.place(ChatRow.rows(for: items, isTurnRunning: session.isTurnRunning))
        let showsWorking = ChatRow.showsWorking(
            items: items, isTurnRunning: session.isTurnRunning, isAwaitingPermission: !session.permissionRequests.isEmpty
        )

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if session.isHistoryUnavailable {
                    Text("Earlier messages aren't available")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 20)
                }
                ForEach(rows) { placed in
                    ChatRowView(
                        row: placed.row,
                        expanded: placed.row.expandedIDs(in: expanded),
                        bubbleWidth: (columnWidth * 0.8).rounded(),
                        toggle: toggle,
                        openFile: actions.openFile
                    )
                    .equatable()
                    .padding(.top, placed.spacing)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                }
                if let error = session.turnError {
                    TurnErrorView(message: error)
                        .padding(.top, 14)
                }
                if showsWorking {
                    WorkingIndicator()
                        .padding(.top, 12)
                        .transition(.opacity)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
            .chatColumn()
            .padding(.top, 20)
            .padding(.bottom, 16)
            // Keyed on the number of rows, so a new row eases in but text streaming into the last
            // row never animates: a layout animation per token would make the text swim.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: rows.count)
            .animation(reduceMotion ? nil : Motion.hover, value: showsWorking)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                offset: geometry.contentOffset.y.rounded(),
                contentHeight: geometry.contentSize.height.rounded(),
                viewportHeight: geometry.containerSize.height.rounded()
            )
        } action: { old, new in
            let follows = ScrollFollowing.isFollowing(was: isFollowing, old: old, new: new)
            if follows != isFollowing { isFollowing = follows }
            // Content grew or the pane changed size (a permission card opening takes room from
            // below): stay on the last line. Without animation, or it would lag behind the text.
            let resized = new.contentHeight != old.contentHeight || new.viewportHeight != old.viewportHeight
            if follows, resized, new.distanceFromBottom > 0 {
                position.scrollTo(edge: .bottom)
            }
        }
        // The initial anchor alone leaves a transcript that is only a little taller than the pane
        // at its top (seen on macOS 27.2), so the first position is set by hand as well.
        .onAppear { position.scrollTo(edge: .bottom) }
        // Sending always brings the reader back to the conversation's end, wherever they were.
        .onChange(of: userMessageCount(items)) { old, new in
            if new > old { jumpToLatest(animated: false) }
        }
        .overlay(alignment: .bottom) {
            if !isFollowing {
                Button {
                    jumpToLatest(animated: true)
                } label: {
                    Image(systemName: "arrow.down")
                        .fontWeight(.medium)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Jump to Latest")
                .accessibilityLabel("Jump to Latest")
                .accessibilityIdentifier("chat.jumpToLatest")
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(reduceMotion ? nil : Motion.hover, value: isFollowing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
        .accessibilityIdentifier("chat.transcript")
    }

    private func toggle(_ id: String) {
        withAnimation(reduceMotion ? nil : Motion.disclosure) {
            if expanded.contains(id) {
                expanded.remove(id)
            } else {
                expanded.insert(id)
            }
        }
        actions.userInteracted()
    }

    private func jumpToLatest(animated: Bool) {
        isFollowing = true
        withAnimation(animated && !reduceMotion ? .snappy(duration: 0.3) : nil) {
            position.scrollTo(edge: .bottom)
        }
    }

    private func userMessageCount(_ items: [ChatItem]) -> Int {
        items.count { if case .userMessage = $0 { true } else { false } }
    }
}

/// A row with the room above it, which depends on the row before.
private struct PlacedRow: Identifiable {
    var row: ChatRow
    var spacing: CGFloat

    var id: String { row.id }

    static func place(_ rows: [ChatRow]) -> [PlacedRow] {
        var placed: [PlacedRow] = []
        placed.reserveCapacity(rows.count)
        for row in rows {
            placed.append(PlacedRow(row: row, spacing: row.spacing(after: placed.last?.row)))
        }
        return placed
    }
}

private extension ChatRow {
    /// The open items that belong to this row, so a row is only redrawn for its own.
    func expandedIDs(in expanded: Set<String>) -> Set<String> {
        guard !expanded.isEmpty else { return [] }
        switch self {
        case .user, .agent:
            return []
        case let .thought(message, _):
            return expanded.contains(message.id) ? [message.id] : []
        case let .tools(_, calls):
            return expanded.intersection(calls.map { ChatItem.toolCall($0).id })
        }
    }
}

/// One transcript row. Equatable on what it shows, so while a reply streams in only the row that
/// grows is evaluated again; the closures never change what a row looks like.
private struct ChatRowView: View, Equatable {
    let row: ChatRow
    let expanded: Set<String>
    let bubbleWidth: CGFloat
    let toggle: (String) -> Void
    let openFile: (URL, Int?) -> Void

    nonisolated static func == (lhs: ChatRowView, rhs: ChatRowView) -> Bool {
        lhs.row == rhs.row && lhs.expanded == rhs.expanded && lhs.bubbleWidth == rhs.bubbleWidth
    }

    var body: some View {
        switch row {
        case let .user(message):
            UserMessageView(message: message, maximumWidth: bubbleWidth)
        case let .agent(message, isStreaming, endsTurn):
            AgentMessageView(message: message, showsCopyButton: endsTurn && !isStreaming)
        case let .thought(message, isStreaming):
            ThoughtRow(
                message: message, isStreaming: isStreaming, isExpanded: expanded.contains(message.id),
                toggle: { toggle(message.id) }
            )
        case let .tools(_, calls):
            ToolCallGroup(calls: calls, expanded: expanded, toggle: toggle, openFile: openFile)
        }
    }
}
