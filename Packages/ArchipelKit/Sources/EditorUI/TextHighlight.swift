import AppKit
import SwiftUI

/// Marks every place a search string appears in text a view shows, and one of them as the hit the
/// search is on.
///
/// Whoever searches counts hits with `ranges(of:in:)` and the views mark them with `apply(to:)`,
/// so the two can never disagree on what a hit is.
public struct TextHighlight: Equatable, Sendable {
    /// The hit a search is on: one occurrence in one piece of text.
    ///
    /// A piece is named by what it says, and by its place where both sides know it. Plain text
    /// views do not know theirs, and for them what the piece says is enough. Markdown numbers
    /// its pieces: the cells of a table and the items of a list say "Yes" or "Done" many times
    /// over, and with the text alone every one of them would carry the mark.
    public struct Current: Equatable, Sendable {
        public var text: String
        /// Zero for the first hit in `text`.
        public var occurrence: Int
        /// Which of the pieces `MarkdownText.searchableText` returns, counted from zero. Nil
        /// when the text is not Markdown's.
        public var piece: Int?

        public init(text: String, occurrence: Int, piece: Int? = nil) {
            self.text = text
            self.occurrence = occurrence
            self.piece = piece
        }
    }

    public var query: String
    public var current: Current?

    public init(query: String, current: Current? = nil) {
        self.query = query
        self.current = current
    }

    /// Where `query` appears in `text`, ignoring case, accents and character width. Hits never
    /// overlap: "aa" is in "aaa" once.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: start..<text.endIndex)
        {
            // An empty hit could only come from a query made of characters the comparison ignores.
            guard !range.isEmpty else { break }
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }

    /// `text` with every hit tinted and the current one in the system's find color. `piece` is
    /// the text's place among Markdown's pieces, nil for a view that does not know it.
    public func apply(to text: AttributedString, piece: Int? = nil) -> AttributedString {
        let plain = String(text.characters)
        let ranges = Self.ranges(of: query, in: plain)
        guard !ranges.isEmpty else { return text }
        let currentIndex = current.flatMap { current -> Int? in
            guard current.text == plain else { return nil }
            // Where both know the place it decides; alike pieces are otherwise all the hit.
            if let wanted = current.piece, let piece, wanted != piece { return nil }
            return current.occurrence
        }
        var marked = text
        for (index, range) in ranges.enumerated() {
            guard let range = Range(range, in: marked) else { continue }
            if index == currentIndex {
                marked[range].backgroundColor = Self.currentColor
                // The find color is a bright yellow in both appearances, so the text on it is
                // dark in both.
                marked[range].foregroundColor = .black
            } else {
                marked[range].backgroundColor = Self.matchColor
            }
        }
        return marked
    }

    public func apply(to text: String) -> AttributedString {
        apply(to: AttributedString(text))
    }

    /// The color of the hit the search is on, as AppKit's own find bar marks it.
    public static let currentColor = Color(nsColor: .findHighlightColor)
    /// Every other hit: the same yellow, thin enough that the text keeps its own color.
    public static let matchColor = Color(nsColor: .findHighlightColor).opacity(0.35)
}

extension EnvironmentValues {
    /// What to mark in the text below. Nil while nothing is being searched for.
    @Entry public var textHighlight: TextHighlight?
}

/// Attributed text that marks the environment's search hits.
struct HighlightedText: View {
    private let text: AttributedString
    /// The text's place among the pieces of its Markdown document.
    private let piece: Int?
    @Environment(\.textHighlight) private var highlight

    init(_ text: AttributedString, piece: Int? = nil) {
        self.text = text
        self.piece = piece
    }

    var body: some View {
        Text(highlight?.apply(to: text, piece: piece) ?? text)
    }
}

extension MarkdownBlock {
    /// How many pieces of `MarkdownText.searchableText` the block makes. The views number their
    /// text with this, so it has to count exactly what `collect` below appends.
    var pieceCount: Int {
        switch kind {
        case .paragraph, .heading, .codeBlock: 1
        case let .blockQuote(blocks): Self.pieceCount(of: blocks)
        case let .unorderedList(items), let .orderedList(_, items): items.reduce(0) { $0 + Self.pieceCount(of: $1.blocks) }
        case let .table(table): table.header.count + table.rows.reduce(0) { $0 + $1.count }
        case .thematicBreak: 0
        }
    }

    static func pieceCount(of blocks: [MarkdownBlock]) -> Int {
        blocks.reduce(0) { $0 + $1.pieceCount }
    }
}

extension MarkdownText {
    /// The text of every piece `MarkdownText` draws for `source`, in reading order: paragraphs,
    /// headings, code blocks and table cells, with the Markdown syntax gone. A search that looks
    /// through these finds what the reader sees, and names its hits the way `TextHighlight.Current`
    /// wants them.
    public nonisolated static func searchableText(of source: String) -> [String] {
        var pieces: [String] = []
        collect(MarkdownDocument.parse(source), into: &pieces)
        return pieces
    }

    private nonisolated static func collect(_ blocks: [MarkdownBlock], into pieces: inout [String]) {
        for block in blocks {
            switch block.kind {
            case let .paragraph(text), let .heading(_, text):
                pieces.append(String(text.characters))
            case let .codeBlock(_, code):
                pieces.append(code)
            case let .blockQuote(blocks):
                collect(blocks, into: &pieces)
            case let .unorderedList(items), let .orderedList(_, items):
                for item in items { collect(item.blocks, into: &pieces) }
            case let .table(table):
                for cell in table.header { pieces.append(String(cell.characters)) }
                for row in table.rows {
                    for cell in row { pieces.append(String(cell.characters)) }
                }
            case .thematicBreak:
                break
            }
        }
    }
}
