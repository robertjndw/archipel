import Foundation

public struct GitError: Error, LocalizedError, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct GitWorktreeEntry: Equatable, Sendable {
    public var path: URL
    public var branch: String?
    public var isMain: Bool
    /// Locked worktrees refuse `git worktree remove` unless forced twice.
    public var isLocked: Bool
    /// Git still knows the worktree but its folder is gone; `git worktree prune` would drop it.
    public var isPrunable: Bool
    /// The repository itself when it has no working tree. Its path is the git directory, with
    /// nothing checked out to open or edit.
    public var isBare: Bool

    public init(path: URL, branch: String?, isMain: Bool, isLocked: Bool = false, isPrunable: Bool = false, isBare: Bool = false) {
        self.path = path
        self.branch = branch
        self.isMain = isMain
        self.isLocked = isLocked
        self.isPrunable = isPrunable
        self.isBare = isBare
    }
}

/// What `git branch -d` did with a branch.
public enum GitBranchDeletion: Equatable, Sendable {
    case deleted
    /// Not merged into HEAD or its upstream, so git kept it rather than lose commits.
    case keptUnmerged
}

public enum GitChangeKind: Sendable {
    case modified, added, deleted, renamed, copied, typeChanged, untracked, conflicted
}

public struct GitFileChange: Identifiable, Equatable, Sendable {
    public var path: String
    public var originalPath: String?
    public var kind: GitChangeKind

    public init(path: String, originalPath: String? = nil, kind: GitChangeKind) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
    }

    public var id: String { path }

    /// Status lists untracked files one by one, so the only folder it reports (with a trailing
    /// slash) is one git will not look into: a nested repository or a linked worktree.
    public var isDirectory: Bool { path.hasSuffix("/") }
}

public struct GitStatus: Equatable, Sendable {
    public var branch: String?
    public var staged: [GitFileChange]
    public var unstaged: [GitFileChange]
    /// Short name of the upstream, e.g. `origin/main`; nil when the branch tracks nothing, and
    /// also when what it tracks does not exist, see `goneUpstream` and `pendingUpstream`.
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    /// The configured upstream when its remote-tracking branch is gone, typically pruned by a fetch
    /// after the pull request was merged and the branch deleted. There is nothing to compare with
    /// or pull from then, so `upstream` is nil and the branch counts as unpublished.
    public var goneUpstream: String?
    /// The configured upstream when it has not been created yet: the branch has no commit, or its
    /// remote has no branch at all, as in the clone of an empty repository. Unlike a gone one,
    /// nothing was ever deleted there, and the first push is what brings it into being.
    public var pendingUpstream: String?

    public init(
        branch: String?,
        staged: [GitFileChange],
        unstaged: [GitFileChange],
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        goneUpstream: String? = nil,
        pendingUpstream: String? = nil
    ) {
        self.branch = branch
        self.staged = staged
        self.unstaged = unstaged
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.goneUpstream = goneUpstream
        self.pendingUpstream = pendingUpstream
    }

    public static let empty = GitStatus(branch: nil, staged: [], unstaged: [])
}

/// What a sidebar row needs about a worktree, cheap enough to poll for many of them.
public struct GitSummary: Equatable, Sendable {
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    /// Distinct paths, so a file that is both staged and modified again counts once.
    public var changedFiles: Int
    /// Not part of `summary(in:)`, which is one status call; callers that want it ask `diffStat(in:)`.
    public var diffStat: GitDiffStat?
    /// See `GitStatus.goneUpstream`.
    public var goneUpstream: String?
    /// See `GitStatus.pendingUpstream`.
    public var pendingUpstream: String?

    public init(
        branch: String?,
        upstream: String?,
        ahead: Int,
        behind: Int,
        changedFiles: Int,
        diffStat: GitDiffStat? = nil,
        goneUpstream: String? = nil,
        pendingUpstream: String? = nil
    ) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changedFiles = changedFiles
        self.diffStat = diffStat
        self.goneUpstream = goneUpstream
        self.pendingUpstream = pendingUpstream
    }
}

/// Where `GitClient.switchBranch` takes a checkout.
public enum GitSwitchTarget: Equatable, Sendable {
    /// A local branch.
    case local(String)
    /// A remote-tracking branch such as `origin/feature`. Creates the local branch `feature` tracking it.
    case remote(String)
    /// A new branch from `base`, or from HEAD when `base` is nil.
    case new(String, base: String?)
}
