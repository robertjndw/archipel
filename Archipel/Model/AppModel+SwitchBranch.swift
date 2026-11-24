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
        // Split by git against the configured remotes: a remote's own name may contain a slash.
        if case .remote(let name) = target, let project = workspace.project(containingWorktree: id),
           let tracking = await git.remoteTrackingBranch(name, in: project.folderURL) {
            // What is known of a remote branch is as old as the last fetch, and the switch should
            // land where the branch is now. A fetch that fails (offline) or is still not done
            // when the deadline passes is not worth refusing the switch for, or holding the sheet
            // any longer: it lands on the branch as last fetched.
            try? await git.fetch(branch: tracking.branch, from: tracking.remote, in: project.folderURL, timeout: Self.switchFetchDeadline)
            try Task.checkCancellation()
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

    /// How long a switch waits for news of the remote branch before it goes ahead without.
    static let switchFetchDeadline = Duration.seconds(5)

    /// The branch a typed name would create. Spaces become dashes so "fix login" is usable as is, and
    /// the configured prefix is added unless the name already carries a prefix of its own.
    func newBranchName(fromTyped typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")
        guard !name.isEmpty else { return nil }
        // A prefix git would reject fails every creation, far from the setting that caused it.
        let prefix = Self.isValidBranchPrefix(settings.branchPrefix) ? settings.branchPrefix : ""
        return prefix.isEmpty || name.hasPrefix(prefix) || name.contains("/") ? name : prefix + name
    }

    /// Whether `prefix` can start a branch name under git's ref rules. Empty is valid: no prefix.
    static func isValidBranchPrefix(_ prefix: String) -> Bool {
        if prefix.isEmpty { return true }
        if prefix.hasPrefix("-") || prefix.hasPrefix("/") || prefix.contains("..") || prefix.contains("//") || prefix.contains("@{") { return false }
        let forbidden = Set(" ~^:?*[\\")
        if prefix.contains(where: { forbidden.contains($0) || $0.unicodeScalars.contains { $0.properties.generalCategory == .control } }) { return false }
        // A path component may not start with a dot or end in ".lock". The last one is still open
        // while the name is being typed, so only a finished one (before a slash) is checked for the end.
        let components = prefix.split(separator: "/", omittingEmptySubsequences: false)
        for (index, component) in components.enumerated() {
            if component.hasPrefix(".") { return false }
            if index < components.count - 1, component.hasSuffix(".lock") { return false }
        }
        return true
    }

    /// Sessions in the worktree with an agent in the middle of something, which includes one that
    /// is waiting for an answer. The sheets warn about these since a switch changes files under
    /// them and a removal stops them.
    func busySessionCount(in id: Worktree.ID) -> Int {
        workspace.worktree(id: id)?.sessions.count { activity(for: $0.id).hasWorkInFlight } ?? 0
    }
}
