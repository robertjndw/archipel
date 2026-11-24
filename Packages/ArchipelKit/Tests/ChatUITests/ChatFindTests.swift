import ACPKit
@testable import ChatUI
import EditorUI
import Foundation
import Testing

private func user(_ id: String, _ text: String) -> ChatItem {
    .userMessage(ChatMessage(id: id, text: text))
}

private func agent(_ id: String, _ text: String) -> ChatItem {
    .agentMessage(ChatMessage(id: id, text: text))
}

private func thought(_ id: String, _ text: String) -> ChatItem {
    .agentThought(ChatMessage(id: id, text: text))
}

private func matches(_ query: String, in item: ChatItem, workingDirectory: String? = nil) -> [ChatFindMatch] {
    ChatFindSearch.matches(of: query, in: ChatFindSearch.fields(of: item, workingDirectory: workingDirectory), itemID: item.id)
}

@Suite
struct ChatFindSearchTests {
    @Test func aUserMessageIsOneStretchOfText() {
        let found = matches("login", in: user("u", "Fix the login. The Login view, I mean."))
        #expect(found.map(\.occurrence) == [0, 1])
        #expect(found.allSatisfy { $0.itemID == "u" && $0.field == 0 && !$0.isInDetails })
        // The bubble marks hits in its text, so each one says which text it is in.
        #expect(found.first?.text == "Fix the login. The Login view, I mean.")
    }

    @Test func caseAccentsAndWidthAreIgnored() {
        #expect(matches("resume", in: user("u", "My Résumé and my RESUME")).count == 2)
        #expect(matches("é", in: user("u", "cafe")).count == 1)
        #expect(matches("ABC", in: user("u", "ａｂｃ")).count == 1)
    }

    @Test func hitsDoNotOverlap() {
        #expect(matches("aa", in: user("u", "aaaaa")).count == 2)
    }

    @Test func nothingToSearchForFindsNothing() {
        #expect(matches("", in: user("u", "text")).isEmpty)
        #expect(matches("   ", in: user("u", "some text here")).isEmpty)
        #expect(!ChatFindSearch.isSearchable(" \n"))
        #expect(ChatFindSearch.isSearchable(" a "))
    }

    @Test func aReplyIsSearchedAsItIsDrawnNotAsItIsWritten() {
        let reply = agent("m", """
        # The **login** form

        Rejects an *empty* `password` now. See [the notes](https://example.com/login).

        ```swift
        let login = true
        ```
        """)
        // The heading, and the code. The link's address is not on screen, so it holds no hit.
        let found = matches("login", in: reply)
        #expect(found.map(\.text) == ["The login form", "let login = true"])
        #expect(found.map(\.field) == [0, 2])
        // Markdown syntax is gone: what reads as one phrase is found as one.
        #expect(matches("the login form", in: reply).count == 1)
        #expect(matches("**", in: reply).isEmpty)
        #expect(matches("empty password", in: reply).count == 1)
    }

    @Test func aHitNeverReachesFromOneBlockIntoTheNext() {
        #expect(matches("one two", in: agent("m", "one\n\ntwo")).isEmpty)
    }

    @Test func aThoughtHasToBeOpenedToShowItsHit() {
        let found = matches("why", in: thought("t", "Why does it fail?"))
        #expect(found.count == 1)
        #expect(found[0].isInDetails)
        #expect(found[0].text == "Why does it fail?")
    }

    @Test func aToolCallIsSearchedByItsTitleAndByWhatItShowsWhenOpened() {
        let call = ChatItem.toolCall(ToolCall(
            toolCallId: "c", title: "Run tests", kind: .execute, status: .completed,
            content: [.content(.text("Compiling LoginTests"))],
            locations: [ToolCallLocation(path: "/work/Sources/Login.swift", line: 18)],
            rawInput: ["command": "swift test --filter LoginTests"],
            terminalOutput: "Executed 12 tests\nTest run passed"
        ))
        let inTitle = matches("run tests", in: call, workingDirectory: "/work")
        #expect(inTitle.count == 1)
        #expect(!inTitle[0].isInDetails)
        // The row marks the hit in its title, so the hit names the title.
        #expect(inTitle[0].text == "Run tests")

        // The location as the row lists it, relative to the working directory, which marks the
        // hit in its label.
        let inLocation = matches("Sources/Login.swift:18", in: call, workingDirectory: "/work")
        #expect(inLocation.map(\.isInDetails) == [true])
        #expect(inLocation.map(\.text) == ["Sources/Login.swift:18"])
        #expect(matches("/work/Sources", in: call, workingDirectory: "/work").isEmpty)
        // The command, the output and the terminal output, one stretch each.
        let tests = matches("tests", in: call, workingDirectory: "/work")
        #expect(tests.map(\.isInDetails) == [false, true, true, true])
        #expect(Set(tests.map(\.field)).count == 4)
        #expect(tests.map(\.text) == ["Run tests", "swift test --filter LoginTests", "Compiling LoginTests", "Executed 12 tests\nTest run passed"])
    }

