import AppKit
import ArchipelCore
import GitKit

/// Bookkeeping for the repository watchers. Not observed.
struct GitWatchState {
    var watchers: [Project.ID: GitMetadataWatcher] = [:]
    var resolving: Set<Project.ID> = []
    /// Folders git did not recognize as a repository, or could not reach. Asked again when the app
    /// comes to the front, not on every workspace change.
    var unwatchable: Set<Project.ID> = []
    /// The projects the last sync saw, so a workspace change that leaves them alone costs nothing.
    var synced: Set<Project.ID> = []
    var pending: [Project.ID: Set<GitMetadataChange>] = [:]
    var flushes: [Project.ID: Task<Void, Never>] = [:]
    var links: [Worktree.ID: (path: URL, link: GitWorktreeLink)] = [:]
    var followUps: [Worktree.ID: (token: UUID, task: Task<Void, Never>)] = [:]
    var observesOcclusion = false
    var visibleRefreshAt: ContinuousClock.Instant?
    /// Set for good by `stopGitWatching()`, so a common directory still being looked up then does
    /// not start a watcher during quit.
    var isStopped = false
}

/// Turns writes in a repository's git directory into refreshes of the worktrees they concern, so a
/// branch switch, commit, push or new worktree made by an agent in a tab shows up in the sidebar
/// within a second instead of with the next poll or app switch.
extension AppModel {
    /// FSEvents already batches for its latency; this gathers a few batches more, since a rebase or
    /// a checkout writes refs over a longer stretch than that.
    private static let gitChangeGathering = Duration.milliseconds(300)
    /// Switching Spaces or uncovering the window can repeat quickly; the poll covers the rest.
    private static let visibleRefreshInterval = Duration.seconds(5)

    func startGitWatching() {
        observeMainWindowOcclusion()
        syncGitWatchers()
    }

    func stopGitWatching() {
        for watcher in gitWatch.watchers.values { watcher.stop() }
        for flush in gitWatch.flushes.values { flush.cancel() }
        for followUp in gitWatch.followUps.values { followUp.task.cancel() }
        let observesOcclusion = gitWatch.observesOcclusion
        gitWatch = GitWatchState()
        gitWatch.observesOcclusion = observesOcclusion
        gitWatch.isStopped = true
    }

    /// Starts a watcher for each project that has none and stops those of removed projects. Runs
    /// with every workspace change, so it returns early unless the set of projects changed.
    func syncGitWatchers(retryingUnwatchable: Bool = false) {
        guard isGitAvailable, !gitWatch.isStopped else { return }
        let projects = workspace.islands.flatMap(\.projects)
        let ids = Set(projects.map(\.id))
        if retryingUnwatchable {
            gitWatch.unwatchable.removeAll()
        } else if ids == gitWatch.synced {
            return
        }
        gitWatch.synced = ids
        for (id, watcher) in gitWatch.watchers where !ids.contains(id) {
            watcher.stop()
            gitWatch.watchers[id] = nil
            gitWatch.flushes.removeValue(forKey: id)?.cancel()
            gitWatch.pending[id] = nil
        }
        gitWatch.unwatchable.formIntersection(ids)
        let tracked = Set(workspace.allWorktrees.map(\.id))
        gitWatch.links = gitWatch.links.filter { tracked.contains($0.key) }
        for project in projects
        where gitWatch.watchers[project.id] == nil && !gitWatch.resolving.contains(project.id) && !gitWatch.unwatchable.contains(project.id) {
            gitWatch.resolving.insert(project.id)
            let git = git
            let folder = project.folderURL
            Task { [weak self] in
                // Fails for a plain folder and for one on a disk that is not mounted.
                let directory = await git.commonDirectory(of: folder)
                guard let self else { return }
                self.gitWatch.resolving.remove(project.id)
                guard !self.gitWatch.isStopped, self.workspace.project(id: project.id) != nil,
                      self.gitWatch.watchers[project.id] == nil
                else { return }
                let watcher = directory.map { directory in
                    GitMetadataWatcher(directory: directory) { [weak self] batch in self?.receive(batch, in: project.id) }
                }
                // FSEvents can refuse a stream; that is tried again on activation like a missing repository.
                guard let watcher, watcher.isRunning else {
                    self.gitWatch.unwatchable.insert(project.id)
                    return
                }
                self.gitWatch.watchers[project.id] = watcher
            }
        }
    }

