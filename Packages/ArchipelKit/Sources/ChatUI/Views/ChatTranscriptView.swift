import ACPKit
import EditorUI
import SwiftUI
import UISupport

/// The conversation: a reading column that follows the newest content until the reader scrolls up.
struct ChatTranscriptView: View {
    let session: ChatSession
    let actions: ChatViewActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatGutter) private var gutter
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isFollowing = true
    /// Room kept free above the first row while the find bar floats there.
    @State private var topInset: CGFloat = 0
    /// Where the transcript is scrolled to and how tall its rows are, as last reported. Kept by
    /// reference: it changes with every scrolled point, and nothing drawn depends on it.
    @State private var scrolled = ScrollState()
    /// Open tool calls and thoughts, by item id. Kept here rather than in the rows, which a lazy
    /// stack throws away and rebuilds as they scroll out and in.
    @State private var expanded: Set<String>
    /// The rows Find opened to show a hit. They close again when the search moves on, so a
    /// search does not leave the transcript longer than it found it.
    @State private var openedByFind: Set<String> = []

    private nonisolated static let contentSpace = "chat.transcript.content"

    /// Previews pass the items that start out open in `expanded`.
    init(session: ChatSession, actions: ChatViewActions, expanded: Set<String> = []) {
        self.session = session
        self.actions = actions
        _expanded = State(initialValue: expanded)
    }

    @State private var columnWidth: CGFloat = ChatMetrics.columnWidth

    var body: some View {
        let items = session.transcript.items
        let rows = placedRows(openFolds: expanded)
        let showsWorking = WorkingStatus.isShown(isTurnRunning: session.isTurnRunning, isAwaitingPermission: !session.permissionRequests.isEmpty)
        let find = session.viewState.find
        let request = FindRequest(find: find, items: items)
        let marks = FindMarks(find: find, rows: rows.map(\.row))

        ScrollViewReader { proxy in
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
                            mark: marks.mark(for: placed.row),
                            toggle: toggle,
                            openFile: actions.openFile
                        )
                        .equatable()
                        .padding(.leading, placed.isInFold ? ChatMetrics.detailIndent : 0)
                        .padding(.top, placed.spacing)
                        // Find aims with these. Measured on the view the row's id names, room
                        // above included, in the content's own space, where scrolling changes
                        // nothing.
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.contentSpace)) } action: { frame in
                            scrolled.heights[placed.id] = frame.height
                            scrolled.tops[placed.id] = frame.minY
                        }
                        // A row that left the screen may be somewhere else when it comes back.
                        .onDisappear { scrolled.tops[placed.id] = nil }
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                    }
                    if let error = session.turnError {
                        TurnErrorView(message: error)
                            .padding(.top, 14)
                    }
                    if showsWorking {
                        WorkingStatusLine(
                            phrase: WorkingStatus.phrase(items: items, isCancelling: session.isCancelling),
                            anchor: session.viewState.turnClock.anchor
                        )
                        .padding(.top, ChatRow.statusSpacing(after: rows.last?.row))
                        .transition(.opacity)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
                .chatColumn()
                .padding(.top, 20 + topInset)
                .padding(.bottom, 16)
                .coordinateSpace(.named(Self.contentSpace))
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
                scrolled.metrics = new
                let follows = ScrollFollowing.isFollowing(was: isFollowing, old: old, new: new)
                if follows != isFollowing { isFollowing = follows }
                // Content grew or the pane changed size (a permission card opening takes room from
                // below): stay on the last line. Without animation, or it would lag behind the text.
                // Not while Find scrolls to a hit: in its first frames that scroll is still within
                // reach of the end, and a reply streaming in would pull it straight back.
                let resized = new.contentHeight != old.contentHeight || new.viewportHeight != old.viewportHeight
                if follows, resized, new.distanceFromBottom > 0, scrolled.revealsInFlight == 0 {
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
            // Find reads the transcript here. With the bar closed the value never changes, so
            // nothing is compared or searched.
            .onChange(of: request, initial: true) { _, request in
                guard let request else { return }
                find.search(request.items, workingDirectory: session.configuration?.workingDirectory)
            }
            .onChange(of: find.revealRequests) {
                reveal(find.current, in: rows, with: proxy)
            }
            .onChange(of: find.isPresented, initial: true) { old, isPresented in
                // The first call is for a tab that comes back with its bar open, not for a bar
                // that opens.
                makeRoomForFindBar(isPresented, animated: old != isPresented)
                // The row the search ended on stays open: it holds what was looked for.
                if !isPresented { openedByFind = [] }
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
        // Over the conversation rather than above it, the way glass bars float: the text goes
        // on under the bar, and only the conversation's very start rests below it.
        .overlay(alignment: .topTrailing) {
            if find.isPresented {
                ChatFindBar(find: find, close: { session.dismissFind() })
                    .padding(.top, 10)
                    .padding(.horizontal, gutter)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
        .animation(reduceMotion ? nil : Motion.disclosure, value: find.isPresented)
    }

    /// Keeps the first rows clear of the find bar. Scrolled all the way up, or in a conversation
    /// shorter than the pane, the bar would cover the first prompt, which cannot be scrolled
    /// out from under it.
    private func makeRoomForFindBar(_ isPresented: Bool, animated: Bool) {
        let inset = isPresented ? ChatFindBar.height : 0
        guard inset != topInset else { return }
        // Nothing to keep in place before the scroll view has reported.
        guard animated, let metrics = scrolled.metrics else {
            topInset = inset
            return
        }
        guard let offset = ScrollFollowing.offset(keepingTextAt: metrics.offset, whenTopInsetChangesBy: inset - topInset) else {
            // At the conversation's very start, which is where one that fits the pane always
            // is, the text moves with the bar: down as it comes, back up as it goes.
            withAnimation(reduceMotion ? nil : Motion.disclosure) { topInset = inset }
            return
        }
        // Elsewhere the room opens above what is on screen. The position moves by the same
        // amount in the same step, without animation, so the text being read stays put.
        topInset = inset
        if isFollowing {
            position.scrollTo(edge: .bottom)
        } else {
            position.scrollTo(y: offset)
        }
    }

    private func placedRows(openFolds: Set<String>) -> [PlacedRow] {
        PlacedRow.place(ChatRow.rows(for: session.transcript.items, isTurnRunning: session.isTurnRunning, openFolds: openFolds))
    }

    /// Brings the hit Find is on into view, opening what hides it first: the fold its step is
    /// in, and its row when the hit is in a thought or in a tool call's details.
    private func reveal(_ match: ChatFindMatch?, in rows: [PlacedRow], with proxy: ScrollViewProxy) {
        guard let match else { return }
        var rows = rows
        let fold = rows.lazy.compactMap(\.row.fold).first { $0.itemIDs.contains(match.itemID) }
        // Rows the search opened and has moved out of close behind it. Without animation, like
        // the opening below: the scroll aims at where the rows will be.
        let left = openedByFind.subtracting([match.itemID, fold?.id].compactMap(\.self))
        var heightsChange = !left.isEmpty
        expanded.subtract(left)
        openedByFind.subtract(left)
        if let fold, !fold.isOpen {
            isFollowing = false
            expanded.insert(fold.id)
            openedByFind.insert(fold.id)
            heightsChange = true
        }
        // Folds that opened or closed changed which rows there are.
        if heightsChange { rows = placedRows(openFolds: expanded) }
        guard let target = ChatRow.scrollTarget(for: match, in: rows.map(\.row)) else { return }
        actions.userInteracted()
        if match.isInDetails, !expanded.contains(match.itemID) {
            // Following would pull the transcript back to its end the moment the row opens. If the
            // hit turns out to be at the end, the scroll view reports that and following resumes.
            isFollowing = false
            expanded.insert(match.itemID)
            openedByFind.insert(match.itemID)
            heightsChange = true
        }
        let id = target.rowID
        let spacing = rows.first { $0.id == id }?.spacing ?? 0
        let animation: Animation? = reduceMotion ? nil : .snappy(duration: 0.3)
        func anchor(rowHeight: CGFloat?) -> UnitPoint {
            UnitPoint(x: 0.5, y: ChatRow.scrollAnchor(
                position: target.position, rowHeight: rowHeight,
                paneHeight: scrolled.metrics?.viewportHeight ?? 0, spacingAbove: spacing
            ))
        }
        scrolled.revealsInFlight += 1
        let heightsChanged = heightsChange
        // A step later, once the rows that opened and closed are laid out.
        Task { @MainActor in
            defer { scrolled.revealsInFlight -= 1 }
            var waitsForLayout = heightsChanged
            if !heightsChanged, let metrics = scrolled.metrics, let top = scrolled.tops[id], let height = scrolled.heights[id],
               ChatRow.isInView(top: top, height: height, metrics: metrics, covered: topInset > 0 ? topInset + 10 : 0)
            {
                return
            }
            if scrolled.heights[id] == nil {
                // The lazy stack never built this row, so there is no height to aim with. Jump
                // to where the hit is inside the pane whatever the height, which builds the row.
                proxy.scrollTo(id, anchor: anchor(rowHeight: nil))
                waitsForLayout = true
            }
            // Long enough for the rows to be laid out and to report.
            if waitsForLayout { try? await Task.sleep(for: .milliseconds(50)) }
            // The height a row reported before it opened, or while it was off screen, need not
            // be the one it has once the scroll brings it in. Then it is aimed at once more.
            for _ in 0..<2 {
                let height = scrolled.heights[id]
                withAnimation(animation) {
                    proxy.scrollTo(id, anchor: anchor(rowHeight: height))
                }
                // Until the scroll has come to rest; see where the transcript follows its end.
                try? await Task.sleep(for: .milliseconds(animation == nil ? 50 : 350))
                if scrolled.heights[id] == height { break }
            }
        }
    }

    private func toggle(_ id: String) {
        withAnimation(reduceMotion ? nil : Motion.disclosure) {
            if expanded.contains(id) {
                expanded.remove(id)
            } else {
                expanded.insert(id)
            }
        }
        // From here on the row is open or closed because the reader said so.
        openedByFind.remove(id)
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

private final class ScrollState {
    /// Nil until the scroll view first reports.
    var metrics: ScrollMetrics?
    /// How tall each row was when it was last laid out, by row id. A row the lazy stack never
    /// built has none.
    var heights: [String: CGFloat] = [:]
    /// Where the rows on screen start, in the scrolled content.
    var tops: [String: CGFloat] = [:]
    /// Scrolls to a hit that have not finished yet.
    var revealsInFlight = 0
}

/// A row with the room above it, which depends on the row before.
private struct PlacedRow: Identifiable {
    var row: ChatRow
    var spacing: CGFloat
    /// A step of an open fold, which is set in under the fold's line.
    var isInFold = false

    var id: String { row.id }

    static func place(_ rows: [ChatRow]) -> [PlacedRow] {
        var placed: [PlacedRow] = []
        placed.reserveCapacity(rows.count)
        var foldSteps: Set<String> = []
        for row in rows {
            if let fold = row.fold { foldSteps = Set(fold.itemIDs) }
            // A thought's row and a tool group are both named after their first item.
            let isInFold = row.fold == nil && foldSteps.contains(row.id)
            placed.append(PlacedRow(row: row, spacing: row.spacing(after: placed.last?.row), isInFold: isInFold))
        }
        return placed
    }
}

private extension ChatRow {
    /// The open items that belong to this row, so a row is only redrawn for its own.
    func expandedIDs(in expanded: Set<String>) -> Set<String> {
        guard !expanded.isEmpty else { return [] }
        switch self {
        case .user, .agent, .fold:
            return []
        case let .thought(message, _):
            return expanded.contains(message.id) ? [message.id] : []
        case let .tools(_, calls, _):
            return expanded.intersection(calls.map { ChatItem.toolCall($0).id })
        }
    }
}

/// What the transcript hands Find to search: the string and the items, or nothing while the
/// bar is closed or its field holds nothing to look for.
private struct FindRequest: Equatable {
    var query: String
    var items: [ChatItem]

    @MainActor
    init?(find: ChatFindModel, items: [ChatItem]) {
        guard find.isPresented, ChatFindSearch.isSearchable(find.query) else { return nil }
        query = find.query
        // What subagents did is not in the conversation, so it is not searched either.
        self.items = ChatRow.mainItems(of: items).items
    }
}

/// What Find marks in one row.
struct RowFindMark: Equatable {
    /// The search string, and the current hit when it is in this row's text.
    var highlight: TextHighlight
    /// The tool call the current hit is in, when it is one of this row's. Its line is marked as
    /// a whole besides the hit itself, which a title cut short or a detail scrolled out of its
    /// block may not show.
    var currentCall: String?

    /// What one call of the row marks in its text. A hit is told by the text it is in, and the
    /// calls of a run often read alike ("Read ChatView.swift" twice over), so only the call the
    /// search is on gets to show the current hit.
    func highlight(forCall id: String) -> TextHighlight {
        id == currentCall ? highlight : TextHighlight(query: highlight.query)
    }
}

/// Find's marks for the rows of one pass over the transcript.
struct FindMarks {
    private var query: String?
    private var current: ChatFindMatch?
    private var currentRowID: String?

    /// `query` is the string to mark, nil while there is none; `current` the hit the search is
    /// on among `rows`.
    init(query: String?, current: ChatFindMatch?, rows: [ChatRow]) {
        self.query = query
        guard query != nil, let current else { return }
        self.current = current
        currentRowID = rows.first { $0.contains(itemID: current.itemID) }?.id
    }

    /// `rows` is only asked for while there is a hit to place, which is rarely.
    @MainActor
    init(find: ChatFindModel, rows: @autoclosure () -> [ChatRow]) {
        guard find.isPresented, ChatFindSearch.isSearchable(find.query) else {
            self.init(query: nil, current: nil, rows: [])
            return
        }
        // The text is marked for the string as it is typed. Which hit is the current one is only
        // known for the string the last search answered.
        guard find.isUpToDate, let current = find.current else {
            self.init(query: find.query, current: nil, rows: [])
            return
        }
        self.init(query: find.query, current: current, rows: rows())
    }

    func mark(for row: ChatRow) -> RowFindMark? {
        guard let query else { return nil }
        guard let current, row.id == currentRowID else { return RowFindMark(highlight: TextHighlight(query: query)) }
        var mark = RowFindMark(highlight: TextHighlight(query: query))
        // A reply's fields are its Markdown pieces one for one, so the field says which of
        // several cells that read alike the hit is in. Other rows tell it by the text alone.
        let piece: Int? = if case .agent = row { current.field } else { nil }
        mark.highlight.current = .init(text: current.text, occurrence: current.occurrence, piece: piece)
        if case .tools = row { mark.currentCall = current.itemID }
        return mark
    }
}

/// One transcript row. Equatable on what it shows, so while a reply streams in only the row that
/// grows is evaluated again; the closures never change what a row looks like.
private struct ChatRowView: View, Equatable {
    let row: ChatRow
    let expanded: Set<String>
    let bubbleWidth: CGFloat
    let mark: RowFindMark?
    let toggle: (String) -> Void
    let openFile: (URL, Int?) -> Void

    nonisolated static func == (lhs: ChatRowView, rhs: ChatRowView) -> Bool {
        lhs.row == rhs.row && lhs.expanded == rhs.expanded && lhs.bubbleWidth == rhs.bubbleWidth && lhs.mark == rhs.mark
    }

    var body: some View {
        content
            // The text views below mark Find's hits themselves, each in its own text.
            .environment(\.textHighlight, mark?.highlight)
    }

    @ViewBuilder private var content: some View {
        switch row {
        case let .user(message):
            UserMessageView(message: message, maximumWidth: bubbleWidth)
        case let .agent(message, isStreaming, endsTurn):
            AgentMessageView(message: message, showsCopyButton: endsTurn && !isStreaming)
        case let .thought(message, _):
            ThoughtRow(message: message, isExpanded: expanded.contains(message.id), toggle: { toggle(message.id) })
        case let .tools(_, calls, steps):
            ToolCallGroup(calls: calls, steps: steps, expanded: expanded, mark: mark, toggle: toggle, openFile: openFile)
        case let .fold(fold):
            ActivityFoldRow(fold: fold, toggle: { toggle(fold.id) })
        }
    }
}