    @Test func aCommandThatIsTheTitleIsNotSearchedTwice() {
        let call = ChatItem.toolCall(ToolCall(toolCallId: "c", title: "swift build", kind: .execute, rawInput: ["command": "swift build"]))
        #expect(matches("swift", in: call).count == 1)
    }

    @Test func anEditIsSearchedInTheLinesItsDiffShows() {
        let old = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "line 20\n", with: "line twenty\n")
        let call = ChatItem.toolCall(ToolCall(
            toolCallId: "c", title: "Edit file", kind: .edit,
            content: [.diff(path: "/work/Sources/Form.swift", oldText: old, newText: new)]
        ))
        // The file's name stands next to a title that does not say it.
        #expect(matches("Form.swift", in: call).map(\.isInDetails) == [false])
        #expect(matches("twenty", in: call).map(\.isInDetails) == [true])
        // Every line of the diff is a stretch of its own, so the hit names the line it is in and
        // that line marks it.
        #expect(matches("twenty", in: call).map(\.text) == ["line twenty"])
        #expect(matches("line 19\nline", in: call).isEmpty)
        // Both sides of the change are on screen, and so are a few lines around it.
        #expect(matches("line 20", in: call).count == 1)
        #expect(matches("line 19", in: call).count == 1)
        // Lines far from the change are not shown, so they hold no hit.
        #expect(matches("line 2", in: call).count == 4)
        #expect(matches("line 40", in: call).isEmpty)
    }

    @Test func onlyTheEndOfLongOutputIsSearched() {
        let output = (1...500).map { "row \($0)" }.joined(separator: "\n")
        let call = ChatItem.toolCall(ToolCall(toolCallId: "c", title: "Run", kind: .execute, terminalOutput: output))
        #expect(matches("row 500", in: call).count == 1)
        #expect(matches("row 7\n", in: call).isEmpty)
    }

    @Test func aHitKnowsRoughlyWhereInItsItemItSits() {
        let found = matches("x", in: user("u", "x" + String(repeating: "-", count: 98) + "x"))
        #expect(found.map(\.position) == [0, 0.99])
        // Across the blocks of a reply as well: the second block starts after all of the first.
        let reply = matches("b", in: agent("m", "aaaa\n\nb"))
        #expect(reply.map(\.position) == [0.8])
    }
}

@Suite
struct ChatFindSteppingTests {
    private func match(_ item: String, _ occurrence: Int = 0, field: Int = 0) -> ChatFindMatch {
        ChatFindMatch(itemID: item, field: field, occurrence: occurrence, isInDetails: false, position: 0, text: "")
    }

    @Test func steppingStartsOverPastEitherEnd() {
        #expect(ChatFindSearch.step(from: 0, count: 3, forward: true) == 1)
        #expect(ChatFindSearch.step(from: 2, count: 3, forward: true) == 0)
        #expect(ChatFindSearch.step(from: 0, count: 3, forward: false) == 2)
        #expect(ChatFindSearch.step(from: 1, count: 3, forward: false) == 0)
        #expect(ChatFindSearch.step(from: 0, count: 1, forward: true) == 0)
    }

    @Test func steppingFromNowhereTakesTheNearestEnd() {
        #expect(ChatFindSearch.step(from: nil, count: 3, forward: true) == 0)
        #expect(ChatFindSearch.step(from: nil, count: 3, forward: false) == 2)
        #expect(ChatFindSearch.step(from: 7, count: 3, forward: true) == 0)
        #expect(ChatFindSearch.step(from: 0, count: 0, forward: true) == nil)
    }

