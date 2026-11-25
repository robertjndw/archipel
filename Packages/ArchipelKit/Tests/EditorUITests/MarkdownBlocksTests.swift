import Foundation
import Testing
@testable import EditorUI

struct MarkdownBlocksTests {
    // MARK: Blocks

    @Test func parsesEachBlockKind() throws {
        let blocks = MarkdownDocument.parse("""
            # Title

            Some text.

            > quoted

            ---

            ```swift title="a.swift"
            let x = 1
            ```

                indented
            """)
        try #require(blocks.count == 6)
        #expect(blocks.map(\.id) == Array(0..<6))
        #expect(blocks[0].kind == .heading(level: 1, text: AttributedString("Title")))
        #expect(blocks[1].kind == .paragraph(AttributedString("Some text.")))
        #expect(blocks[2].kind == .blockQuote([MarkdownBlock(id: 0, kind: .paragraph(AttributedString("quoted")))]))
        #expect(blocks[3].kind == .thematicBreak)
        #expect(blocks[4].kind == .codeBlock(language: "swift", code: "let x = 1"))
        #expect(blocks[5].kind == .codeBlock(language: nil, code: "indented"))
    }

    @Test func headingLevels() {
        let levels = MarkdownDocument.parse("# a\n## b\n### c\n#### d\n").map { block -> Int? in
            if case .heading(let level, _) = block.kind { level } else { nil }
        }
        #expect(levels == [1, 2, 3, 4])
    }

