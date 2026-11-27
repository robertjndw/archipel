import Foundation
import Markdown

/// One block of a rendered Markdown document, with its inline content already turned into
/// attributed text so the views only lay things out.
struct MarkdownBlock: Hashable, Sendable, Identifiable {
    /// The block's index among its siblings. Appending text only ever changes the last block of
    /// a document, so every earlier block keeps its id and SwiftUI keeps its view.
    var id: Int
    var kind: Kind

    enum Kind: Hashable, Sendable {
        case paragraph(AttributedString)
        case heading(level: Int, text: AttributedString)
        /// `language` is the first word of the info string, lowercased; nil for indented code and
        /// fences without one. `code` has no trailing line break.
        case codeBlock(language: String?, code: String)
        case blockQuote([MarkdownBlock])
        case unorderedList([MarkdownListItem])
        case orderedList(start: Int, items: [MarkdownListItem])
        case table(MarkdownTable)
        case thematicBreak
    }
}

struct MarkdownListItem: Hashable, Sendable, Identifiable {
    enum Checkbox: Hashable, Sendable { case checked, unchecked }

    var id: Int
    /// Nil for an ordinary item, set for a GitHub task list item.
    var checkbox: Checkbox?
    var blocks: [MarkdownBlock]
}

struct MarkdownTable: Hashable, Sendable {
    enum Alignment: Hashable, Sendable { case leading, center, trailing }

    /// One entry per column; nil where the delimiter row has no colon.
    var alignments: [Alignment?]
    var header: [AttributedString]
    /// Every row has exactly `alignments.count` cells, padded with empty ones.
    var rows: [[AttributedString]]
}

enum MarkdownDocument {
    static func parse(_ source: String, paths: MarkdownPathLinker? = nil) -> [MarkdownBlock] {
        parseWithOffsets(source, paths: paths).blocks
    }

    /// Also returns the UTF-8 offset at which each top-level block's first line starts, which the
    /// stream parser needs to know where it can resume.
    static func parseWithOffsets(_ source: String, paths: MarkdownPathLinker? = nil) -> (blocks: [MarkdownBlock], offsets: [Int]) {
        let text = holdingBackAmbiguousLastLine(source)
        // Smart punctuation is off: agents write command lines in prose, and `--force` turning
        // into an en dash, or a quote flipping direction as the next token arrives, is worse
        // than straight quotes.
        let document = Document(parsing: text, options: [.disableSmartOpts])
        let lineStarts = lineStartOffsets(text)
        var blocks: [MarkdownBlock] = []
        var lines: [Int?] = []
        for child in document.children {
            guard let block = makeBlock(child, id: blocks.count, paths: paths) else { continue }
            blocks.append(block)
            lines.append(child.range?.lowerBound.line)
        }
        // When a table interrupts a paragraph, cmark rebuilds the paragraph without a position and
        // gives the table the paragraph's first line. Borrowing the next known line puts both at
        // the same offset, which the stream parser treats as one unit.
        var offsets = Array(repeating: 0, count: lines.count)
        var next: Int?
        for index in lines.indices.reversed() {
            if let line = lines[index] { next = line }
            let line = next ?? lines[..<index].last { $0 != nil }.flatMap(\.self) ?? 1
            offsets[index] = lineStarts[min(max(line - 1, 0), lineStarts.count - 1)]
        }
        return (blocks, offsets)
    }

    /// A last line of only `-` or `=` turns the paragraph above it into a setext heading, but while
    /// streaming it is far more often the start of a list item or a rule. Leaving it out until the
    /// line is longer or finished stops the paragraph from flashing as a heading.
    static func holdingBackAmbiguousLastLine(_ source: String) -> String {
        let utf8 = source.utf8
        guard let last = utf8.last, last != UInt8(ascii: "\n"), last != UInt8(ascii: "\r") else { return source }
        let lineStart = utf8.lastIndex { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }.map(utf8.index(after:)) ?? utf8.startIndex
        var spaces = 0
        var marker: UInt8?
        for byte in utf8[lineStart...] {
            switch byte {
            case UInt8(ascii: " ") where marker == nil:
                spaces += 1
                if spaces > 3 { return source }
            case UInt8(ascii: " "), UInt8(ascii: "\t"):
                guard marker != nil else { return source }
            case UInt8(ascii: "-"), UInt8(ascii: "="):
                guard marker == nil else { return source }
                marker = byte
            default:
                return source
            }
        }
        guard marker != nil else { return source }
        return String(source[..<lineStart])
    }