    @Test func theCurrentHitStaysTheCurrentHitAsTheTranscriptGrows() {
        let current = match("m1", 1)
        let grown = [match("u"), match("m1", 0), match("m1", 1), match("m2"), match("m2", 1)]
        #expect(ChatFindSearch.index(of: current, formerly: 2, in: grown) == 2)
        // Hits that came in before it move it down the list.
        #expect(ChatFindSearch.index(of: current, formerly: 1, in: grown) == 2)
        // Its place in its item may have changed; it is the same hit all the same.
        var moved = current
        moved.position = 0.3
        #expect(ChatFindSearch.index(of: moved, formerly: 2, in: grown) == 2)
    }

    @Test func aHitThatIsGoneHandsOverToItsNeighbor() {
        let gone = match("gone")
        #expect(ChatFindSearch.index(of: gone, formerly: 1, in: [match("a"), match("b"), match("c")]) == 1)
        #expect(ChatFindSearch.index(of: gone, formerly: 5, in: [match("a"), match("b")]) == 1)
        #expect(ChatFindSearch.index(of: gone, formerly: 0, in: []) == nil)
        // Without a hit to keep, the newest is the one to be on.
        #expect(ChatFindSearch.index(of: nil, formerly: nil, in: [match("a"), match("b")]) == 1)
    }

    @Test func scrollingAimsAtTheRowAndAtThePartOfItThatHoldsTheHit() {
        let read = ToolCall(toolCallId: "a", title: "Read A", kind: .read)
        let edit = ToolCall(toolCallId: "b", title: "Edit B", kind: .edit)
        let rows: [ChatRow] = [
            .user(ChatMessage(id: "u", text: "u")),
            .tools(id: "tool:a", calls: [read, edit]),
            .agent(ChatMessage(id: "m", text: "m"), isStreaming: false, endsTurn: true),
        ]
        func target(_ item: String, at position: Double) -> (rowID: String, position: Double)? {
            var match = match(item)
            match.position = position
            return ChatRow.scrollTarget(for: match, in: rows)
        }
        #expect(target("m", at: 0)?.rowID == "m")
        #expect(target("m", at: 0)?.position == 0)
        #expect(target("m", at: 0.5)?.position == 0.5)
        #expect(target("m", at: 1)?.position == 1)
        // A group is one row; the second of its two calls starts its lower half.
        #expect(target("tool:b", at: 0)?.rowID == "tool:a")
        #expect(target("tool:b", at: 0)?.position == 0.5)
        #expect(target("tool:b", at: 0.5)?.position == 0.75)
        #expect(target("elsewhere", at: 0) == nil)
        #expect(rows[1].contains(itemID: "tool:b"))
        #expect(!rows[1].contains(itemID: "m"))
    }

    /// Where a hit comes to rest in the pane: `scrollTo` lines up the anchor's point of the row
    /// with the same point of the pane.
    private func restingPlace(of position: Double, rowHeight: CGFloat, paneHeight: CGFloat, spacingAbove: CGFloat = 0) -> CGFloat {
        let anchor = ChatRow.scrollAnchor(position: position, rowHeight: rowHeight, paneHeight: paneHeight, spacingAbove: spacingAbove)
        let hit = spacingAbove + position * (rowHeight - spacingAbove)
        return anchor * paneHeight + hit - anchor * rowHeight
    }

    @Test func aHitLandsInsideThePaneHoweverTallItsRowIs() {
        let pane: CGFloat = 600
        // A row shorter than the pane, one just taller, one as tall, and one of five panes.
        for rowHeight in [40, 300, 599.5, 600, 640, 1800, 3000] as [CGFloat] {
            for position in [0, 0.1, 0.5, 0.9, 1] {
                let y = restingPlace(of: position, rowHeight: rowHeight, paneHeight: pane)
                // The outermost tenths belong to the find bar and to Jump to Latest. A row as
                // tall as the pane has no choice, and fills it.
                if abs(rowHeight - pane) < 1 {
                    #expect(y >= 0 && y <= pane, "row \(rowHeight), hit at \(position), lands at \(y)")
                } else {
                    #expect(y >= 0.12 * pane - 0.5 && y <= 0.88 * pane + 0.5, "row \(rowHeight), hit at \(position), lands at \(y)")
                }
            }
        }
        // The first line of a row several panes tall comes down out from under the find bar,
        // and its last line up from under the pane's edge, which a fixed anchor never did.
        #expect(abs(restingPlace(of: 0, rowHeight: 3000, paneHeight: pane) - 0.12 * pane) < 0.5)
        #expect(abs(restingPlace(of: 1, rowHeight: 3000, paneHeight: pane) - 0.88 * pane) < 0.5)
    }

