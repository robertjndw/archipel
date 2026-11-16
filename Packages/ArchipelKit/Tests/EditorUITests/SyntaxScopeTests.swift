import Foundation
import Testing
@testable import EditorUI

struct HighlightParserTests {
    @Test func mapsSpansToRunsOverDecodedText() {
        let html = #"<span class="hljs-keyword">let</span> s = <span class="hljs-string">&quot;a&lt;b&amp;&quot;</span> <span class="hljs-comment">// \#u{1F600}</span>"#
        let (runs, length) = HighlightHTMLParser.runs(fromHTML: html)
        let text = #"let s = "a<b&" // \#u{1F600}"#
        #expect(length == (text as NSString).length)
        #expect(runs == [
            HighlightRun(location: 0, length: 3, scope: .keyword),
            HighlightRun(location: 8, length: 6, scope: .string),
            HighlightRun(location: 15, length: 5, scope: .comment),
        ])
    }

    @Test func innermostScopeWinsAndUnknownClassesInherit() {
        let html = #"<span class="hljs-meta">#if <span class="hljs-keyword">DEBUG</span> x</span><span class="language-xml"><span class="hljs-title function_ invoke__">f</span></span>"#
        let (runs, _) = HighlightHTMLParser.runs(fromHTML: html)
        #expect(runs == [
            HighlightRun(location: 0, length: 4, scope: .preprocessor),
            HighlightRun(location: 4, length: 5, scope: .keyword),
            HighlightRun(location: 9, length: 2, scope: .preprocessor),
            HighlightRun(location: 11, length: 1, scope: .functionCall),
        ])
    }

    @Test func scopeMapping() {
        #expect(SyntaxScope(highlightClass: "hljs-title class_") == .typeDeclaration)
        #expect(SyntaxScope(highlightClass: "hljs-title class_ inherited__") == .typeName)
        #expect(SyntaxScope(highlightClass: "hljs-variable language_") == .keyword)
        #expect(SyntaxScope(highlightClass: "hljs-subst") == .plain)
        #expect(SyntaxScope(highlightClass: "hljs-emphasis") == nil)
        #expect(SyntaxScope(highlightClass: "language-css") == nil)
    }

    @Test func engineHighlightsWithTheBundledScript() async throws {
        let text = "let answer = 42 // comment\n"
        let runs = try #require(await SyntaxHighlighter.shared.runs(for: text, grammar: "swift"))
        #expect(runs.contains(HighlightRun(location: 0, length: 3, scope: .keyword)))
        #expect(runs.contains { $0.scope == .number && $0.location == 13 })
        #expect(runs.contains { $0.scope == .comment })
        #expect(await SyntaxHighlighter.shared.runs(for: text, grammar: "no-such-language") == nil)
    }
}
