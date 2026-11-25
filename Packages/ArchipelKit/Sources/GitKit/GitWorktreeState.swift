import Foundation
import Observation

/// The last pull request answer for a worktree, with the branch it was asked for: after a branch
/// switch the old answer must not be shown, even before the next lookup.
public struct PullRequestLookup: Equatable, Sendable {
    public var branch: String
    /// After a failed lookup this is still the answer from before it: a dropped connection or an
    /// expired `gh` login says nothing about the pull request, and the badge should not blink away.
    public var pullRequest: GitPullRequest?
    public var checkedAt: ContinuousClock.Instant
    /// Lookups in a row that failed, for this branch.
    public var failures: Int

    public init(branch: String, pullRequest: GitPullRequest?, checkedAt: ContinuousClock.Instant, failures: Int = 0) {
        self.branch = branch
        self.pullRequest = pullRequest
        self.checkedAt = checkedAt
        self.failures = failures
    }

    public var answer: PullRequestFreshness.Answer {
        if failures > 0 { return .failed(repeatedly: failures > 1) }
        return pullRequest == nil ? .none : .found
    }
}

/// What one refresh of a `GitWorktreeState` reads besides the status.
public struct GitRefreshRequest: Equatable, Sendable {
    /// Ask `git remote` even though the branch has an upstream. Without one it is asked anyway,
    /// since that is when the remotes decide whether the branch can be published.
    public var readsRemotes: Bool
    /// Look up the pull request when the last answer for the branch is at least this old; nil
    /// leaves it alone. See `PullRequestFreshness`.
    public var pullRequestAge: Duration?

    public init(readsRemotes: Bool = false, pullRequestAge: Duration? = nil) {
        self.readsRemotes = readsRemotes
        self.pullRequestAge = pullRequestAge
    }

    func merged(with other: GitRefreshRequest) -> GitRefreshRequest {
        let age: Duration? = switch (pullRequestAge, other.pullRequestAge) {
        case (let mine?, let theirs?): min(mine, theirs)
        case (let mine, let theirs): mine ?? theirs
        }
        return GitRefreshRequest(readsRemotes: readsRemotes || other.readsRemotes, pullRequestAge: age)
    }
}

/// What the states of one store share: the git client, the app's settings and `gh`.
@MainActor
public final class GitStateEnvironment {
    let git: GitClient
    /// Whether line counts are wanted; a diff reads every changed file, so they cost more than the status.
    let countsLines: @MainActor () -> Bool
    /// Off means no lookups and no pull request shown anywhere. Read in views, so an observable
    /// setting behind it redraws them when it changes.
    let looksUpPullRequests: @MainActor () -> Bool
    private let searchPATH: @MainActor () async -> String
    private var gitHub: Task<GitHubClient?, Never>?

    public init(
        git: GitClient = GitClient(),
        countsLines: @escaping @MainActor () -> Bool = { false },
        looksUpPullRequests: @escaping @MainActor () -> Bool = { false },
        searchPATH: @escaping @MainActor () async -> String = { "" }
    ) {
        self.git = git
        self.countsLines = countsLines
        self.looksUpPullRequests = looksUpPullRequests
        self.searchPATH = searchPATH
    }

    /// Resolved once when found: whether `gh` is installed does not change often enough to justify
    /// searching the PATH for every lookup.
    func gitHubClient() -> Task<GitHubClient?, Never> {
        if let gitHub { return gitHub }
        let searchPATH = searchPATH
        let task = Task { GitHubClient(searchPATH: await searchPATH()) }
        gitHub = task
        return task
    }

    /// A missing `gh` is looked for again next time, since it may be installed while the app runs.
    func forgetMissingGitHub(_ task: Task<GitHubClient?, Never>) {
        if gitHub == task { gitHub = nil }
    }
}

/// Everything the app knows about one worktree's repository: the status, line counts, remotes,
/// pull request and the push, pull, fetch or commit running in it. The sidebar, the menus, the
/// sheets and the Changes tab all read this one object, and every git command any of them runs
/// refreshes it, so no two places can show two different answers.
@MainActor @Observable
public final class GitWorktreeState {
    public let root: URL
    /// The last status git gave. Kept when a later read fails, so a moment of index.lock does not
    /// empty the list or the sidebar row. Nil before the first read and for a folder that is not a
    /// repository.
    public private(set) var status: GitStatus?
    /// False once git said the folder is not (or no longer) a repository; nil until it was asked.
    public private(set) var isRepository: Bool?
    /// Why the last read failed in a folder that is a repository.
    public private(set) var refreshError: String?
    /// Only kept while there are changes and `GitStateEnvironment.countsLines` says so.
    public private(set) var diffStat: GitDiffStat?
    /// The configured remotes; nil until read.
    public private(set) var remotes: [String]?
    public private(set) var pullRequestLookup: PullRequestLookup?
    public private(set) var operation: GitOperation?

