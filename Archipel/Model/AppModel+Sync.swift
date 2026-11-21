import ArchipelCore
import Foundation
import GitKit

/// A push, pull or fetch asked for from the Project menu or the palette.
enum SyncAction {
    case push, pull, fetch

    var failureTitle: String {
        switch self {
        case .push: "The push failed."
        case .pull: "The pull failed."
        case .fetch: "The fetch failed."
        }
    }
}

/// Push, pull and fetch without the inspector. Same git calls as the Changes panel, so the rules are
/// the same too: a push publishes a branch that has no upstream yet, and a pull only fast-forwards.
extension AppModel {
    /// False while the worktree is already syncing, without git, for a folder that is not a
    /// repository as far as the last status poll could tell, and when the action could only fail:
    /// nothing to pull from, nowhere to publish to, no remote to fetch. The Changes tab's sync menu
    /// draws the same lines, except that this Push stays available with nothing ahead.
    func canSync(_ action: SyncAction, _ id: Worktree.ID?) -> Bool {
        guard let id, isGitAvailable, syncsInFlight[id] == nil, let summary = gitSummaries[id] else { return false }
        let hasRemote = summary.upstream != nil || worktreesWithRemote.contains(id)
        switch action {
        case .pull: return summary.branch != nil && summary.upstream != nil
        case .push: return summary.branch != nil && hasRemote
        case .fetch: return hasRemote
        }
    }

    /// A push publishes a branch that has no upstream yet, and the menu should say so.
    func pushPublishes(_ id: Worktree.ID?) -> Bool {
        guard let summary = id.flatMap({ gitSummaries[$0] }) else { return false }
        return summary.branch != nil && summary.upstream == nil
    }

    func sync(_ action: SyncAction, worktree id: Worktree.ID) {
        Task { await performSync(action, worktree: id) }
    }

    /// For several worktrees picked in the sidebar. One after the other, since they often share a
    /// repository and git locks its refs while it fetches. The ones that cannot sync are skipped.
    func sync(_ action: SyncAction, worktrees ids: [Worktree.ID]) {
        let ids = ids.filter { canSync(action, $0) }
        guard !ids.isEmpty else { return }
        Task {
            for id in ids { await performSync(action, worktree: id, namingIt: true) }
        }
    }

    private func performSync(_ action: SyncAction, worktree id: Worktree.ID, namingIt: Bool = false) async {
        guard let worktree = workspace.worktree(id: id), isGitAvailable, syncsInFlight[id] == nil else { return }
        syncsInFlight[id] = action
        var failure: String?
        do {
            switch action {
            case .push: try await git.push(in: worktree.path)
            case .pull: try await git.pull(in: worktree.path)
            case .fetch: try await git.fetch(in: worktree.path, userInitiated: true)
            }
        } catch is CancellationError {
            // Nobody is waiting for an answer any more.
        } catch {
            failure = error.localizedDescription
        }
        syncsInFlight[id] = nil
        if let failure {
            // In a batch the user has to be told which of the worktrees it was.
            problem = namingIt ? "\(action.failureTitle) \(worktree.displayName): \(failure)" : "\(action.failureTitle) \(failure)"
        }
        // Also after a failure: a rejected push or a refused pull has usually fetched, so the
        // counts moved anyway. A push can have created the pull request's branch on the remote.
        refreshGitStatus(of: [id], lookingUpPullRequests: action == .push, minimumPullRequestAge: .zero)
    }
}
