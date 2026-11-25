import Foundation

/// A push, pull, fetch or commit running for a worktree. One at a time per worktree, whoever
/// started it; see `GitWorktreeState.begin(_:)`.
public enum GitOperation: Equatable, Sendable {
    case commit, push, pull, fetch
}

/// Whether pull, push and fetch make sense for a worktree right now, and what Push is called. The
/// one rule for the Changes tab's sync menu and main button, the Project menu, the palette and the
/// sidebar's batch menu.
public struct GitSyncState: Equatable, Sendable {
    /// Where the action is offered. The two differ on purpose in two places, see `canPush(from:)`.
    public enum Surface: Sendable {
        /// The Changes tab, which shows the counts next to its controls.
        case changesTab
        /// Menus, the palette and the sidebar's batch menu, which act without showing counts and,
        /// in a batch, on several worktrees at once.
        case command
    }

    /// False before the first status read and for a folder that is not a repository. Nothing can
    /// sync then.
    public var isKnown: Bool
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var isDetached: Bool
    public var hasRemote: Bool
    /// Where Publish Branch would push to; nil when git could only guess, see `GitClient.publishRemote`.
    public var publishRemote: String?
    /// The upstream the branch had until it was deleted. Such a branch is unpublished again.
    public var goneUpstream: String?
    public var isBusy: Bool

    /// `remotes` nil means not read yet; an upstream alone already says there is a remote.
    public init(status: GitStatus?, remotes: [String]?, isBusy: Bool) {
        isKnown = status != nil
        upstream = status?.upstream
        ahead = status?.ahead ?? 0
        behind = status?.behind ?? 0
        isDetached = status != nil && status?.branch == nil
        let remotes = remotes ?? []
        hasRemote = status?.upstream != nil || !remotes.isEmpty
        publishRemote = GitClient.publishRemote(among: remotes, goneUpstream: status?.goneUpstream ?? status?.pendingUpstream)
        goneUpstream = status?.goneUpstream
        self.isBusy = isBusy
    }

    public var isPublished: Bool { upstream != nil }

    private var hasBranch: Bool { isKnown && !isDetached }

    /// Pull fetches first, so it is useful even when the last known count is zero.
    public var canPull: Bool { hasBranch && isPublished && !isBusy }

    public var canFetch: Bool { isKnown && hasRemote && !isBusy }

    /// Whether a push has anything to do, ignoring whether an action is already running.
    ///
    /// The Changes tab shows the counts and offers Push only with commits ahead. A command offers
    /// it with nothing ahead too: the user may know of a commit the last poll has not seen, and
    /// git answers "Everything up-to-date" at worst.
    ///
    /// A branch whose upstream was deleted is not pushed by a command. That state is what a merged
    /// pull request leaves behind, and a push would put the branch back on the remote, for every
    /// such worktree of a batch at once. Publishing it again on purpose is in the tab's sync menu.
    public func canPublishOrPush(from surface: Surface) -> Bool {
        guard hasBranch else { return false }
        switch surface {
        case .changesTab:
            return isPublished ? ahead > 0 : publishRemote != nil
        case .command:
            guard goneUpstream == nil else { return false }
            return isPublished || publishRemote != nil
        }
    }

    public func canPush(from surface: Surface) -> Bool {
        canPublishOrPush(from: surface) && !isBusy
    }

    /// Whether Push publishes the branch, which is what its title says then. Not for a command on a
    /// branch whose upstream is gone: that item stays disabled, and should not read as an
    /// invitation to publish while it is.
    public func pushPublishes(from surface: Surface) -> Bool {
        guard isKnown, !isPublished else { return false }
        return surface == .changesTab || (!isDetached && goneUpstream == nil)
    }

    public func pushTitle(from surface: Surface) -> String {
        pushPublishes(from: surface) ? String(localized: "Publish Branch") : String(localized: "Push")
    }

    /// Whether the Changes tab's main button may offer the push. Not for a branch whose upstream was
    /// deleted, for the reason in `canPublishOrPush(from:)`: one click on the main button would put
    /// it back on the remote.
    public var promotesPush: Bool { canPublishOrPush(from: .changesTab) && goneUpstream == nil }

    /// Whether the main button should offer Pull. Also true for a diverged branch: the pull fails
    /// with an explanation, which beats a push that git rejects.
    public var needsPull: Bool { hasBranch && isPublished && behind > 0 }
}
