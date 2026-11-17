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
    /// False while the worktree is already syncing, without git, or for a folder that is not a
    /// repository as far as the last status poll could tell.
    func canSync(_ id: Worktree.ID?) -> Bool {
        guard let id, isGitAvailable, syncsInFlight[id] == nil else { return false }
        return gitSummaries[id] != nil
    }

    /// A push publishes a branch that has no upstream yet, and the menu should say so.
    func pushPublishes(_ id: Worktree.ID?) -> Bool {
        guard let summary = id.flatMap({ gitSummaries[$0] }) else { return false }
        return summary.branch != nil && summary.upstream == nil
    }

    func sync(_ action: SyncAction, worktree id: Worktree.ID) {
        guard let worktree = workspace.worktree(id: id), isGitAvailable, syncsInFlight[id] == nil else { return }
        syncsInFlight[id] = action
        let git = git
        let folder = worktree.path
        Task { [weak self] in
            var failure: String?
            do {
                switch action {
                case .push: try await git.push(in: folder)
                case .pull: try await git.pull(in: folder)
                case .fetch: try await git.fetch(in: folder)
                }
            } catch is CancellationError {
                // Nobody is waiting for an answer any more.
            } catch {
                failure = error.localizedDescription
            }
            guard let self else { return }
            self.syncsInFlight[id] = nil
            if let failure { self.problem = "\(action.failureTitle) \(failure)" }
            // Also after a failure: a rejected push or a refused pull has usually fetched, so the
            // counts moved anyway. A push can have created the pull request's branch on the remote.
            self.refreshGitStatus(of: [id], lookingUpPullRequests: action == .push, minimumPullRequestAge: .zero)
        }
    }
}
