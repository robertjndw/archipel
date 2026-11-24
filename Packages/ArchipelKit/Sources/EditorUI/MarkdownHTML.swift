import Foundation
import Markdown

/// Turns Markdown into the HTML the preview shows: CommonMark with GitHub's tables, task lists and
/// strikethrough, headings that carry GitHub's anchor ids, and fenced code coloured like the editor.
enum MarkdownHTML {
    struct CodeBlock: Equatable, Sendable {
        var language: String
        var code: String
    }

    /// The fenced blocks with a language, in document order, for highlighting ahead of `render`.
    static func codeBlocks(in markdown: String) -> [CodeBlock] {
        var collector = CodeBlockCollector()
        collector.visit(parse(markdown))
        return collector.blocks
    }

    /// `highlights` holds runs for the blocks `codeBlocks` returned, by their index there. A block
    /// without runs is shown plain. In a task that has been cancelled it stops early and returns
    /// what it has, which the caller is expected to throw away.
    static func render(_ markdown: String, highlights: [Int: [HighlightRun]] = [:]) -> String {
        var renderer = Renderer(highlights: highlights)
        return renderer.visit(parse(markdown))
    }

    private static func parse(_ markdown: String) -> Document {
        Document(parsing: strippingFrontMatter(markdown))
    }

    /// YAML front matter is metadata for site generators, not prose. GitHub and VS Code both leave
    /// it out of the rendered page; parsed as Markdown it would come out as a rule and a heading.
    static func strippingFrontMatter(_ markdown: String) -> String {
        guard markdown.hasPrefix("---\n") else { return markdown }
        let rest = markdown.dropFirst(4)
        for line in rest.split(separator: "\n", omittingEmptySubsequences: false) where line == "---" || line == "..." {
            let next = rest.index(line.endIndex, offsetBy: 1, limitedBy: rest.endIndex) ?? rest.endIndex
            return String(rest[next...])
        }
        // Never closed, so it was a rule after all.
        return markdown
    }

    /// GitHub's anchor for a heading: lowercased, punctuation dropped, spaces to hyphens.
    static func slug(for title: String) -> String {
        var slug = ""
        for character in title.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                slug.append(character)
            } else if character == " " {
                slug.append("-")
            }
        }
        return slug
    }

    static func escape(_ text: some StringProtocol) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Wraps the runs in spans named after their scope; the page's stylesheet colours them.
    static func highlightedHTML(_ code: String, runs: [HighlightRun]) -> String {
        let string = code as NSString
        var html = ""
        var position = 0
        for run in runs.sorted(by: { $0.location < $1.location }) where run.location >= position && NSMaxRange(run.range) <= string.length {
            if run.location > position {
                html += escape(string.substring(with: NSRange(location: position, length: run.location - position)))
            }
            html += "<span class=\"s\(run.scope.rawValue)\">\(escape(string.substring(with: run.range)))</span>"
            position = NSMaxRange(run.range)
        }
        if position < string.length { html += escape(string.substring(from: position)) }
        return html
    }

    fileprivate static func language(of block: Markdown.CodeBlock) -> String? {
        // The info string can carry more than the language, as in ```swift title="main.swift".
        guard let word = block.language?.split(whereSeparator: \.isWhitespace).first, !word.isEmpty else { return nil }
        return word.lowercased()
    }
}

private struct CodeBlockCollector: MarkupWalker {
    var blocks: [MarkdownHTML.CodeBlock] = []

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let language = MarkdownHTML.language(of: codeBlock) else { return }
        blocks.append(.init(language: language, code: codeBlock.code))
    }
}

private struct Renderer: MarkupVisitor {
    let highlights: [Int: [HighlightRun]]
    /// Counts the blocks with a language, in the same order as `CodeBlockCollector`.
    private var codeBlockIndex = 0
    private var usedSlugs: [String: Int] = [:]
    /// What the document's raw HTML has opened so far. A `<div align="center">` is meant to stay
    /// open across the Markdown that follows it, so this lives as long as the render.
    private var openElements = HTMLSanitizer.OpenElements()

    init(highlights: [Int: [HighlightRun]]) {
        self.highlights = highlights
    }

    private mutating func children(of markup: Markup) -> String {
        var html = ""
        for child in markup.children {
            // A newer revision of the buffer has replaced this one; a long document should not
            // be rendered to the end for nobody.
            if Task.isCancelled { break }
            html += visit(child)
        }
        return html
    }

    /// The inline content of a paragraph, heading or cell. A link that raw HTML opened in it
    /// ends with it: left open, the browser would carry it into every block that follows and
    /// make the rest of the document one click target.
    private mutating func inlineChildren(of markup: Markup) -> String {
        children(of: markup) + openElements.closeAll("a")
    }

    private func escape(_ text: some StringProtocol) -> String { MarkdownHTML.escape(text) }

    mutating func defaultVisit(_ markup: Markup) -> String { children(of: markup) }

    mutating func visitDocument(_ document: Document) -> String { children(of: document) }

