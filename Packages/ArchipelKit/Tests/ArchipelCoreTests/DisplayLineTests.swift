import Testing
@testable import ArchipelCore

struct DisplayLineTests {
    private func read(_ text: String, limit: Int = 100) -> DisplayLine {
        DisplayLine(text, limit: limit, blanks: .dropped)
    }

    private func decide(_ text: String, limit: Int = 100) -> DisplayLine {
        DisplayLine(text, limit: limit, blanks: .marked)
    }

    @Test func staysOnOneLine() {
        #expect(read("  a\n\n b\r\n\tc\u{2028}d\u{2029}e\u{0}f\u{1B}g  ").text == "a b c d e f g")
        #expect(read("").text.isEmpty)
        #expect(read(" \n\t").text.isEmpty)
    }

    @Test func nothingCanReorderWhatIsShown() {
        for control in ["\u{202A}", "\u{202B}", "\u{202D}", "\u{202E}", "\u{202C}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{200E}", "\u{200F}", "\u{061C}"] {
            #expect(read("a\(control)b").text == "ab")
            #expect(decide("a\(control)b").text == "a\u{FFFD}b")
        }
    }

    @Test func textThatIsOnlyReadKeepsItsEmojiAndJoiners() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(read("Done \(family) \u{2705}\u{FE0F}").text == "Done \(family) \u{2705}\u{FE0F}")
        #expect(read("\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}").text.unicodeScalars.contains("\u{200C}"))
        #expect(read("Done").isFaithful)
    }

    @Test func aCutLineSaysSo() {
        #expect(read("abcdef", limit: 3) == DisplayLine(text: "abc…", isFaithful: false))
        #expect(read("abc", limit: 3) == DisplayLine(text: "abc", isFaithful: true))
        // Only blank space is past the limit, so nothing is missing.
        #expect(read("abc \n ", limit: 3) == DisplayLine(text: "abc", isFaithful: true))
    }

    @Test func aRunOfBlanksIsMarkedOnce() {
        #expect(decide("ls\u{3164}\u{3164}\u{2800}\u{200B} -la") == DisplayLine(text: "ls\u{FFFD} -la", isFaithful: false))
        #expect(decide("ls -la") == DisplayLine(text: "ls -la", isFaithful: true))
        // The mark takes a place like any other character.
        #expect(decide("ab\u{3164}cd", limit: 3).text == "ab\u{FFFD}…")
    }

    @Test func wideCharactersTakeTwoColumns() {
        #expect(read("abc").columns == 3)
        #expect(read("\u{4E2D}\u{6587}a").columns == 5)
        #expect(read("\u{1F680}").columns == 2)
    }
}
