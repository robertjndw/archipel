import Foundation
import Testing
@testable import GitKit

struct GitParserTests {
    @Test func parsesBranchAndEntryKinds() {
        let output = [
            "# branch.oid 492fcb4b06d8bd5e37005c30d252d97a8c2d890e",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +1 -0",
            "1 M. N... 100644 100644 100644 aaaa bbbb Sources/App.swift",
            "1 .M N... 100644 100644 100644 aaaa aaaa README.md",
            "1 MM N... 100644 100644 100644 aaaa bbbb both.txt",
            "1 A. N... 000000 100644 100644 0000 bbbb new file.txt",
            "1 D. N... 100644 000000 000000 aaaa 0000 gone.txt",
            "1 .D N... 100644 100644 000000 aaaa aaaa removed.txt",
            "1 .T N... 100644 100644 120000 aaaa aaaa link",
            "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflict file.txt",
            "? untracked dir/notes  two spaces.md",
            "! ignored.log",
            "",
        ].joined(separator: "\0")

        let status = GitParser.status(output)

        #expect(status.branch == "main")
        #expect(status.staged == [
            GitFileChange(path: "Sources/App.swift", kind: .modified),
            GitFileChange(path: "both.txt", kind: .modified),
            GitFileChange(path: "new file.txt", kind: .added),
            GitFileChange(path: "gone.txt", kind: .deleted),
        ])
        #expect(status.unstaged == [
            GitFileChange(path: "README.md", kind: .modified),
            GitFileChange(path: "both.txt", kind: .modified),
            GitFileChange(path: "removed.txt", kind: .deleted),
            GitFileChange(path: "link", kind: .typeChanged),
            GitFileChange(path: "conflict file.txt", kind: .conflicted),
            GitFileChange(path: "untracked dir/notes  two spaces.md", kind: .untracked),
        ])
    }

    @Test func parsesRenamesWithOriginalPathInNextField() {
        let output = [
            "# branch.head (detached)",
            "2 RM N... 100644 100644 100644 aaaa aaaa R100 new name.txt",
            "old name.txt",
            "2 C. N... 100644 100644 100644 aaaa aaaa C75 copy.swift",
            "source.swift",
            "",
        ].joined(separator: "\0")

        let status = GitParser.status(output)

        #expect(status.branch == nil)
        #expect(status.staged == [
            GitFileChange(path: "new name.txt", originalPath: "old name.txt", kind: .renamed),
            GitFileChange(path: "copy.swift", originalPath: "source.swift", kind: .copied),
        ])
        #expect(status.unstaged == [GitFileChange(path: "new name.txt", kind: .modified)])
    }

    @Test func keepsUnicodePathsIntact() {
        // A leading combining mark must not fuse with the separator before it.
        let combining = "\u{301}accent.txt"
        let output = "# branch.head f\u{fc}r\0? \(combining)\0? \u{65E5}\u{672C}.md\0"

        let status = GitParser.status(output)

        #expect(status.branch == "f\u{fc}r")
        #expect(status.unstaged.map(\.path) == [combining, "\u{65E5}\u{672C}.md"])
    }

    @Test func parsesEmptyOutput() {
        #expect(GitParser.status("") == .empty)
        #expect(GitParser.worktrees("").isEmpty)
    }

    @Test func parsesWorktreeList() {
        let output = [
            "worktree /repo/main", "HEAD 1111", "branch refs/heads/main", "",
            "worktree /repo/wt with space", "HEAD 2222", "detached", "",
            "worktree /repo/feature", "HEAD 3333", "branch refs/heads/feature/x", "locked", "",
            "worktree /repo/gone", "HEAD 4444", "branch refs/heads/gone", "prunable gitdir file points to non-existent location", "",
            "worktree /repo/held", "HEAD 5555", "detached", "locked in use by CI", "prunable", "",
            "",
        ].joined(separator: "\0")

        let entries = GitParser.worktrees(output)

        #expect(entries == [
            GitWorktreeEntry(path: URL(filePath: "/repo/main", directoryHint: .isDirectory), branch: "main", isMain: true),
            GitWorktreeEntry(path: URL(filePath: "/repo/wt with space", directoryHint: .isDirectory), branch: nil, isMain: false),
            GitWorktreeEntry(path: URL(filePath: "/repo/feature", directoryHint: .isDirectory), branch: "feature/x", isMain: false, isLocked: true),
            GitWorktreeEntry(path: URL(filePath: "/repo/gone", directoryHint: .isDirectory), branch: "gone", isMain: false, isPrunable: true),
            GitWorktreeEntry(path: URL(filePath: "/repo/held", directoryHint: .isDirectory), branch: nil, isMain: false, isLocked: true, isPrunable: true),
        ])
    }
}
