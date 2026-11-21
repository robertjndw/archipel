import Foundation
import Testing
@testable import GitKit

struct GitMetadataChangeTests {
    @Test(arguments: [
        ("HEAD", GitMetadataChange.head(worktree: nil)),
        ("worktrees/feature/HEAD", .head(worktree: "feature")),
        ("refs/heads/main", .localBranch("main")),
        ("refs/heads/feature/login", .localBranch("feature/login")),
        ("refs/remotes/origin/feature/login", .remoteBranch("origin/feature/login")),
        ("packed-refs", .refs),
        ("reftable/tables.list", .refs),
        ("worktrees", .worktreeList),
        ("worktrees/feature", .worktreeList),
        ("worktrees/feature/gitdir", .worktreeList),
        ("worktrees/feature/reftable/tables.list", .head(worktree: "feature")),
        ("worktrees/feature/reftable/0x01-0x02-abcd.ref", .head(worktree: "feature")),
    ])
    func classifiesWhatMatters(path: String, expected: GitMetadataChange) {
        #expect(GitMetadataChange(relativePath: path) == expected)
    }

    /// The app's own `git status` and `git fetch` write these all the time. Reacting to them would
    /// make every poll schedule another one.
    @Test(arguments: [
        "index", "index.lock", "worktrees/feature/index", "worktrees/feature/index.lock",
        "HEAD.lock", "worktrees/feature/HEAD.lock", "refs/heads/main.lock", "packed-refs.lock",
        "reftable/tables.list.lock", "objects/2e/65efe2", "objects/maintenance.lock", "logs/HEAD",
        "logs/refs/heads/main", "worktrees/feature/logs/HEAD", "FETCH_HEAD", "ORIG_HEAD",
        "worktrees/feature/ORIG_HEAD", "worktrees/feature/AUTO_MERGE.lock", "COMMIT_EDITMSG",
        "worktrees/feature/COMMIT_EDITMSG", "worktrees/feature/locked", "worktrees/feature/refs",
        "worktrees/feature/refs/bisect/bad", "refs/remotes/origin/HEAD", "refs/tags/v1", "refs/stash",
        "config", "hooks/pre-commit", "info/exclude", "", "refs/heads", "refs/remotes/origin",
        "worktrees/feature/reftable/tables.list.lock",
    ])
    func ignoresChurn(path: String) {
        #expect(GitMetadataChange(relativePath: path) == nil)
    }

    @Test func churnIsTheNoiseOfReadsAndFetches() {
        for path in ["objects", "objects/pack", "logs/refs/heads", "lfs/objects", "index", "worktrees/a/index", "worktrees/a/logs", "FETCH_HEAD", "refs/heads/main.lock"] {
            #expect(GitMetadataChange.isChurn(relativePath: path), "\(path)")
        }
        // A dropped batch here, or for the folder itself, may have hidden a branch move.
        for path in ["", "refs", "refs/heads", "refs/remotes/origin", "worktrees", "worktrees/a", "HEAD", "packed-refs"] {
            #expect(!GitMetadataChange.isChurn(relativePath: path), "\(path)")
        }
    }

    @Test func readsLinkedWorktreeName() {
        #expect(GitWorktreeLink(dotGitFile: "gitdir: /repo/.git/worktrees/feature\n") == .linked("feature"))
        #expect(GitWorktreeLink(dotGitFile: "gitdir: ../repo/.git/worktrees/feature") == .linked("feature"))
        #expect(GitWorktreeLink(dotGitFile: "gitdir: ../.git/modules/vendor") == .unknown)
        #expect(GitWorktreeLink(dotGitFile: "") == .unknown)
    }

    @Test func readsLinkFromDisk() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "GitWorktreeLink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let main = base.appending(path: "main")
        let linked = base.appending(path: "linked")
        try FileManager.default.createDirectory(at: main.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/linked\n".write(to: linked.appending(path: ".git"), atomically: true, encoding: .utf8)

        #expect(GitWorktreeLink.of(main) == .main)
        #expect(GitWorktreeLink.of(linked) == .linked("linked"))
        #expect(GitWorktreeLink.of(base) == .unknown)
        #expect(GitWorktreeLink.of(base.appending(path: "missing")) == .unknown)
    }

    // MARK: Planning

    private func worktree(
        _ id: Int, _ link: GitWorktreeLink, branch: String?, upstream: String? = nil, onScreen: Bool = true
    ) -> GitWatchedWorktree<Int> {
        GitWatchedWorktree(id: id, link: link, branch: branch, upstream: upstream, isOnScreen: onScreen)
    }

    @Test func headChangeRefreshesThatCheckoutOnly() {
        let worktrees = [worktree(1, .main, branch: "main"), worktree(2, .linked("feature"), branch: "feature")]

        let main = GitChangeResponse.plan(for: [.head(worktree: nil)], in: worktrees)
        let linked = GitChangeResponse.plan(for: [.head(worktree: "feature")], in: worktrees)

        #expect(main.statusRefreshes == [1])
        #expect(linked.statusRefreshes == [2])
        #expect(linked.branchReads.isEmpty)
    }

