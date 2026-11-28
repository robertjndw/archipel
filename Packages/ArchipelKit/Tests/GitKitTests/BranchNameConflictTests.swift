import Testing
@testable import GitKit

struct BranchNameConflictTests {
    private let existing: Set<String> = ["main", "rj/quiet-harbor", "feature"]

    @Test func anExistingNameConflicts() {
        #expect(GitClient.branchNameConflicts("main", with: existing))
        #expect(GitClient.branchNameConflicts("rj/quiet-harbor", with: existing))
    }

    @Test func aNameUnderAnExistingBranchConflicts() {
        // `feature` is a file in refs/heads, so `feature/login` has no folder to go in.
        #expect(GitClient.branchNameConflicts("feature/login", with: existing))
        #expect(GitClient.branchNameConflicts("feature/a/b", with: existing))
    }

    @Test func aNameAboveAnExistingBranchConflicts() {
        // `rj` is a folder in refs/heads, so it cannot also be a branch.
        #expect(GitClient.branchNameConflicts("rj", with: existing))
    }

    @Test func neighboursDoNotConflict() {
        #expect(!GitClient.branchNameConflicts("rj/quiet-harbor-2", with: existing))
        #expect(!GitClient.branchNameConflicts("rj/other", with: existing))
        #expect(!GitClient.branchNameConflicts("features", with: existing))
        #expect(!GitClient.branchNameConflicts("mai", with: existing))
    }
}