    /// CommonMark ends a line at `\n`, `\r\n` or a lone `\r`, and numbers lines the same way.
    static func lineStartOffsets(_ text: String) -> [Int] {
        var starts = [0]
        var previousWasCR = false
        for (offset, byte) in text.utf8.enumerated() {
            if byte == UInt8(ascii: "\n") {
                if previousWasCR {
                    starts[starts.count - 1] = offset + 1
                } else {
                    starts.append(offset + 1)
                }
                previousWasCR = false
            } else if byte == UInt8(ascii: "\r") {
                starts.append(offset + 1)
                previousWasCR = true
            } else {
                previousWasCR = false
            }
        }
        return starts
    }

    // MARK: Blocks

    private static func makeBlocks(_ children: some Sequence<Markup>, paths: MarkdownPathLinker?) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for child in children {
            if let block = makeBlock(child, id: blocks.count, paths: paths) { blocks.append(block) }
        }
        return blocks
    }

    private static func makeBlock(_ markup: Markup, id: Int, paths: MarkdownPathLinker?) -> MarkdownBlock? {
        let kind: MarkdownBlock.Kind
        switch markup {
        case let paragraph as Paragraph:
            kind = .paragraph(inlineText(paragraph, paths: paths))
        case let heading as Heading:
            kind = .heading(level: heading.level, text: inlineText(heading, paths: paths))
        case let code as CodeBlock:
            kind = .codeBlock(language: language(of: code), code: trimmingFinalLineBreak(code.code))
        case let quote as BlockQuote:
            kind = .blockQuote(makeBlocks(quote.children, paths: paths))
        case let list as UnorderedList:
            kind = .unorderedList(makeItems(list.listItems, paths: paths))
        case let list as OrderedList:
            kind = .orderedList(start: Int(list.startIndex), items: makeItems(list.listItems, paths: paths))
        case let table as Table:
            kind = .table(makeTable(table, paths: paths))
        case is ThematicBreak:
            kind = .thematicBreak
        case let html as HTMLBlock:
            // Shown as written. A chat transcript is no place to run someone's markup.
            kind = .paragraph(AttributedString(trimmingFinalLineBreak(html.rawHTML)))
        default:
            // Directives and other extensions are not enabled, so this is only a safety net.
            let text = markup.format()
            guard !text.isEmpty else { return nil }
            kind = .paragraph(AttributedString(text))
        }
        return MarkdownBlock(id: id, kind: kind)
    }

    private static func makeItems(_ items: some Sequence<ListItem>, paths: MarkdownPathLinker?) -> [MarkdownListItem] {
        items.enumerated().map { index, item in
            let checkbox: MarkdownListItem.Checkbox? = switch item.checkbox {
            case .checked: .checked
            case .unchecked: .unchecked
            case nil: nil
            }
            return MarkdownListItem(id: index, checkbox: checkbox, blocks: makeBlocks(item.children, paths: paths))
        }
    }

    private static func makeTable(_ table: Table, paths: MarkdownPathLinker?) -> MarkdownTable {
        let alignments: [MarkdownTable.Alignment?] = table.columnAlignments.map {
            switch $0 {
            case .left: .leading
            case .center: .center
            case .right: .trailing
            case nil: nil
            }
        }
        func cells(_ row: some Markup) -> [AttributedString] {
            var cells: [AttributedString] = row.children.compactMap { child in
                guard let cell = child as? Table.Cell else { return nil }
                // swift-markdown turns on cmark's span extension, which keeps a spanned-over cell
                // in the tree with a span of zero. GitHub has no spans, so the cell is empty here.
                return cell.colspan > 0 && cell.rowspan > 0 ? inlineText(cell, paths: paths) : AttributedString()
            }
            if cells.count < alignments.count {
                cells += Array(repeating: AttributedString(), count: alignments.count - cells.count)
            }
            return Array(cells.prefix(alignments.count))
        }
        return MarkdownTable(
            alignments: alignments,
            header: cells(table.head),
            rows: table.body.rows.map { cells($0) }
        )
    }

    /// Same rule as the HTML preview: the info string can carry more than the language, as in
    /// ```swift title="main.swift".
    private static func language(of block: CodeBlock) -> String? {
        guard let word = block.language?.split(whereSeparator: \.isWhitespace).first, !word.isEmpty else { return nil }
        return word.lowercased()
    }

    private static func trimmingFinalLineBreak(_ text: String) -> String {
        if text.hasSuffix("\r\n") { return String(text.dropLast(2)) }
        if text.hasSuffix("\n") || text.hasSuffix("\r") { return String(text.dropLast()) }
        return text
    }

    // MARK: Inlines

    private static func inlineText(_ markup: Markup, paths: MarkdownPathLinker?) -> AttributedString {
        var builder = InlineBuilder(paths: paths)
        builder.append(children: markup)
        return builder.result
    }
}

