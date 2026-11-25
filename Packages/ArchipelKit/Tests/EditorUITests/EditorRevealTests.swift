import Testing
@testable import EditorUI

@MainActor
struct EditorRevealTests {
    private func offset(_ line: Int, _ column: Int?, _ text: String) -> Int {
        EditorReveal.offset(line: line, column: column, in: text, index: LineIndex(text))
    }

    @Test func firstLineStart() {
        #expect(offset(1, nil, "abc\ndef") == 0)
        #expect(offset(1, 1, "abc\ndef") == 0)
    }

    @Test func middleLineWithColumn() {
        #expect(offset(2, 3, "abc\ndef\nghi") == 6)
    }

    @Test func columnPastLineEndClampsBeforeTerminator() {
        #expect(offset(1, 99, "abc\ndef") == 3)
        #expect(offset(2, 99, "abc\ndef") == 7)
    }

    @Test func linePastEndClampsToLastLine() {
        #expect(offset(50, 2, "abc\ndef") == 5)
        #expect(offset(0, nil, "abc\ndef") == 0)
    }

    @Test func crlfTerminatorIsNotPartOfTheLine() {
        let text = "abc\r\ndef\r\n"
        #expect(offset(1, 99, text) == 3)
        #expect(offset(2, 2, text) == 6)
    }

    @Test func emptyText() {
        #expect(offset(3, 4, "") == 0)
    }
}
