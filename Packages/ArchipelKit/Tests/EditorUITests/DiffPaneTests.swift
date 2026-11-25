import AppKit
import GitKit
import Testing
@testable import EditorUI

private func diff(_ lines: [GitDiffLine], oldStart: Int = 1, newStart: Int = 1) -> GitFileDiff {
    let old = lines.filter { $0.kind != .added }.count
    let new = lines.filter { $0.kind != .removed }.count
    return GitFileDiff(oldPath: "a", newPath: "a", status: .modified, hunks: [
        GitDiffHunk(oldStart: oldStart, oldCount: old, newStart: newStart, newCount: new, lines: lines),
    ])
}

/// Old: a b c d. New: a B d e. Side by side: a | b/B | c/- | d | -/e.
private let small = DiffDocument(diff: diff([
    GitDiffLine(.context, "a"),
    GitDiffLine(.removed, "b"),
    GitDiffLine(.removed, "c"),
    GitDiffLine(.added, "B"),
    GitDiffLine(.context, "d"),
    GitDiffLine(.added, "e"),
]))

/// 40 unchanged lines with one change after the 20th, so there is a fold on each side of it.
private func long(change: String = "new", prepended: [String] = []) -> DiffDocument {
    var lines = prepended.map { GitDiffLine(.added, $0) }
    lines += (1...40).map { GitDiffLine(.context, "line \($0)") }
    lines.insert(GitDiffLine(.added, change), at: prepended.count + 20)
    return DiffDocument(diff: diff(lines))
}

@MainActor
struct DiffPaneTextTests {
    @Test func selectedTextReadsLikeThePane() {
        let sideBySide = DiffLayout(document: small, unified: false, showsAllLines: true)
        let start = DiffTextPosition(row: 0, column: 0)
        #expect(DiffPaneText.text(from: start, to: DiffPaneText.end(of: sideBySide, role: .old)!, in: sideBySide, role: .old) == "a\nb\nc\nd")
        // Filler rows add nothing, not even an empty line.
        #expect(DiffPaneText.text(from: start, to: DiffPaneText.end(of: sideBySide, role: .new)!, in: sideBySide, role: .new) == "a\nB\nd\ne")
        #expect(DiffPaneText.text(from: DiffTextPosition(row: 1, column: 0), to: DiffTextPosition(row: 3, column: 1), in: sideBySide, role: .old) == "b\nc\nd")
        #expect(DiffPaneText.text(from: DiffTextPosition(row: 3, column: 1), to: DiffTextPosition(row: 3, column: 1), in: sideBySide, role: .old) == "")

        let unified = DiffLayout(document: small, unified: true, showsAllLines: true)
        #expect(DiffPaneText.text(from: start, to: DiffPaneText.end(of: unified, role: .unified)!, in: unified, role: .unified) == "a\nb\nc\nB\nd\ne")
    }

    @Test func aSelectionAcrossAFoldTakesTheFoldedLinesToo() {
        let layout = DiffLayout(document: long(), unified: true, showsAllLines: false)
        #expect(layout.items.first == .fold(0..<17))
        let text = DiffPaneText.text(from: DiffTextPosition(row: 15, column: 5), to: DiffTextPosition(row: 18, column: 4), in: layout, role: .unified)
        #expect(text == "16\nline 17\nline 18\nline")
    }

    @Test func aDoubleClickTakesTheWord() {
        #expect(DiffPaneText.word(in: "let total_count = 1", at: 6) == 4..<15)
        #expect(DiffPaneText.word(in: "a + b", at: 2) == 2..<3)
        #expect(DiffPaneText.word(in: "end", at: 99) == 0..<3)
        #expect(DiffPaneText.word(in: "", at: 0) == 0..<0)
    }

    @Test func voiceOverHearsWhichLinesWereAddedOrRemoved() {
        let unified = DiffLayout(document: small, unified: true, showsAllLines: true)
        let text = DiffPaneText.accessible(unified, role: .unified)
        #expect(text.string == "a\nRemoved: b\nRemoved: c\nAdded: B\nd\nAdded: e")
        #expect(text.line(containing: 0) == 0)
        #expect(text.line(containing: 3) == 1)
        #expect(text.range(ofLine: 1) == NSRange(location: 2, length: 11))
        #expect(text.range(ofLine: 5) == NSRange(location: 35, length: 8))
        // Columns count in the line's own text, after its prefix.
        #expect(text.offset(item: 1, column: 1) == 2 + 9 + 1)

        let old = DiffPaneText.accessible(DiffLayout(document: small, unified: false, showsAllLines: true), role: .old)
        #expect(old.string == "a\nRemoved: b\nRemoved: c\nd\n")

        let folded = DiffPaneText.accessible(DiffLayout(document: long(), unified: true, showsAllLines: false), role: .unified)
        #expect(folded.string.hasPrefix("17 unchanged lines hidden\nline 18\n"))
    }
}