    @Test func headChangeOfHiddenCheckoutOnlyReadsTheBranch() {
        let worktrees = [worktree(1, .main, branch: "main"), worktree(2, .linked("feature"), branch: "feature", onScreen: false)]

        let response = GitChangeResponse.plan(for: [.head(worktree: "feature")], in: worktrees)

        #expect(response.branchReads == [2])
        #expect(response.statusRefreshes.isEmpty)
    }

    @Test func headChangeAlsoReadsCheckoutsThatCouldNotBeTied() {
        let worktrees = [worktree(1, .unknown, branch: "main", onScreen: false), worktree(2, .linked("feature"), branch: "feature")]

        let response = GitChangeResponse.plan(for: [.head(worktree: nil)], in: worktrees)

        #expect(response.branchReads == [1])
        #expect(response.statusRefreshes.isEmpty)
    }

    @Test func untrackedWorktreeHeadChangesNothing() {
        let worktrees = [worktree(1, .main, branch: "main")]

        #expect(GitChangeResponse.plan(for: [.head(worktree: "scratch")], in: worktrees).isEmpty)
    }

    @Test func branchMoveRefreshesCheckoutsOnScreenWithThatBranch() {
        let worktrees = [
            worktree(1, .main, branch: "main"),
            worktree(2, .linked("a"), branch: "feature"),
            worktree(3, .linked("b"), branch: "feature", onScreen: false),
        ]

        let response = GitChangeResponse.plan(for: [.localBranch("feature")], in: worktrees)

        #expect(response.statusRefreshes == [2])
        #expect(response.branchReads.isEmpty)
    }

    @Test func pushLooksUpPullRequestsByUpstreamOrByName() {
        let worktrees = [
            worktree(1, .main, branch: "main", upstream: "origin/main"),
            worktree(2, .linked("a"), branch: "feature", upstream: "origin/other-name"),
            // Not published yet as far as the app knows: `git push -u` creates the remote branch first.
            worktree(3, .linked("b"), branch: "fresh", onScreen: false),
            worktree(4, .linked("c"), branch: nil),
        ]

        #expect(GitChangeResponse.plan(for: [.remoteBranch("origin/other-name")], in: worktrees).pushCandidates == [2: "origin/other-name"])
        #expect(GitChangeResponse.plan(for: [.remoteBranch("origin/feature")], in: worktrees).pushCandidates.isEmpty)
        #expect(GitChangeResponse.plan(for: [.remoteBranch("origin/fresh")], in: worktrees).pushCandidates == [3: "origin/fresh"])
        #expect(GitChangeResponse.plan(for: [.remoteBranch("upstream/fresh")], in: worktrees).pushCandidates == [3: "upstream/fresh"])
    }

    @Test func pushCandidateCoversTheStatusRefreshOfTheSameBatch() {
        let worktrees = [worktree(1, .main, branch: "main", upstream: "origin/main")]

        let response = GitChangeResponse.plan(for: [.localBranch("main"), .remoteBranch("origin/main"), .head(worktree: nil)], in: worktrees)

        #expect(response.pushCandidates == [1: "origin/main"])
        #expect(response.statusRefreshes.isEmpty)
        #expect(response.branchReads.isEmpty)
    }

    @Test func packedRefsRefreshesEveryCheckout() {
        let worktrees = [worktree(1, .main, branch: "main"), worktree(2, .linked("a"), branch: "feature", onScreen: false)]

        let response = GitChangeResponse.plan(for: [.refs], in: worktrees)

        #expect(response.statusRefreshes == [1])
        #expect(response.branchReads == [2])
        #expect(!response.discoversWorktrees)
    }

    @Test func worktreeListChangeOnlyRediscovers() {
        let response = GitChangeResponse.plan(for: [.worktreeList], in: [worktree(1, .main, branch: "main")])

        #expect(response.discoversWorktrees)
        #expect(response.statusRefreshes.isEmpty && response.branchReads.isEmpty && response.pushCandidates.isEmpty)
    }

    // MARK: Follow-ups

    @Test func followUpWaitsAddUpToTheSchedule() {
        #expect(PullRequestFollowUp.waits == [.seconds(15), .seconds(30), .seconds(75)])
        #expect(PullRequestFollowUp.waits.reduce(.zero, +) == PullRequestFollowUp.schedule.last)
    }

    @Test func followUpsStopOnceFoundOrSwitchedAway() {
        #expect(PullRequestFollowUp.continues(pushedBranch: "feature", currentBranch: "feature", pullRequestFound: false))
        #expect(!PullRequestFollowUp.continues(pushedBranch: "feature", currentBranch: "feature", pullRequestFound: true))
        #expect(!PullRequestFollowUp.continues(pushedBranch: "feature", currentBranch: "main", pullRequestFound: false))
        #expect(!PullRequestFollowUp.continues(pushedBranch: "feature", currentBranch: nil, pullRequestFound: false))
    }
}
