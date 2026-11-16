import Foundation
import Testing
@testable import GitKit

struct GitHubClientTests {
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