    @Test func htmlStaysLiteral() {
        let blocks = MarkdownDocument.parse("<div class=\"x\">\nhi\n</div>\n\nA <b>bold</b> claim.\n")
        #expect(blocks.map(\.kind) == [
            .paragraph(AttributedString("<div class=\"x\">\nhi\n</div>")),
            .paragraph(AttributedString("A <b>bold</b> claim.")),
        ])
    }

    @Test func keepsPunctuationAsTyped() {
        #expect(MarkdownDocument.parse("Use --force and \"quotes\" -- or not.").first?.kind
            == .paragraph(AttributedString("Use --force and \"quotes\" -- or not.")))
    }

    // MARK: Inlines

    @Test func inlineAttributesLandOnTheirRanges() throws {
        let text = try paragraph("a **bold** b *it* c ~~gone~~ d `code` e [link](https://example.com/x) f")
        #expect(String(text.characters) == "a bold b it c gone d code e link f")
        #expect(intent(of: "bold", in: text) == .stronglyEmphasized)
        #expect(intent(of: "it", in: text) == .emphasized)
        #expect(intent(of: "gone", in: text) == .strikethrough)
        #expect(intent(of: "code", in: text) == .code)
        let link = try #require(text.range(of: "link"))
        #expect(text[link].runs.count == 1)
        #expect(text[link].runs.first?.link == URL(string: "https://example.com/x"))
        // Nothing leaks onto the plain text around them.
        for plain in ["a ", " b ", " c ", " d ", " e ", " f"] {
            let range = try #require(text.range(of: plain))
            #expect(text[range].runs.allSatisfy { $0.inlinePresentationIntent == nil && $0.link == nil })
        }
    }

    @Test func nestedEmphasisCombines() throws {
        let text = try paragraph("***both*** and **bold `code`**")
        #expect(intent(of: "both", in: text) == [.emphasized, .stronglyEmphasized])
        #expect(intent(of: "code", in: text) == [.stronglyEmphasized, .code])
    }

    @Test func lineBreaksBecomeNewlines() throws {
        #expect(String(try paragraph("one\ntwo  \nthree\\\nfour").characters) == "one\ntwo\nthree\nfour")
    }

    @Test func imagesBecomeLinkedAltText() throws {
        let text = try paragraph("See ![the logo](art/logo.png).")
        #expect(String(text.characters) == "See the logo.")
        let range = try #require(text.range(of: "the logo"))
        #expect(text[range].runs.first?.link == URL(string: "art/logo.png"))
    }

    @Test func relativeLinksAreKeptForTheHostToResolve() throws {
        let text = try paragraph("[guide](docs/guide.md#setup)")
        #expect(text.runs.first?.link == URL(string: "docs/guide.md#setup"))
    }

    @Test func referenceLinksResolve() throws {
        let blocks = MarkdownDocument.parse("See [the docs][d].\n\n[d]: https://example.com\n")
        try #require(blocks.count == 1)
        guard case .paragraph(let text) = blocks[0].kind else { Issue.record("not a paragraph"); return }
        #expect(text.runs.contains { $0.link == URL(string: "https://example.com") })
    }

    // MARK: Lists

    @Test func nestedListsAndOrderedStart() throws {
        let blocks = MarkdownDocument.parse("""
            3. three
            4. four
               - nested
                 - deeper
            """)
        try #require(blocks.count == 1)
        guard case .orderedList(let start, let items) = blocks[0].kind else { Issue.record("not an ordered list"); return }
        #expect(start == 3)
        #expect(items.map(\.id) == [0, 1])
        #expect(items[0].blocks == [MarkdownBlock(id: 0, kind: .paragraph(AttributedString("three")))])
        try #require(items[1].blocks.count == 2)
        guard case .unorderedList(let nested) = items[1].blocks[1].kind else { Issue.record("not nested"); return }
        #expect(nested.count == 1)
        guard case .unorderedList(let deeper) = nested[0].blocks.last?.kind else { Issue.record("not deeper"); return }
        #expect(deeper[0].blocks == [MarkdownBlock(id: 0, kind: .paragraph(AttributedString("deeper")))])
    }

    @Test func taskListItems() throws {
        let blocks = MarkdownDocument.parse("- [x] done\n- [ ] todo\n- plain\n")
        guard case .unorderedList(let items) = blocks.first?.kind else { Issue.record("not a list"); return }
        #expect(items.map(\.checkbox) == [.checked, .unchecked, nil])
        #expect(items[0].blocks == [MarkdownBlock(id: 0, kind: .paragraph(AttributedString("done")))])
    }

    // MARK: Tables

    @Test func tablesWithAlignment() throws {
        let blocks = MarkdownDocument.parse("| A | B | C | D |\n|:--|:-:|--:|---|\n| 1 | **2** | 3 |\n| 5 | 6 | 7 | 8 |\n")
        guard case .table(let table) = blocks.first?.kind else { Issue.record("not a table"); return }
        #expect(table.alignments == [.leading, .center, .trailing, nil])
        #expect(table.header.map { String($0.characters) } == ["A", "B", "C", "D"])
        #expect(table.rows.map { $0.map { String($0.characters) } } == [["1", "2", "3", ""], ["5", "6", "7", "8"]])
        #expect(intent(of: "2", in: table.rows[0][1]) == .stronglyEmphasized)
    }

    @Test func emptyCellsStayEmptyRatherThanSpanning() throws {
        let blocks = MarkdownDocument.parse("| A | B | C |\n|---|---|---|\n| 1 || 3 |\n")
        guard case .table(let table) = blocks.first?.kind else { Issue.record("not a table"); return }
        #expect(table.rows.map { $0.map { String($0.characters) } } == [["1", "", "3"]])
    }

    // MARK: Incomplete text

    @Test func unclosedFenceShowsWhatArrived() {
        #expect(MarkdownDocument.parse("Intro\n\n```swift\nlet a = 1\n\nlet b").map(\.kind) == [
            .paragraph(AttributedString("Intro")),
            .codeBlock(language: "swift", code: "let a = 1\n\nlet b"),
        ])
    }

    @Test(arguments: ["Some **bold", "Some *it", "Some ~~gone", "Some `code", "Some [link](https://exa", "Some [link", "Some [link]("])
    func unfinishedInlinesArePlainText(_ source: String) throws {
        let text = try paragraph(source)
        #expect(String(text.characters) == source)
        #expect(text.runs.allSatisfy { $0.inlinePresentationIntent == nil && $0.link == nil })
    }

    @Test(arguments: ["| A | B |", "| A | B |\n", "| A | B |\n|--", "| A | B |\n|---|"])
    func partialTableIsTextUntilTheDelimiterRowIsComplete(_ source: String) {
        let blocks = MarkdownDocument.parse(source)
        #expect(blocks.count == 1)
        guard case .paragraph = blocks.first?.kind else {
            Issue.record("expected a paragraph for \(source.debugDescription), got \(blocks)")
            return
        }
    }

    @Test func completeDelimiterRowMakesATable() {
        guard case .table(let table) = MarkdownDocument.parse("| A | B |\n|---|--").first?.kind else {
            Issue.record("not a table")
            return
        }
        #expect(table.rows.isEmpty)
    }

    @Test func aLoneDashDoesNotTurnTheParagraphIntoAHeading() {
        #expect(MarkdownDocument.parse("Some text\n-").map(\.kind) == [.paragraph(AttributedString("Some text"))])
        #expect(MarkdownDocument.parse("Some text\r\n=").map(\.kind) == [.paragraph(AttributedString("Some text"))])
        // Once the line goes on or ends, it is whatever CommonMark says it is.
        guard case .unorderedList = MarkdownDocument.parse("Some text\n- item").last?.kind else {
            Issue.record("expected a list")
            return
        }
        #expect(MarkdownDocument.parse("Some text\n-\n").first?.kind == .heading(level: 2, text: AttributedString("Some text")))
        #expect(MarkdownDocument.parse("Some text\n--").first?.kind == .heading(level: 2, text: AttributedString("Some text")))
    }

    // MARK: Streaming

    @Test func appendingKeepsEarlierBlocksAndReparsesOnlyTheEnd() {
        var parser = MarkdownStreamParser()
        parser.update("# Title\n\nFirst paragraph.\n\nSecond")
        let before = parser.blocks
        parser.update("# Title\n\nFirst paragraph.\n\nSecond paragraph, longer")
        #expect(parser.fullParseCount == 0)
        #expect(Array(parser.blocks.prefix(2)) == Array(before.prefix(2)))
        #expect(parser.blocks.map(\.id) == [0, 1, 2])
        #expect(parser.blocks[2].kind == .paragraph(AttributedString("Second paragraph, longer")))
    }

    @Test func blockIdentitiesSurviveEveryAppend() {
        let text = StreamSamples.kitchenSink
        var parser = MarkdownStreamParser()
        var previous: [MarkdownBlock] = []
        var end = text.startIndex
        while end < text.endIndex {
            end = text.index(end, offsetBy: 7, limitedBy: text.endIndex) ?? text.endIndex
            let blocks = parser.update(String(text[..<end]))
            #expect(blocks.map(\.id) == Array(blocks.indices))
            // At most the last two blocks change: the open one, and one the unfinished line may
            // have started (`| ` after a table is a paragraph until it becomes `| 1 |`).
            let settled = max(previous.count - 2, 0)
            #expect(Array(blocks.prefix(settled)) == Array(previous.prefix(settled)))
            previous = blocks
        }
        #expect(parser.fullParseCount == 0)
    }

    @Test func editsOtherThanAppendsParseEverything() {
        var parser = MarkdownStreamParser()
        parser.update("one\n\ntwo")
        parser.update("one\n\nthree")
        #expect(parser.fullParseCount == 1)
        #expect(parser.blocks == MarkdownDocument.parse("one\n\nthree"))
    }

    @Test func referenceDefinitionsFallBackToFullParses() {
        var parser = MarkdownStreamParser()
        parser.update("See [x].\n\nMore text")
        parser.update("See [x].\n\nMore text\n\n[x]: https://example.com\n")
        #expect(parser.blocks == MarkdownDocument.parse("See [x].\n\nMore text\n\n[x]: https://example.com\n"))
        #expect(parser.fullParseCount == 1)
    }

    @Test(arguments: StreamSamples.all.indices, Array(UInt64(1)...6))
    func streamingInRandomChunksMatchesAFullParse(document: Int, seed: UInt64) {
        let text = StreamSamples.all[document]
        var generator = SplitMix64(seed: seed &* 0x9E37_79B9 &+ UInt64(document))
        var parser = MarkdownStreamParser()
        // Chunks are cut in UTF-8 bytes where possible, so a chunk can end between `\r` and `\n`.
        let bytes = Array(text.utf8)
        var end = 0
        while end < bytes.count {
            end = min(bytes.count, end + Int.random(in: 1...24, using: &generator))
            // Never inside a multi-byte character; a stream delivers whole characters.
            while end < bytes.count && bytes[end] & 0xC0 == 0x80 { end += 1 }
            let prefix = String(decoding: bytes[..<end], as: UTF8.self)
            let streamed = parser.update(prefix)
            let full = MarkdownDocument.parse(prefix)
            guard streamed == full else {
                Issue.record("Mismatch at \(end) of \(bytes.count) bytes, after \(prefix.suffix(40).debugDescription)")
                return
            }
        }
    }

    // MARK: Helpers

    private func paragraph(_ source: String) throws -> AttributedString {
        let blocks = MarkdownDocument.parse(source)
        try #require(blocks.count == 1)
        guard case .paragraph(let text) = blocks[0].kind else {
            Issue.record("not a paragraph: \(blocks[0])")
            return AttributedString()
        }
        return text
    }

    /// The single intent over `substring`, or nil when it is missing or mixed.
    private func intent(of substring: String, in text: AttributedString) -> InlinePresentationIntent? {
        guard let range = text.range(of: substring) else { return nil }
        let intents = Set(text[range].runs.map { $0.inlinePresentationIntent?.rawValue ?? 0 })
        guard intents.count == 1, let raw = intents.first, raw != 0 else { return nil }
        return InlinePresentationIntent(rawValue: raw)
    }
}