    mutating func visitHeading(_ heading: Heading) -> String {
        // Repeated titles get -1, -2 and so on, as on GitHub, so every anchor leads somewhere.
        let base = MarkdownHTML.slug(for: heading.plainText)
        let count = usedSlugs[base, default: 0]
        usedSlugs[base] = count + 1
        let slug = count == 0 ? base : "\(base)-\(count)"
        return "<h\(heading.level) id=\"\(escape(slug))\">\(inlineChildren(of: heading))</h\(heading.level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String { "<p>\(inlineChildren(of: paragraph))</p>\n" }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String { "<blockquote>\n\(children(of: blockQuote))</blockquote>\n" }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String { "<hr>\n" }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        guard let language = MarkdownHTML.language(of: codeBlock) else {
            return "<pre><code>\(escape(codeBlock.code))</code></pre>\n"
        }
        let index = codeBlockIndex
        codeBlockIndex += 1
        let body = highlights[index].map { MarkdownHTML.highlightedHTML(codeBlock.code, runs: $0) } ?? escape(codeBlock.code)
        return "<pre><code class=\"language-\(escape(language))\">\(body)</code></pre>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        // Other elements may stay open for the blocks that follow. A link may not, see `inlineChildren`.
        HTMLSanitizer.sanitize(html.rawHTML, open: &openElements) + openElements.closeAll("a")
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        let start = orderedList.startIndex == 1 ? "" : " start=\"\(orderedList.startIndex)\""
        return "<ol\(start)>\n\(children(of: orderedList))</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String { "<ul>\n\(children(of: unorderedList))</ul>\n" }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        switch listItem.checkbox {
        case .checked:
            "<li class=\"task\"><input type=\"checkbox\" checked disabled> \(children(of: listItem))</li>\n"
        case .unchecked:
            "<li class=\"task\"><input type=\"checkbox\" disabled> \(children(of: listItem))</li>\n"
        case nil:
            "<li>\(children(of: listItem))</li>\n"
        }
    }

    mutating func visitTable(_ table: Table) -> String {
        let alignments = table.columnAlignments
        func cells(_ row: some Markup, tag: String, into html: inout String, renderer: inout Renderer) {
            for (column, child) in row.children.enumerated() {
                guard let cell = child as? Table.Cell else { continue }
                var attributes = ""
                if column < alignments.count, let alignment = alignments[column] {
                    let value = switch alignment {
                    case .left: "left"
                    case .center: "center"
                    case .right: "right"
                    }
                    // Not a style attribute: the preview's Content Security Policy turns those off.
                    attributes += " align=\"\(value)\""
                }
                if cell.colspan > 1 { attributes += " colspan=\"\(cell.colspan)\"" }
                if cell.rowspan > 1 { attributes += " rowspan=\"\(cell.rowspan)\"" }
                // A spanned-over cell is still in the tree, with a span of zero.
                guard cell.colspan > 0, cell.rowspan > 0 else { continue }
                html += "<\(tag)\(attributes)>\(renderer.inlineChildren(of: cell))</\(tag)>"
            }
        }
        var html = "<table>\n<thead>\n<tr>"
        cells(table.head, tag: "th", into: &html, renderer: &self)
        html += "</tr>\n</thead>\n"
        if table.body.childCount > 0 {
            html += "<tbody>\n"
            for row in table.body.rows {
                html += "<tr>"
                cells(row, tag: "td", into: &html, renderer: &self)
                html += "</tr>\n"
            }
            html += "</tbody>\n"
        }
        return html + "</table>\n"
    }

    mutating func visitText(_ text: Text) -> String { escape(text.string) }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String { "<em>\(children(of: emphasis))</em>" }

    mutating func visitStrong(_ strong: Strong) -> String { "<strong>\(children(of: strong))</strong>" }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String { "<del>\(children(of: strikethrough))</del>" }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String { "<code>\(escape(inlineCode.code))</code>" }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) -> String { "<code>\(escape(symbolLink.destination ?? ""))</code>" }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        HTMLSanitizer.sanitize(inlineHTML.rawHTML, open: &openElements)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String { "\n" }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String { "<br>\n" }

    mutating func visitLink(_ link: Link) -> String {
        let title = link.title.map { " title=\"\(escape($0))\"" } ?? ""
        let destination = link.destination ?? ""
        // An unsafe destination leaves the text as a link that leads nowhere.
        let href = HTMLSanitizer.isSafeLinkDestination(destination) ? " href=\"\(escape(destination))\"" : ""
        return "<a\(href)\(title)>\(children(of: link))</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let title = image.title.map { " title=\"\(escape($0))\"" } ?? ""
        let source = image.source ?? ""
        // The same rule as for an `<img>` written in HTML. Without a source the alt text shows.
        let src = HTMLSanitizer.isSafeImageSource(source) ? " src=\"\(escape(source))\"" : ""
        return "<img\(src) alt=\"\(escape(image.plainText))\"\(title)>"
    }
}
