import AppKit
import ArchipelCore
import GitKit
import InspectorUI

/// Bookkeeping for the status poll and the background fetches. Not observed.
struct GitRefreshState {
    /// Keyed by project: worktrees share one repository, so one fetch serves them all.
    var fetchedAt: [Project.ID: ContinuousClock.Instant] = [:]
    var fetchesInFlight: Set<Project.ID> = []
    var timer: Task<Void, Never>?
}

extension AppModel {
    static let gitStatusInterval = Duration.seconds(10)
    /// `gh` is a network call per worktree, so the timer's ticks are capped at one lookup per
    /// interval. "No PR yet" and failures are asked again sooner; see `PullRequestFreshness`.
    static let pullRequestInterval = PullRequestFreshness.foundLifetime
    /// One network call per repository. Five minutes keeps the behind counts reasonably fresh without
    /// fetching all the time.
    static let fetchInterval = Duration.seconds(300)

    func makeGitStates() -> GitStateStore<Worktree.ID> {
        let environment = GitStateEnvironment(
            git: git,
            countsLines: { [weak self] in self?.settings.showsGitStatusInSidebar ?? false },
            looksUpPullRequests: { [weak self] in self?.settings.showsPullRequests ?? false },
            searchPATH: { [weak self] in await self?.toolSearchPATH() ?? "" }
        )
        let store = GitStateStore<Worktree.ID>(environment: environment)
        store.onStatusRead = { [weak self] id, status in self?.followBranch(of: id, to: status.branch) }
        return store
    }

    /// The git state of a worktree, made on first use. For a worktree that is gone, only what the
    /// store still holds until the next prune.
    func gitState(for id: Worktree.ID) -> GitWorktreeState? {
        guard let worktree = workspace.worktree(id: id) else { return gitStates.existingState(for: id) }
        return gitStates.state(for: id, root: worktree.path)
    }

    /// Git keeps the branch, the workspace only remembers it. A read the store kept is never older
    /// than a switch made in the app, see `switchBranch(of:to:releasingLeftover:)`.
    private func followBranch(of id: Worktree.ID, to branch: String?) {
        guard let current = workspace.worktree(id: id), current.branch != branch else { return }
        mutate { $0.updateWorktree(id: id) { $0.branch = branch } }
    }

    /// The worktrees the status poll and the repository watchers keep current: every row the
    /// sidebar lists, which in "Needs Me" includes rows from other islands and collapsed projects,
    /// and the selected worktree, which the inspector and the tab bar draw from even when its
    /// project is collapsed. Rows that are not listed cost no git call.
    var gitStatusTargets: [Worktree.ID] {
        var ids = sidebarRows.map(\.id)
        if let selected = workspace.selectedWorktreeID, !ids.contains(selected) { ids.append(selected) }
        return ids
    }

    /// Refreshes `gitStatusTargets`. Pull requests are only looked up when asked for, and then only
    /// when the last answer for that branch is older than `minimumPullRequestAge`.
    func refreshGitStatus(lookingUpPullRequests: Bool, minimumPullRequestAge: Duration = pullRequestInterval) {
        let existing = Set(workspace.allWorktrees.map(\.id))
        pruneRemovedState(keeping: existing)
        InspectorView.forgetWorktrees(except: workspace.allWorktrees.lazy.map(\.path))
        refreshGitStatus(of: gitStatusTargets, lookingUpPullRequests: lookingUpPullRequests, minimumPullRequestAge: minimumPullRequestAge)
    }

    func refreshGitStatus(of ids: [Worktree.ID], lookingUpPullRequests: Bool, minimumPullRequestAge: Duration = pullRequestInterval) {
        guard isGitAvailable else { return }
        let request = GitRefreshRequest(pullRequestAge: lookingUpPullRequests ? minimumPullRequestAge : nil)
        for id in ids { gitState(for: id)?.requestRefresh(request) }
    }

