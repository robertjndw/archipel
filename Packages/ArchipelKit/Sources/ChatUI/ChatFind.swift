import ACPKit
import EditorUI
import Foundation
import Observation

/// One stretch of text Find looks through, cut the way the transcript shows it: a hit never
/// reaches from one stretch into the next.
struct FindField: Equatable, Sendable {
    var text: String
    /// Shown only while the item's row is open: a thought's text, a tool call's details.
    var isInDetails = false
}

/// One place the search string appears in the transcript.
struct ChatFindMatch: Equatable, Sendable {
    /// The transcript item the hit is in.
    var itemID: String
    /// Which of the item's stretches of text, and which hit in it, counted from zero.
    var field: Int
    var occurrence: Int
    /// The row has to be opened for the hit to be on screen.
    var isInDetails: Bool
    /// Roughly where in the item the hit sits, from 0 at its start to 1 at its end. A message
    /// can be taller than the pane, and this is what brings the right part of it into view.
    var position: Double
    /// The stretch of text the hit is in. The views mark hits inside their own text and tell
    /// the current one by it.
    var text: String

    /// Whether `other` is this hit after the transcript grew: the same place, wherever it sits
    /// in its item by now.
    func isSamePlace(as other: ChatFindMatch) -> Bool {
        itemID == other.itemID && field == other.field && occurrence == other.occurrence
    }
}

/// What Find looks through and how it counts.
enum ChatFindSearch {
    /// A search string of nothing but spaces would hit between every two words.
    static func isSearchable(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The text of `item` as the transcript shows it, in reading order. A tool call gives its
    /// title first and then what its row shows when opened.
    static func fields(of item: ChatItem, workingDirectory: String?) -> [FindField] {
        switch item {
        case let .userMessage(message):
            return message.text.isEmpty ? [] : [FindField(text: message.text)]
        case let .agentMessage(message):
            // One field per piece and none left out, so a hit's field is its piece's number;
            // see `TextHighlight.Current`.
            return MarkdownText.searchableText(of: message.text).map { FindField(text: $0) }
        case let .agentThought(message):
            return message.text.isEmpty ? [] : [FindField(text: message.text, isInDetails: true)]
        case let .toolCall(call):
            return fields(of: call, workingDirectory: workingDirectory)
        }
    }

    private static func fields(of call: ToolCall, workingDirectory: String?) -> [FindField] {
        var fields = [FindField(text: call.displayTitle(relativeTo: workingDirectory))]
        if let name = call.diffFileNameMissingFromTitle { fields.append(FindField(text: name)) }
        func detail(_ text: String) {
            if !text.isEmpty { fields.append(FindField(text: text, isInDetails: true)) }
        }
        // An opened row lists the first few places only, however many a search turned up.
        for location in call.listedLocations.shown {
            detail(location.displayLabel(relativeTo: workingDirectory))
        }
        // Only the end of a long output is shown at all, so only that part is searched. The
        // block scrolls to the line of the hit the search is on.
        func output(_ text: String) {
            detail(OutputTail.tail(of: text).text)
        }
        if call.commandDiffersFromTitle, let command = call.command { output(command) }
        for text in call.textContent { output(text) }
        if let terminal = call.terminalOutput { output(terminal) }
        for diff in call.diffs {
            // A field per line, as the diff draws them: each line marks its own hits.
            for line in LineDiff.analysis(old: diff.oldText, new: diff.newText).lines where line.kind != .gap {
                detail(line.text)
            }
        }
        return fields
    }

    /// The hits in one item's text, in reading order.
    static func matches(of query: String, in fields: [FindField], itemID: String) -> [ChatFindMatch] {
        let total = fields.reduce(0) { $0 + $1.text.utf8.count }
        guard total > 0, isSearchable(query) else { return [] }
        var matches: [ChatFindMatch] = []
        var before = 0
        for (index, field) in fields.enumerated() {
            for (occurrence, range) in TextHighlight.ranges(of: query, in: field.text).enumerated() {
                let offset = field.text.utf8.distance(from: field.text.startIndex, to: range.lowerBound)
                matches.append(ChatFindMatch(
                    itemID: itemID, field: index, occurrence: occurrence, isInDetails: field.isInDetails,
                    position: Double(before + offset) / Double(total), text: field.text
                ))
            }
            before += field.text.utf8.count
        }
        return matches
    }

    /// Where stepping from `current` lands among `count` hits. Past either end it starts over
    /// at the other.
    static func step(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return forward ? 0 : count - 1 }
        return (current + (forward ? 1 : count - 1)) % count
    }

