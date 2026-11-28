import Foundation
import Testing
@testable import ArchipelCore

struct WorktreePlaceholderTests {
    @Test func olderFilesDecodeWithoutAPlaceholder() throws {
        let original = Worktree(path: URL(fileURLWithPath: "/code/app"), branch: "main")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "placeholderBranch")
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Worktree.self, from: data).placeholderBranch == nil)
    }

    @Test func placeholderRoundTrips() throws {
        let original = Worktree(path: URL(fileURLWithPath: "/code/app"), branch: "quiet-harbor", placeholderBranch: "quiet-harbor")
        let decoded = try JSONDecoder().decode(Worktree.self, from: JSONEncoder().encode(original))
        #expect(decoded.placeholderBranch == "quiet-harbor")
    }

    @Test func isOnPlaceholderBranchTruthTable() {
        let path = URL(fileURLWithPath: "/code/app")
        #expect(!Worktree(path: path, branch: "main").isOnPlaceholderBranch)
        #expect(!Worktree(path: path, branch: nil).isOnPlaceholderBranch)
        #expect(Worktree(path: path, branch: "calm-bay", placeholderBranch: "calm-bay").isOnPlaceholderBranch)
        #expect(!Worktree(path: path, branch: "feature/x", placeholderBranch: "calm-bay").isOnPlaceholderBranch)
        #expect(!Worktree(path: path, branch: nil, placeholderBranch: "calm-bay").isOnPlaceholderBranch)
    }
}
