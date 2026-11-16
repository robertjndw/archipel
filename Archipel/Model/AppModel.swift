import AgentKit
import AppKit
import ArchipelCore
import EditorUI
import GitKit
import Observation
import TerminalKit

@Observable
final class AppModel {
    private(set) var workspace: Workspace
    private(set) var activities: [Session.ID: SessionActivity] = [:] {
        didSet { stayAwake.agentsWorking = hasWorkingSessions }
    }
    private(set) var terminals: [Session.ID: TerminalSession] = [:]
    private(set) var launchFailures: [Session.ID: String] = [:]
    /// The glow each worktree row last played. Not persisted, so nothing glows after a launch.
    private(set) var statusPulses: [Worktree.ID: StatusPulseCount] = [:]
    /// Glows of changes that happened while Archipel was in the background. They would play behind
    /// another app where nobody sees them, so they wait for the app to come back.
    @ObservationIgnored private var pulsesAwaitingActivation: [Worktree.ID: StatusPulse] = [:]
    @ObservationIgnored private var subagentExpiry: (date: Date, task: Task<Void, Never>)?
    /// Shown as an alert.
    var problem: String?

    let git = GitClient()
    /// Open file buffers. They live here and not in the editor views because
    /// a view only exists while its tab is selected.
    let documents = FileDocumentStore()
    /// A file tab with unsaved edits that the user asked to close.
    var tabAwaitingCloseDecision: Tab?
    /// Diff review comments of every worktree. Kept here for the same reason as `documents`.
    let reviewComments = ReviewCommentStore()
    /// The project whose settings sheet is open. Lives here because both the sidebar and Run open it.
    var projectSettingsID: Project.ID?
    /// Set when the sheet is opened to configure a script, so it starts on that page.
    var projectSettingsShowsScripts = false
    /// The project the Add Worktree sheet is open for. Here for the same reason as `projectSettingsID`:
    /// the sidebar, the Project menu and the palette all open it.
    var addWorktreeProjectID: Project.ID?
    /// Set by Commit… to put the cursor in the inspector's commit message field; the inspector clears it.
    var focusCommitMessageRequest = false
    let settings: AppSettings
    let devServers = DevServerMonitor()
    let resources = ResourceMonitor()
    let stayAwake = StayAwake()
    /// The latest subscription limits per provider, for the status bar. See AppModel+Usage.
    var usage: [UsageProvider: ProviderUsage] = UsageArchive.load()
    /// Images for projects whose icon is a file or was found in the repository. See `loadIcon(of:)`.
    var projectIcons: [Project.ID: NSImage] = [:]

    /// The script a session runs instead of its agent. Deliberately not persisted: after a relaunch
    /// a script tab comes back as a plain shell, so a setup script or dev server never starts by itself.
    var scriptSessions: [Session.ID: ScriptRun] = [:]
    /// Review comments waiting for their target session to be ready for input, by session.
    @ObservationIgnored var pendingReviews: [Session.ID: PendingReview] = [:]
    @ObservationIgnored var terminalStartTimes: [Session.ID: ContinuousClock.Instant] = [:]