/// Bold, italic, strikethrough and code are presentation intents rather than fonts, so SwiftUI
/// applies them on top of whatever font the block uses: inline code in a heading stays heading
/// sized, and bold inside italics is both.
private struct InlineBuilder {
    var result = AttributedString()
    private var intent: InlinePresentationIntent = []
    private var link: URL?
    private let paths: MarkdownPathLinker?
    private var lookupsLeft = MarkdownPathLinker.lookupsPerText

    init(paths: MarkdownPathLinker?) {
        self.paths = paths
    }

    mutating func append(children markup: Markup) {
        for child in markup.children { append(child) }
    }

    private mutating func append(_ markup: Markup) {
        switch markup {
        case let text as Markdown.Text:
            appendProse(text.string)
        case let code as InlineCode:
            let codeLink = link == nil ? linkForCode(code.code) : nil
            appendText(code.code, adding: .code, link: codeLink)
        case let html as InlineHTML:
            appendText(html.rawHTML)
        case is SoftBreak:
            // Chat replies are written line by line, and GitHub comments and most chat clients
            // keep a single line break as one. Joining the lines would mangle short lists of
            // paths and the like that an agent writes without list markers.
            appendText("\n")
        case is LineBreak:
            appendText("\n")
        case is Emphasis:
            withIntent(.emphasized) { $0.append(children: markup) }
        case is Strong:
            withIntent(.stronglyEmphasized) { $0.append(children: markup) }
        case is Strikethrough:
            withIntent(.strikethrough) { $0.append(children: markup) }
        case let linkNode as Markdown.Link:
            withLink(linkNode.destination) { $0.append(children: markup) }
        case let image as Markdown.Image:
            // No inline images in a transcript; the alt text links to the picture instead.
            let alt = image.plainText
            withLink(image.source) { $0.appendText(alt.isEmpty ? (image.source ?? "") : alt) }
        case let symbol as SymbolLink:
            appendText(symbol.destination ?? "", adding: .code)
        default:
            append(children: markup)
        }
    }

    private mutating func appendText(_ string: some StringProtocol, adding extra: InlinePresentationIntent = [], link: URL? = nil) {
        guard !string.isEmpty else { return }
        var piece = AttributedString(string)
        let combined = intent.union(extra)
        if !combined.isEmpty { piece.inlinePresentationIntent = combined }
        if let link = link ?? self.link { piece.link = link }
        result.append(piece)
    }

    /// Plain text, with the file paths in it linked. Text inside a Markdown link already goes
    /// somewhere and is left alone.
    private mutating func appendProse(_ string: String) {
        guard let paths, link == nil, string.contains("/") else { return appendText(string) }
        var plainStart = string.startIndex
        for word in string.split(whereSeparator: \.isWhitespace) where word.contains("/") {
            guard lookupsLeft > 0 else { break }
            lookupsLeft -= 1
            guard let found = paths.link(forWord: word) else { continue }
            appendText(string[plainStart..<found.range.lowerBound])
            appendText(string[found.range], link: found.url)
            plainStart = found.range.upperBound
        }
        appendText(string[plainStart...])
    }

    private mutating func linkForCode(_ code: String) -> URL? {
        guard let paths, lookupsLeft > 0 else { return nil }
        lookupsLeft -= 1
        return paths.link(forCode: code)
    }

    private mutating func withIntent(_ added: InlinePresentationIntent, _ body: (inout InlineBuilder) -> Void) {
        let saved = intent
        intent.formUnion(added)
        body(&self)
        intent = saved
    }

    private mutating func withLink(_ destination: String?, _ body: (inout InlineBuilder) -> Void) {
        let saved = link
        var target: URL?
        if let destination, !destination.isEmpty {
            // A destination URL cannot represent (a space, say) leaves the text plain rather than
            // dropping it.
            target = linkForDestination(destination) ?? URL(string: destination)
        }
        link = target
        body(&self)
        link = saved
    }

    /// A destination without a scheme is a path relative to the reply's folder. Resolved here,
    /// where the folder is known; `src/a.swift:12` parses as a URL with the scheme `src/a.swift`,
    /// so anything not written as `scheme://` gets a try.
    private mutating func linkForDestination(_ destination: String) -> URL? {
        guard let paths, lookupsLeft > 0 else { return nil }
        if let scheme = URL(string: destination)?.scheme?.lowercased(),
           destination.contains("://") || ["mailto", "file", "http", "https"].contains(scheme) {
            return nil
        }
        lookupsLeft -= 1
        return paths.link(forDestination: destination)
    }
}