    @ObservationIgnored private let environment: GitStateEnvironment
    /// Told about every status read that was kept, for the host to follow the branch name.
    @ObservationIgnored var onStatusRead: ((GitStatus) -> Void)?
    /// Bumped by `invalidatePendingReads()`. A read that started under an older value is dropped.
    @ObservationIgnored private var generation = 0
    /// Reads run one after another, so a later one always lands after an earlier one. What is asked
    /// for while one runs is merged into the next.
    @ObservationIgnored private var pending: GitRefreshRequest?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var diffStatCheckedAt: ContinuousClock.Instant?
    /// The branch the running lookup was started for.
    @ObservationIgnored private var pullRequestInFlight: String?
    /// A lookup asked for while another ran for a different branch, or forced, with the age it asked for.
    @ObservationIgnored private var pullRequestQueued: Duration?

    /// Unlike the status, a diff reads every changed file. While the status stays the same the last
    /// count is reused for this long, so a huge generated file is not diffed on every poll.
    static let diffStatInterval = Duration.seconds(60)

    public init(root: URL, environment: GitStateEnvironment = GitStateEnvironment()) {
        self.root = root
        self.environment = environment
    }

    public var summary: GitSummary? {
        status.map { GitSummary($0, diffStat: diffStat) }
    }

    public var syncState: GitSyncState {
        GitSyncState(status: status, remotes: remotes, isBusy: operation != nil)
    }

    /// The pull request of the branch that is checked out. A lookup made for a branch the worktree
    /// has since switched away from does not count, and none counts while lookups are turned off.
    public var pullRequest: GitPullRequest? {
        guard environment.looksUpPullRequests(), let lookup = pullRequestLookup,
              let branch = status?.branch, lookup.branch == branch
        else { return nil }
        return lookup.pullRequest
    }

    // MARK: Operations

    /// Claims the worktree for `operation`. False while another push, pull, fetch or commit runs
    /// there, from whichever part of the app started it; the caller then does nothing.
    public func begin(_ operation: GitOperation) -> Bool {
        guard self.operation == nil else { return false }
        self.operation = operation
        return true
    }

    public func end(_ operation: GitOperation) {
        if self.operation == operation { self.operation = nil }
    }

    // MARK: Reading

