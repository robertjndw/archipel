import Foundation
import Testing
@testable import GitKit

struct GitTrackingParserTests {
    @Test func parsesUpstreamAndAheadBehind() {
        let output = ["# branch.oid abc", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +3 -12", ""]
            .joined(separator: "\0")
        let status = GitParser.status(output)
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 3)
        #expect(status.behind == 12)
    }

    @Test func missingUpstreamLeavesDefaults() {
        let status = GitParser.status(["# branch.oid abc", "# branch.head feature", ""].joined(separator: "\0"))
        #expect(status.upstream == nil)
        #expect(status.ahead == 0)
        #expect(status.behind == 0)
        #expect(GitStatus.empty.upstream == nil)
    }

    @Test func upstreamWithoutCountsWhenItsBranchIsGone() {
        let status = GitParser.status(["# branch.head main", "# branch.upstream origin/main", ""].joined(separator: "\0"))
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 0)
        #expect(status.behind == 0)
    }

    @Test func summaryCountsDistinctPaths() {
        let output = [
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +1 -2",
            "1 MM N... 100644 100644 100644 aaaa bbbb both.txt",
            "1 M. N... 100644 100644 100644 aaaa bbbb staged.txt",
            "1 .M N... 100644 100644 100644 aaaa aaaa unstaged.txt",
            "2 R. N... 100644 100644 100644 aaaa aaaa R100 new.txt",
            "old.txt",
            "? untracked/",
            "",
        ].joined(separator: "\0")
        #expect(GitParser.summary(output) == GitSummary(branch: "main", upstream: "origin/main", ahead: 1, behind: 2, changedFiles: 5))
    }
}