    @Test func theRoomAboveARowIsNotPartOfWhatTheHitIsMeasuredIn() {
        // The view that is scrolled to starts with the row's spacing. A hit in the row's first
        // line is that far down it.
        let y = restingPlace(of: 0, rowHeight: 1000, paneHeight: 600, spacingAbove: 28)
        #expect(abs(y - 0.12 * 600) < 0.5)
    }

    @Test func aRowThatWasNeverLaidOutIsAimedAtByThePositionAlone() {
        // Whatever height it turns out to have, the hit is then inside the pane.
        #expect(ChatRow.scrollAnchor(position: 0.3, rowHeight: nil, paneHeight: 600) == 0.3)
        #expect(ChatRow.scrollAnchor(position: 0.3, rowHeight: 900, paneHeight: 0) == 0.3)
        #expect(ChatRow.scrollAnchor(position: 7, rowHeight: nil, paneHeight: 600) == 1)
    }

    @Test func aRowThatIsOnScreenWholeNeedsNoScrolling() {
        let metrics = ScrollMetrics(offset: 1000, contentHeight: 5000, viewportHeight: 600)
        #expect(ChatRow.isInView(top: 1100, height: 300, metrics: metrics, covered: 46))
        // Under the find bar, past the pane's end, and taller than the pane.
        #expect(!ChatRow.isInView(top: 1020, height: 300, metrics: metrics, covered: 46))
        #expect(ChatRow.isInView(top: 1020, height: 300, metrics: metrics, covered: 0))
        #expect(!ChatRow.isInView(top: 1400, height: 300, metrics: metrics, covered: 46))
        #expect(!ChatRow.isInView(top: 1100, height: 900, metrics: metrics, covered: 46))
    }
}

@Suite
struct FindMarksTests {
    private func call(_ id: String, _ title: String) -> ToolCall {
        ToolCall(toolCallId: id, title: title, kind: .read, status: .completed, terminalOutput: "ok")
    }

    @Test func everyRowMarksTheStringAndOnlyTheHitsRowTheCurrentOne() throws {
        let items = [user("u", "Fix the login"), agent("m", "The login works now.")]
        let rows = ChatRow.rows(for: items, isTurnRunning: false)
        let current = try #require(matches("login", in: items[1]).first)
        let marks = FindMarks(query: "login", current: current, rows: rows)
        #expect(marks.mark(for: rows[0]) == RowFindMark(highlight: TextHighlight(query: "login")))
        // A reply's hit says which of its Markdown pieces it is in; a bubble's does not.
        #expect(marks.mark(for: rows[1])?.highlight.current == .init(text: "The login works now.", occurrence: 0, piece: 0))
        let inBubble = try #require(matches("login", in: items[0]).first)
        #expect(FindMarks(query: "login", current: inBubble, rows: rows).mark(for: rows[0])?.highlight.current == .init(text: "Fix the login", occurrence: 0))
        #expect(marks.mark(for: rows[1])?.currentCall == nil)
        // Without a string nothing is marked, and without a hit only the string.
        #expect(FindMarks(query: nil, current: current, rows: rows).mark(for: rows[1]) == nil)
        #expect(FindMarks(query: "login", current: nil, rows: rows).mark(for: rows[1]) == RowFindMark(highlight: TextHighlight(query: "login")))
    }

