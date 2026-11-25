@testable import EditorUI
import Foundation
import SwiftUI
import Testing

@Suite
struct TextHighlightTests {
    private func marked(_ text: AttributedString) -> [String] {
        text.runs.filter { $0.backgroundColor != nil }.map { String(text[$0.range].characters) }
    }

    private func current(_ text: AttributedString) -> [String] {
        text.runs.filter { $0.backgroundColor == TextHighlight.currentColor }.map { String(text[$0.range].characters) }
    }

    @Test func findsEveryHitIgnoringCaseAndAccents() {
        let text = "Login, login and LÓGIN"
        let ranges = TextHighlight.ranges(of: "login", in: text)
        #expect(ranges.map { String(text[$0]) } == ["Login", "login", "LÓGIN"])
        #expect(TextHighlight.ranges(of: "", in: text).isEmpty)
        #expect(TextHighlight.ranges(of: "x", in: "").isEmpty)
        #expect(TextHighlight.ranges(of: "aa", in: "aaa").count == 1)
    }

    @Test func marksEveryHitAndLeavesTheRestAlone() {
        let text = TextHighlight(query: "an").apply(to: "An apple and a banner")
        #expect(marked(text) == ["An", "an", "an"])
        #expect(current(text).isEmpty)
        #expect(String(text.characters) == "An apple and a banner")
    }

    @Test func theCurrentHitIsToldByItsTextAndItsNumber() {
        let highlight = TextHighlight(query: "an", current: .init(text: "An apple and a banner", occurrence: 1))
        let text = highlight.apply(to: "An apple and a banner")
        #expect(current(text) == ["an"])
        #expect(marked(text) == ["An", "an", "an"])
        let run = text.runs.first { $0.backgroundColor == TextHighlight.currentColor }
        #expect(run?.foregroundColor == .black)
        #expect(run.map { String(text[$0.range].characters) + String(text[$0.range.upperBound...].characters.prefix(1)) } == "and")
        // Another piece of text has hits of its own, but none of them is the current one.
        #expect(current(highlight.apply(to: "A banner and a plan")).isEmpty)
        #expect(marked(highlight.apply(to: "A banner and a plan")) == ["an", "an", "an"])
    }

    @Test func attributesTheTextAlreadyHasAreKept() {
        var source = AttributedString("bold login")
        source[source.range(of: "bold")!].inlinePresentationIntent = .stronglyEmphasized
        let text = TextHighlight(query: "login").apply(to: source)
        #expect(text.runs.first?.inlinePresentationIntent == .stronglyEmphasized)
        #expect(marked(text) == ["login"])
        // A hit that reaches across two styles is still one hit.
        #expect(marked(TextHighlight(query: "d l").apply(to: source)).joined() == "d l")
    }

    @Test func textWithoutAHitComesBackUnchanged() {
        let source = AttributedString("nothing here")
        #expect(TextHighlight(query: "login").apply(to: source) == source)
    }

    @Test func ofPiecesThatReadAlikeOnlyTheOneAtTheHitsPlaceIsCurrent() {
        // A column that says "passed" in every row: three pieces with the same text.
        let highlight = TextHighlight(query: "passed", current: .init(text: "passed", occurrence: 0, piece: 5))
        let cells = [3, 5, 7].map { current(highlight.apply(to: AttributedString("passed"), piece: $0)) }
        #expect(cells == [[], ["passed"], []])
        // Every cell still marks its hit.
        #expect(marked(highlight.apply(to: AttributedString("passed"), piece: 3)) == ["passed"])
        // A view that does not know its place goes by the text, as does a hit without a place.
        #expect(current(highlight.apply(to: AttributedString("passed"))) == ["passed"])
        let unplaced = TextHighlight(query: "passed", current: .init(text: "passed", occurrence: 0))
        #expect(current(unplaced.apply(to: AttributedString("passed"), piece: 3)) == ["passed"])
    }

    @Test func theViewsNumberTheirPiecesTheWayTheSearchCountsThem() {
        let sources = [
            MarkdownSamples.kitchenSink,
            "| A | B |\n|---|---|\n| yes | yes |\n| yes | no |\n\nafter",
            "> quote\n>\n> - one\n> - two\n\n1. first\n   - nested\n2. second\n\n---\n\n```\ncode\n```",
            "",
        ]
        for source in sources {
            let blocks = MarkdownDocument.parse(source)
            #expect(MarkdownBlock.pieceCount(of: blocks) == MarkdownText.searchableText(of: source).count)
        }
        // A table's cells follow each other row by row, the header first; the paragraph behind
        // the table comes after all of them.
        let blocks = MarkdownDocument.parse(sources[1])
        #expect(blocks.map(\.pieceCount) == [6, 1])
        #expect(MarkdownText.searchableText(of: sources[1]) == ["A", "B", "yes", "yes", "yes", "no", "after"])
    }

    @Test func searchableTextIsWhatMarkdownTextDraws() {
        let pieces = MarkdownText.searchableText(of: """
        # A **bold** heading

        Some `code` and a [link](https://example.com).

        - first
        - second
          > quoted

        | Name | Value |
        |------|-------|
        | one  | 1     |

        ```swift
        let x = 1
        ```

        ---
        """)
        #expect(pieces == [
            "A bold heading", "Some code and a link.", "first", "second", "quoted", "Name", "Value", "one", "1", "let x = 1",
        ])
        #expect(MarkdownText.searchableText(of: "").isEmpty)
    }
}
