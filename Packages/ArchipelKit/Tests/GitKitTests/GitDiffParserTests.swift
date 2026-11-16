import Testing
@testable import GitKit

struct GitDiffParserTests {
    @Test func parsesModifiedFileWithWholeFileHunk() {
        let output = """
        diff --git a/Sources/app.swift b/Sources/app.swift
        index 1111111..2222222 100644
        --- a/Sources/app.swift
        +++ b/Sources/app.swift
        @@ -1,3 +1,3 @@ struct App {
         let a = 1
        -let b = 2
        +let b = 3
         let c = 4

        """
        let diffs = GitParser.fileDiffs(output)
        #expect(diffs.count == 1)
        let diff = try! #require(diffs.first)
        #expect(diff.status == .modified)
        #expect(diff.oldPath == "Sources/app.swift")
        #expect(diff.newPath == "Sources/app.swift")
        #expect(!diff.isBinary)
        #expect(diff.hunks == [GitDiffHunk(oldStart: 1, oldCount: 3, newStart: 1, newCount: 3, lines: [
            GitDiffLine(.context, "let a = 1"),
            GitDiffLine(.removed, "let b = 2"),
            GitDiffLine(.added, "let b = 3"),
            GitDiffLine(.context, "let c = 4"),
        ])])
    }

    @Test func contentThatLooksLikeHeadersStaysContent() {
        let output = """
        diff --git a/notes.md b/notes.md
        --- a/notes.md
        +++ b/notes.md
        @@ -1,2 +1,3 @@
        -diff --git is a command
        +@@ -1 +1 @@ looks like a hunk
        +--- and so does this
         -- a lua comment

        """
        let lines = GitParser.fileDiffs(output).first?.hunks.first?.lines
        #expect(lines == [
            GitDiffLine(.removed, "diff --git is a command"),
            GitDiffLine(.added, "@@ -1 +1 @@ looks like a hunk"),
            GitDiffLine(.added, "--- and so does this"),
            GitDiffLine(.context, "-- a lua comment"),
        ])
    }

    @Test func marksMissingNewlineOnTheRightSide() {
        let output = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         one
        -two
        \\ No newline at end of file
        +two

        """
        let lines = GitParser.fileDiffs(output).first?.hunks.first?.lines
        #expect(lines == [
            GitDiffLine(.context, "one"),
            GitDiffLine(.removed, "two", hasNewline: false),
            GitDiffLine(.added, "two"),
        ])
    }

    @Test func missingNewlineAfterTheLastHunkLine() {
        let output = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -old
        +new
        \\ No newline at end of file

        """
        let lines = GitParser.fileDiffs(output).first?.hunks.first?.lines
        #expect(lines?.last == GitDiffLine(.added, "new", hasNewline: false))
        #expect(lines?.first?.hasNewline == true)
    }

    @Test func emptyContextLineWithoutLeadingSpace() {
        // What diff.suppressBlankEmpty produces.
        let output = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,3 +1,3 @@\n x\n\n-y\n+z\n"
        let lines = GitParser.fileDiffs(output).first?.hunks.first?.lines
        #expect(lines == [GitDiffLine(.context, "x"), GitDiffLine(.context, ""), GitDiffLine(.removed, "y"), GitDiffLine(.added, "z")])
    }

    @Test func keepsCarriageReturnsAndUnicode() {
        let output = "diff --git a/w.txt b/w.txt\n--- a/w.txt\n+++ b/w.txt\n@@ -1 +1 @@\n-caf\u{e9}\r\n+caf\u{e9} \u{1F600}\r\n"
        let lines = GitParser.fileDiffs(output).first?.hunks.first?.lines
        #expect(lines == [GitDiffLine(.removed, "caf\u{e9}\r"), GitDiffLine(.added, "caf\u{e9} \u{1F600}\r")])
    }

    @Test func newDeletedRenamedAndBinaryFiles() {
        let output = """
        diff --git a/new file.txt b/new file.txt
        new file mode 100644
        index 0000000..e69de29
        --- /dev/null
        +++ b/new file.txt\t
        @@ -0,0 +1 @@
        +hello
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/old.txt b/new.txt
        similarity index 100%
        rename from old.txt
        rename to new.txt
        diff --git a/logo.png b/logo.png
        index 1111111..2222222 100644
        Binary files a/logo.png and b/logo.png differ

        """
        let diffs = GitParser.fileDiffs(output)
        #expect(diffs.count == 4)
        #expect(diffs[0].status == .added)
        #expect(diffs[0].oldPath == nil)
        #expect(diffs[0].newPath == "new file.txt")
        #expect(diffs[0].hunks.first?.lines == [GitDiffLine(.added, "hello")])
        #expect(diffs[1].status == .deleted)
        #expect(diffs[1].oldPath == "gone.txt")
        #expect(diffs[1].newPath == nil)
        #expect(diffs[2] == GitFileDiff(oldPath: "old.txt", newPath: "new.txt", status: .renamed))
        #expect(diffs[3].isBinary)
        #expect(diffs[3].hunks.isEmpty)
    }

    @Test func hunkHeaderDefaultsCountToOne() {
        #expect(GitParser.hunkHeader("-3 +4,0 @@") == GitDiffHunk(oldStart: 3, oldCount: 1, newStart: 4, newCount: 0))
        #expect(GitParser.hunkHeader("-1,2 +1,5 @@ func x()") == GitDiffHunk(oldStart: 1, oldCount: 2, newStart: 1, newCount: 5))
        #expect(GitParser.hunkHeader("garbage") == nil)
    }

    @Test func unquotesCStylePaths() {
        #expect(GitParser.unquote("\"tab\\there\"") == "tab\there")
        #expect(GitParser.unquote("\"caf\\303\\251\"") == "caf\u{e9}")
        #expect(GitParser.unquote("\"quote\\\"d\"") == "quote\"d")
        #expect(GitParser.unquote("plain name") == "plain name")
    }

    @Test func findsRenameOrigin() {
        let nameStatus = "R087\0src/old.swift\0src/new.swift\0M\0other.swift\0R100\0a\0b\0"
        #expect(GitParser.renameOrigin(of: "src/new.swift", in: nameStatus) == "src/old.swift")
        #expect(GitParser.renameOrigin(of: "b", in: nameStatus) == "a")
        #expect(GitParser.renameOrigin(of: "other.swift", in: nameStatus) == nil)
    }
}