    @Test func ofCallsThatReadAlikeOnlyTheOneTheSearchIsOnShowsTheCurrentHit() throws {
        let first = call("a", "Read Login.swift")
        let second = call("b", "Read Login.swift")
        let items: [ChatItem] = [.toolCall(first), .toolCall(second)]
        let rows = ChatRow.rows(for: items, isTurnRunning: false)
        try #require(rows.count == 1)
        let current = try #require(matches("login", in: items[1]).first)
        let mark = try #require(FindMarks(query: "login", current: current, rows: rows).mark(for: rows[0]))
        #expect(mark.currentCall == items[1].id)
        #expect(mark.highlight(forCall: items[1].id).current == .init(text: "Read Login.swift", occurrence: 0))
        // The same words one line up are a hit, but not the one the search is on.
        #expect(mark.highlight(forCall: items[0].id) == TextHighlight(query: "login"))
    }

    @Test func aHitInADiffMarksItsLineAndItsCall() throws {
        let edit = ToolCall(
            toolCallId: "c", title: "Edit file", kind: .edit,
            content: [.diff(path: "/work/Form.swift", oldText: "let a = 1\n", newText: "let login = 1\n")]
        )
        let items: [ChatItem] = [.toolCall(edit)]
        let rows = ChatRow.rows(for: items, isTurnRunning: false)
        let current = try #require(matches("login", in: items[0]).first)
        let mark = try #require(FindMarks(query: "login", current: current, rows: rows).mark(for: rows[0]))
        // The call's line is marked as a whole, and the diff's line marks the word.
        #expect(mark.currentCall == items[0].id)
        #expect(mark.highlight(forCall: items[0].id).current == .init(text: "let login = 1", occurrence: 0))
    }

    @Test func ofTableCellsThatReadAlikeTheHitNamesItsOwn() throws {
        let table = agent("m", """
        | Test | Result |
        |------|--------|
        | Login | passed |
        | Logout | passed |
        | Reset | passed |
        """)
        let rows = ChatRow.rows(for: [table], isTurnRunning: false)
        let found = matches("passed", in: table)
        #expect(found.count == 3)
        // Three cells with the same text: only the place among the pieces tells them apart.
        let currents = found.map { FindMarks(query: "passed", current: $0, rows: rows).mark(for: rows[0])?.highlight.current }
        #expect(currents.map { $0?.text } == ["passed", "passed", "passed"])
        #expect(currents.map { $0?.piece } == [3, 5, 7])
    }

    @Test func theLineOfTheCurrentHitIsWhereItsBlockScrollsTo() {
        let output = (1...300).map { "row \($0)" }.joined(separator: "\n")
        var highlight = TextHighlight(query: "row 2")
        // "row 2" itself, then "row 20" to "row 29": the third hit is in the 21st line.
        highlight.current = .init(text: output, occurrence: 2)
        #expect(highlight.currentLine(in: output) == 20)
        // Another block's text is not this one's hit, and a search without a current hit has none.
        #expect(highlight.currentLine(in: "row 2\nrow 20") == nil)
        #expect(TextHighlight(query: "row 2").currentLine(in: output) == nil)

        // Line 20 of a block that shows eleven lines comes to rest in its middle.
        let offset = CodeBlockScroll.offset(centering: 20, padding: 10, blockHeight: 200)
        let lineTop = 10 + 20 * ChatMetrics.codeLineHeight
        #expect(lineTop - offset == (200 - ChatMetrics.codeLineHeight) / 2)
        // The first lines cannot be centered; the block stays at its top.
        #expect(CodeBlockScroll.offset(centering: 1, padding: 10, blockHeight: 200) == 0)
    }
}

@Suite
struct FindKeysTests {
    @Test func returnWalksBackThroughTheConversationAndShiftReturnForward() {
        // A search starts on the newest hit, so Return goes on to the one before it.
        #expect(FindKeys.action(forCommand: "insertNewline:", isShiftDown: false) == .previous)
        #expect(FindKeys.action(forCommand: "insertNewline:", isShiftDown: true) == .next)
        #expect(FindKeys.action(forCommand: "insertLineBreak:", isShiftDown: false) == .previous)
        #expect(FindKeys.action(forCommand: "insertNewlineIgnoringFieldEditor:", isShiftDown: true) == .next)
    }