/// Keeps the blocks of a growing document and re-parses only its end.
///
/// CommonMark decides block structure line by line, and a top-level block that a complete line has
/// closed stays closed: no later line can reach back into it. So when the new text only appends to
/// the old, every block the complete lines have closed is final, and parsing again from the line
/// where the open one starts gives the same blocks a full parse would.
///
/// The unfinished last line does not count. It can close a block that its finished version would
/// have continued: `| ` is not a table row yet and ends the table, `| 1 |` is a row. So the parser
/// resumes at the last block that starts before that line, not at the very last block.
///
/// Link reference definitions are the one thing that reaches across the whole document; once one
/// could be present, every update parses everything.
struct MarkdownStreamParser {
    let paths: MarkdownPathLinker?
    private(set) var source = ""
    private(set) var blocks: [MarkdownBlock] = []
    /// UTF-8 offset of the line where the last block starts, or where parsing must resume.
    private var resumeOffset = 0
    /// Blocks before `resumeOffset`.
    private var finalCount = 0
    private var mayHaveDefinitions = false
    /// How many updates re-parsed the whole text; for tests and measurements.
    private(set) var fullParseCount = 0

    init(paths: MarkdownPathLinker? = nil) {
        self.paths = paths
    }

    @discardableResult
    mutating func update(_ newSource: String) -> [MarkdownBlock] {
        if newSource.utf8.count == source.utf8.count, newSource == source { return blocks }
        // Compared as bytes: as Characters, a `\r` the new text completes to `\r\n` would not be
        // a prefix, and neither would a letter that gains a combining accent.
        let appends = newSource.utf8.count > source.utf8.count && newSource.utf8.starts(with: source.utf8)
        if appends && !mayHaveDefinitions {
            let tailStart = newSource.utf8.index(newSource.utf8.startIndex, offsetBy: resumeOffset)
            // The resume point is always just after a line break, so this never splits a character.
            let tail = String(newSource[tailStart...])
            if Self.mayContainDefinition(tail) {
                mayHaveDefinitions = true
            } else {
                let parsed = MarkdownDocument.parseWithOffsets(tail, paths: paths)
                var merged = Array(blocks.prefix(finalCount))
                for var block in parsed.blocks {
                    block.id = merged.count
                    merged.append(block)
                }
                record(newSource, blocks: merged, newOffsets: parsed.offsets.map { $0 + resumeOffset })
                return blocks
            }
        }
        fullParseCount += 1
        mayHaveDefinitions = Self.mayContainDefinition(newSource)
        let parsed = MarkdownDocument.parseWithOffsets(newSource, paths: paths)
        finalCount = 0
        resumeOffset = 0
        record(newSource, blocks: parsed.blocks, newOffsets: parsed.offsets)
        return blocks
    }

    /// `newOffsets` are the start offsets of the blocks from `finalCount` on.
    private mutating func record(_ newSource: String, blocks newBlocks: [MarkdownBlock], newOffsets: [Int]) {
        source = newSource
        blocks = newBlocks
        let utf8 = newSource.utf8
        let lastLineStart = utf8.lastIndex { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }
            .map { utf8.distance(from: utf8.startIndex, to: $0) + 1 } ?? 0
        // Without such a block (nothing but the unfinished line since the resume point), it stays put.
        guard var open = newOffsets.lastIndex(where: { $0 < lastLineStart }) else { return }
        // A table that interrupts a paragraph reports the paragraph's first line as its start, so
        // both have to be parsed again together.
        while open > 0 && newOffsets[open - 1] >= newOffsets[open] { open -= 1 }
        resumeOffset = newOffsets[open]
        finalCount += open
    }

    /// Errs towards yes: a false alarm only costs full parses. Looks for `[label]:` at the start
    /// of a line, after any quote or list markers, since definitions can live inside those too.
    static func mayContainDefinition(_ text: String) -> Bool {
        var atLineStart = true
        var seenBracket = false
        var previous: UInt8 = 0
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                atLineStart = true
                seenBracket = false
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: ">"), UInt8(ascii: "-"), UInt8(ascii: "*"),
                 UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: ")"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                break
            case UInt8(ascii: "["):
                if atLineStart { seenBracket = true }
                atLineStart = false
            case UInt8(ascii: ":"):
                if seenBracket && previous == UInt8(ascii: "]") { return true }
                atLineStart = false
            default:
                atLineStart = false
            }
            previous = byte
        }
        return false
    }
}
