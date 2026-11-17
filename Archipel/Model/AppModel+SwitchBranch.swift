import ArchipelCore
import Foundation
import GitKit

extension AppModel {
    /// Checks out another branch in the worktree's own folder, as opposed to `createWorktree`, which
    /// puts a branch in a new folder. Throws git's explanation when it refuses, for example because
    /// uncommitted changes would be overwritten or the branch is checked out in another worktree.
    ///
    /// `releasingLeftover` is the user's word that a missing worktree holding the branch was
    /// deleted; without it that case throws `LeftoverWorktreeError` for the sheet to ask about.
    func switchBranch(of id: Worktree.ID, to target: GitSwitchTarget, releasingLeftover: Bool = false) async throws {
        guard let worktree = workspace.worktree(id: id) else { return }
        try requireGit()
        if case .local(let branch) = target, let project = workspace.project(containingWorktree: id) {
            try await releasePrunedBranch(branch, in: project, confirmed: releasingLeftover)
        }
        // Bumped on both sides of the checkout: a branch name read while it runs can be either one.
        branchGenerations[id, default: 0] += 1
        try await git.switchBranch(to: target, in: worktree.path)
        // Ask git instead of guessing from the target, e.g. `.remote("origin/x")` ends up on `x`.
        let branch = await git.currentBranch(in: worktree.path)
        branchGenerations[id, default: 0] += 1
        mutate { $0.updateWorktree(id: id) { $0.branch = branch } }
        // The old branch's counts and pull request would otherwise linger until the next poll.
        refreshGitStatus(of: [id], lookingUpPullRequests: true, minimumPullRequestAge: .zero)
    }

    /// The branch a typed name would create. Spaces become dashes so "fix login" is usable as is, and
    /// the configured prefix is added unless the name already carries a prefix of its own.
    func newBranchName(fromTyped typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")
        guard !name.isEmpty else { return nil }
        let prefix = settings.branchPrefix
        return prefix.isEmpty || name.hasPrefix(prefix) || name.contains("/") ? name : prefix + name
    }

    /// Sessions in the worktree with an agent in the middle of something, which includes one that
    /// is waiting for an answer. The sheets warn about these since a switch changes files under
    /// them and a removal stops them.
    func busySessionCount(in id: Worktree.ID) -> Int {
        workspace.worktree(id: id)?.sessions.count { activity(for: $0.id).isBusy || activity(for: $0.id).needsUser } ?? 0
    }
}
