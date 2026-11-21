import Foundation

/// What a write inside a repository's git directory means for the sidebar.
///
/// Only a handful of paths matter. Everything else git writes (the index, `*.lock` files, objects,
/// reflogs, `FETCH_HEAD`, `ORIG_HEAD`) is ignored on purpose: the app's own `git status` rewrites the
/// index on every poll, and reacting to that would make the poll trigger itself.
public enum GitMetadataChange: Hashable, Sendable {
    /// `HEAD` of the main checkout (nil) or `worktrees/<name>/HEAD` of a linked worktree.
    case head(worktree: String?)
    /// `refs/heads/<branch>`.
    case localBranch(String)
    /// `refs/remotes/<remote>/<branch>`, kept as `<remote>/<branch>` because that is how git spells
    /// an upstream, and a remote name may itself contain a slash.
    case remoteBranch(String)
    /// `packed-refs` or a reftable: some refs changed, and which ones would take reading them.
    case refs
    /// A linked worktree was added, removed or moved.
    case worktreeList

    /// `path` is relative to the repository's common git directory, with `/` separators.
    public init?(relativePath path: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = parts.last, !last.hasSuffix(".lock") else { return nil }
        switch parts.first {
        case "HEAD" where parts.count == 1:
            self = .head(worktree: nil)
        case "packed-refs" where parts.count == 1:
            self = .refs
        case "reftable":
            self = .refs
        case "refs" where parts.count >= 3 && parts[1] == "heads":
            self = .localBranch(parts.dropFirst(2).joined(separator: "/"))
        case "refs" where parts.count >= 4 && parts[1] == "remotes":
            // `origin/HEAD` only points at another remote branch and moves with `remote set-head`.
            guard parts.count > 4 || parts[3] != "HEAD" else { return nil }
            self = .remoteBranch(parts.dropFirst(2).joined(separator: "/"))
        case "worktrees":
            switch parts.count {
            // The folder itself, or `worktrees` when the first one is added or the last one removed.
            case 1, 2: self = .worktreeList
            case 3 where last == "HEAD": self = .head(worktree: parts[1])
            // Rewritten when a worktree is moved or repaired; the folder keeps its name then.
            case 3 where last == "gitdir": self = .worktreeList
            // A reftable repository keeps each worktree's HEAD in its own table, not a HEAD file.
            case 4... where parts[2] == "reftable": self = .head(worktree: parts[1])
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Paths git rewrites as a side effect of reading or fetching, whose loss tells nothing about
    /// refs. FSEvents flags a dropped batch with the folder it gave up on, and a dropped batch under
    /// `objects` during a big fetch must not look like "anything may have changed".
    public static func isChurn(relativePath path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = parts.last else { return false }
        if churnFolders.contains(parts[0]) { return true }
        if parts.count >= 3, parts[0] == "worktrees", churnFolders.contains(parts[2]) { return true }
        return last.hasSuffix(".lock") || churnFiles.contains(last) || last.hasPrefix("sharedindex.")
    }

    private static let churnFolders: Set<Substring> = ["objects", "logs", "lfs", "hooks", "info", "rr-cache", "modules"]
    private static let churnFiles: Set<Substring> = [
        "index", "FETCH_HEAD", "ORIG_HEAD", "AUTO_MERGE", "COMMIT_EDITMSG", "MERGE_MSG", "MERGE_HEAD", "SQUASH_MSG", "gc.pid", "gc.log",
    ]
}

/// How a checkout is tied to its repository's git directory, which is what lets a change to
/// `worktrees/<name>/HEAD` be traced back to a folder in the sidebar.
public enum GitWorktreeLink: Hashable, Sendable {
    /// `.git` is the repository itself.
    case main
    /// `.git` is a file pointing at `worktrees/<name>` in the main checkout's git directory.
    case linked(String)
    /// Not a checkout root (a subfolder of a repository, a submodule, a plain or missing folder).
    case unknown

    /// Reads `<folder>/.git`. Touches the disk, so keep it off the main thread.
    public static func of(_ folder: URL) -> GitWorktreeLink {
        let dotGit = folder.appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path(percentEncoded: false), isDirectory: &isDirectory) else { return .unknown }
        if isDirectory.boolValue { return .main }
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8) else { return .unknown }
        return GitWorktreeLink(dotGitFile: contents)
    }

    /// Parses the `gitdir: <path>` line of a linked worktree's `.git` file. The path may be
    /// relative (`worktree.useRelativePaths`), so only its last two components are looked at.
    public init(dotGitFile contents: String) {
        let line = contents.split(whereSeparator: \.isNewline).first { $0.hasPrefix("gitdir:") }
        let path = line.map { $0.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces) } ?? ""
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[parts.count - 2] == "worktrees" else {
            self = .unknown
            return
        }
        self = .linked(String(parts[parts.count - 1]))
    }
}