    /// Returns once a read that started after this call has landed.
    public func refresh(_ request: GitRefreshRequest = GitRefreshRequest()) async {
        pending = pending.map { $0.merged(with: request) } ?? request
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            startReading()
        }
    }

    /// For callers that do not wait.
    public func requestRefresh(_ request: GitRefreshRequest = GitRefreshRequest()) {
        Task { await refresh(request) }
    }

    /// For a change made in the app that a read already running cannot have seen, such as a branch
    /// switch: what that read brings back is dropped, and the next one is what counts.
    public func invalidatePendingReads() {
        generation += 1
    }

    private func startReading() {
        guard reader == nil else { return }
        reader = Task {
            while let request = pending {
                pending = nil
                let served = waiters
                waiters = []
                await read(request)
                for waiter in served { waiter.resume() }
            }
            reader = nil
        }
    }

    private func read(_ request: GitRefreshRequest) async {
        let generation = generation
        let git = environment.git
        let root = root
        let previous = status
        var read: GitStatus?
        var failure: String?
        var isRepository = true
        do {
            read = try await git.status(in: root)
        } catch {
            // A folder that is not a repository, or has vanished, throws as well as a repository
            // git could not read for a moment.
            isRepository = await git.isRepository(root)
            failure = error.localizedDescription
        }

        // A read that failed in a repository keeps the counts of the status it keeps.
        var diffStat = diffStat
        var countedLines = false
        if let read {
            if read.changedFiles > 0, environment.countsLines() {
                let isFresh = diffStatCheckedAt.map { $0.duration(to: .now) < Self.diffStatInterval } ?? false
                if !(isFresh && read == previous && diffStat != nil) {
                    // Throws on an unborn branch, which leaves the line counts out and the file count in.
                    diffStat = try? await git.diffStat(in: root)
                    countedLines = true
                }
            } else {
                diffStat = nil
            }
        } else if !isRepository {
            diffStat = nil
        }

        var remotes: [String]?
        if let read, request.readsRemotes || read.upstream == nil || self.remotes == nil {
            remotes = await git.remoteNames(in: root)
        }

        guard generation == self.generation else { return }
        if countedLines { diffStatCheckedAt = .now }
        if let read {
            if status != read { status = read }
            if self.isRepository != true { self.isRepository = true }
            if refreshError != nil { refreshError = nil }
        } else if !isRepository {
            if status != nil { status = nil }
            if self.isRepository != false { self.isRepository = false }
            if refreshError != nil { refreshError = nil }
        } else if refreshError != failure {
            refreshError = failure
        }
        if self.diffStat != diffStat { self.diffStat = diffStat }
        if let remotes, self.remotes != remotes { self.remotes = remotes }
        if let read { onStatusRead?(read) }
        if let age = request.pullRequestAge { lookUpPullRequest(minimumAge: age) }
    }

    /// A missing `gh` means no pull request. Any other failure keeps the one that was there.
    private func lookUpPullRequest(minimumAge: Duration) {
        guard environment.looksUpPullRequests() else { return }
        // No upstream is not enough to skip: `gh` matches the branch name, and a branch pushed
        // without `-u` (`git push origin HEAD`) can have a pull request all the same.
        guard let status, let branch = status.branch, status.upstream != nil || !(remotes ?? []).isEmpty else {
            // Runs with every poll for each worktree without a remote, and writing nil over nil
            // would still redraw the sidebar.
            if pullRequestLookup != nil { pullRequestLookup = nil }
            return
        }
        if let last = pullRequestLookup, last.branch == branch,
           !PullRequestFreshness.isDue(
               last.answer,
               age: last.checkedAt.duration(to: .now),
               hasUpstream: status.upstream != nil,
               requestedAge: minimumAge
           ) {
            return
        }
        if let asked = pullRequestInFlight {
            // The running lookup answers for the branch it was started on. After a switch that
            // answer is filed under the old name, and without this nothing would ask again until
            // the next refresh that looks up pull requests. A forced lookup is queued even for the
            // same branch, since the running one may have asked just before the PR was opened.
            if asked != branch || minimumAge == .zero {
                pullRequestQueued = min(pullRequestQueued ?? minimumAge, minimumAge)
            }
            return
        }
        pullRequestInFlight = branch
        let gitHub = environment.gitHubClient()
        let root = root
        Task {
            let client = await gitHub.value
            var pullRequest: GitPullRequest?
            // Counts as a failure so a missing `gh` backs off instead of being searched for every minute.
            var failed = client == nil
            if let client {
                do {
                    pullRequest = try await client.pullRequest(in: root)
                } catch {
                    failed = true
                }
            }
            if client == nil { environment.forgetMissingGitHub(gitHub) }
            pullRequestInFlight = nil
            let queued = pullRequestQueued
            pullRequestQueued = nil
            var failures = 0
            if failed {
                let previous = pullRequestLookup.flatMap { $0.branch == branch ? $0 : nil }
                // Without `gh` there is nothing left to vouch for the old answer.
                if client != nil { pullRequest = previous?.pullRequest }
                failures = (previous?.failures ?? 0) + 1
            }
            pullRequestLookup = PullRequestLookup(branch: branch, pullRequest: pullRequest, checkedAt: .now, failures: failures)
            if let queued { lookUpPullRequest(minimumAge: queued) }
        }
    }

    /// A state frozen as given, for previews. Never runs git as long as nobody asks it to refresh.
    /// Not behind DEBUG: the app's UITests configuration compiles its previews against a release
    /// build of this package.
    public static func preview(
        root: URL,
        status: GitStatus?,
        isRepository: Bool? = true,
        refreshError: String? = nil,
        diffStat: GitDiffStat? = nil,
        remotes: [String]? = ["origin"],
        pullRequest: PullRequestLookup? = nil,
        operation: GitOperation? = nil
    ) -> GitWorktreeState {
        let state = GitWorktreeState(root: root, environment: GitStateEnvironment(looksUpPullRequests: { true }))
        state.status = status
        state.isRepository = isRepository
        state.refreshError = refreshError
        state.diffStat = diffStat
        state.remotes = remotes
        state.pullRequestLookup = pullRequest
        state.operation = operation
        return state
    }
}

/// The `GitWorktreeState` of every worktree, by the host's own id. Not observed: views reach a state
/// through `state(for:root:)` and observe the state itself.
@MainActor
public final class GitStateStore<ID: Hashable> {
    public let environment: GitStateEnvironment
    private var states: [ID: GitWorktreeState] = [:]
    /// Told about every status read a state kept, with the id it belongs to.
    public var onStatusRead: ((ID, GitStatus) -> Void)?

    public init(environment: GitStateEnvironment) {
        self.environment = environment
    }

    /// Made on first use. A worktree that moved gets a fresh state at its new path; whatever the old
    /// one held was about another folder.
    public func state(for id: ID, root: URL) -> GitWorktreeState {
        // Asked from view bodies, so the cheap comparison goes first.
        if let state = states[id], state.root == root || state.root.standardizedFileURL == root.standardizedFileURL { return state }
        let state = GitWorktreeState(root: root, environment: environment)
        state.onStatusRead = { [weak self] status in self?.onStatusRead?(id, status) }
        states[id] = state
        return state
    }

    /// Without making one.
    public func existingState(for id: ID) -> GitWorktreeState? {
        states[id]
    }

    public func forget(except ids: Set<ID>) {
        if !states.keys.allSatisfy(ids.contains) { states = states.filter { ids.contains($0.key) } }
    }

    /// Puts a `preview` state in place of the worktree's own.
    public func show(_ state: GitWorktreeState, for id: ID) {
        states[id] = state
    }
}
