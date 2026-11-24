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
        #expect(html.contains("<th align=\"left\">A</th>"))
        #expect(html.contains("<td align=\"right\">2</td>"))
    }

    @Test func linksAndImagesKeepTheirDestinations() {
        let html = MarkdownHTML.render("[docs](docs/guide.md \"Guide\") ![logo](../art/logo.png)")
        #expect(html.contains("<a href=\"docs/guide.md\" title=\"Guide\">docs</a>"))
        #expect(html.contains("<img src=\"../art/logo.png\" alt=\"logo\">"))
    }

    @Test func keepsTheHTMLReadmesUse() {
        let markdown = """
            <div align="center">

            <img src="docs/images/icon.png" width="128" alt="App icon">

            # Title

            ![macOS](https://img.shields.io/badge/macOS-27-black?logo=apple)

            </div>

            Press <kbd>⌘</kbd><kbd>K</kbd>,<br>then wait.

            <details>
            <summary>More</summary>

            Hidden *text*.

            </details>
            """
        let html = MarkdownHTML.render(markdown)
        #expect(html.contains("<div align=\"center\">\n"))
        #expect(html.contains("<img src=\"docs/images/icon.png\" width=\"128\" alt=\"App icon\">"))
        #expect(html.contains("<h1 id=\"title\">Title</h1>"))
        #expect(html.contains("<img src=\"https://img.shields.io/badge/macOS-27-black?logo=apple\" alt=\"macOS\">"))
        #expect(html.contains("</div>\n"))
        #expect(html.contains("<p>Press <kbd>⌘</kbd><kbd>K</kbd>,<br>then wait.</p>"))
        #expect(html.contains("<details>\n<summary>More</summary>\n"))
        #expect(html.contains("<p>Hidden <em>text</em>.</p>"))
        #expect(html.contains("</details>"))
    }

    @Test func rendersThisRepositorysReadmeWithoutLosingItsHTML() throws {
        let readme = URL(filePath: #filePath).appending(path: "../../../../../README.md").standardizedFileURL
        let markdown = try String(contentsOf: readme, encoding: .utf8)
        let html = MarkdownHTML.render(markdown)
        #expect(html.contains("<div align=\"center\">"))
        #expect(html.contains("<img src=\"docs/images/icon.png\" width=\"128\" alt=\"Archipel app icon\">"))
        #expect(html.contains("<kbd>Ctrl</kbd>+<kbd>1</kbd>"))
        // Raw tags that came through as text would show up escaped.
        #expect(!html.contains("&lt;kbd") && !html.contains("&lt;div") && !html.contains("&lt;img"))
        #expect(markdown.components(separatedBy: "<kbd>").count == html.components(separatedBy: "<kbd>").count)
        #expect(markdown.components(separatedBy: "</kbd>").count == html.components(separatedBy: "</kbd>").count)
        // The centred block closes where the README closes it, and nothing was closed for it.
        #expect(html.components(separatedBy: "</div>").count == 2)
        #expect(html.components(separatedBy: "<a").count == html.components(separatedBy: "</a>").count)
    }

    @Test func neutralisesDangerousBlockHTML() {
        let markdown = """
            <script>alert(1)</script>

            <style>article { display: none }</style>

            <meta http-equiv="refresh" content="0; url=https://example.com/">

            <iframe src="https://example.com/"></iframe>

            <form action="https://example.com/"><input name="q"></form>

            <link rel="stylesheet" href="https://example.com/x.css">

            <base href="https://example.com/">

            <object data="x.swf"></object><embed src="x.swf">

            <div style="position:fixed;inset:0" onclick="x()">kept</div>
            """
        let html = MarkdownHTML.render(markdown).lowercased()
        for needle in ["<script", "alert(1)", "<style", "display: none", "<meta", "<iframe", "<form", "<input", "<link", "<base", "<object", "<embed", "style=", "onclick", "example.com"] {
            #expect(!html.contains(needle), "\(needle) should be gone")
        }
        #expect(html.contains("<div>kept</div>"))
    }

    @Test func neutralisesDangerousInlineHTML() {
        // Inline HTML reaches the renderer one tag at a time, with the text between as its own node.
        let html = MarkdownHTML.render("Click <a href=\"shortcuts://run\" style=\"position:fixed;inset:0;opacity:0\" onmouseover=\"x()\">here</a> or <script>alert(1)</script> or <iframe src=\"https://example.com\"></iframe> <img src=x onerror=alert(2)>.")
        #expect(html.contains("<a href=\"shortcuts://run\">here</a>"))
        #expect(!html.contains("style="))
        #expect(!html.contains("onmouseover"))
        #expect(!html.contains("onerror"))
        #expect(!html.contains("<script"))
        #expect(!html.contains("<iframe"))
        #expect(html.contains("<img src=\"x\">"))
    }

    @Test func tableAlignmentNeedsNoStyleAttribute() {
        let html = MarkdownHTML.render("| A | B | C |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n")
        #expect(!html.contains("style="))
        #expect(html.contains("<td align=\"center\">2</td>"))
    }

    @Test func markdownLinksToScriptsLoseTheirDestination() {
        let html = MarkdownHTML.render("[a](javascript:alert(1)) [b](data:text/html,x) [c](shortcuts://run) [d](docs/a&b.md)")
        #expect(html.contains("<a>a</a>"))
        #expect(html.contains("<a>b</a>"))
        #expect(html.contains("<a href=\"shortcuts://run\">c</a>"))
        #expect(html.contains("<a href=\"docs/a&amp;b.md\">d</a>"))
    }

    @Test func markdownImagesFollowTheImageRule() {
        let html = MarkdownHTML.render("""
            ![a](http://example.com/t.png) ![b](javascript:alert(1)) ![c](archipel-preview://local/etc/passwd)
            ![d](file:///etc/passwd) ![e](data:text/html,x)

            ![ok](https://example.com/badge.svg "Badge") ![rel](docs/a&b.png) ![inline](data:image/png;base64,AAAA)
            """)
        for alt in ["a", "b", "c", "d", "e"] {
            #expect(html.contains("<img alt=\"\(alt)\">"))
        }
        for needle in ["http://example.com", "javascript:", "archipel-preview:", "file:", "data:text"] {
            #expect(!html.contains(needle), "\(needle) should be gone")
        }
        #expect(html.contains("<img src=\"https://example.com/badge.svg\" alt=\"ok\" title=\"Badge\">"))
        #expect(html.contains("<img src=\"docs/a&amp;b.png\" alt=\"rel\">"))
        #expect(html.contains("<img src=\"data:image/png;base64,AAAA\" alt=\"inline\">"))
    }

    @Test func anUnclosedLinkEndsWithItsBlock() {
        let html = MarkdownHTML.render("""
            <div>
            <a href="https://example.com/">

            Ordinary text.

            </div>
            """)
        #expect(html.contains("<div>\n<a href=\"https://example.com/\">\n</a>"))
        #expect(html.contains("<p>Ordinary text.</p>"))
        // The div is still the document's to close.
        #expect(html.contains("</div>"))
        #expect(html.components(separatedBy: "</a>").count == 2)
    }

    @Test func anUnclosedInlineLinkEndsWithItsParagraph() {
        let html = MarkdownHTML.render("Start <a href=\"https://example.com/\">here *and* on\n\n# Next\n\nMore text.\n")
        #expect(html.contains("<p>Start <a href=\"https://example.com/\">here <em>and</em> on</a></p>"))
        #expect(html.contains("<h1 id=\"next\">Next</h1>"))
        #expect(html.contains("<p>More text.</p>"))

        let heading = MarkdownHTML.render("# Title <a href=\"x\">\n\nText\n")
        #expect(heading.contains("<a href=\"x\"></a></h1>"))
        let cell = MarkdownHTML.render("| A |\n|---|\n| <a href=\"x\">1 |\n\nText\n")
        #expect(cell.contains("<td><a href=\"x\">1</a></td>"))
    }

    @Test func aLinkCannotHideBehindATableCell() {
        let html = MarkdownHTML.render("<div>\n<a href=\"https://example.com/\"><table><tr><td>\n\nText\n")
        #expect(html.contains("<td>\n</td></tr></table></a><p>Text</p>"))
    }

    @Test func closedInlineHTMLIsLeftAlone() {
        let html = MarkdownHTML.render("See <a href=\"a.md\"><img src=\"a.png\" width=\"20\"></a> and <kbd>K</kbd>, stray </a></kbd> ignored.")
        #expect(html.contains("<p>See <a href=\"a.md\"><img src=\"a.png\" width=\"20\"></a> and <kbd>K</kbd>, stray  ignored.</p>"))
    }

    @Test func unterminatedTagsRenderInOnePass() {
        let markdown = "<div \n" + String(repeating: "<a \n", count: 400 * 1024 / 4)
        var html = ""
        let elapsed = ContinuousClock().measure { html = MarkdownHTML.render(markdown) }
        #expect(elapsed < .seconds(10), "took \(elapsed)")
        #expect(html.hasPrefix("&lt;div"))
    }

    @Test func aCancelledRenderStopsEarly() async {
        let markdown = String(repeating: "Paragraph with *some* text.\n\n", count: 2000)
        let complete = MarkdownHTML.render(markdown)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return MarkdownHTML.render(markdown)
        }
        let cancelled = await task.value
        #expect(complete.components(separatedBy: "<p>").count == 2001)
        #expect(cancelled.isEmpty)
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
