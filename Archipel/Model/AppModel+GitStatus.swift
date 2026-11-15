import AppKit
import ArchipelCore
import GitKit

/// The last pull request answer for a worktree, with the branch it was asked for: after a branch
/// switch the old answer must not be shown, even before the next lookup.
struct PullRequestLookup {
    var branch: String
    var pullRequest: GitPullRequest?
    var checkedAt: ContinuousClock.Instant
}

/// Bookkeeping that keeps refreshes of one worktree from overlapping. Not observed.
struct GitRefreshState {
    struct Request {
        var lookingUpPullRequests: Bool
        var minimumPullRequestAge: Duration

        func merged(with other: Request) -> Request {
            switch (lookingUpPullRequests, other.lookingUpPullRequests) {
            case (true, true): Request(lookingUpPullRequests: true, minimumPullRequestAge: min(minimumPullRequestAge, other.minimumPullRequestAge))
            case (true, false): self
            case (false, _): other
            }
        }
    }

    var summariesInFlight: Set<Worktree.ID> = []
    /// Asked for while a refresh of the same worktree was running; run once that one is done, since
    /// its answer may predate whatever prompted the request.
    var queued: [Worktree.ID: Request] = [:]
    var pullRequestsInFlight: Set<Worktree.ID> = []
    var diffStatCheckedAt: [Worktree.ID: ContinuousClock.Instant] = [:]
    /// Keyed by project: worktrees share one repository, so one fetch serves them all.
    var fetchedAt: [Project.ID: ContinuousClock.Instant] = [:]
    var fetchesInFlight: Set<Project.ID> = []
    var gitHub: Task<GitHubClient?, Never>?
    var timer: Task<Void, Never>?
}

extension AppModel {
    static let gitStatusInterval = Duration.seconds(10)
    static let diffStatInterval = Duration.seconds(60)
    /// `gh` is a network call per worktree, and a pull request rarely appears or changes state without
    /// the user knowing, so this can be slow.
    static let pullRequestInterval = Duration.seconds(300)
    /// One network call per repository. Five minutes keeps the behind counts reasonably fresh without
    /// fetching all the time.
    static let fetchInterval = Duration.seconds(300)

    /// Refreshes every worktree of the selected island. Pull requests are only looked up when asked
    /// for, and then only when the last answer for that branch is older than `minimumPullRequestAge`.
    func refreshGitStatus(lookingUpPullRequests: Bool, minimumPullRequestAge: Duration = pullRequestInterval) {
        // Only written when something was removed: this runs on every timer tick, and any write to an
        // observed property re-renders the whole sidebar.
        let existing = Set(workspace.allWorktrees.map(\.id))
        if !gitSummaries.keys.allSatisfy(existing.contains) {
            gitSummaries = gitSummaries.filter { existing.contains($0.key) }
        }
        if !pullRequests.keys.allSatisfy(existing.contains) {
            pullRequests = pullRequests.filter { existing.contains($0.key) }
        }
        let ids = selectedIsland?.projects.flatMap(\.worktrees).map(\.id) ?? []
        refreshGitStatus(of: ids, lookingUpPullRequests: lookingUpPullRequests, minimumPullRequestAge: minimumPullRequestAge)
    }

    func refreshGitStatus(of ids: [Worktree.ID], lookingUpPullRequests: Bool, minimumPullRequestAge: Duration = pullRequestInterval) {
        let request = GitRefreshState.Request(lookingUpPullRequests: lookingUpPullRequests, minimumPullRequestAge: minimumPullRequestAge)
        for id in ids { refreshSummary(of: id, request) }
    }

