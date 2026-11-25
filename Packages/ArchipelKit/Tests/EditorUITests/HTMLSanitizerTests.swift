import Foundation
import Testing
@testable import EditorUI

struct HTMLSanitizerTests {
    private func clean(_ html: String) -> String { HTMLSanitizer.sanitize(html) }

    // MARK: What READMEs rely on

    @Test func keepsLayoutMarkup() {
        #expect(clean("<div align=\"center\">") == "<div align=\"center\">")
        #expect(clean("</div>") == "</div>")
        #expect(clean("<img src=\"docs/images/icon.png\" width=\"128\" alt=\"Archipel app icon\">")
            == "<img src=\"docs/images/icon.png\" width=\"128\" alt=\"Archipel app icon\">")
        #expect(clean("<kbd>Ctrl</kbd>+<kbd>1</kbd>") == "<kbd>Ctrl</kbd>+<kbd>1</kbd>")
        #expect(clean("<details open>\n<summary>More</summary>\ntext\n</details>\n") == "<details open>\n<summary>More</summary>\ntext\n</details>\n")
        #expect(clean("<h1 align=\"center\" id=\"top\">Title</h1>") == "<h1 align=\"center\" id=\"top\">Title</h1>")
        #expect(clean("<a name=\"install\"></a>") == "<a name=\"install\"></a>")
        #expect(clean("<sub>x</sub><sup>2</sup>") == "<sub>x</sub><sup>2</sup>")
    }

    @Test func keepsTables() {
        let table = "<table>\n<tr><th align=\"left\" colspan=\"2\">A</th></tr>\n<tr><td rowspan=\"2\" valign=\"top\">1</td><td>2</td></tr>\n</table>\n"
        #expect(clean(table) == table)
    }

    @Test func keepsBadgesAndThemedPictures() {
        #expect(clean("<a href=\"https://example.com/ci\"><img src=\"https://img.shields.io/badge/macOS-27-black?logo=apple&logoColor=white\" alt=\"macOS\"></a>")
            == "<a href=\"https://example.com/ci\"><img src=\"https://img.shields.io/badge/macOS-27-black?logo=apple&logoColor=white\" alt=\"macOS\"></a>")
        #expect(clean("<picture><source media=\"(prefers-color-scheme: dark)\" srcset=\"art/dark.png 1x, art/dark@2x.png 2x\"><img src=\"art/light.png\"></picture>")
            == "<picture><source media=\"(prefers-color-scheme: dark)\" srcset=\"art/dark.png 1x, art/dark@2x.png 2x\"><img src=\"art/light.png\"></picture>")
        #expect(clean("<img src=\"data:image/png;base64,AAAA\">") == "<img src=\"data:image/png;base64,AAAA\">")
    }

    @Test func normalisesHowTagsAreWritten() {
        #expect(clean("<BR/>") == "<br>")
        #expect(clean("<br />") == "<br>")
        #expect(clean("<IMG SRC='a.png' WIDTH=40>") == "<img src=\"a.png\" width=\"40\">")
        #expect(clean("<p\n  align = \"right\"\n>") == "<p align=\"right\">")
        // Entities in text and values keep their meaning.
        #expect(clean("<span title=\"a &amp; b\">&copy; &lt;3</span>") == "<span title=\"a &amp; b\">&copy; &lt;3</span>")
    }

    // MARK: What must not get through

    @Test(arguments: ["script", "style", "iframe", "object", "textarea", "title", "noscript", "template", "svg", "math", "select"])
    func dropsElementsWithTheirContent(_ name: String) {
        #expect(clean("before<\(name) a=\"b\">inside <b>x</b></\(name)>after") == "beforeafter")
        #expect(clean("before<\(name.uppercased())>inside</\(name.uppercased()) >after") == "beforeafter")
        // Unclosed in this fragment: the rest belongs to it.
        #expect(clean("before<\(name)>inside") == "before")
    }

    @Test func aLongerNameDoesNotCloseAScript() {
        #expect(clean("<script>a</scripted>b</script>c") == "c")
    }

    @Test(arguments: ["embed", "form", "meta", "link", "base", "input", "button", "video", "audio", "frame", "frameset", "body", "html", "head", "applet", "marquee", "plaintext"])
    func dropsTagsThatAreNotAllowed(_ name: String) {
        #expect(clean("a<\(name) src=\"https://example.com/\" href=\"https://example.com/\">b</\(name)>c") == "abc")
    }

    @Test func dropsMetaRefreshAndRemoteStyles() {
        #expect(clean("<meta http-equiv=\"refresh\" content=\"0; url=https://example.com/\">") == "")
        #expect(clean("<link rel=\"stylesheet\" href=\"https://example.com/x.css\">") == "")
        #expect(clean("<base href=\"https://example.com/\">") == "")
        #expect(clean("<form action=\"https://example.com/\"><input name=\"q\"><button>Go</button></form>") == "Go")
    }

    @Test func dropsEventHandlersStylesAndClasses() {
        #expect(clean("<img src=\"a.png\" onerror=\"alert(1)\" ONLOAD=alert(2)>") == "<img src=\"a.png\">")
        #expect(clean("<a href=\"x.md\" style=\"position:fixed;inset:0;opacity:0\" onclick=\"x()\" target=\"_blank\">y</a>") == "<a href=\"x.md\">y</a>")
        #expect(clean("<div class=\"task\" style='background:url(https://example.com/)' data-x=\"1\" hidden>") == "<div>")
        // Without a space in between the browser still sees two attributes.
        #expect(clean("<img src=\"a.png\"onerror=\"alert(1)\">") == "<img src=\"a.png\">")
        #expect(clean("<img/src=\"a.png\"/onerror=alert(1)>") == "<img src=\"a.png\">")
    }

    @Test func judgesTheFirstOfARepeatedAttribute() {
        #expect(clean("<a href=\"javascript:alert(1)\" href=\"ok.md\">x</a>") == "<a>x</a>")
        #expect(clean("<a href=\"ok.md\" href=\"javascript:alert(1)\">x</a>") == "<a href=\"ok.md\">x</a>")
    }

    @Test(arguments: [
        "javascript:alert(1)",
        "JaVaScRiPt:alert(1)",
        "  javascript:alert(1)",
        "java\tscript:alert(1)",
        "java&#115;cript:alert(1)",
        "java&#x73cript:alert(1)",
        "javascript&colon;alert(1)",
        "java&Tab;script:alert(1)",
        "java&NewLine;script:alert(1)",
        "&#106;avascript:alert(1)",
        "&#0000106avascript:alert(1)",
        "\u{1}javascript:alert(1)",
        "vbscript:msgbox(1)",
        "data:text/html,<script>alert(1)</script>",
        "blob:https://example.com/1",
        // An entity this code does not know could still turn into part of a scheme.
        "javascript&unknown;:alert(1)",
    ])
    func dropsScriptLinks(_ href: String) {
        #expect(clean("<a href=\"\(href)\">x</a>") == "<a>x</a>")
    }

    @Test(arguments: ["shortcuts://run-shortcut?name=x", "ssh://host", "https://example.com/?a=1&b=2", "mailto:a@example.com", "#top", "docs/a:b.md", "../x.md?a&b"])
    func keepsOtherLinksForTheAppToJudge(_ href: String) {
        #expect(clean("<a href=\"\(href)\">x</a>") == "<a href=\"\(href)\">x</a>")
    }

    @Test(arguments: [
        "http://example.com/a.png",
        "file:///etc/passwd",
        "ftp://example.com/a.png",
        "javascript:alert(1)",
        "data:text/html,hi",
        "smb://host/share/a.png",
    ])
    func dropsImageSourcesThePolicyWouldBlock(_ source: String) {
        #expect(clean("<img src=\"\(source)\" alt=\"a\">") == "<img alt=\"a\">")
        #expect(clean("<source srcset=\"ok.png 1x, \(source) 2x\">") == "<source>")
    }

    @Test func imageSourcesAreJudgedAfterTheirEntities() {
        // The browser decodes the value before it parses the URL, so this is an `http:` image.
        #expect(clean("<img src=\"http&#58;//example.com/a.png\" alt=\"a\">") == "<img alt=\"a\">")
        #expect(clean("<img src=\"data&colon;text/html,x\" alt=\"a\">") == "<img alt=\"a\">")
    }

    @Test func aTabHidesNoSchemeInASource() {
        // The URL parser skips a tab, so this is `http:`.
        #expect(clean("<img src=\"ht&Tab;tp://example.com/a.png\" alt=\"a\">") == "<img alt=\"a\">")
        // In a srcset the tab ends the URL instead, leaving the relative path `ht`.
        #expect(HTMLSanitizer.isSafeSourceSet("ok.png 1x, ht&Tab;tp://example.com/a.png 2x"))
        #expect(!HTMLSanitizer.isSafeSourceSet("ok.png 1x, &Tab;http://example.com/a.png 2x"))
    }

    @Test func dropsCommentsAndDeclarations() {
        #expect(clean("a<!-- <script>x</script> -->b") == "ab")
        #expect(clean("a<!-->b") == "ab")
        #expect(clean("a<!-- never closed <b>x</b>") == "a")
        #expect(clean("<!DOCTYPE html>a<?php echo 1 ?>b<![CDATA[x]]>c") == "abc")
    }

    @Test func escapesWhatIsNotATag() {
        #expect(clean("a < b") == "a &lt; b")
        #expect(clean("x <3 y") == "x &lt;3 y")
        #expect(clean("</ >") == "&lt;/ >")
        #expect(clean("<") == "&lt;")
        // Cut off by the end of the fragment, so text, and so is everything after it.
        #expect(clean("<div align=\"center\"") == "&lt;div align=\"center\"")
        #expect(clean("<a title=\"<script>alert(1)</script>") == "&lt;a title=\"&lt;script>alert(1)&lt;/script>")
        #expect(clean("<a href='x") == "&lt;a href='x")
        #expect(clean("<b>kept</b> <i <b not a tag") == "<b>kept</b> &lt;i &lt;b not a tag")
        #expect(clean("<b>kept</b> <a href='x <b>text</b> </div") == "<b>kept</b> &lt;a href='x &lt;b>text&lt;/b> &lt;/div")
        #expect(clean("a </div") == "a &lt;/div")
    }

    // MARK: Cost

    /// Scanning each of these to its end once per `<` takes minutes at this size;
    /// one pass takes milliseconds, so the bound leaves room for a slow machine and a debug build.
    @Test(arguments: [
        ("<div ", "<a\n"),
        ("", "<a x='"),
        ("", "<a x='>' "),
        ("", "<a/x="),
        ("", "</a"),
        ("", "<a<"),
        ("<div>", "</span>"),
    ])
    func unterminatedTagsCostOnePass(_ start: String, _ unit: String) {
        let input = start + String(repeating: unit, count: 400 * 1024 / unit.utf8.count)
        var output = ""
        let elapsed = ContinuousClock().measure { output = clean(input) }
        #expect(elapsed < .seconds(5), "\(unit.debugDescription) took \(elapsed)")
        #expect(!output.contains("<a"))

        var open = HTMLSanitizer.OpenElements()
        let tracked = ContinuousClock().measure { _ = HTMLSanitizer.sanitize(input, open: &open) }
        #expect(tracked < .seconds(5), "\(unit.debugDescription) took \(tracked) with open elements")
    }

    // MARK: Source sets

    @Test(arguments: [
        "ok.png 1x&#44;http://example.com/t.png 2x",
        "ok.png 1x&#x2c;http://example.com/t.png 2x",
        "ok.png 1x&#44 http://example.com/t.png 2x",
        "ok.png 1x&comma;http://example.com/t.png 2x",
        "ok.png 1x,&#9;javascript:alert(1) 2x",
        "ok.png 1x, java&#115;cript:alert(1) 2x",
        "ok.png,file:///etc/passwd",
    ])
    func judgesEveryCandidateOfADecodedSourceSet(_ srcset: String) {
        #expect(clean("<img srcset=\"\(srcset)\" alt=\"a\">") == "<img alt=\"a\">")
        #expect(!HTMLSanitizer.isSafeSourceSet(srcset))
    }

    @Test func keepsOrdinarySourceSets() {
        #expect(HTMLSanitizer.isSafeSourceSet("art/dark.png 1x, art/dark@2x.png 2x"))
        #expect(HTMLSanitizer.isSafeSourceSet("https://example.com/a.png 480w,\n  https://example.com/b.png 800w,"))
        #expect(HTMLSanitizer.isSafeSourceSet("a.png?x=1&amp;y=2 2x"))
        #expect(HTMLSanitizer.isSafeSourceSet(""))
    }

    // MARK: Escaped ampersands

    @Test func aCorrectlyEscapedAmpersandKeepsTheAttribute() {
        #expect(clean("<a href=\"a&amp;b.md\">x</a>") == "<a href=\"a&amp;b.md\">x</a>")
        #expect(clean("<img src=\"logo&amp;dark.png\">") == "<img src=\"logo&amp;dark.png\">")
        #expect(clean("<a href=\"a&#38;b.md\">x</a>") == "<a href=\"a&#38;b.md\">x</a>")
        #expect(HTMLSanitizer.destination(of: "a&amp;b.md", decodingEntities: true) == .relative)
        // Decoded once, as the browser does: what is left is text, not another entity.
        #expect(HTMLSanitizer.destination(of: "java&amp;#115;cript:alert(1)", decodingEntities: true) == .relative)
        #expect(clean("<a href=\"javascript&amp;colon;alert(1)\">x</a>") == "<a href=\"javascript&amp;colon;alert(1)\">x</a>")
        #expect(HTMLSanitizer.destination(of: "javascript&amp;colon;alert(1)", decodingEntities: true) == .relative)
        // One it cannot decode is still distrusted.
        #expect(HTMLSanitizer.destination(of: "a&unknown;b.md", decodingEntities: true) == .unclear)
    }

    // MARK: Sizes

    @Test func holdsSizesToSaneValues() {
        #expect(clean("<img src=\"x\" width=\"99999\" height=\"99999\">") == "<img src=\"x\" width=\"2000\" height=\"2000\">")
        #expect(clean("<img src=x width=99999999999999999999999999999999 height=&#57;9999>") == "<img src=\"x\" width=\"2000\" height=\"2000\">")
        #expect(clean("<img src=x width=\"128\" height=\"50%\">") == "<img src=\"x\" width=\"128\" height=\"50%\">")
        #expect(clean("<td width=\"9999%\" height=\" 30px\">") == "<td width=\"100%\" height=\"30\">")
        #expect(clean("<img src=x width=\"wide\" height>") == "<img src=\"x\">")
        #expect(clean("<table border=\"99999\" cellpadding=\"4\" cellspacing=\"5000\">") == "<table border=\"100\" cellpadding=\"4\" cellspacing=\"100\">")
        #expect(clean("<hr size=\"99999\">") == "<hr size=\"100\">")
        // A font size is a step from 1 to 7, not a length.
        #expect(clean("<font size=\"+2\">") == "<font size=\"+2\">")
        #expect(HTMLSanitizer.cappedLength("12.75", limit: 2000) == "12")
        #expect(HTMLSanitizer.cappedLength("", limit: 2000) == nil)
    }

    // MARK: Open elements

    @Test func closesWhatAClosingTagLeavesOpenInside() {
        var open = HTMLSanitizer.OpenElements()
        #expect(HTMLSanitizer.sanitize("<div><a href=\"x\"><b>t</div>", open: &open) == "<div><a href=\"x\"><b>t</b></a></div>")
        #expect(!open.contains("a") && !open.contains("div"))
    }

    @Test func dropsClosingTagsThatCloseNothing() {
        var open = HTMLSanitizer.OpenElements()
        #expect(HTMLSanitizer.sanitize("a</a></div></p>b", open: &open) == "ab")
        #expect(HTMLSanitizer.sanitize("<kbd>", open: &open) == "<kbd>")
        #expect(HTMLSanitizer.sanitize("</kbd></kbd>", open: &open) == "</kbd>")
    }

    @Test func openElementsCarryOverBetweenFragments() {
        var open = HTMLSanitizer.OpenElements()
        #expect(HTMLSanitizer.sanitize("<div align=\"center\">\n", open: &open) == "<div align=\"center\">\n")
        #expect(HTMLSanitizer.sanitize("<img src=\"a.png\"><br>", open: &open) == "<img src=\"a.png\"><br>")
        #expect(open.contains("div") && !open.contains("img") && !open.contains("br"))
        #expect(HTMLSanitizer.sanitize("</div>\n", open: &open) == "</div>\n")
        #expect(!open.contains("div"))
    }

    @Test func closingALinkClosesWhatIsInsideItFirst() {
        // Behind an open table cell the browser would ignore a lone `</a>`.
        var open = HTMLSanitizer.OpenElements()
        _ = HTMLSanitizer.sanitize("<div><a href=\"x\"><table><tr><td>", open: &open)
        #expect(open.closeAll("a") == "</td></tr></table></a>")
        #expect(open.closeAll("a") == "")
        #expect(open.contains("div"))
    }

    @Test func quotesInValuesCannotEndThem() {
        #expect(clean("<img alt='\" onerror=\"alert(1)' src=a.png>") == "<img alt=\"&quot; onerror=&quot;alert(1)\" src=\"a.png\">")
        #expect(clean("<span title=\"a > b <i>\">") == "<span title=\"a &gt; b &lt;i&gt;\">")
        #expect(clean("<span title=a\"b>") == "<span title=\"a&quot;b\">")
    }

    @Test func voidElementsHaveNoClosingTag() {
        #expect(clean("</br></img>") == "")
    }

    @Test func keepsTextOutsideASCII() {
        #expect(clean("<kbd>⌘</kbd> für <b>Ünïcode</b> 🎉") == "<kbd>⌘</kbd> für <b>Ünïcode</b> 🎉")
        // A tag name starts with an ASCII letter, for the browser too.
        #expect(clean("<İ>x") == "&lt;İ>x")
        #expect(clean("<aİ title=\"t\">x</aİ>") == "x")
    }

    @Test func worksOnTheFragmentsOfInlineHTML() {
        // An opening tag, text and a closing tag arrive as three nodes.
        #expect(clean("<script>") == "")
        #expect(clean("</script>") == "")
        #expect(clean("<a href=\"javascript:alert(1)\" onclick=\"x()\">") == "<a>")
    }

    // MARK: Destinations

    @Test func tellsSchemesFromRelativePaths() {
        #expect(HTMLSanitizer.destination(of: "docs/guide.md") == .relative)
        #expect(HTMLSanitizer.destination(of: "/abs/a:b") == .relative)
        #expect(HTMLSanitizer.destination(of: "?q=a:b") == .relative)
        #expect(HTMLSanitizer.destination(of: "#a:b") == .relative)
        #expect(HTMLSanitizer.destination(of: "HTTPS://example.com") == .scheme("https"))
        #expect(HTMLSanitizer.destination(of: "x-my.app+v2:thing") == .scheme("x-my.app+v2"))
        #expect(HTMLSanitizer.destination(of: "1abc:thing") == .unclear)
        #expect(HTMLSanitizer.destination(of: "a b:thing") == .unclear)
        #expect(HTMLSanitizer.destination(of: ":thing") == .unclear)
        // The URL parser drops tabs and newlines wherever they are, so these still name a scheme.
        #expect(HTMLSanitizer.destination(of: "java\tscript:alert(1)") == .scheme("javascript"))
        #expect(HTMLSanitizer.destination(of: "ht\ntps://example.com") == .scheme("https"))
    }

    @Test func markdownDestinationsHaveNoEntityLayer() {
        // In a Markdown link the ampersand is just a character, and is escaped on the way out.
        #expect(HTMLSanitizer.isSafeLinkDestination("a&b.md"))
        #expect(!HTMLSanitizer.isSafeLinkDestination("a&b.md", decodingEntities: true))
        #expect(!HTMLSanitizer.isSafeLinkDestination("javascript:alert(1)"))
    }

    @Test func decodesTheEntitiesThatCanHideAScheme() {
        #expect(HTMLSanitizer.decodeEntities("&#58;&#x3a;&#X3A&colon;&amp;&lt;&gt;&quot;&apos;") == "::::&<>\"'")
        #expect(HTMLSanitizer.decodeEntities("&#0;&#xD800;&#x110000;") == "\u{FFFD}\u{FFFD}\u{FFFD}")
        #expect(HTMLSanitizer.decodeEntities("a & b &; &# &#x; &eacute; &ampx") == "a & b &; &# &#x; &eacute; &ampx")
    }
}