struct DiffFoldingAcrossRefreshesTests {
    @Test func unfoldedLinesSurviveANewVersionOfTheDiff() {
        let first = long()
        var items = DiffFolding.items(for: first.unified)
        #expect(items.first == .fold(0..<17))
        items = DiffFolding.expanding(items, at: 0)
        let unfolded = DiffFolding.unfoldedLines(items, rows: first.unified, document: first)
        #expect(unfolded.count == 17)

        // The agent adds two lines at the top: new line numbers shift, the old side does not.
        let second = long(change: "newer", prepended: ["x", "y"])
        let keeping = DiffFolding.rows(showing: unfolded, in: second.unified, document: second)
        let refreshed = DiffFolding.items(for: second.unified, keeping: keeping)
        #expect(!refreshed.contains { if case .fold(let range) = $0 { range.lowerBound < 20 } else { false } })
        // The fold after the change is untouched.
        #expect(refreshed.last == DiffFolding.items(for: second.unified).last)
    }

    @Test func aLineThatChangedIsNotKeptOpen() {
        let first = long()
        let unfolded = DiffFolding.unfoldedLines(DiffFolding.allRows(first.unified), rows: first.unified, document: first)
        let edited = DiffDocument(diff: diff((1...40).map { GitDiffLine(.context, $0 == 2 ? "rewritten" : "line \($0)") } + [GitDiffLine(.added, "end")]))
        let keeping = DiffFolding.rows(showing: unfolded, in: edited.unified, document: edited)
        #expect(!keeping.contains(1))
        #expect(keeping.contains(0))
    }

    @Test func theLineAtTheTopIsFoundAgainAfterLinesAreAddedAbove() {
        let first = long()
        let items = DiffFolding.allRows(first.unified)
        let anchor = DiffFolding.anchor(at: 10, in: items, rows: first.unified, document: first)
        #expect(anchor == DiffLineAnchor(side: .old, line: 11))

        let second = long(prepended: ["x", "y", "z"])
        let secondItems = DiffFolding.allRows(second.unified)
        #expect(DiffFolding.item(showing: anchor!, in: secondItems, rows: second.unified, document: second) == 13)
        // Inside a fold it is the fold, here the one after the added lines and their context.
        let folded = DiffFolding.items(for: second.unified)
        #expect(DiffFolding.item(showing: anchor!, in: folded, rows: second.unified, document: second) == 6)
        // An added line has no old number and is found by its new one.
        let added = DiffFolding.anchor(at: 1, in: secondItems, rows: second.unified, document: second)
        #expect(added == DiffLineAnchor(side: .new, line: 2))
        #expect(DiffFolding.item(showing: added!, in: secondItems, rows: second.unified, document: second) == 1)
    }
}

@MainActor
struct DiffPaneViewTests {
    /// A pane in a scroll view, the way the container hosts it.
    private func host(_ layout: DiffLayout, role: DiffPaneRole, height: CGFloat = 200) -> (DiffPaneView, NSScrollView) {
        let pane = DiffPaneView(role: role)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        scrollView.documentView = pane
        pane.layoutState = layout
        pane.updateSize()
        return (pane, scrollView)
    }

    @Test func selectAllTakesTheWholeSideAndANewLayoutClearsItOnlyWhenItsLinesChanged() {
        let layout = DiffLayout(document: small, unified: false, showsAllLines: true)
        let (pane, _) = host(layout, role: .new)
        #expect(pane.selectedRange == nil)
        pane.selectAll(nil)
        #expect(pane.selectedText == "a\nB\nd\ne")
        // Highlights arriving set the same layout again, which keeps the selection.
        pane.layoutState = layout
        #expect(pane.selectedText == "a\nB\nd\ne")
        // The poll's next version of an unchanged diff keeps it too.
        pane.layoutState = DiffLayout(document: small, unified: false, showsAllLines: true)
        #expect(pane.selectedText == "a\nB\nd\ne")

        let rewritten = DiffDocument(diff: diff([GitDiffLine(.context, "a"), GitDiffLine(.removed, "b"), GitDiffLine(.added, "X")]))
        pane.layoutState = DiffLayout(document: rewritten, unified: false, showsAllLines: true)
        #expect(pane.selectedRange == nil)
    }