    func startGitStatusTimer() {
        guard gitRefresh.timer == nil else { return }
        gitRefresh.timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.gitStatusInterval)
                guard !Task.isCancelled, let self else { return }
                if NSApp.isActive {
                    self.refreshGitStatus(lookingUpPullRequests: false)
                    self.fetchRemotesIfDue()
                }
            }
        }
    }

    func stopGitStatusTimer() {
        gitRefresh.timer?.cancel()
        gitRefresh.timer = nil
    }

    /// Fetches each project of the selected island whose last fetch is older than `fetchInterval`, then
    /// refreshes its worktrees so the behind counts move. Failures are silent: no network, a remote
    /// that needs a password or a folder without a remote all just mean the counts stay as they were.
    func fetchRemotesIfDue() {
        guard settings.fetchesAutomatically else { return }
        for project in selectedIsland?.projects ?? [] {
            if let last = gitRefresh.fetchedAt[project.id], last.duration(to: .now) < Self.fetchInterval { continue }
            guard !gitRefresh.fetchesInFlight.contains(project.id) else { continue }
            // Without an upstream anywhere there is nothing a fetch could make "behind".
            let ids = project.worktrees.map(\.id)
            guard ids.contains(where: { gitSummaries[$0]?.upstream != nil }) else { continue }
            gitRefresh.fetchesInFlight.insert(project.id)
            gitRefresh.fetchedAt[project.id] = .now
            let git = git
            let folder = project.folderURL
            Task { [weak self] in
                let fetched = (try? await git.fetch(in: folder)) != nil
                guard let self else { return }
                self.gitRefresh.fetchesInFlight.remove(project.id)
                if fetched { self.refreshGitStatus(of: ids, lookingUpPullRequests: false) }
            }
        }
    }

    func rowContent(for worktree: Worktree) -> WorktreeRowContent {
        let summary = gitSummaries[worktree.id]
        let lookup = pullRequests[worktree.id]
        let pullRequest = lookup?.branch == summary?.branch ? lookup?.pullRequest : nil
        let git = summary.map {
            WorktreeGitState(
                changedFiles: $0.changedFiles,
                ahead: $0.ahead,
                behind: $0.behind,
                insertions: $0.diffStat?.insertions ?? 0,
                deletions: $0.diffStat?.deletions ?? 0,
                pullRequest: pullRequest.map(Self.badge)
            )
        }
        let options = WorktreeRowContent.Options(
            showsGitStatus: settings.showsGitStatusInSidebar,
            showsPullRequests: settings.showsPullRequests,
            showsMessages: settings.showsAgentMessagesInSidebar
        )
        return WorktreeRowContent(worktree: worktree, activity: activity(for: worktree), git: git, options: options)
    }

    private static func badge(for pullRequest: GitPullRequest) -> PullRequestBadge {
        let state: PullRequestBadge.State = switch pullRequest.state {
        case .open: pullRequest.isDraft ? .draft : .open
        case .merged: .merged
        case .closed: .closed
        }
        return PullRequestBadge(number: pullRequest.number, state: state)
    }

    private func refreshSummary(of id: Worktree.ID, _ request: GitRefreshState.Request) {
        guard let worktree = workspace.worktree(id: id) else { return }
        guard !gitRefresh.summariesInFlight.contains(id) else {
            gitRefresh.queued[id] = gitRefresh.queued[id].map { $0.merged(with: request) } ?? request
            return
        }
        gitRefresh.summariesInFlight.insert(id)
        let git = git
        let wantsDiffStat = settings.showsGitStatusInSidebar
        let previous = gitSummaries[id]
        let diffStatIsFresh = gitRefresh.diffStatCheckedAt[id].map { $0.duration(to: .now) < Self.diffStatInterval } ?? false
        Task { [weak self] in
            // A folder that is not a repository (or has vanished) throws; that only means "no summary".
            var summary = try? await git.summary(in: worktree.path)
            var countedLines = false
            // A second git call, so only when there is something to count. An unborn branch throws,
            // which leaves the line counts out and the file count in.
            if wantsDiffStat, let changed = summary?.changedFiles, changed > 0 {
                var previousStatus = previous
                previousStatus?.diffStat = nil
                // Unlike status, a diff reads every changed file. While the status is the same the
                // last count is reused for a while, so a huge generated file is not diffed every poll.
                if diffStatIsFresh, previousStatus == summary, let known = previous?.diffStat {
                    summary?.diffStat = known
                } else {
                    summary?.diffStat = try? await git.diffStat(in: worktree.path)
                    countedLines = true
                }
            }
            guard let self else { return }
            if countedLines { self.gitRefresh.diffStatCheckedAt[id] = .now }
            self.gitRefresh.summariesInFlight.remove(id)
            guard let current = self.workspace.worktree(id: id) else {
                self.gitRefresh.queued[id] = nil
                self.gitSummaries[id] = nil
                self.pullRequests[id] = nil
                return
            }
            if self.gitSummaries[id] != summary { self.gitSummaries[id] = summary }
            if let summary, current.branch != summary.branch {
                self.mutate { $0.updateWorktree(id: id) { $0.branch = summary.branch } }
            }
            if request.lookingUpPullRequests, self.settings.showsPullRequests {
                self.lookUpPullRequest(of: id, summary: summary, minimumAge: request.minimumPullRequestAge)
            }
            if let next = self.gitRefresh.queued.removeValue(forKey: id) {
                self.refreshSummary(of: id, next)
            }
        }
    }

    /// Every failure, including a missing `gh` or no network, just means no badge.
    private func lookUpPullRequest(of id: Worktree.ID, summary: GitSummary?, minimumAge: Duration) {
        guard let worktree = workspace.worktree(id: id), let summary, let branch = summary.branch, summary.upstream != nil else {
            pullRequests[id] = nil
            return
        }
        if let last = pullRequests[id], last.branch == branch, last.checkedAt.duration(to: .now) < minimumAge { return }
        guard !gitRefresh.pullRequestsInFlight.contains(id) else { return }
        gitRefresh.pullRequestsInFlight.insert(id)
        let gitHub = gitHubClient()
        Task { [weak self] in
            let client = await gitHub.value
            let pullRequest = try? await client?.pullRequest(in: worktree.path)
            guard let self else { return }
            self.gitRefresh.pullRequestsInFlight.remove(id)
            guard self.workspace.worktree(id: id) != nil else { return }
            self.pullRequests[id] = PullRequestLookup(branch: branch, pullRequest: pullRequest, checkedAt: .now)
        }
    }

    /// Resolved once: whether `gh` is installed does not change while the app runs often enough to
    /// justify searching the PATH for every lookup.
    private func gitHubClient() -> Task<GitHubClient?, Never> {
        if let task = gitRefresh.gitHub { return task }
        let task = Task { [weak self] () -> GitHubClient? in
            guard let path = await self?.toolSearchPATH() else { return nil }
            return GitHubClient(searchPATH: path)
        }
        gitRefresh.gitHub = task
        return task
    }
}