/// Small, fast and reproducible on every platform, unlike the system generator.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum StreamSamples {
    /// The same reply as the kitchen-sink preview.
    static let kitchenSink = #"""
    # Refactoring the session store

    I moved the persistence into `SessionStore` and kept the public API **unchanged**. A few
    *details* are worth a look, and the old ~~`legacyLoad()`~~ path is gone. See the
    [migration notes](https://example.com/notes) or `docs/sessions.md`.

    ## What changed

    1. Sessions are written atomically, through a temporary file.
    2. Loading tolerates a missing file:
       - an empty store is returned
       - a warning is logged once
         - nested a third level
    3. The cache is keyed by worktree path.

    Next, in a follow-up:

    9. Drop the old file format.
    10. Remove the migration flag.
    11. Delete `LegacySessionStore`.

    ### Checklist

    - [x] Unit tests for the store
    - [x] Migration from the old format
    - [ ] UI tests for the restore flow

    | Case | Before | After |
    |:-----|:------:|------:|
    | Cold launch | 420 ms | 180 ms |
    | Warm launch | 95 ms | 60 ms |
    | Restore 50 sessions | 2.1 s | 0.4 s |

    > Note: the store now refuses to load a file written by a newer version, instead of
    > silently dropping fields it does not know.

    ```swift
    struct SessionStore: Sendable {
        let url: URL

        func save(_ sessions: [Session]) throws {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: url, options: .atomic) // never half-written
        }
    }
    ```

    Run the tests with:

    ```sh
    swift test --filter SessionStoreTests --parallel
    ```

    ---

    That's all. Ask if anything is unclear.
    """#

    static let all = [kitchenSink, fencesWithMarkdownInside, listsAndQuotes, crlf, setextAndTables, oddities]

    /// Constructs whose meaning depends on lines further down, or that span lines.
    static let oddities = """
        Emphasis *that spans
        two lines* and a [link that
        wraps](https://example.com) and `code
        across lines`.
        Text then a list:
        1) one
        2) two
        7. starts at seven but cannot interrupt
        a paragraph

        - item

              indented code inside the item
        - > quote in a list
          > ```
          > fenced in a quote
          > ```

        <!-- a comment

        with a blank line inside -->

        <div>

        *not emphasis in html*

        </div>

            indented code
            after html

        | lone | header |
        not a delimiter

        > | quoted | table |
        > |--------|-------|
        > | a      | b     |

        Line with trailing backslash\\
        and a final line
        """

    static let fencesWithMarkdownInside = """
        Here is a file:

        ```markdown
        # Not a heading

        - not a list

        | not | a table |
        |-----|---------|

        ```

        And one with tildes and a longer fence:

        ~~~~python
        def f():

            return "```"
        ~~~~

        ````
        ```
        inner fence
        ```
        ````

        After the fences, **bold** text.
        """

    static let listsAndQuotes = """
        1. First item

           continued in a second paragraph
        2. Second item
           - nested *one*
           - nested two

             still nested
        3. Third

        - loose

        - list

        > Quote line one
        lazy continuation
        > > nested quote
        >
        > - list in quote

        Paragraph with a hard break
        and a soft one
        and `code`, emoji \u{1F600} and caf\u{0065}\u{0301}.
        """

    static let crlf = "# Title\r\n\r\nLine one\r\nline two\r\n\r\n```sh\r\necho hi\r\n\r\necho there\r\n```\r\n\r\n- a\r\n- b\r\n\r\n| x | y |\r\n|---|---|\r\n| 1 | 2 |\r\n\r\nEnd\r\n"

    static let setextAndTables = """
        Heading One
        ===========

        Some text
        - a list right after

        Heading Two
        -

        Paragraph then a table:
        | a | b |
        |---|:-:|
        | 1 | 2 |
        | 3 | 4 |
        not a row? yes it is

        ***

        - [ ] task
        - [x] done
        * other bullet
        + third bullet

        <details>
        <summary>raw html</summary>

        inside
        </details>
        """
}