    func startGitStatusTimer() {
        guard gitRefresh.timer == nil else { return }
        gitRefresh.timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.gitStatusInterval)
                guard !Task.isCancelled, let self else { return }
                if NSApp.isActive || self.isMainWindowVisible {
                    self.refreshGitStatus(lookingUpPullRequests: true)
                    self.refreshMissingWorktrees()
                    self.fetchRemotesIfDue()
                    // An agent installed from one of the app's own terminals should not stay
                    // greyed out until the user happens to switch apps and back.
                    self.refreshAgentAvailability()
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
        guard settings.fetchesAutomatically, isGitAvailable else { return }
        for project in selectedIsland?.projects ?? [] {
            if let last = gitRefresh.fetchedAt[project.id], last.duration(to: .now) < Self.fetchInterval { continue }
            guard !gitRefresh.fetchesInFlight.contains(project.id) else { continue }
            // Without an upstream anywhere there is nothing a fetch could make "behind".
            let ids = project.worktrees.map(\.id)
            // One that is gone or not there yet counts: the fetch is what notices the branch being pushed.
            guard ids.contains(where: {
                guard let status = gitStates.existingState(for: $0)?.status else { return false }
                return status.upstream != nil || status.goneUpstream != nil || status.pendingUpstream != nil
            }) else { continue }
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
        let state = gitState(for: worktree.id)
        let git = state?.summary.map {
            WorktreeGitState(
                changedFiles: $0.changedFiles,
                ahead: $0.ahead,
                behind: $0.behind,
                insertions: $0.diffStat?.insertions ?? 0,
                deletions: $0.diffStat?.deletions ?? 0,
                pullRequest: state?.pullRequest.map(Self.badge(for:))
            )
        }
        let options = WorktreeRowContent.Options(
            showsGitStatus: settings.showsGitStatusInSidebar,
            showsPullRequests: settings.showsPullRequests,
            showsMessages: settings.showsAgentMessagesInSidebar
        )
        return WorktreeRowContent(
            worktree: worktree,
            activity: activity(for: worktree),
            git: git,
            options: options,
            agentOverrides: agentOverrides
        )
    }

    /// The pull request of the branch the worktree has checked out, while pull requests are shown
    /// at all. A lookup made for a branch it has since switched away from does not count.
    func pullRequestBadge(for id: Worktree.ID) -> PullRequestBadge? {
        gitState(for: id)?.pullRequest.map(Self.badge(for:))
    }

    private static func badge(for pullRequest: GitPullRequest) -> PullRequestBadge {
        let state: PullRequestBadge.State = switch pullRequest.state {
        case .open: pullRequest.isDraft ? .draft : .open
        case .merged: .merged
        case .closed: .closed
        }
        return PullRequestBadge(number: pullRequest.number, state: state)
    }
}

#if DEBUG
extension AppModel {
    /// Shows `summary` and `pullRequest` for the worktree as if git had reported them. A summary has
    /// only a count of files, so the status is made up of as many placeholders.
    func showGitForPreview(_ id: Worktree.ID, root: URL, summary: GitSummary, pullRequest: PullRequestLookup? = nil) {
        let status = GitStatus(
            branch: summary.branch,
            staged: [],
            unstaged: (0..<summary.changedFiles).map { GitFileChange(path: "File\($0).swift", kind: .modified) },
            upstream: summary.upstream,
            ahead: summary.ahead,
            behind: summary.behind,
            goneUpstream: summary.goneUpstream,
            pendingUpstream: summary.pendingUpstream
        )
        gitStates.show(.preview(root: root, status: status, diffStat: summary.diffStat, pullRequest: pullRequest), for: id)
    }

    func showGitForPreview(_ summaries: [Worktree.ID: GitSummary], pullRequests: [Worktree.ID: PullRequestLookup] = [:]) {
        for (id, summary) in summaries {
            guard let worktree = workspace.worktree(id: id) else { continue }
            showGitForPreview(id, root: worktree.path, summary: summary, pullRequest: pullRequests[id])
        }
    }
}
#endif
