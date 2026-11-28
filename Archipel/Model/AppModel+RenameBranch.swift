import ArchipelCore
import Foundation
import GitKit

/// What the branch name sheet is open for.
struct BranchNameRequest: Identifiable, Equatable {
    enum Purpose: Equatable {
        case rename
        /// Publish was asked for while the branch still had its generated name. The sheet renames
        /// it, or keeps the name on purpose, and then pushes.
        case publish
    }

    var worktreeID: Worktree.ID
    var purpose: Purpose

    var id: Worktree.ID { worktreeID }
}

extension AppModel {
    /// Only before the branch is on a remote. Renaming a published branch leaves the old one
    /// behind there, and on GitHub a renamed head closes its pull request, so that stays a job for
    /// the terminal. A gone or pending upstream does not count as published: nothing of this name
    /// is on the remote now.
    func canRenameBranch(_ id: Worktree.ID?) -> Bool {
        guard let id, isGitAvailable, let worktree = workspace.worktree(id: id), !worktree.isMain,
              worktree.branch != nil, !missingWorktrees.contains(id),
              let state = gitState(for: id), let status = state.status
        else { return false }
        return status.branch != nil && status.upstream == nil && !state.syncState.isBusy
    }

    /// Whether Publish should ask for a name first: the branch still has the name the app made up,
    /// and nothing has published it yet. An agent that pushed the placeholder from a terminal gave
    /// it an upstream, and then the name stands.
    func needsBranchName(_ id: Worktree.ID?) -> Bool {
        guard let id, let worktree = workspace.worktree(id: id), worktree.isOnPlaceholderBranch,
              let status = gitState(for: id)?.status
        else { return false }
        return status.upstream == nil
    }

    func requestBranchName(for id: Worktree.ID, purpose: BranchNameRequest.Purpose) {
        guard readyForSheet() else { return }
        branchNameRequest = BranchNameRequest(worktreeID: id, purpose: purpose)
    }

    /// Renames the worktree's branch with `git branch -m`, which refuses a name that is taken, so
    /// a name claimed after the sheet checked it fails here instead of overwriting anything.
    func renameBranch(of id: Worktree.ID, to name: String) async throws {
        guard let worktree = workspace.worktree(id: id) else { return }
        try requireGit()
        // Asked fresh because the cached name lags behind a checkout made in a terminal, and
        // renaming whatever the sidebar last saw could hit another branch.
        guard let current = await git.currentBranch(in: worktree.path) else {
            throw GitError(message: "The worktree is not on a branch, so there is nothing to rename.")
        }
        // Bumped on both sides, for the reason in `switchBranch(of:to:)`: a branch or status read
        // that started before the rename would otherwise write the old name back.
        let state = gitState(for: id)
        branchGenerations[id, default: 0] += 1
        state?.invalidatePendingReads()
        try await git.renameBranch(current, to: name, in: worktree.path)
        branchGenerations[id, default: 0] += 1
        state?.invalidatePendingReads()
        mutate {
            $0.updateWorktree(id: id) {
                $0.branch = name
                $0.placeholderBranch = nil
            }
        }
        refreshGitStatus(of: [id], lookingUpPullRequests: true, minimumPullRequestAge: .zero)
    }

    /// The user chose to publish under the generated name, so Publish stops asking.
    func keepGeneratedBranchName(of id: Worktree.ID) {
        mutate { $0.updateWorktree(id: id) { $0.placeholderBranch = nil } }
    }
}
