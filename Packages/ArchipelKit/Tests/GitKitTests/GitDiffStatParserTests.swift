import Testing
@testable import GitKit

struct GitDiffStatParserTests {
    @Test func sumsTextFilesAndSkipsBinaryOnes() {
        let output = """
        10\t2\tSources/App.swift
        0\t5\tdir with space/old name.txt
        -\t-\tassets/logo.png
        3\t0\tweird\tname.txt

        """
        #expect(GitParser.numstat(output) == GitDiffStat(insertions: 13, deletions: 7))
    }

    @Test func emptyOutputIsZero() {
        #expect(GitParser.numstat("") == .zero)
    }
}