    @Test func aSelectionFollowsItsLinesThroughARefresh() throws {
        let first = DiffLayout(document: long(), unified: true, showsAllLines: true)
        // Clicked on the line after "line 4" and dragged backwards to the middle of "line 3".
        let anchor = DiffTextPosition(row: 4, column: 0)
        let head = DiffTextPosition(row: 2, column: 5)
        let carried = try #require(DiffPaneText.carry((anchor, head), from: first, to: first, role: .unified))
        #expect(carried.anchor == anchor && carried.head == head)

        // The agent adds two lines at the top: the same lines now sit two rows further down.
        let second = DiffLayout(document: long(prepended: ["x", "y"]), unified: true, showsAllLines: true)
        let moved = try #require(DiffPaneText.carry((anchor, head), from: first, to: second, role: .unified))
        #expect(moved.anchor == DiffTextPosition(row: 6, column: 0))
        #expect(moved.head == DiffTextPosition(row: 4, column: 5))
        #expect(DiffPaneText.text(from: moved.head, to: moved.anchor, in: second, role: .unified) == "3\nline 4\n")

        // A line inside the selection was rewritten: nothing to carry.
        let edited = DiffDocument(diff: diff((1...40).map { GitDiffLine(.context, $0 == 4 ? "rewritten" : "line \($0)") } + [GitDiffLine(.added, "end")]))
        #expect(DiffPaneText.carry((anchor, head), from: first, to: DiffLayout(document: edited, unified: true, showsAllLines: true), role: .unified) == nil)
        // A line added between the ends changes what is selected, so that is dropped as well.
        var inserted = (1...40).map { GitDiffLine(.context, "line \($0)") }
        inserted.insert(GitDiffLine(.added, "between"), at: 3)
        #expect(DiffPaneText.carry((anchor, head), from: first, to: DiffLayout(document: DiffDocument(diff: diff(inserted)), unified: true, showsAllLines: true), role: .unified) == nil)
    }

    @Test func aSelectionStartingOnFillerIsCarriedFromTheLineAfterIt() throws {
        let sideBySide = DiffLayout(document: small, unified: false, showsAllLines: true)
        // On the new side row 2 is filler (c was removed), so this selects just the "d" of row 3.
        let selection = (anchor: DiffTextPosition(row: 2, column: 0), head: DiffTextPosition(row: 3, column: 1))
        let carried = try #require(DiffPaneText.carry(selection, from: sideBySide, to: sideBySide, role: .new))
        #expect(carried.anchor == DiffTextPosition(row: 3, column: 0))
        #expect(carried.head == DiffTextPosition(row: 3, column: 1))
    }

    @Test func aPointMapsToTheCharacterUnderIt() {
        let layout = DiffLayout(document: small, unified: false, showsAllLines: true)
        let (pane, _) = host(layout, role: .old)
        let row = EditorTheme.lineHeight
        let x = DiffLineRenderer.textInset
        #expect(pane.textPosition(at: NSPoint(x: 0, y: row * 1.5), in: layout) == DiffTextPosition(row: 1, column: 0))
        #expect(pane.textPosition(at: NSPoint(x: x + 300, y: row * 2.5), in: layout) == DiffTextPosition(row: 2, column: 1))
        // Above the text is its start, below it its end.
        #expect(pane.textPosition(at: NSPoint(x: 50, y: -5), in: layout) == DiffTextPosition(row: 0, column: 0))
        #expect(pane.textPosition(at: NSPoint(x: 50, y: row * 40), in: layout) == DiffTextPosition(row: 4, column: 0))
    }

    @Test func keysScrollThePane() {
        let layout = DiffLayout(document: long(), unified: true, showsAllLines: true)
        let (pane, scrollView) = host(layout, role: .unified)
        let clip = scrollView.contentView
        pane.moveDown(nil)
        #expect(clip.bounds.minY == EditorTheme.lineHeight)
        pane.moveUp(nil)
        #expect(clip.bounds.minY == 0)
        pane.scrollPageDown(nil)
        #expect(clip.bounds.minY == clip.bounds.height - EditorTheme.lineHeight * 2)
        pane.scrollToEndOfDocument(nil)
        #expect(clip.bounds.maxY == pane.frame.maxY)
        pane.scrollToBeginningOfDocument(nil)
        #expect(clip.bounds.minY == 0)
    }

    @Test func foldsCanBeOpenedThroughAccessibility() throws {
        let layout = DiffLayout(document: long(), unified: true, showsAllLines: false)
        let (pane, _) = host(layout, role: .unified)
        var expanded: [Int] = []
        pane.onExpandFold = { expanded.append($0) }
        let actions = try #require(pane.accessibilityCustomActions())
        #expect(actions.map(\.name) == ["Show 17 unchanged lines from line 1", "Show 17 unchanged lines from line 24"])
        #expect(actions[1].handler?() == true)
        #expect(expanded == [layout.items.count - 1])

        #expect((pane.accessibilityValue() as? String)?.hasPrefix("17 unchanged lines hidden\n") == true)
        #expect(pane.accessibilityNumberOfCharacters() == (pane.accessibilityValue() as? String)?.utf16.count)
        #expect(pane.accessibilityLine(for: 30) == 1)
    }