    private func receive(_ batch: GitMetadataWatcher.Batch, in project: Project.ID) {
        var changes = Set(batch.paths.compactMap(GitMetadataChange.init(relativePath:)))
        if batch.mayHaveMissedChanges { changes.formUnion([.refs, .worktreeList]) }
        guard !changes.isEmpty else { return }
        gitWatch.pending[project, default: []].formUnion(changes)
        guard gitWatch.flushes[project] == nil else { return }
        gitWatch.flushes[project] = Task { [weak self] in
            try? await Task.sleep(for: Self.gitChangeGathering)
            guard !Task.isCancelled, let self else { return }
            self.gitWatch.flushes[project] = nil
            await self.respondToGitChanges(in: project)
        }
    }

    private func respondToGitChanges(in projectID: Project.ID) async {
        guard let changes = gitWatch.pending.removeValue(forKey: projectID) else { return }
        guard isGitAvailable, let project = workspace.project(id: projectID) else { return }
        if changes.contains(.worktreeList) {
            // A worktree may have been moved, which keeps its folder name in `worktrees/` but not its path.
            for worktree in project.worktrees { gitWatch.links[worktree.id] = nil }
        }
        let links = await worktreeLinks(of: project.worktrees)
        // The project may have gone, or lost worktrees, while the links were read.
        guard let project = workspace.project(id: projectID) else { return }
        let onScreen = Set(gitStatusTargets)
        let worktrees = project.worktrees.map { worktree in
            GitWatchedWorktree(
                id: worktree.id,
                link: links[worktree.id] ?? .unknown,
                branch: worktree.branch,
                upstream: gitStates.existingState(for: worktree.id)?.status?.upstream,
                isOnScreen: onScreen.contains(worktree.id)
            )
        }
        let response = GitChangeResponse.plan(for: changes, in: worktrees)
        if response.discoversWorktrees { refreshWorktreeDiscovery() }
        refreshGitStatus(of: Array(response.statusRefreshes), lookingUpPullRequests: false)
        readBranches(of: response.branchReads)
        await respondToRemoteMoves(response.pushCandidates, in: project)
    }

    /// A remote branch moves on a push, but also on every fetch or pull of someone else's commits:
    /// the app's own background fetch, Sync, an agent's `git fetch`. Only a push leaves it where the
    /// local branch is, and only a push is worth asking `gh` about right away and again later.
    private func respondToRemoteMoves(_ candidates: [Worktree.ID: String], in project: Project) async {
        guard !candidates.isEmpty else { return }
        var pushed: [Worktree.ID] = []
        var fetched: [Worktree.ID] = []
        if settings.showsPullRequests {
            let git = git
            let folder = project.folderURL
            for (id, remoteBranch) in candidates {
                guard let branch = project.worktrees.first(where: { $0.id == id })?.branch else {
                    fetched.append(id)
                    continue
                }
                let matches = await git.refsMatch("refs/remotes/\(remoteBranch)", "refs/heads/\(branch)", in: folder)
                if matches { pushed.append(id) } else { fetched.append(id) }
            }
        } else {
            fetched = Array(candidates.keys)
        }
        refreshGitStatus(of: fetched, lookingUpPullRequests: false)
        lookUpPullRequestsAfterPush(pushed)
    }