/// A tracked checkout of a watched repository, as the planner needs to see it.
public struct GitWatchedWorktree<ID: Hashable & Sendable>: Sendable {
    public var id: ID
    public var link: GitWorktreeLink
    public var branch: String?
    /// As `git status` reports it (`origin/feature`); nil when unknown or not set.
    public var upstream: String?
    /// Whether its row is on screen and therefore worth a `git status`.
    public var isOnScreen: Bool

    public init(id: ID, link: GitWorktreeLink, branch: String?, upstream: String?, isOnScreen: Bool) {
        self.id = id
        self.link = link
        self.branch = branch
        self.upstream = upstream
        self.isOnScreen = isOnScreen
    }
}

/// The refreshes a batch of changes calls for.
public struct GitChangeResponse<ID: Hashable & Sendable>: Equatable, Sendable {
    /// Only the branch name, for checkouts whose rows are not on screen: a name is one cheap git
    /// call, and the island switcher, the peek and the menu bar show it without a row.
    public var branchReads: Set<ID> = []
    public var statusRefreshes: Set<ID> = []
    /// Checkouts whose remote branch moved, with that remote branch (`origin/feature`). It is a push
    /// only when the remote branch now points where the local one does, which the caller checks;
    /// otherwise someone else's commits were fetched. Each gets at least a status refresh.
    public var pushCandidates: [ID: String] = [:]
    public var discoversWorktrees = false

    public init() {}

    public var isEmpty: Bool {
        branchReads.isEmpty && statusRefreshes.isEmpty && pushCandidates.isEmpty && !discoversWorktrees
    }

    public static func plan(for changes: Set<GitMetadataChange>, in worktrees: [GitWatchedWorktree<ID>]) -> GitChangeResponse {
        var response = GitChangeResponse()
        func touch(_ worktree: GitWatchedWorktree<ID>) {
            if worktree.isOnScreen {
                response.statusRefreshes.insert(worktree.id)
            } else {
                response.branchReads.insert(worktree.id)
            }
        }
        for change in changes {
            switch change {
            case .head(let name):
                let link: GitWorktreeLink = name.map { .linked($0) } ?? .main
                // A checkout that could not be tied to its git directory might be the one that
                // moved, and a branch read is cheap enough to ask it anyway.
                for worktree in worktrees where worktree.link == link || worktree.link == .unknown { touch(worktree) }
            case .localBranch(let branch):
                // A commit, reset or rebase moves the branch without touching HEAD. The name of a
                // hidden checkout does not change with it, so only rows on screen are refreshed.
                for worktree in worktrees where worktree.branch == branch && worktree.isOnScreen {
                    response.statusRefreshes.insert(worktree.id)
                }
            case .remoteBranch(let remoteBranch):
                for worktree in worktrees where tracks(worktree, remoteBranch) {
                    response.pushCandidates[worktree.id] = remoteBranch
                }
            case .refs:
                for worktree in worktrees { touch(worktree) }
            case .worktreeList:
                response.discoversWorktrees = true
            }
        }
        let candidates = Set(response.pushCandidates.keys)
        response.statusRefreshes.subtract(candidates)
        response.branchReads.subtract(response.statusRefreshes.union(candidates))
        return response
    }

    /// Without a known upstream, the branch of the same name: a first `git push -u` creates the
    /// remote branch before the upstream is ever seen.
    private static func tracks(_ worktree: GitWatchedWorktree<ID>, _ remoteBranch: String) -> Bool {
        if let upstream = worktree.upstream { return upstream == remoteBranch }
        guard let branch = worktree.branch else { return false }
        return remoteBranch.hasSuffix("/" + branch)
    }
}

/// After a push, a pull request is usually opened within a minute or two (`gh pr create`, or the
/// link git prints), and the regular lookup is minutes apart. These ask a few more times.
public enum PullRequestFollowUp {
    /// When to ask again, counted from the push.
    public static let schedule: [Duration] = [.seconds(15), .seconds(45), .seconds(120)]

    /// The pauses between lookups that hit `schedule`.
    public static var waits: [Duration] {
        var previous = Duration.zero
        return schedule.map { at in
            defer { previous = at }
            return at - previous
        }
    }

    /// Stops once the checkout moved to another branch, whose pull request is not what the push was
    /// about, or once a pull request for the pushed branch has turned up.
    public static func continues(pushedBranch: String, currentBranch: String?, pullRequestFound: Bool) -> Bool {
        currentBranch == pushedBranch && !pullRequestFound
    }
}