    @Test func voiceOverIsToldOfAnAnswerAndOfAStepButNotOfHitsStreamingIn() {
        func key(_ query: String, _ index: Int?, _ count: Int, upToDate: Bool = true) -> FindKeys.Announcement? {
            FindKeys.Announcement(query: query, currentIndex: index, count: count, isUpToDate: upToDate)
        }
        // Nothing to say while the answer is on its way or the field holds nothing.
        #expect(key("login", 2, 3, upToDate: false) == nil)
        #expect(key(" ", nil, 0) == nil)
        // An answer, a step and "no matches" each change it.
        #expect(key("login", 2, 3) != nil)
        #expect(key("login", 2, 3) != key("login", 1, 3))
        #expect(key("login", nil, 0) != key("logi", nil, 0))
        // A reply that streams in more hits behind the current one does not.
        #expect(key("login", 2, 3) == key("login", 2, 7))
    }

    @Test func escapeClosesAndEverythingElseIsTheFields() {
        #expect(FindKeys.action(forCommand: "cancelOperation:", isShiftDown: false) == .close)
        #expect(FindKeys.action(forCommand: "moveLeft:", isShiftDown: false) == nil)
        #expect(FindKeys.action(forCommand: "deleteBackward:", isShiftDown: true) == nil)
    }

    @Test func theCountSaysWhereTheSearchIs() {
        #expect(FindKeys.status(query: "a", currentIndex: 2, count: 17, isUpToDate: true) == "3 of 17")
        #expect(FindKeys.status(query: "", currentIndex: nil, count: 0, isUpToDate: true) == nil)
        #expect(FindKeys.status(query: "a", currentIndex: nil, count: 0, isUpToDate: true) == "Not Found")
        #expect(FindKeys.spokenStatus(query: "a", currentIndex: 2, count: 17, isUpToDate: true) == "Match 3 of 17")
        #expect(FindKeys.spokenStatus(query: "a", currentIndex: nil, count: 0, isUpToDate: true) == "No matches")
    }

    @Test func aSearchUnderWayKeepsTheLastCountAndNeverSaysNotFound() {
        #expect(FindKeys.status(query: "ab", currentIndex: 2, count: 17, isUpToDate: false) == "3 of 17")
        #expect(FindKeys.status(query: "ab", currentIndex: nil, count: 0, isUpToDate: false) == nil)
        #expect(FindKeys.spokenStatus(query: "ab", currentIndex: nil, count: 0, isUpToDate: false) == nil)
    }
}

@MainActor @Suite
struct ChatFindModelTests {
    private let items: [ChatItem] = [
        user("u1", "Fix the login"),
        thought("t1", "The login form validates too little"),
        agent("m1", "The **login** form now rejects an empty password."),
        user("u2", "Thanks"),
    ]

    private func model(searching query: String) async -> ChatFindModel {
        let find = ChatFindModel(delay: .zero)
        find.present()
        find.query = query
        find.search(items, workingDirectory: nil)
        await find.settle()
        return find
    }

    @Test func aNewSearchStartsOnTheNewestHitAndShowsIt() async {
        let find = await model(searching: "login")
        #expect(find.matches.map(\.itemID) == ["u1", "t1", "m1"])
        #expect(find.currentIndex == 2)
        #expect(find.current?.itemID == "m1")
        #expect(find.isUpToDate)
        #expect(find.revealRequests == 1)
    }

    @Test func steppingMovesThroughTheHitsAndAsksForEachToBeShown() async {
        let find = await model(searching: "login")
        find.step(forward: false)
        #expect(find.current?.itemID == "t1")
        find.step(forward: false)
        find.step(forward: false)
        #expect(find.current?.itemID == "m1")
        find.step(forward: true)
        #expect(find.current?.itemID == "u1")
        #expect(find.revealRequests == 5)
    }

    @Test func nothingFoundLeavesNothingToStepTo() async {
        let find = await model(searching: "logout")
        #expect(find.matches.isEmpty)
        #expect(find.currentIndex == nil)
        find.step(forward: true)
        #expect(find.revealRequests == 0)
    }

    @Test func clearingTheFieldClearsTheHitsAtOnce() async {
        let find = await model(searching: "login")
        find.query = " "
        #expect(find.matches.isEmpty)
        #expect(find.currentIndex == nil)
        #expect(find.isUpToDate)
    }

    @Test func aChangedStringIsNotAnsweredByTheOldHits() async {
        let find = await model(searching: "login")
        find.query = "password"
        #expect(!find.isUpToDate)
        // Stepping waits for the new answer instead of moving through the old one.
        find.step(forward: true)
        #expect(find.revealRequests == 1)
        find.search(items, workingDirectory: nil)
        await find.settle()
        #expect(find.matches.map(\.itemID) == ["m1"])
        #expect(find.revealRequests == 2)
    }

