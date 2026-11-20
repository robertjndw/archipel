import Foundation
import Testing
@testable import EditorUI

struct MarkdownHTMLTests {
    @Test func rendersBlocksAndInlines() {
        let html = MarkdownHTML.render("# Title\n\nSome *em*, **strong**, ~~gone~~ and `code`.\n\n> quoted\n\n---\n")
        #expect(html.contains("<h1 id=\"title\">Title</h1>"))
        #expect(html.contains("<p>Some <em>em</em>, <strong>strong</strong>, <del>gone</del> and <code>code</code>.</p>"))
        #expect(html.contains("<blockquote>\n<p>quoted</p>\n</blockquote>"))
        #expect(html.contains("<hr>"))
    }

    @Test func escapesText() {
        let html = MarkdownHTML.render("a < b & `<tag>`")
        #expect(html.contains("a &lt; b &amp; <code>&lt;tag&gt;</code>"))
    }

    @Test func headingAnchorsMatchGitHub() {
        let html = MarkdownHTML.render("## What's New?\n\n## What's New?\n")
        #expect(html.contains("<h2 id=\"whats-new\">"))
        #expect(html.contains("<h2 id=\"whats-new-1\">"))
    }

    @Test func rendersTaskListsAndOrderedStart() {
        let html = MarkdownHTML.render("- [x] done\n- [ ] todo\n\n3. three\n4. four\n")
        #expect(html.contains("<input type=\"checkbox\" checked disabled>"))
        #expect(html.contains("<input type=\"checkbox\" disabled>"))
        #expect(html.contains("<ol start=\"3\">"))
    }

    @Test func rendersTablesWithAlignment() {
        let html = MarkdownHTML.render("| A | B |\n|:--|--:|\n| 1 | 2 |\n")
        #expect(html.contains("<th style=\"text-align: left\">A</th>"))
        #expect(html.contains("<td style=\"text-align: right\">2</td>"))
    }

    @Test func linksAndImagesKeepTheirDestinations() {
        let html = MarkdownHTML.render("[docs](docs/guide.md \"Guide\") ![logo](../art/logo.png)")
        #expect(html.contains("<a href=\"docs/guide.md\" title=\"Guide\">docs</a>"))
        #expect(html.contains("<img src=\"../art/logo.png\" alt=\"logo\">"))
    }

    @Test func dropsFrontMatter() {
        let html = MarkdownHTML.render("---\ntitle: Hi\n---\n# Body\n")
        #expect(!html.contains("title: Hi"))
        #expect(html.contains("<h1 id=\"body\">Body</h1>"))
    }

    @Test func keepsAnUnclosedLeadingRule() {
        #expect(MarkdownHTML.strippingFrontMatter("---\ntext\n") == "---\ntext\n")
    }

    @Test func highlightsFencedCodeByIndex() {
        let markdown = "```\nplain\n```\n\n```swift\nlet x = 1\n```\n"
        let blocks = MarkdownHTML.codeBlocks(in: markdown)
        #expect(blocks == [.init(language: "swift", code: "let x = 1\n")])
        let runs = [HighlightRun(location: 0, length: 3, scope: .keyword)]
        let html = MarkdownHTML.render(markdown, highlights: [0: runs])
        #expect(html.contains("<pre><code>plain\n</code></pre>"))
        #expect(html.contains("<code class=\"language-swift\"><span class=\"s\(SyntaxScope.keyword.rawValue)\">let</span> x = 1\n</code>"))
    }
}