    /// Where the hit the search was on is among new results for the same search string. The
    /// transcript only grows at its end, so the hit is usually still there; one that is gone
    /// hands over to whatever took its place in the list.
    static func index(of current: ChatFindMatch?, formerly index: Int?, in matches: [ChatFindMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let current else { return matches.count - 1 }
        if let index, index < matches.count, matches[index].isSamePlace(as: current) { return index }
        if let found = matches.firstIndex(where: { $0.isSamePlace(as: current) }) { return found }
        return min(index ?? matches.count - 1, matches.count - 1)
    }
}

/// Searches a transcript off the main actor, and remembers each item's text and its hits so a
/// reply that is streaming in costs one item's work per search rather than the whole
/// conversation's.
actor ChatFindIndex {
    private struct Entry {
        var item: ChatItem
        var fields: [FindField]
        /// The search string `matches` answers.
        var query: String
        var matches: [ChatFindMatch]
    }

    private var entries: [String: Entry] = [:]
    /// How many items had to be searched in the last pass, for tests.
    private(set) var searchedItems = 0

    /// Every hit, in the transcript's order.
    func matches(of query: String, in items: [ChatItem], workingDirectory: String?) -> [ChatFindMatch] {
        var kept: [String: Entry] = [:]
        kept.reserveCapacity(items.count)
        var matches: [ChatFindMatch] = []
        searchedItems = 0
        for item in items {
            var entry = entries[item.id] ?? Entry(item: item, fields: [], query: "", matches: [])
            let isSameItem = entries[item.id] != nil && entry.item == item
            if !isSameItem {
                entry.item = item
                entry.fields = ChatFindSearch.fields(of: item, workingDirectory: workingDirectory)
            }
            // A hit holds nothing but its own item's data, so an item that did not change
            // answers the same search with the same hits.
            if !isSameItem || entry.query != query {
                entry.query = query
                entry.matches = ChatFindSearch.matches(of: query, in: entry.fields, itemID: item.id)
                searchedItems += 1
            }
            kept[item.id] = entry
            matches += entry.matches
        }
        entries = kept
        return matches
    }

    /// Lets go of the remembered text. A closed find bar should not hold a second copy of the
    /// conversation.
    func reset() {
        entries = [:]
    }
}

/// Find in the conversation: the search string, its hits and which of them the search is on.
///
/// Lives with the session rather than in a view, so the menu bar can open it and a tab that is
/// switched away from comes back with its find bar as it was. The transcript view feeds it the
/// items to search; searching happens off the main actor, a moment after the last change.
@MainActor @Observable
final class ChatFindModel {
    private(set) var isPresented = false
    /// What the find field holds.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            revealsNextResults = true
            if !ChatFindSearch.isSearchable(query) { clearResults() }
        }
    }

    private(set) var matches: [ChatFindMatch] = []
    /// The hit the search is on, as an index into `matches`.
    private(set) var currentIndex: Int?
    /// The search string `matches` answers. While it lags behind `query` the hits are the last
    /// search's: the bar keeps their count up, but nothing steps through them.
    private(set) var searchedQuery = ""
    /// Counts requests to put the cursor in the find field. The bar focuses its field whenever
    /// this changes, as the composer does for the session's.
    private(set) var focusRequests = 0
    /// Counts the times the current hit has to be brought into view. Results that merely update
    /// while a reply streams in never count: the reader stays where they are.
    private(set) var revealRequests = 0

    /// The hit the search is on has not been scrolled to yet, so the next step shows it instead
    /// of moving on. That is the case when the bar comes back with the string it had.
    @ObservationIgnored private var isCurrentRevealed = false
    @ObservationIgnored private var answeredFocusRequests = 0
    @ObservationIgnored private var revealsNextResults = false
    @ObservationIgnored private var pending: Input?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let index = ChatFindIndex()
    /// How long changes pile up before a search starts. Typing and streamed chunks both arrive
    /// in bursts, and each search is for the latest state only.
    @ObservationIgnored private let delay: Duration

    private struct Input {
        var query: String
        var items: [ChatItem]
        var workingDirectory: String?
    }

    init(delay: Duration = .milliseconds(120)) {
        self.delay = delay
    }

    var current: ChatFindMatch? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    /// Whether `matches` is the answer to what the field holds now.
    var isUpToDate: Bool {
        !ChatFindSearch.isSearchable(query) || searchedQuery == query
    }

    // MARK: Showing and stepping

    /// Shows the find bar and puts the cursor in its field. With the bar already up it only
    /// moves the cursor back there.
    func present() {
        isPresented = true
        focusRequests += 1
    }

    /// True once for every request to focus the field, so a find bar that is rebuilt when its
    /// tab comes back does not take the keyboard a second time.
    func takeFocusRequest() -> Bool {
        guard answeredFocusRequests != focusRequests else { return false }
        answeredFocusRequests = focusRequests
        return true
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        pending = nil
        // The string stays for the next time; its hits would be stale by then.
        clearResults()
        Task { [index] in await index.reset() }
    }

    /// Moves to the next hit, or with `forward` false to the one before, starting over past
    /// either end. With the bar closed it opens it and shows the first hit once there is one.
    func step(forward: Bool) {
        guard isPresented else {
            present()
            revealsNextResults = true
            return
        }
        // Results for a string that is still being searched for are about to be replaced, and
        // the new ones bring their own first hit into view.
        guard isUpToDate, !matches.isEmpty else { return }
        if isCurrentRevealed || currentIndex == nil {
            currentIndex = ChatFindSearch.step(from: currentIndex, count: matches.count, forward: forward)
        }
        reveal()
    }

    private func reveal() {
        guard currentIndex != nil else { return }
        isCurrentRevealed = true
        revealRequests += 1
    }

    private func clearResults() {
        matches = []
        currentIndex = nil
        searchedQuery = ""
        isCurrentRevealed = false
    }

    // MARK: Searching

    /// Searches `items` for the field's string, soon. Call it whenever either changed while the
    /// bar is up; searches never overlap, and each one takes the newest state it was handed.
    func search(_ items: [ChatItem], workingDirectory: String?) {
        guard isPresented, ChatFindSearch.isSearchable(query) else {
            pending = nil
            return
        }
        pending = Input(query: query, items: items, workingDirectory: workingDirectory)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.work()
        }
    }

    private func work() async {
        while pending != nil {
            try? await Task.sleep(for: delay)
            guard let input = pending else { break }
            pending = nil
            let found = await index.matches(of: input.query, in: input.items, workingDirectory: input.workingDirectory)
            // The bar was closed or the string changed while this ran: its answer is to a
            // question nobody is asking any more.
            guard isPresented, input.query == query else { continue }
            apply(found, for: input.query)
        }
        worker = nil
    }

    private func apply(_ found: [ChatFindMatch], for query: String) {
        let former = current
        let formerIndex = currentIndex
        let isSameSearch = query == searchedQuery
        matches = found
        searchedQuery = query
        if isSameSearch {
            currentIndex = ChatFindSearch.index(of: former, formerly: formerIndex, in: found)
        } else {
            // The newest hit first: it is the one nearest to where the reader is. Return in the
            // field then walks back from it; see `FindKeys`.
            currentIndex = found.isEmpty ? nil : found.count - 1
            isCurrentRevealed = false
        }
        if revealsNextResults {
            revealsNextResults = false
            reveal()
        }
    }

    /// Waits until every search asked for so far has been answered, for tests.
    func settle() async {
        while let worker {
            await worker.value
        }
    }
}
