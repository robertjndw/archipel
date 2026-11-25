import AgentKit
import Testing

struct ArgumentSplitterTests {
    @Test func splitsOnWhitespace() {
        #expect(ArgumentSplitter.split("  --model   opus \t--verbose ") == ["--model", "opus", "--verbose"])
    }

    @Test func emptyInputGivesNoWords() {
        #expect(ArgumentSplitter.split("") == [])
        #expect(ArgumentSplitter.split("   ") == [])
    }

    @Test func quotesGroupWords() {
        #expect(ArgumentSplitter.split(#"--append-system-prompt "be brief" -c 'a b'"#)
            == ["--append-system-prompt", "be brief", "-c", "a b"])
    }

    @Test func otherQuoteIsLiteralInsideQuotes() {
        #expect(ArgumentSplitter.split(#""it's" 'say "hi"'"#) == ["it's", #"say "hi""#])
    }

    @Test func adjacentQuotedPartsJoin() {
        #expect(ArgumentSplitter.split(#"--x="a b"c"#) == ["--x=a bc"])
    }

    @Test func emptyQuotesMakeAnEmptyWord() {
        #expect(ArgumentSplitter.split(#"a "" b"#) == ["a", "", "b"])
    }

    @Test func backslashEscapes() {
        #expect(ArgumentSplitter.split(#"a\ b "c\"d" 'e\f'"#) == ["a b", #"c"d"#, #"e\f"#])
    }

    @Test func unterminatedQuoteKeepsRest() {
        #expect(ArgumentSplitter.split(#"--x "abc def"#) == ["--x", "abc def"])
    }

    @Test func balancedInputIsWellFormed() {
        #expect(ArgumentSplitter.isWellFormed(""))
        #expect(ArgumentSplitter.isWellFormed(#"--model "opus 4" 'a b' c\ d"#))
    }

    @Test func unterminatedQuoteOrTrailingBackslashIsNotWellFormed() {
        #expect(!ArgumentSplitter.isWellFormed(#"--x "abc def"#))
        #expect(!ArgumentSplitter.isWellFormed("--x 'a b"))
        #expect(!ArgumentSplitter.isWellFormed(#"--path C:\"#))
    }
}
