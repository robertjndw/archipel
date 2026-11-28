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

    var operation: GitOperation {
        switch self {
        case .push: .push
        case .pull: .pull
        case .fetch: .fetch
        }
    }
}

/// Push, pull and fetch without the inspector. Same git calls and the same `GitSyncState` rule as
/// the Changes panel: a push publishes a branch that has no upstream yet, and a pull only
/// fast-forwards. The worktree's `GitWorktreeState` holds the one running operation, so a push from
/// here and one from the panel never overlap and each shows the other's progress.
extension AppModel {
    /// False without git, before the first status read, while anything runs in the worktree, and
    /// when the action could only fail. See `GitSyncState.canPush(from:)` for where this Push
    /// differs from the Changes tab's on purpose.
    func canSync(_ action: SyncAction, _ id: Worktree.ID?) -> Bool {
        guard let id, isGitAvailable, let sync = gitState(for: id)?.syncState else { return false }
        switch action {
        case .pull: return sync.canPull
        case .push: return sync.canPush(from: .command)
        case .fetch: return sync.canFetch
        }
    }

    /// A push publishes a branch that has no upstream yet, and the menu should say so.
    func pushPublishes(_ id: Worktree.ID?) -> Bool {
        guard let id else { return false }
        return gitState(for: id)?.syncState.pushPublishes(from: .command) ?? false
    }

    /// What the menu item says. The ellipsis is there while Publish opens the name sheet first.
    func pushTitle(_ id: Worktree.ID?) -> String {
        guard pushPublishes(id) else { return "Push" }
        return needsBranchName(id) ? "Publish Branch…" : "Publish Branch"
    }

    /// A push of a branch that still has its generated name asks for the real one first, see
    /// `needsBranchName(_:)`. The name sheet pushes once it is answered.
    func sync(_ action: SyncAction, worktree id: Worktree.ID) {
        if action == .push, needsBranchName(id) {
            requestBranchName(for: id, purpose: .publish)
            return
        }
        Task { await performSync(action, worktree: id) }
    }

    /// The push after the name sheet. Past the name check, which has just been answered.
    func publishBranch(of id: Worktree.ID) {
        Task { await performSync(.push, worktree: id) }
    }

    /// Whether a batch over several worktrees includes this one. A batch never opens sheets, so a
    /// branch that still needs a name is left for the user to publish on its own.
    func canSyncInBatch(_ action: SyncAction, _ id: Worktree.ID) -> Bool {
        canSync(action, id) && !(action == .push && needsBranchName(id))
    }

    /// For several worktrees picked in the sidebar. One after the other, since they often share a
    /// repository and git locks its refs while it fetches. The ones that cannot sync are skipped.
    func sync(_ action: SyncAction, worktrees ids: [Worktree.ID]) {
        let ids = ids.filter { canSyncInBatch(action, $0) }
        guard !ids.isEmpty else { return }
        Task {
            for id in ids { await performSync(action, worktree: id, namingIt: true) }
        }
    }

    private func performSync(_ action: SyncAction, worktree id: Worktree.ID, namingIt: Bool = false) async {
        guard let worktree = workspace.worktree(id: id), isGitAvailable, let state = gitState(for: id),
              state.begin(action.operation)
        else { return }
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
        if let failure {
            // In a batch the user has to be told which of the worktrees it was.
            problem = namingIt ? "\(action.failureTitle) \(worktree.displayName): \(failure)" : "\(action.failureTitle) \(failure)"
        }
        // Also after a failure: a rejected push or a refused pull has usually fetched, so the
        // counts moved anyway. A push can have created the pull request's branch on the remote.
        // Before the operation ends, like in the Changes tab, so the action that just ran is not
        // offered again for a moment on the old counts.
        await state.refresh(GitRefreshRequest(readsRemotes: action == .push, pullRequestAge: action == .push ? .zero : nil))
        state.end(action.operation)
    }
}
