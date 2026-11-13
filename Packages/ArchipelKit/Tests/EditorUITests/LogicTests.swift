import Foundation
import Testing
@testable import EditorUI

struct SourceLanguageTests {
    @Test(arguments: [
        ("main.swift", "swift"), ("Package.swift", "swift"), ("lib.rs", "rust"), ("App.tsx", "typescript"),
        ("index.mjs", "javascript"), ("tool.py", "python"), ("main.go", "go"), ("x.c", "c"), ("x.hpp", "cpp"),
        ("data.json", "json"), ("ci.yml", "yaml"), ("Cargo.toml", "ini"), ("README.md", "markdown"),
        ("build.sh", "bash"), ("index.html", "xml"), ("site.css", "css"), ("schema.sql", "sql"),
        ("Dockerfile", "dockerfile"), ("Dockerfile.dev", "dockerfile"), ("Makefile", "makefile"),
        (".gitignore", "bash"), (".env.local", "bash"), ("CMakeLists.txt", "cmake"), ("Gemfile", "ruby"),
    ])
    func detectsGrammar(_ name: String, _ grammar: String) {
        #expect(SourceLanguage.grammar(forFileName: name) == grammar)
    }

    @Test func unknownFilesHaveNoGrammar() {
        #expect(SourceLanguage.grammar(forFileName: "LICENSE") == nil)
        #expect(SourceLanguage.grammar(forFileName: "photo.heic") == nil)
    }
}

struct TextSnifferTests {
    @Test func detectsBinaryByNulByte() {
        #expect(TextSniffer.isBinary(Data([0x50, 0x4B, 0x00, 0x03])))
        #expect(!TextSniffer.isBinary(Data("plain text".utf8)))
        #expect(TextSniffer.decode(Data([0x00, 0x01, 0x02])) == nil)
    }

    @Test func decodesBOMsAndLegacyText() throws {
        #expect(TextSniffer.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hi".utf8)) == "hi")
        let utf16 = try #require("h\u{e9}".data(using: .utf16LittleEndian))
        #expect(TextSniffer.decode(Data([0xFF, 0xFE]) + utf16) == "h\u{e9}")
        // 0xE9 alone is invalid UTF-8 but fine as Latin-1.
        #expect(TextSniffer.decode(Data([0x63, 0x61, 0x66, 0xE9])) == "caf\u{e9}")
    }

    @Test func foldsUniformLineEndingsOnly() throws {
        let crlf = try #require(TextSniffer.decodeWithFormat(Data("a\r\nb\r\n".utf8)))
        #expect(crlf.text == "a\nb\n")
        #expect(crlf.format.lineEnding == .crlf)
        let mixed = try #require(TextSniffer.decodeWithFormat(Data("a\r\nb\n".utf8)))
        #expect(mixed.text == "a\r\nb\n")
        #expect(mixed.format.lineEnding == .lf)
        let cr = try #require(TextSniffer.decodeWithFormat(Data("a\rb".utf8)))
        #expect(cr.text == "a\nb")
        #expect(cr.format.lineEnding == .cr)
    }

    @Test func encodeRestoresFormat() throws {
        let format = TextFileFormat(encoding: .utf8, hasBOM: true, lineEnding: .crlf)
        #expect(try format.encode("a\nb") == Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb".utf8))
        // A pasted CRLF must not turn into CR CR LF.
        #expect(try format.encode("a\r\nb") == Data([0xEF, 0xBB, 0xBF]) + Data("a\r\nb".utf8))
        let latin1 = TextFileFormat(encoding: .isoLatin1)
        #expect(throws: TextFileFormat.EncodingError.self) { try latin1.encode("\u{1F600}") }
    }
}

struct IndentationTests {
    @Test func detectsIndentation() {
        #expect(IndentationStyle.detect(in: "func a() {\n\tb()\n\tif x {\n\t\tc()\n\t}\n}\n") == .tab)
        #expect(IndentationStyle.detect(in: "a:\n  b:\n    c: 1\n  d: 2\n") == .spaces(2))
        #expect(IndentationStyle.detect(in: "struct A {\n    var b = 1\n    func c() {\n        d()\n    }\n}\n") == .spaces(4))
        #expect(IndentationStyle.detect(in: "no indentation\nat all\n") == .tab)
    }
}

struct LineIndexTests {
    @Test func breaksLinesLikeNSString() {
        let text = "a\nb\r\nc\rd\u{2028}e\u{85}f\n"
        let index = LineIndex(text)
        #expect(index.starts == [0, 2, 5, 7, 9, 11, 13])
        #expect(index.length == (text as NSString).length)
        #expect(index.line(containing: 0) == 0)
        #expect(index.line(containing: 3) == 1)
        #expect(index.line(containing: 12) == 5)
    }

    @Test func countsUTF16ForAstralCharacters() {
        let index = LineIndex("\u{1F600}x\ny")
        #expect(index.starts == [0, 4])
    }

    @Test @MainActor func changedRangeIsMinimal() {
        let (range, replacement) = CodeScrollView.changedRange(from: "let a = 1\nlet b = 2\n", to: "let a = 1\nlet b = 3\n")
        #expect(range == NSRange(location: 18, length: 1))
        #expect(replacement == "3")
        let (emojiRange, emojiReplacement) = CodeScrollView.changedRange(from: "x\u{1F600}", to: "x\u{1F601}")
        #expect(emojiRange == NSRange(location: 1, length: 2))
        #expect(emojiReplacement == "\u{1F601}")
    }
}

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