    @Test func hitsThatStreamInAreCountedWithoutMovingTheReader() async {
        let find = await model(searching: "login")
        find.step(forward: false)
        let reveals = find.revealRequests
        find.search(items + [agent("m2", "Also covered the login tests.")], workingDirectory: nil)
        await find.settle()
        #expect(find.matches.count == 4)
        #expect(find.current?.itemID == "t1")
        #expect(find.revealRequests == reveals)
    }

    @Test func closingKeepsTheStringAndComingBackShowsTheNewestHitOnTheFirstStep() async {
        let find = await model(searching: "login")
        find.step(forward: false)
        find.dismiss()
        #expect(!find.isPresented)
        #expect(find.query == "login")
        #expect(find.matches.isEmpty)

        find.present()
        find.search(items, workingDirectory: nil)
        await find.settle()
        // Back with its string, it marks the hits but leaves the reader where they are.
        let reveals = find.revealRequests
        #expect(find.current?.itemID == "m1")
        // The first step shows the hit it is on; only the next one moves on.
        find.step(forward: true)
        #expect(find.current?.itemID == "m1")
        #expect(find.revealRequests == reveals + 1)
        find.step(forward: true)
        #expect(find.current?.itemID == "u1")
    }

    @Test func steppingWithTheBarClosedOpensItAndShowsTheFirstHit() async {
        let find = ChatFindModel(delay: .zero)
        find.query = "login"
        find.step(forward: true)
        #expect(find.isPresented)
        find.search(items, workingDirectory: nil)
        await find.settle()
        #expect(find.current?.itemID == "m1")
        #expect(find.revealRequests == 1)
    }

    @Test func anItemThatDidNotChangeIsNotSearchedAgainForTheSameString() async {
        let index = ChatFindIndex()
        #expect(await index.matches(of: "login", in: items, workingDirectory: nil).map(\.itemID) == ["u1", "t1", "m1"])
        #expect(await index.searchedItems == items.count)
        // A reply streams in: only the item that grew is looked through.
        var grown = items
        grown.append(agent("m2", "Also covered the login"))
        #expect(await index.matches(of: "login", in: grown, workingDirectory: nil).count == 4)
        #expect(await index.searchedItems == 1)
        grown[4] = agent("m2", "Also covered the login tests, and the login form.")
        #expect(await index.matches(of: "login", in: grown, workingDirectory: nil).count == 5)
        #expect(await index.searchedItems == 1)
        // Another string asks every item again.
        #expect(await index.matches(of: "form", in: grown, workingDirectory: nil).count == 3)
        #expect(await index.searchedItems == grown.count)
    }

    @Test func aClosedBarSearchesNothing() async {
        let find = ChatFindModel(delay: .zero)
        find.query = "login"
        find.search(items, workingDirectory: nil)
        await find.settle()
        #expect(find.matches.isEmpty)
    }

    @Test func eachRequestForTheKeyboardIsAnsweredOnce() {
        let find = ChatFindModel(delay: .zero)
        #expect(!find.takeFocusRequest())
        find.present()
        #expect(find.takeFocusRequest())
        #expect(!find.takeFocusRequest())
        find.present()
        #expect(find.takeFocusRequest())
    }

    @Test func aSessionWithNothingOnScreenHasNothingToFind() {
        let empty = ChatSession(previewAgentName: "Agent", phase: .ready)
        #expect(!empty.canFind)
        #expect(!empty.showFind())
        #expect(!empty.viewState.find.isPresented)

        var transcript = ChatTranscript()
        transcript.appendUserPrompt([.text("Fix the login")])
        let chat = ChatSession(previewAgentName: "Agent", phase: .ready, transcript: transcript)
        #expect(chat.showFind())
        #expect(chat.viewState.find.isPresented)
        let focusRequests = chat.composerFocusRequests
        chat.dismissFind()
        #expect(!chat.viewState.find.isPresented)
        // Closing hands the keyboard back to the composer.
        #expect(chat.composerFocusRequests == focusRequests + 1)
    }
}