    /// Transient repository state for the sidebar rows of the selected island.
    var gitSummaries: [Worktree.ID: GitSummary] = [:]
    var pullRequests: [Worktree.ID: PullRequestLookup] = [:]
    /// Everything `git worktree list` reported per project at the last refresh. Suggestions are
    /// derived from it on read, so adding or dismissing one updates the sidebar without a git call.
    var gitWorktrees: [Project.ID: [GitWorktreeEntry]] = [:]
    /// Tracked worktrees whose folder was deleted behind our back.
    var missingWorktrees: Set<Worktree.ID> = []
    @ObservationIgnored var worktreeDiscoveryGeneration = 0
    @ObservationIgnored var gitRefresh = GitRefreshState()
    private let store: WorkspaceStore
    private let terminalApp: TerminalApp?
    private let hookServer: HookServer
    let notifier = AttentionNotifier()
    /// Most recently focused tabs first, for Ctrl-Tab. Not observed: nothing on screen draws from it
    /// until the switcher opens, and it changes on every focus move.
    @ObservationIgnored private(set) var recentTabs = RecentTabs(
        ids: (UserDefaults.standard.stringArray(forKey: AppModel.recentTabsKey) ?? []).compactMap(UUID.init(uuidString:))
    )
    private static let recentTabsKey = "recentTabIDs"
    private let hookExecutableURL: URL
    private var loginPATH: Task<String, Never>
    private var eventTasks: [Session.ID: Task<Void, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    /// False when the workspace file could not be read. Saving then would
    /// replace the user's real data with the empty default.
    private var canSave = true

    init() {
        // Debug builds use their own folder so they can run next to the installed
        // app. Sharing it would mean sharing the workspace file, and the hook server
        // unlinks any socket already at its path, so the installed app would stop
        // getting agent status. ARCHIPEL_SUPPORT_DIR is for throwaway runs.
        #if DEBUG
        let supportFolder = "Archipel Dev"
        #else
        let supportFolder = "Archipel"
        #endif
        let support = ProcessInfo.processInfo.environment["ARCHIPEL_SUPPORT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.applicationSupportDirectory.appending(path: supportFolder, directoryHint: .isDirectory)
        settings = AppSettings()
        store = WorkspaceStore(fileURL: support.appending(path: "workspace.json"))
        hookServer = HookServer(socketURL: support.appending(path: "hook.sock"))
        hookExecutableURL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/archipel-hook")
        loginPATH = Task.detached { await LoginEnvironment.resolvePATH() }

        var problems: [String] = []
        do {
            workspace = try store.load()
        } catch {
            workspace = Workspace()
            canSave = false
            problems.append("The workspace could not be read, so changes will not be saved. \(error.localizedDescription)")
        }
        // Ghostty reads this once at startup to find its terminfo and shell integration.
        if let resources = Bundle.main.resourceURL?.appending(path: "ghostty").path {
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
        }
        do {
            terminalApp = try TerminalApp()
        } catch {
            terminalApp = nil
            problems.append("The terminal engine failed to start. \(error.localizedDescription)")
        }
        do {
            try hookServer.start()
        } catch {
            problems.append("Agent status reporting is unavailable. \(error)")
        }
        problem = problems.isEmpty ? nil : problems.joined(separator: "\n\n")

        notifier.onOpenSession = { [weak self] id in self?.select(session: id) }
        notifier.onResponse = { [weak self] response in self?.answer(response) }
        notifier.start()
        Task { [weak self, messages = hookServer.messages] in
            for await message in messages {
                self?.receive(message)
            }
        }
        for id in visibleSessionIDs { ensureRunning(id) }
        if let id = focusedTab?.id { recentTabs.visit(id) }
        refreshBranches()
        refreshWorktreeDiscovery()
        refreshGitStatus(lookingUpPullRequests: true)
        loadProjectIcons()
        refreshCodexUsage()
        watchSessionInteraction()
        devServers.start { [weak self] in self?.terminals ?? [:] }
        resources.start { [weak self] in self?.resourceSources() ?? [:] }
        terminalApp?.acceptsDroppedText = { [weak self] in !(self?.isInternalDragPayload($0) ?? false) }
    }

    #if DEBUG
    /// For SwiftUI previews. Starts no terminal engine, hook socket, notifier, monitors or git
    /// refreshes and never saves, so a preview can't touch the real workspace file or take the socket
    /// from a running Archipel. Set `gitSummaries`, `usage` etc. on the result when a preview needs them.
    init(
        preview workspace: Workspace,
        activities: [Session.ID: SessionActivity] = [:],
        launchFailures: [Session.ID: String] = [:]
    ) {
        let scratch = URL.temporaryDirectory.appending(path: "ArchipelPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = WorkspaceStore(fileURL: scratch.appending(path: "workspace.json"))
        hookServer = HookServer(socketURL: scratch.appending(path: "hook.sock"))
        hookExecutableURL = scratch.appending(path: "archipel-hook")
        terminalApp = nil
        loginPATH = Task { "/usr/bin:/bin" }
        canSave = false
        // Its own suite, so flipping a toggle in the canvas never reaches the Debug app's defaults.
        // Cleared first so every preview starts from the default settings.
        let defaults = UserDefaults(suiteName: "ArchipelPreview")!
        defaults.removePersistentDomain(forName: "ArchipelPreview")
        settings = AppSettings(defaults: defaults)
        self.workspace = workspace
        self.activities = activities
        self.launchFailures = launchFailures
    }
    #endif

    /// The login shell's PATH, for finding tools such as `gh` that launchd's
    /// bare PATH does not reach.
    func toolSearchPATH() async -> String {
        await loginPATH.value
    }

    // MARK: Selection

    var selectedIsland: Island? {
        workspace.selectedIslandID.flatMap { workspace.island(id: $0) }
    }

    var selectedWorktree: Worktree? {
        workspace.selectedWorktreeID.flatMap { workspace.worktree(id: $0) }
    }

    /// The sessions on screen right now: the selected tab of every pane.
    var visibleSessionIDs: [Session.ID] {
        selectedWorktree.map { workspace.visibleSessionIDs(in: $0.id) } ?? []
    }

    var focusedSessionID: Session.ID? {
        selectedWorktree.flatMap { workspace.focusedSessionID(in: $0.id) }
    }

    var focusedTab: Tab? {
        selectedWorktree?.focusedPane?.selectedTab
    }

    func select(island id: Island.ID) {
        changingSelection { $0.selectIsland(id) }
    }

    func select(worktree id: Worktree.ID?) {
        guard let id, workspace.worktree(id: id) != nil else { return }
        changingSelection { $0.selectWorktree(id) }
    }

    func select(session id: Session.ID?) {
        guard let id, workspace.session(id: id) != nil else { return }
        changingSelection { $0.selectSession(id) }
    }

    func selectIsland(at index: Int) {
        guard workspace.islands.indices.contains(index) else { return }
        select(island: workspace.islands[index].id)
    }

    func selectNextNeedingAttention() {
        let next = nextSessionNeedingAttention(after: focusedSessionID, in: workspace, activities: activities)
        if let next { select(session: next) }
    }

    func select(tab id: Tab.ID) {
        changingSelection { $0.selectTab(id: id) }
    }

    func focus(pane id: Pane.ID) {
        guard selectedWorktree?.focusedPaneID != id else { return }
        mutate { $0.focusPane(id: id) }
    }

    /// Moves to the tab before or after the current one in the focused pane,
    /// wrapping around.
    func selectAdjacentTab(offset: Int) {
        guard let pane = selectedWorktree?.focusedPane, let current = pane.selectedTab,
              let index = pane.tabs.firstIndex(where: { $0.id == current.id })
        else { return }
        let count = pane.tabs.count
        select(tab: pane.tabs[(index + offset + count) % count].id)
    }

    func appDidBecomeActive() {
        terminalApp?.setAppFocused(true)
        for (id, kind) in pulsesAwaitingActivation where workspace.worktree(id: id) != nil {
            statusPulses[id, default: StatusPulseCount()].play(kind)
        }
        pulsesAwaitingActivation.removeAll()
        // Coming back to the app does not mark anything as seen: the window may have been in front
        // all along with nobody at the desk. Clicking or typing into a session does; see
        // watchSessionInteraction().
        refreshBranches()
        refreshWorktreeDiscovery()
        refreshGitStatus(lookingUpPullRequests: true, minimumPullRequestAge: .seconds(30))
        fetchRemotesIfDue()
        startGitStatusTimer()
    }

    func appDidResignActive() {
        terminalApp?.setAppFocused(false)
        stopGitStatusTimer()
    }

    /// Every mutation that can change which session is on screen goes through
    /// here, so the terminal that left the screen stops rendering and the one
    /// that entered it is started and marked as seen.
    func changingSelection(_ change: (inout Workspace) -> Void) {
        let previous = Set(visibleSessionIDs)
        let previousPlace = (selectedIsland?.id, selectedWorktree?.id)
        mutate(change)
        if previousPlace != (selectedIsland?.id, selectedWorktree?.id) {
            refreshGitStatus(lookingUpPullRequests: true)
        }
        let current = Set(visibleSessionIDs)
        for id in previous.subtracting(current) { terminals[id]?.setOccluded(true) }
        for id in current {
            ensureRunning(id)
            terminals[id]?.setOccluded(false)
            markViewed(id)
        }
    }

    private func markViewed(_ id: Session.ID) {
        // Without hooks nothing tells us that the user dealt with a request,
        // so looking at the session has to count as dealing with it.
        if workspace.session(id: id)?.agent.definition.reportsLifecycleThroughHooks == false,
           activities[id]?.needsUser == true {
            activities[id]?.status = .finished
        }
        // Observers fire on every write, equal or not, and this runs for each visible session on every
        // selection change.
        if activities[id]?.unread == true { activities[id]?.markViewed() }
        notifier.clear(sessionID: id)
        refreshDockBadge()
    }

    /// Clears the unread state of a worktree's sessions without opening them.
    func markRead(worktree id: Worktree.ID) {
        for session in workspace.worktree(id: id)?.sessions ?? [] { markViewed(session.id) }
    }

    private func isBeingViewed(_ id: Session.ID) -> Bool {
        NSApp.isActive && visibleSessionIDs.contains(id)
    }

    // MARK: Islands

    func addIsland(name: String, symbol: String, tint: Tint) {
        changingSelection { _ = $0.addIsland(name: name, symbol: symbol, tint: tint) }
    }

    func updateIsland(_ id: Island.ID, name: String, symbol: String, tint: Tint) {
        mutate {
            $0.updateIsland(id: id) { island in
                island.name = name
                island.symbol = symbol
                island.tint = tint
            }
        }
    }

    func removeIsland(_ id: Island.ID) {
        changingSelection { _ = $0.removeIsland(id: id) }
    }

    // MARK: Projects

    /// One at a time, so two picked worktrees of the same repository end up in one project
    /// instead of racing to create it twice.
    func addProjects(folders: [URL]) {
        Task {
            for folder in folders { await addProject(folder: folder) }
            refreshBranches()
            refreshWorktreeDiscovery()
        }
    }

    /// Like VS Code, a picked linked worktree is treated as part of its repository: the main
    /// checkout becomes the project (and its locked primary), and the picked folder joins it as a
    /// worktree. Plain folders and main checkouts become projects as they are.
    private func addProject(folder: URL) async {
        if let tracked = project(atFolder: folder), let main = tracked.worktrees.first(where: \.isMain) {
            changingSelection { $0.selectWorktree(main.id) }
            return
        }
        if let main = await mainCheckout(ofLinkedWorktree: folder) {
            let worktree = Worktree(path: folder, branch: await git.currentBranch(in: folder))
            if let existing = project(atFolder: main) {
                changingSelection {
                    $0.updateProject(id: existing.id) { $0.isExpanded = true }
                    if !$0.addWorktree(worktree, to: existing.id),
                       let tracked = existing.worktrees.first(where: { Self.resolvedKey($0.path) == Self.resolvedKey(folder) }) {
                        $0.selectWorktree(tracked.id)
                    }
                }
                return
            }
            let project = insertProject(folder: main)
            changingSelection { _ = $0.addWorktree(worktree, to: project.id) }
            return
        }
        insertProject(folder: folder)
    }

    private func project(atFolder folder: URL) -> Project? {
        // Resolved because git hands back the main checkout with symlinks followed.
        let key = Self.resolvedKey(folder)
        return workspace.islands.flatMap(\.projects).first { Self.resolvedKey($0.folderURL) == key }
    }

    @discardableResult
    private func insertProject(folder: URL) -> Project {
        let main = Worktree(path: folder, isMain: true)
        let project = Project(name: folder.lastPathComponent, folderURL: folder, worktrees: [main])
        guard let island = selectedIsland else { return project }
        changingSelection {
            _ = $0.addProject(project, to: island.id)
            $0.selectWorktree(main.id)
        }
        loadIcon(of: project)
        return project
    }

    /// The main checkout when `folder` is the root of a linked worktree; nil for main checkouts,
    /// subfolders, bare repositories and plain folders.
    private func mainCheckout(ofLinkedWorktree folder: URL) async -> URL? {
        guard let entries = try? await git.worktrees(of: folder),
              let main = entries.first, main.isMain,
              entries.dropFirst().contains(where: { Self.resolvedKey($0.path) == Self.resolvedKey(folder) }),
              await git.isRepository(main.path)
        else { return nil }
        return main.path
    }

    func renameProject(_ id: Project.ID, to name: String) {
        mutate { $0.renameProject(id: id, to: name) }
    }

    func setProject(_ id: Project.ID, expanded: Bool) {
        mutate { $0.updateProject(id: id) { $0.isExpanded = expanded } }
    }

    func removeProject(_ project: Project) {
        changingSelection { $0.removeProject(id: project.id) }
    }

    func moveProject(_ id: Project.ID, to island: Island.ID) {
        changingSelection { $0.moveProject(id: id, to: island) }
    }

    // MARK: Worktrees

    /// Git worktrees of the project that are not in the sidebar yet, dismissed ones included.
    /// Prunable ones are left out: their folder is gone, so there is nothing to open.
    func availableWorktrees(for project: Project) async throws -> [GitWorktreeEntry] {
        let entries = try await git.worktrees(of: project.folderURL)
        let current = workspace.project(id: project.id) ?? project
        let aligned = Self.aligned(entries, to: current)
        gitWorktrees[project.id] = aligned
        return Self.untracked(aligned ?? entries, in: current)
    }

    static func untracked(_ entries: [GitWorktreeEntry], in project: Project) -> [GitWorktreeEntry] {
        let known = Set(project.worktrees.map { Project.worktreeKey($0.path) })
        return entries.filter { !$0.isPrunable && !known.contains(Project.worktreeKey($0.path)) }
    }

    /// Worktrees are created outside the repository by default so they never
    /// show up as untracked files inside it.
    func createWorktree(in project: Project, branch: String, createBranch: Bool) async throws {
        // The sheet may have been open while the settings changed.
        let project = workspace.project(id: project.id) ?? project
        let path = worktreePath(for: project, branch: branch)
        // git creates the new branch before it notices the folder is taken, leaving the branch behind
        // after a failed add, so the folder is checked first.
        if FileManager.default.fileExists(atPath: path.path) {
            throw GitError(message: "The folder \(path.abbreviatedPath) already exists. Pick another branch name, or move or delete that folder.")
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git.addWorktree(
            repository: project.folderURL,
            path: path,
            branch: branch,
            createBranch: createBranch,
            base: project.baseBranch
        )
        let worktree = Worktree(path: path, branch: branch)
        changingSelection { _ = $0.addWorktree(worktree, to: project.id) }
        if workspace.project(id: project.id)?.scripts.setupCommand != nil {
            startScript(.setup, in: worktree.id)
        }
    }

    /// Takes the worktree out of the sidebar. With `deleteFolder` git removes the folder too,
    /// forcing past uncommitted changes when `force` is set (the sheet only sets it after warning
    /// about them). `deleteBranch` names the branch the user agreed to delete; it is deleted only if
    /// the worktree still had it checked out, and git keeps it when unmerged.
    /// Throws, leaving everything in place, when git refuses to remove the folder. A branch that
    /// cannot be deleted does not throw: the worktree is gone by then, so it is reported instead.
    func removeWorktree(_ id: Worktree.ID, deleteFolder: Bool, deleteBranch: String?, force: Bool) async throws -> BranchRemoval {
        guard let worktree = workspace.worktree(id: id), !worktree.isMain,
              let project = workspace.project(containingWorktree: id)
        else { return .notRequested }
        // Asked fresh because the cached name lags behind checkouts made in the terminal.
        let checkedOut = deleteFolder && deleteBranch != nil ? await git.currentBranch(in: worktree.path) : nil
        if deleteFolder {
            try await git.removeWorktree(repository: project.folderURL, path: worktree.path, force: force)
        }
        // A folder that stays on disk would be suggested again right away.
        changingSelection { $0.removeWorktree(id: id, dismiss: !deleteFolder) }
        missingWorktrees.remove(id)
        refreshWorktreeDiscovery()

        guard deleteFolder, let branch = deleteBranch else { return .notRequested }
        // The user confirmed the name shown in the sheet. If the worktree switched branches since,
        // that name is not what it had checked out, so nothing is deleted on a guess.
        guard checkedOut == branch else {
            return .failed(branch, "the worktree no longer had it checked out.")
        }
        do {
            return switch try await git.deleteBranch(branch, in: project.folderURL) {
            case .deleted: .deleted(branch)
            case .keptUnmerged: .keptUnmerged(branch)
            }
        } catch {
            return .failed(branch, error.localizedDescription)
        }
    }

    enum BranchRemoval: Equatable {
        case notRequested
        case deleted(String)
        case keptUnmerged(String)
        case failed(String, String)
    }

    /// The branch of a checkout changes behind our back whenever the user or
    /// an agent switches branches, so the stored name is only a cache.
    func refreshBranches() {
        let worktrees = workspace.allWorktrees
        Task {
            for worktree in worktrees {
                let branch = await git.currentBranch(in: worktree.path)
                guard let current = workspace.worktree(id: worktree.id), current.branch != branch else { continue }
                mutate { $0.updateWorktree(id: worktree.id) { $0.branch = branch } }
            }
        }
    }

    // MARK: Sessions

    func newSession(in worktreeID: Worktree.ID, agent: AgentDefinition, pane: Pane.ID? = nil) {
        guard let worktree = workspace.worktree(id: worktreeID) else { return }
        let count = worktree.sessions.count { $0.agent.rawValue == agent.id }
        let session = Session(
            title: count == 0 ? agent.displayName : "\(agent.displayName) \(count + 1)",
            agent: AgentKind(rawValue: agent.id)
        )
        changingSelection {
            _ = $0.addSession(session, to: worktreeID, pane: pane)
            $0.selectSession(session.id)
        }
    }

    func renameSession(_ id: Session.ID, to title: String) {
        mutate {
            $0.updateSession(id: id) {
                $0.title = title
                $0.hasCustomTitle = true
            }
        }
    }

    // MARK: Tabs

    func openFile(_ url: URL, preview: Bool) {
        open(.file(url), preview: preview)
    }

    func openDiff(path: String, staged: Bool, preview: Bool) {
        open(.diff(path: path, staged: staged), preview: preview)
    }

    private func open(_ content: TabContent, preview: Bool) {
        guard let worktree = selectedWorktree else { return }
        changingSelection { workspace in
            // Opening a preview reuses the pane's preview tab. One with unsaved edits would vanish
            // with its edits still in the buffer and no tab left to save or discard them from.
            for tab in worktree.panes.flatMap(\.tabs) where tab.isPreview {
                if case .file(let url) = tab.content, documents.isDirty(url) { workspace.pinTab(id: tab.id) }
            }
            _ = workspace.openTab(content, in: worktree.id, preview: preview)
        }
    }

    func pin(tab id: Tab.ID) {
        mutate { $0.pinTab(id: id) }
    }

    /// Returns false, with the reason shown, when a file could not be saved.
    @discardableResult
    func saveAllDocuments() -> Bool {
        do {
            try documents.saveAll()
            return true
        } catch {
            problem = "Not every file could be saved. \(error.localizedDescription)"
            return false
        }
    }

    /// Closing a session tab ends the session. A file with unsaved edits is
    /// not closed here; the user is asked first.
    func close(tab id: Tab.ID) {
        guard let tab = workspace.tab(id: id) else { return }
        if case .file(let url) = tab.content, documents.isDirty(url) {
            tabAwaitingCloseDecision = tab
            return
        }
        closeNow(tab)
    }

    func resolveClose(of tab: Tab, saving: Bool) {
        guard case .file(let url) = tab.content else { return }
        if saving {
            do {
                try documents.save(url)
            } catch {
                problem = "The file could not be saved, so its tab was kept open. \(error.localizedDescription)"
                return
            }
        } else {
            documents.discardChanges(url)
        }
        closeNow(tab)
    }

    /// The file's buffer is released by `mutate` once no tab shows the file any more.
    private func closeNow(_ tab: Tab) {
        changingSelection { $0.closeTab(id: tab.id) }
    }

    func split(tab id: Tab.ID) {
        changingSelection { _ = $0.splitTab(id: id) }
    }

    func move(tab id: Tab.ID, toPane pane: Pane.ID, at index: Int? = nil) {
        changingSelection { $0.moveTab(id: id, toPane: pane, at: index) }
    }

    /// Kills the process if there is one and starts again, resuming the
    /// agent's conversation unless `fresh` is set.
    func restartSession(_ id: Session.ID, fresh: Bool = false) {
        tearDown(id, restarting: true)
        if fresh {
            mutate {
                $0.updateSession(id: id) {
                    $0.agentSessionID = nil
                    $0.agentTitle = nil
                }
            }
        }
        ensureRunning(id)
    }

    func activity(for id: Session.ID) -> SessionActivity {
        activities[id] ?? SessionActivity()
    }

    /// The one activity that best represents a worktree in the sidebar: a
    /// session that needs the user wins over a working one, which wins over
    /// an unread one.
    func activity(for worktree: Worktree) -> SessionActivity? {
        let all = worktree.sessions.compactMap { activities[$0.id] }
        return all.first(where: \.needsUser)
            ?? all.first { $0.status == .working || $0.status == .starting }
            ?? all.first(where: \.unread)
    }

    var hasWorkingSessions: Bool {
        activities.values.contains(where: \.isBusy)
    }

    // MARK: Running sessions

    /// One walk over the workspace rather than two lookups per terminal, since this runs on every scan.
    private func resourceSources() -> [Session.ID: ResourceMonitor.Source] {
        var sources: [Session.ID: ResourceMonitor.Source] = [:]
        for worktree in workspace.islands.lazy.flatMap(\.projects).flatMap(\.worktrees) {
            for session in worktree.sessions {
                guard let terminal = terminals[session.id] else { continue }
                sources[session.id] = .init(
                    terminal: terminal,
                    worktreeID: worktree.id,
                    worktreeName: worktree.displayName,
                    origin: "\(worktree.displayName) · \(session.displayTitle)"
                )
            }
        }
        return sources
    }

    private func ensureRunning(_ id: Session.ID) {
        guard terminals[id] == nil, let session = workspace.session(id: id),
              let worktree = workspace.worktree(containing: id), let terminalApp
        else { return }
        let definition = session.agent.definition
        let script = scriptSessions[id]
        let location = WorktreeEnvironment(
            worktreePath: worktree.path,
            rootPath: workspace.project(containing: id)?.folderURL ?? worktree.path,
            branch: worktree.branch
        )

        var command = if let script {
            ScriptLaunch.command(
                script: script.command,
                context: LaunchContext(
                    archipelSessionID: id,
                    agentSessionID: nil,
                    hookExecutableURL: hookExecutableURL,
                    socketURL: hookServer.socketURL
                ),
                worktree: location
            )
        } else {
            agentCommand(for: session, definition: definition).adding(location)
        }

        launchFailures[id] = nil
        apply(.launched, to: id)
        Task {
            let path = await loginPATH.value
            // The session may have been closed or started by another path while we waited.
            guard terminals[id] == nil, workspace.session(id: id) != nil else { return }
            guard FileManager.default.fileExists(atPath: worktree.path.path) else {
                launchFailures[id] = "The folder \(worktree.path.path) no longer exists."
                apply(.processExited(code: 1), to: id)
                return
            }
            guard let executable = LoginEnvironment.locate(command.executable, inPATH: path) else {
                launchFailures[id] = "\(definition.displayName) is not installed, or \"\(command.executable)\" is not on your PATH."
                apply(.processExited(code: 127), to: id)
                return
            }
            command.executable = executable
            command.environment["PATH"] = path

            do {
                let terminal = try terminalApp.makeSession(.init(
                    workingDirectory: worktree.path,
                    command: command.shellCommandLine,
                    environment: command.environment,
                    waitAfterCommand: true
                ))
                terminals[id] = terminal
                terminalStartTimes[id] = .now
                terminal.setOccluded(!visibleSessionIDs.contains(id))
                observe(terminal, for: id)
                if script?.kind == .setup {
                    // A setup script is a job with an end, so the sidebar shows it as busy until it exits.
                    apply(.activity, to: id)
                } else if !definition.reportsLifecycleThroughHooks {
                    // Only Claude announces itself through a hook. Everything else
                    // would sit on "starting" forever without this.
                    apply(.sessionStarted, to: id)
                }
            } catch {
                launchFailures[id] = error.localizedDescription
                apply(.processExited(code: 1), to: id)
            }
        }
    }

    private func agentCommand(for session: Session, definition: AgentDefinition) -> LaunchCommand {
        // Claude lets us choose the conversation id up front. It is only
        // persisted once a hook confirms it, so a session that never really
        // started is not "resumed" into an error on the next launch.
        let presetID = definition.presetsAgentSessionID ? UUID().uuidString.lowercased() : nil
        let context = LaunchContext(
            archipelSessionID: session.id,
            agentSessionID: session.agentSessionID ?? presetID,
            hookExecutableURL: hookExecutableURL,
            socketURL: hookServer.socketURL
        )
        var command = definition.launchCommand(for: context)
        if session.agentSessionID != nil, let resume = definition.resumeCommand(for: context) {
            command = resume
        }
        if definition.acceptsPrompts {
            command.arguments += settings.extraArguments(for: definition.id)
        }
        return command
    }

    private func observe(_ terminal: TerminalSession, for id: Session.ID) {
        eventTasks[id] = Task { [weak self] in
            for await event in terminal.events {
                guard let self else { return }
                switch event {
                case .notification(_, let body):
                    self.receiveTerminalNotification(body, for: id)
                case .bell:
                    self.apply(.bell, to: id)
                case .childExited(let exitCode):
                    self.apply(.processExited(code: Int32(truncatingIfNeeded: exitCode)), to: id)
                case .titleChanged(let title):
                    self.receiveTerminalTitle(title, for: id)
                case .workingDirectoryChanged, .progress, .closeRequested:
                    break
                }
            }
        }
    }

    private func receiveTerminalNotification(_ body: String, for id: Session.ID) {
        guard let agent = workspace.session(id: id)?.agent,
              // Hooks report the same moments with more detail, and Claude's
              // "waiting for input" notification would turn a finished turn
              // back into an attention state.
              !agent.definition.reportsLifecycleThroughHooks
        else { return }
        switch agent {
        case .codex:
            // The launch overrides restrict Codex to approval notifications.
            apply(.attentionRequested(.permission, message: body), to: id)
        default:
            apply(.attentionRequested(.question, message: body), to: id)
        }
    }

    /// Agents name their conversation through the terminal title, usually
    /// behind a status glyph or spinner character that we do not want in a tab.
    private func receiveTerminalTitle(_ raw: String, for id: Session.ID) {
        let title = String(raw.drop { !($0.isLetter || $0.isNumber) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let session = workspace.session(id: id), session.agentTitle != title else { return }
        mutate { $0.updateSession(id: id) { $0.agentTitle = title } }
    }

    /// A restart keeps what belongs to the session rather than its process: the script it reruns and
    /// review comments still waiting to be delivered.
    private func tearDown(_ id: Session.ID, restarting: Bool = false) {
        eventTasks.removeValue(forKey: id)?.cancel()
        terminals.removeValue(forKey: id)?.close()
        terminalStartTimes[id] = nil
        activities[id] = nil
        launchFailures[id] = nil
        if !restarting {
            scriptSessions[id] = nil
            pendingReviews[id] = nil
        }
        notifier.clear(sessionID: id)
        refreshDockBadge()
    }

    private func receive(_ message: HookMessage) {
        // Limits belong to the account, so a reading counts even if its session was closed meanwhile.
        if let reading = message.usage { recordUsage(reading) }
        guard let session = workspace.session(id: message.sessionID) else { return }
        // An agent that has only started has no conversation on disk yet, and
        // resuming that id would fail. Wait for proof of a first turn.
        let hasConversation = switch message.event {
        case .promptSubmitted, .activity, .attentionRequested, .turnFinished: true
        default: false
        }
        if hasConversation, let agentSessionID = message.agentSessionID, session.agentSessionID != agentSessionID {
            mutate { $0.updateSession(id: session.id) { $0.agentSessionID = agentSessionID } }
        }
        if let event = message.event { apply(event, to: session.id) }
        // Codex has just written the turn's token counts, and its limits with them, to its log.
        if session.agent == .codex, case .turnFinished? = message.event { refreshCodexUsage() }
    }

    private func apply(_ event: AgentEvent, to id: Session.ID) {
        guard workspace.session(id: id) != nil else { return }
        var activity = activities[id] ?? SessionActivity()
        let before = activity
        let viewed = isBeingViewed(id)
        activity.apply(event, isBeingViewed: viewed)
        commit(activity, replacing: before, of: id, viewed: viewed)
    }

    private func commit(_ activity: SessionActivity, replacing before: SessionActivity, of id: Session.ID, viewed: Bool) {
        // Most hook events (a tool call while already working) change nothing, and writing anyway would
        // re-render every view that reads `activities`.
        guard activity != before, let session = workspace.session(id: id) else { return }
        activities[id] = activity
        scheduleSubagentExpiry()
        let statusChanged = activity.status != before.status
        let worktree = workspace.worktree(containing: id)
        let siblings = (worktree?.sessions ?? []).lazy.filter { $0.id != id }.compactMap { self.activities[$0.id] }
        let pulse = StatusPulse.kind(from: before, to: activity, siblings: siblings)
        if let pulse, let worktreeID = worktree?.id {
            if NSApp.isActive {
                statusPulses[worktreeID, default: StatusPulseCount()].play(pulse)
            } else {
                pulsesAwaitingActivation[worktreeID] = max(pulsesAwaitingActivation[worktreeID] ?? pulse, pulse)
            }
        }
        // Before posting: buttons on an older notification of this session must not answer whatever comes next.
        if statusChanged { notifier.invalidate(sessionID: id) }

        // Finished banners follow the glow, so they wait until the whole worktree is done.
        let worthABanner = activity.status == .finished ? pulse == .finished : statusChanged
        // The session stays unread while on screen, but a banner about the thing you are looking at
        // is noise.
        if activity.unread, !viewed, worthABanner {
            notify(session: session, activity: activity)
        }
        refreshDockBadge()
        if statusChanged {
            sessionStatusChanged(id, from: before.status, to: activity.status)
        }
    }

    /// A subagent whose stop got lost keeps its worktree busy until something prunes it, and no
    /// further event may come. So a timer prunes at the earliest expiry.
    private func scheduleSubagentExpiry() {
        let next = activities.values.compactMap(\.subagents.nextExpiry).min()
        guard next != subagentExpiry?.date else { return }
        subagentExpiry?.task.cancel()
        guard let next else {
            subagentExpiry = nil
            return
        }
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.expireQuietSubagents()
        }
        subagentExpiry = (next, task)
    }

    private func expireQuietSubagents() {
        subagentExpiry = nil
        let now = Date()
        // One session at a time, so the worktree's result glows when its last busy session settles.
        for (id, before) in activities {
            var activity = before
            activity.expireSubagents(at: now)
            commit(activity, replacing: before, of: id, viewed: isBeingViewed(id))
        }
        scheduleSubagentExpiry()
    }

    private func notify(session: Session, activity: SessionActivity) {
        let enabled = switch activity.status {
        case .needsAttention: settings.notifiesWhenAttentionNeeded
        case .finished: settings.notifiesWhenFinished
        case .exited: settings.notifiesWhenExited
        case .notStarted, .starting, .working: false
        }
        guard enabled else { return }
        if settings.suppressesNotificationsWhileActive, NSApp.isActive { return }
        let location = [
            workspace.island(containing: session.id)?.name,
            workspace.project(containing: session.id)?.name,
            workspace.worktree(containing: session.id)?.branch,
        ]
        deliverNotification(
            session: session,
            activity: activity,
            title: "\(session.displayTitle): \(activity.status.label)",
            subtitle: location.compactMap(\.self).joined(separator: " / ")
        )
    }

    /// For a state the app brings about itself, such as answering a prompt from a notification. No
    /// hook reports it back, or not reliably: Claude sends nothing when a request is denied.
    func resolveAttention(of id: Session.ID, to status: SessionStatus) {
        guard var activity = activities[id] else { return }
        let before = activity.status
        activity.status = status
        activity.markViewed()
        activities[id] = activity
        notifier.clear(sessionID: id)
        refreshDockBadge()
        if status != before { sessionStatusChanged(id, from: before, to: status) }
    }

    func refreshDockBadge() {
        notifier.setDockBadge(settings.showsDockBadge ? attentionSummary(of: workspace, activities: activities).needsAttention : 0)
    }

    // MARK: Pane focus

    /// Pane frames in window coordinates with a top-left origin, reported by
    /// the pane views. Not observed: it changes on every layout pass.
    @ObservationIgnored var paneFrames: [Pane.ID: CGRect] = [:]

    /// A terminal is an AppKit view that swallows its own clicks, so SwiftUI gestures on the pane
    /// never see them. Watching mouse-downs is the only way to know which pane the user is in.
    /// Clicking into a pane focuses it and, like typing into a session, counts as having seen what
    /// it finished or asked. Apart from selecting the session, nothing else clears its unread state.
    private func watchSessionInteraction() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, let window = event.window, window.sheets.isEmpty, let content = window.contentView {
                let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
                let panes = self.selectedWorktree?.panes ?? []
                if let pane = panes.first(where: { self.paneFrames[$0.id]?.contains(point) == true }) {
                    self.focus(pane: pane.id)
                    if case .session(let id)? = pane.selectedTab?.content { self.acknowledge(id) }
                }
            }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Runs on every key press. Skip the view walk when nothing is unread.
            if let self, self.activities.values.contains(where: \.unread),
               let responder = event.window?.firstResponder as? NSView,
               let id = self.terminals.first(where: { responder.isDescendant(of: $0.value.view) })?.key {
                self.acknowledge(id)
            }
            return event
        }
    }

    /// Cheap enough for every key press: only an unread session does any work.
    private func acknowledge(_ id: Session.ID) {
        guard activities[id]?.unread == true else { return }
        markViewed(id)
    }

    // MARK: Persistence

    func mutate(_ change: (inout Workspace) -> Void) {
        let sessionsBefore = workspace.allSessionIDs
        let filesBefore = openFileURLs
        change(&workspace)
        // Whichever way a session leaves the workspace (closing its tab, removing its worktree,
        // project or island), its terminal and live state must go with it.
        for id in sessionsBefore.subtracting(workspace.allSessionIDs) { tearDown(id) }
        // Same for file buffers, which otherwise hold the whole text and undo history until quit.
        // A dirty one is kept: the quit prompt is then the last chance to save those edits.
        for url in filesBefore.subtracting(openFileURLs) where !documents.isDirty(url) { documents.close(url) }
        // Here rather than in changingSelection so clicking into another pane counts too.
        if let id = focusedTab?.id { recentTabs.visit(id) }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private var openFileURLs: Set<URL> {
        var urls = Set<URL>()
        for tab in workspace.allWorktrees.lazy.flatMap(\.panes).flatMap(\.tabs) {
            // Standardized like FileDocumentStore's keys, so two spellings of one path count as one file.
            if case .file(let url) = tab.content { urls.insert(url.standardizedFileURL) }
        }
        return urls
    }

    func saveNow() {
        saveTask?.cancel()
        guard canSave else { return }
        UserDefaults.standard.set(recentTabs.ids.map(\.uuidString), forKey: Self.recentTabsKey)
        do {
            try store.save(workspace)
        } catch {
            problem = "The workspace could not be saved. \(error.localizedDescription)"
        }
    }

    func shutDown() {
        saveNow()
        hookServer.stop()
        for terminal in terminals.values { terminal.close() }
    }
}
