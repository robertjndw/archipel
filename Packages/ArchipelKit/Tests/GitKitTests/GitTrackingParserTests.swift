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

    @Test func decodesPullRequestJSON() throws {
        let json = #"{"number":42,"url":"https://github.com/o/r/pull/42","title":"Add thing","state":"MERGED","isDraft":false}"#
        let pr = try GitHubParser.pullRequest(Data(json.utf8))
        #expect(pr == GitPullRequest(number: 42, url: URL(string: "https://github.com/o/r/pull/42")!, title: "Add thing", state: .merged, isDraft: false))

        let draft = #"{"number":1,"url":"https://github.com/o/r/pull/1","title":"WIP","state":"OPEN","isDraft":true}"#
        let parsed = try GitHubParser.pullRequest(Data(draft.utf8))
        #expect(parsed.state == .open)
        #expect(parsed.isDraft)
    }

    @Test func rejectsUnknownStateAndGarbage() {
        let unknown = #"{"number":1,"url":"https://x.test/1","title":"t","state":"WEIRD","isDraft":false}"#
        #expect(throws: GitError.self) { try GitHubParser.pullRequest(Data(unknown.utf8)) }
        #expect(throws: GitError.self) { try GitHubParser.pullRequest(Data("not json".utf8)) }
    }

    @Test func missingExecutableYieldsNoClient() {
        #expect(GitHubClient(searchPATH: "/nonexistent/dir") == nil || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gh") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/gh"))
    }
}
