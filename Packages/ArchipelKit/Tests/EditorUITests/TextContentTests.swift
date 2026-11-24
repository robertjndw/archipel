import Foundation
import Testing
@testable import EditorUI

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

    @Test func measuresTheLongestLine() {
        #expect(TextSniffer.longestLineLength("") == 0)
        #expect(TextSniffer.longestLineLength("ab\nabcd\r\nabc") == 4)
        #expect(TextSniffer.longestLineLength("one\rthree\r") == 5)
        // In the units TextKit lays out: CJK is one each, not the three bytes UTF-8 takes, and an
        // emoji outside the BMP is a surrogate pair.
        #expect(TextSniffer.longestLineLength("\u{e9}") == 1)
        #expect(TextSniffer.longestLineLength("\u{65e5}\u{672c}\u{8a9e}\nab") == 3)
        #expect(TextSniffer.longestLineLength("\u{1F600}") == 2)
        let cjk = String(repeating: "\u{6f22}", count: 20_000)
        #expect(TextSniffer.longestLineLength(cjk) == cjk.utf16.count)
        #expect(TextSniffer.longestLineLength(cjk) <= TextBuffer.maximumLineLength)
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

    @Test func keepsCRLFTogetherAcrossReadChunks() {
        // The index reads 4096 UTF-16 units at a time; the CR is the last unit of the first chunk.
        let text = String(repeating: "a", count: 4095) + "\r\nb"
        #expect(LineIndex(text).starts == [0, 4097])
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