    @Test func aFoldActionStillOpensItsOwnFoldAfterAnEarlierOneOpened() throws {
        let layout = DiffLayout(document: long(), unified: true, showsAllLines: false)
        let (pane, _) = host(layout, role: .unified)
        var expanded: [Int] = []
        pane.onExpandFold = { index in
            expanded.append(index)
            layout.items = DiffFolding.expanding(layout.items, at: index)
        }
        let actions = try #require(pane.accessibilityCustomActions())
        let lastFold = try #require(layout.items.last)
        #expect(actions[0].handler?() == true)
        // VoiceOver still holds the action it was given before the first fold opened and moved
        // every item after it.
        #expect(actions[1].handler?() == true)
        #expect(expanded == [0, layout.items.count - 17])
        #expect(!layout.items.contains(lastFold))
        // Already open: there is nothing left for it to do.
        #expect(actions[1].handler?() == false)
    }

    @Test func foldActionsNameTheLineByThePanesOwnSide() throws {
        // The added line after the 20th shifts every later line by one on the new side.
        let layout = DiffLayout(document: long(), unified: false, showsAllLines: false)
        let (old, _) = host(layout, role: .old)
        let (new, _) = host(layout, role: .new)
        #expect(try #require(old.accessibilityCustomActions()).map(\.name).last == "Show 17 unchanged lines from line 24")
        #expect(try #require(new.accessibilityCustomActions()).map(\.name).last == "Show 17 unchanged lines from line 25")
    }

    @Test func clicksInAnEmptyLayoutDoNothing() throws {
        let empty = DiffDocument(diff: diff([]))
        let layout = DiffLayout(document: empty, unified: false, showsAllLines: false)
        #expect(layout.rows.isEmpty)
        let (pane, _) = host(layout, role: .new)
        for clicks in 1...3 {
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 20, y: 5), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            ))
            pane.mouseDown(with: event)
            pane.mouseUp(with: event)
        }
        #expect(pane.selectedRange == nil)
    }

    @Test func tabMovesTheKeyboardFocusOutOfThePane() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let layout = DiffLayout(document: small, unified: false, showsAllLines: true)
        let before = DiffPaneView(role: .old)
        let pane = DiffPaneView(role: .new)
        let after = DiffPaneView(role: .old)
        for (index, view) in [before, pane, after].enumerated() {
            view.frame = NSRect(x: CGFloat(index) * 100, y: 0, width: 100, height: 100)
            view.layoutState = layout
            window.contentView?.addSubview(view)
        }
        before.nextKeyView = pane
        pane.nextKeyView = after

        window.makeFirstResponder(pane)
        pane.keyDown(with: try key("\t", code: 48))
        #expect(window.firstResponder === after)

        window.makeFirstResponder(pane)
        pane.keyDown(with: try key("\u{19}", code: 48, modifiers: .shift))
        #expect(window.firstResponder === before)
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }
}

@MainActor
struct DiffContainerRefreshTests {
    private func panes(in container: DiffContainerView) -> [DiffPaneView] {
        container.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? DiffPaneView }
    }

    @Test func aNewVersionKeepsOpenedFoldsAndTheLineAtTheTop() throws {
        let container = DiffContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 120))
        container.configure(document: long(), version: 1, presentation: .inline, showsAllLines: false, highlights: nil)
        container.layoutSubtreeIfNeeded()
        let pane = try #require(panes(in: container).first)
        pane.onExpandFold?(0)
        let layout = try #require(pane.layoutState)
        #expect(layout.items.first == .row(0))

        // Scroll so that old line 10 sits at the top, a little way into it.
        let clip = try #require(pane.enclosingScrollView?.contentView)
        clip.setBoundsOrigin(NSPoint(x: 0, y: EditorTheme.lineHeight * 9 + 3))

        container.configure(document: long(prepended: ["x", "y"]), version: 2, presentation: .inline, showsAllLines: false, highlights: nil)
        let refreshed = try #require(pane.layoutState)
        #expect(refreshed !== layout)
        #expect(refreshed.items.prefix(19) == (0..<19).map(DiffDisplayItem.row)[...])
        // Two lines were added above, so the same line is two rows further down.
        #expect(clip.bounds.minY == EditorTheme.lineHeight * 11 + 3)
    }
}
