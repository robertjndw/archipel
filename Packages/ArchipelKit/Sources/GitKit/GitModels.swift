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

    public init(path: URL, branch: String?, isMain: Bool, isLocked: Bool = false, isPrunable: Bool = false) {
        self.path = path
        self.branch = branch
        self.isMain = isMain
        self.isLocked = isLocked
        self.isPrunable = isPrunable
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
}

public struct GitStatus: Equatable, Sendable {
    public var branch: String?
    public var staged: [GitFileChange]
    public var unstaged: [GitFileChange]
    /// Short name of the upstream, e.g. `origin/main`; nil when the branch tracks nothing.
    public var upstream: String?
    public var ahead: Int
    public var behind: Int

    public init(
        branch: String?,
        staged: [GitFileChange],
        unstaged: [GitFileChange],
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0
    ) {
        self.branch = branch
        self.staged = staged
        self.unstaged = unstaged
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
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

    public init(branch: String?, upstream: String?, ahead: Int, behind: Int, changedFiles: Int, diffStat: GitDiffStat? = nil) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changedFiles = changedFiles
        self.diffStat = diffStat
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