    /// Read from disk once per worktree and path, off the main thread: the folder may be on a slow
    /// or vanished volume.
    private func worktreeLinks(of worktrees: [Worktree]) async -> [Worktree.ID: GitWorktreeLink] {
        var links: [Worktree.ID: GitWorktreeLink] = [:]
        var unknown: [(id: Worktree.ID, path: URL)] = []
        for worktree in worktrees {
            if let known = gitWatch.links[worktree.id], known.path == worktree.path {
                links[worktree.id] = known.link
            } else {
                unknown.append((worktree.id, worktree.path))
            }
        }
        guard !unknown.isEmpty else { return links }
        let read = await Task.detached(priority: .utility) {
            unknown.map { (id: $0.id, path: $0.path, link: GitWorktreeLink.of($0.path)) }
        }.value
        for entry in read {
            links[entry.id] = entry.link
            // A folder that is missing right now may be back later, so only what was found is kept.
            if entry.link != .unknown { gitWatch.links[entry.id] = (entry.path, entry.link) }
        }
        return links
    }

    /// The branch name alone, for worktrees whose rows are not on screen. Mirrors `refreshBranches()`.
    private func readBranches(of ids: Set<Worktree.ID>) {
        let worktrees = workspace.allWorktrees.filter { ids.contains($0.id) }
        guard !worktrees.isEmpty else { return }
        let git = git
        Task { [weak self] in
            for worktree in worktrees {
                guard FileManager.default.fileExists(atPath: worktree.path.path) else { continue }
                let generation = self?.branchGenerations[worktree.id]
                let branch = await git.currentBranch(in: worktree.path)
                guard let self else { return }
                guard generation == self.branchGenerations[worktree.id],
                      let current = self.workspace.worktree(id: worktree.id), current.branch != branch
                else { continue }
                self.mutate { $0.updateWorktree(id: worktree.id) { $0.branch = branch } }
            }
        }
    }

    /// Asks for the pull request right away and then a few more times, since `gh pr create` tends to
    /// run a little after the push that prompted this.
    private func lookUpPullRequestsAfterPush(_ ids: [Worktree.ID]) {
        guard !ids.isEmpty else { return }
        refreshGitStatus(of: ids, lookingUpPullRequests: true, minimumPullRequestAge: .zero)
        for id in ids {
            gitWatch.followUps.removeValue(forKey: id)?.task.cancel()
            guard let branch = workspace.worktree(id: id)?.branch else { continue }
            let token = UUID()
            let task = Task { [weak self] in
                for wait in PullRequestFollowUp.waits {
                    try? await Task.sleep(for: wait)
                    guard !Task.isCancelled, let self else { return }
                    let lookup = self.gitStates.existingState(for: id)?.pullRequestLookup
                    guard PullRequestFollowUp.continues(
                        pushedBranch: branch,
                        currentBranch: self.workspace.worktree(id: id)?.branch,
                        pullRequestFound: lookup?.branch == branch && lookup?.pullRequest != nil
                    ), self.settings.showsPullRequests else { break }
                    self.refreshGitStatus(of: [id], lookingUpPullRequests: true, minimumPullRequestAge: .zero)
                }
                if self?.gitWatch.followUps[id]?.token == token { self?.gitWatch.followUps[id] = nil }
            }
            gitWatch.followUps[id] = (token, task)
        }
    }

    // MARK: Window visibility

    /// Archipel is often left open on a second screen while the user works in another app. The status
    /// poll keeps going then, and stops once the window is covered, minimized or closed.
    var isMainWindowVisible: Bool {
        NSApp.windows.contains { Self.isMainWindow($0) && $0.occlusionState.contains(.visible) }
    }

    private func observeMainWindowOcclusion() {
        guard !gitWatch.observesOcclusion else { return }
        gitWatch.observesOcclusion = true
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, Self.isMainWindow(window), !NSApp.isActive else { return }
                if self.isMainWindowVisible {
                    // The window just came into view, so catch up on what changed while it was hidden.
                    let last = self.gitWatch.visibleRefreshAt
                    if last.map({ $0.duration(to: .now) >= Self.visibleRefreshInterval }) ?? true {
                        self.gitWatch.visibleRefreshAt = .now
                        self.refreshGitStatus(lookingUpPullRequests: true)
                    }
                    self.startGitStatusTimer()
                } else {
                    self.stopGitStatusTimer()
                }
            }
        }
    }
}
