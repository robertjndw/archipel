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
        didSet {
            stayAwake.agentsWorking = hasWorkingSessions
            refreshAttention()
        }
    }
    /// What needs the user across all islands, and per island. Kept up to date where `activities`
    /// and `workspace` change, so the status bar, the menu bar icon, the Dock badge and the island
    /// switcher read a stored value instead of each walking every session in their view bodies.
    private(set) var workspaceAttention = AttentionSummary.zero
    @ObservationIgnored private var dockAttentionRequest: Int?
    private(set) var islandAttention: [Island.ID: AttentionSummary] = [:]
    /// The sidebar lists only the worktrees that need the user, from every island. Not persisted: a
    /// filter that hides every project would greet the next launch as a broken sidebar.
    var showsOnlyNeedsMe = false {
        didSet {
            guard showsOnlyNeedsMe != oldValue else { return }
            if showsOnlyNeedsMe { SidebarTips.needsMeFilterUsed() }
            needsMePin = nil
            // Pin the worktree that's already open, or answering its request would pull the row
            // out from under the user.
            guard showsOnlyNeedsMe, let selected = selectedWorktree?.id,
                  worktreesNeedingAttention(in: workspace, activities: activities).contains(selected)
            else { return }
            needsMePin = selected
        }
    }
    /// The worktree last selected while the filter was on. It stays listed for as long as it is the
    /// selection, since opening it is what clears its request and the row would vanish under the
    /// pointer otherwise.
    private(set) var needsMePin: Worktree.ID?
    private(set) var terminals: [Session.ID: TerminalSession] = [:]
    private(set) var launchFailures: [Session.ID: String] = [:]
    /// Counts the launches asked for per session. A launch waits for the login PATH, and a restart
    /// or Run in that time asks for another one with a different command; only the latest may start.
    @ObservationIgnored private var launchGenerations: [Session.ID: Int] = [:]
    /// The glow each worktree row last played. Not persisted, so nothing glows after a launch.
    private(set) var statusPulses: [Worktree.ID: StatusPulseCount] = [:]
    /// Glows of worktrees whose row is not in the sidebar. A collapsed project plays them on its
    /// header, an island other than the selected one on its button in the switcher.
    private(set) var projectPulses: [Project.ID: StatusPulseCount] = [:]
    private(set) var islandPulses: [Island.ID: StatusPulseCount] = [:]
    /// Glows of changes that happened while Archipel was in the background. They would play behind
    /// another app where nobody sees them, so they wait for the app to come back.
    @ObservationIgnored private var pulsesAwaitingActivation: [Worktree.ID: StatusPulse] = [:]
    @ObservationIgnored private var awaitedPulsesTask: Task<Void, Never>?
    @ObservationIgnored private var subagentExpiry: (date: Date, task: Task<Void, Never>)?
    /// Shown as an alert, one message at a time. Assigning while another message is still up puts
    /// the new one in line instead of replacing what the user has not read yet (a failed save
    /// arriving on top of a startup problem, say); dismissing the alert, which sets this to nil,
    /// brings up the next.
    var problem: String? {
        didSet {
            guard !isArrangingProblems else { return }
            if let shown = oldValue, let next = problem {
                guard next != shown else { return }
                isArrangingProblems = true
                problem = shown
                isArrangingProblems = false
                // A failure that repeats (every save while the disk is full) is worth saying once.
                if !queuedProblems.contains(next) { queuedProblems.append(next) }
            } else if oldValue != nil, problem == nil, !queuedProblems.isEmpty {
                presentNextProblemSoon()
            }
        }
    }
    @ObservationIgnored private var queuedProblems: [String] = []
    @ObservationIgnored private var isArrangingProblems = false

    let git = GitClient()
    /// Open file buffers. They live here and not in the editor views because
    /// a view only exists while its tab is selected.
    let documents = FileDocumentStore()
    /// Pages of web tabs, for the same reason as `documents`.
    let webPages = WebPageStore()
    /// A file tab with unsaved edits that the user asked to close.
    var tabAwaitingCloseDecision: Tab?
    /// A close or restart the user asked for while the session was working or waiting on them.
    var sessionAwaitingInterruptDecision: SessionInterruption?
    /// Diff review comments of every worktree. Kept here for the same reason as `documents`.
    let reviewComments: ReviewCommentStore
    /// The project whose settings sheet is open. Lives here because both the sidebar and Run open it.
    var projectSettingsID: Project.ID?
    /// Set when the sheet is opened to configure a script, so it starts on that page.
    var projectSettingsShowsScripts = false
    /// The project the Add Worktree sheet is open for. Here for the same reason as `projectSettingsID`:
    /// the sidebar, the Project menu and the palette all open it.
    var addWorktreeProjectID: Project.ID?
    /// The worktree the Switch Branch sheet is open for. Opened from the sidebar, the inspector's
    /// branch name, the Project menu and the palette.
    var switchBranchWorktreeID: Worktree.ID?
    /// Set by Commit… to put the cursor in the inspector's commit message field; the inspector clears it.
    var focusCommitMessageRequest = false
    /// What the menu bar and the palette asked to rename, remove or create. The sidebar and the tab
    /// bar keep the same for their context menus in state of their own; these are presented by the
    /// window, which is the one place a menu command can reach.
    var renameRequest: RenameTarget?
    /// The worktree itself rather than its id: the sheet stays up to report on a branch it could
    /// not delete, after the worktree has left the workspace.
    var worktreeAwaitingRemoval: Worktree?
    var isCreatingIsland = false
    /// The push, pull or fetch running per worktree for the Project menu and the palette, which
    /// offer one at a time. See AppModel+Sync.
    var syncsInFlight: [Worktree.ID: SyncAction] = [:]
    let settings: AppSettings
    let devServers = DevServerMonitor()
    let resources = ResourceMonitor()
    let stayAwake = StayAwake()
    /// The latest subscription limits per provider, for the status bar. See AppModel+Usage.
    var usage: [UsageProvider: ProviderUsage] = UsageArchive.load()
    /// How full each Claude session's context window is, and when its prompt cache goes cold. Only
    /// in memory: Claude sends the context again as soon as a resumed session draws its status line.
    /// See AppModel+Context.
    var sessionContexts: [Session.ID: SessionContext] = [:]
    var promptCaches: [Session.ID: PromptCacheState] = [:]
    @ObservationIgnored var promptCacheReads: [Session.ID: Task<Void, Never>] = [:]
    /// Images for projects whose icon is a file or was found in the repository. See `loadIcon(of:)`.
    var projectIcons: [Project.ID: NSImage] = [:]
    /// The known editors found on this Mac, in `ExternalEditor.known` order. Looked up at launch and
    /// whenever the app comes forward, since menus and tab bars read it in their bodies.
    private(set) var installedEditors: [ExternalEditor] = []
    /// Ids of the agents whose executable is on the login PATH, for dimming the ones that are not.
    /// Holds every agent until the PATH is known, so nothing is dimmed on a guess.
    private(set) var installedAgentIDs = Set(AgentDefinition.builtIns.map(\.id))
    /// False on a Mac without Xcode or the Command Line Tools; see `DeveloperTools`. Nothing may
    /// start git then, or the system's install dialog comes up.
    private(set) var isGitAvailable = true
    /// Reopens the main window when none exists. Set by the app, which is the only place that can
    /// reach the scene's `openWindow`; see `showMainWindow()`.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// The script a session runs instead of its agent. Not persisted, unlike `Session.script`: after
    /// a relaunch a script tab is a plain shell until the user runs the script again, so a setup
    /// script or dev server never starts by itself.
    var scriptSessions: [Session.ID: ScriptRun] = [:]
    /// Review comments waiting for their target session to be ready for input, by session.
    @ObservationIgnored var pendingReviews: [Session.ID: PendingReview] = [:]
    @ObservationIgnored var terminalStartTimes: [Session.ID: ContinuousClock.Instant] = [:]

    /// Transient repository state for the sidebar rows of the selected island.
    var gitSummaries: [Worktree.ID: GitSummary] = [:]
    /// Worktrees without an upstream whose repository has a remote all the same, which is what
    /// tells a branch that can be published from one that has nowhere to go.
    var worktreesWithRemote: Set<Worktree.ID> = []
    var pullRequests: [Worktree.ID: PullRequestLookup] = [:]
    /// Everything `git worktree list` reported per project at the last refresh. Suggestions are
    /// derived from it on read, so adding or dismissing one updates the sidebar without a git call.
    var gitWorktrees: [Project.ID: [GitWorktreeEntry]] = [:]
    /// Tracked worktrees whose folder was deleted behind our back.
    var missingWorktrees: Set<Worktree.ID> = []
    @ObservationIgnored var worktreeDiscoveryGeneration = 0
    @ObservationIgnored var worktreeDiscoveryInFlight = false
    /// Counts the branch switches made in the app, per worktree. A branch name git reported before
    /// a switch must not be written after it; see `refreshBranches()`.
    @ObservationIgnored var branchGenerations: [Worktree.ID: Int] = [:]
    @ObservationIgnored private var branchRefresh = (inFlight: false, queued: false)
    @ObservationIgnored var gitRefresh = GitRefreshState()
    private let store: WorkspaceStore
    private let terminalApp: TerminalApp?
    /// The Ghostty colors the panes draw around terminals; nil without a terminal engine.
    private(set) var terminalColors: TerminalColors?
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
    /// When the oldest change not yet on disk was made.
    @ObservationIgnored private var unsavedSince: ContinuousClock.Instant?
    /// AppKit can post an activation twice in a row; this keeps the second one from repeating the work.
    @ObservationIgnored private var isAppActive = false
    /// False when the workspace file could not be read or comes from a newer version. Saving then
    /// would replace the user's real data with the empty default.
    private var canSave = true
    /// True from a launch that quarantined the workspace file until the user has put something into
    /// the empty workspace that replaced it. Saving is on then, but the worktrees are missing only
    /// from the stand-in, and the review comments kept for them must outlive it: restoring the
    /// backup should bring them back.
    @ObservationIgnored private var isStandInWorkspace = false

    /// Where this build keeps its workspace, socket and tips.
    static var supportDirectory: URL {
        // Debug builds use their own folder so they can run next to the installed
        // app. Sharing it would mean sharing the workspace file, and the hook server
        // unlinks any socket already at its path, so the installed app would stop
        // getting agent status. ARCHIPEL_SUPPORT_DIR is for throwaway runs.
        #if UITESTS
        // The UI test build is a Debug build under another bundle id. Launched without
        // ARCHIPEL_SUPPORT_DIR it must still stay away from the Debug build's workspace and socket.
        let supportFolder = "Archipel UI Tests"
        #elseif DEBUG
        let supportFolder = "Archipel Dev"
        #else
        let supportFolder = "Archipel"
        #endif
        return ProcessInfo.processInfo.environment["ARCHIPEL_SUPPORT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.applicationSupportDirectory.appending(path: supportFolder, directoryHint: .isDirectory)
    }

    init() {
        let support = Self.supportDirectory
        settings = AppSettings()
        store = WorkspaceStore(fileURL: support.appending(path: "workspace.json"))
        // A file of its own next to the workspace: comments are no part of its schema, and a damaged
        // comments file must never be a reason to quarantine the workspace.
        reviewComments = ReviewCommentStore(fileURL: support.appending(path: "review-comments.json"))
        hookServer = HookServer(socketURL: support.appending(path: "hook.sock"))
        hookExecutableURL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/archipel-hook")
        loginPATH = Task.detached { await LoginEnvironment.resolvePATH() }

        var problems: [String] = []
        do {
            workspace = try store.load()
        } catch WorkspaceStore.LoadError.quarantined(let backup) {
            // The damaged file is out of the way, so saving the new workspace overwrites nothing.
            workspace = Workspace()
            isStandInWorkspace = true
            // The comments go by worktree, so they are pruned as soon as the user starts over with
            // a project. A copy next to the backup keeps the two restorable together.
            let comments = support.appending(path: "review-comments.json")
            let name = "review-comments" + String(backup.lastPathComponent.dropFirst("workspace".count))
            try? FileManager.default.copyItem(at: comments, to: backup.deletingLastPathComponent().appending(path: name))
            problems.append("The workspace file was damaged, so Archipel started with an empty workspace; the old file was kept at \(backup.path).")
        } catch WorkspaceStore.LoadError.newerSchema {
            workspace = Workspace()
            canSave = false
            problems.append("The workspace was saved by a newer version of Archipel, so it is shown empty and nothing you change will be saved until you update Archipel.")
        } catch {
            workspace = Workspace()
            canSave = false
            problems.append("The workspace could not be read (\(error.localizedDescription)), so it is shown empty and nothing you change will be saved.")
        }
        // Ghostty reads this once at startup to find its terminfo and shell integration.
        if let resources = Bundle.main.resourceURL?.appending(path: "ghostty").path {
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
        }
        do {
            terminalApp = try TerminalApp()
        } catch {
            terminalApp = nil
            problems.append("The terminal engine failed to start (\(error.localizedDescription)), so no session can run.")
        }
        do {
            try hookServer.start()
        } catch {
            problems.append("Agent status reporting could not start (\(error)), so the sidebar cannot show whether agents are working, waiting or done.")
        }
        // Before anything below starts git. A few milliseconds, once.
        isGitAvailable = DeveloperTools.isGitInstalled()
        if !isGitAvailable { problems.append(Self.gitMissingMessage) }
        problem = Self.startupMessage(for: problems)

        notifier.onOpenSession = { [weak self] id in
            self?.showMainWindow()
            self?.select(session: id)
        }
        notifier.onResponse = { [weak self] response in self?.answer(response) }
        notifier.start()
        observeActivation()
        Task { [weak self, messages = hookServer.messages] in
            for await message in messages {
                self?.receive(message)
            }
        }
        refreshAttention()
        for id in visibleSessionIDs { ensureRunning(id) }
        openVisibleWebPages()
        if let id = focusedTab?.id { recentTabs.visit(id) }
        refreshInstalledEditors()
        refreshAgentAvailability()
        refreshBranches()
        refreshWorktreeDiscovery()
        refreshGitStatus(lookingUpPullRequests: true)
        loadProjectIcons()
        refreshCodexUsage()
        watchSessionInteraction()
        devServers.start { [weak self] in self?.terminals ?? [:] }
        resources.start { [weak self] in self?.resourceSources() ?? [:] }
        terminalApp?.acceptsDroppedText = { [weak self] in !(self?.isInternalDragPayload($0) ?? false) }
        terminalColors = terminalApp?.colors
        terminalApp?.onColorsChange = { [weak self] in self?.terminalColors = $0 }
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
        reviewComments = ReviewCommentStore()
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
        refreshAttention()
    }
    #endif

    // MARK: Problems

    static let gitMissingMessage = "Git is not installed, so branches, changes, pull requests and new worktrees are unavailable until you install the Xcode Command Line Tools (run xcode-select --install in Terminal)."

    /// Everything that went wrong while starting, as the one message the alert shows. Each problem
    /// is a sentence of its own that says what the user is left without.
    static func startupMessage(for problems: [String]) -> String? {
        switch problems.count {
        case 0: nil
        case 1: problems[0]
        default: "Archipel started with \(problems.count) problems:\n\n" + problems.map { "• \($0)" }.joined(separator: "\n\n")
        }
    }

    /// Not in the same turn: the alert is still on its way out, and SwiftUI drops a presentation
    /// asked for while it dismisses.
    private func presentNextProblemSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            // Something else may have come up meanwhile; the line moves on when that is dismissed.
            guard let self, self.problem == nil, !self.queuedProblems.isEmpty else { return }
            self.problem = self.queuedProblems.removeFirst()
        }
    }

    /// For anything the user asks for that needs git: a clear message instead of the system's
    /// install dialog.
    func requireGit() throws {
        if !isGitAvailable { throw GitError(message: Self.gitMissingMessage) }
    }

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
        if id != workspace.selectedIslandID { SidebarTips.islandSwitched() }
        changingSelection { $0.selectIsland(id) }
    }

    func select(worktree id: Worktree.ID?) {
        guard let id, workspace.worktree(id: id) != nil else { return }
        changingSelection { $0.selectWorktree(id) }
    }

    func select(session id: Session.ID?) {
        guard let id, workspace.session(id: id) != nil else { return }
        changingSelection { $0.selectSession(id) }
        // Asking for a session by name is engaging with it, even when it was on screen already.
        markViewed(id)
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
        if case .session(let session)? = workspace.tab(id: id)?.content { markViewed(session) }
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

    /// Observed here rather than in a view: the app keeps running, and agents keep working, after
    /// its window was closed, and coming back to it then still has to refresh and resume polling.
    private func observeActivation() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidResignActive() }
        }
    }

    func appDidBecomeActive() {
        guard !isAppActive else { return }
        if let request = dockAttentionRequest {
            NSApp.cancelUserAttentionRequest(request)
            dockAttentionRequest = nil
        }
        isAppActive = true
        terminalApp?.setAppFocused(true)
        playAwaitedPulses()
        // Coming back to the app does not mark anything as seen: the window may have been in front
        // all along with nobody at the desk. Clicking or typing into a session does; see
        // watchSessionInteraction().
        // An editor or an agent may have been installed while the user was away.
        refreshInstalledEditors()
        refreshAgentAvailability()
        if !isGitAvailable { lookForGitAgain() }
        refreshBranches()
        refreshWorktreeDiscovery()
        refreshGitStatus(lookingUpPullRequests: true, minimumPullRequestAge: .seconds(30))
        fetchRemotesIfDue()
        startGitStatusTimer()
    }

    /// Plays the glows that waited for the app to come back, one after the other from the top of
    /// the sidebar down. Started together they would all run in step.
    private func playAwaitedPulses() {
        awaitedPulsesTask?.cancel()
        awaitedPulsesTask = Task { @MainActor [weak self] in
            // The window is still coming to the front, and the start of the glow would be missed.
            try? await Task.sleep(for: .milliseconds(300))
            // The user may have switched away again by now. Then they keep waiting.
            guard let self, isAppActive, !Task.isCancelled else { return }
            // Several worktrees can share a project header or an island button, which then plays
            // once, for whatever needs the user most.
            var order: [PulseTarget] = []
            var pulses: [PulseTarget: StatusPulse] = [:]
            for id in workspace.allWorktrees.lazy.map(\.id) {
                guard let pulse = pulsesAwaitingActivation[id] else { continue }
                let target = pulseTarget(for: id)
                if pulses[target] == nil { order.append(target) }
                pulses[target] = max(pulses[target] ?? pulse, pulse)
            }
            pulsesAwaitingActivation.removeAll()
            for target in order {
                guard let pulse = pulses[target] else { continue }
                play(pulse, on: target)
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    /// Where a worktree's glow can be seen right now.
    private enum PulseTarget: Hashable {
        case worktree(Worktree.ID)
        case project(Project.ID)
        case island(Island.ID)
    }

    private func pulseTarget(for id: Worktree.ID) -> PulseTarget {
        // The "Needs Me" list has rows from every island and ignores what is collapsed.
        guard !showsOnlyNeedsMe else { return .worktree(id) }
        if let island = workspace.island(containingWorktree: id), island.id != selectedIsland?.id {
            return .island(island.id)
        }
        if let project = workspace.project(containingWorktree: id), !project.isExpanded {
            return .project(project.id)
        }
        return .worktree(id)
    }

    private func play(_ pulse: StatusPulse, on target: PulseTarget) {
        switch target {
        case .worktree(let id): statusPulses[id, default: StatusPulseCount()].play(pulse)
        case .project(let id): projectPulses[id, default: StatusPulseCount()].play(pulse)
        case .island(let id): islandPulses[id, default: StatusPulseCount()].play(pulse)
        }
    }

    func appDidResignActive() {
        guard isAppActive else { return }
        isAppActive = false
        terminalApp?.setAppFocused(false)
        stopGitStatusTimer()
    }

    private func refreshInstalledEditors() {
        let installed = ExternalEditor.installed()
        if installed != installedEditors { installedEditors = installed }
    }

    /// Looks for each agent's executable once the login PATH is known. A missing agent is otherwise
    /// only found out when a session fails to start.
    func refreshAgentAvailability() {
        Task { [weak self] in
            guard let path = await self?.loginPATH.value else { return }
            // The shell is launched by its full path, which need not be in a folder on the PATH.
            let executables = AgentDefinition.builtIns.map {
                (id: $0.id, name: $0.id == AgentDefinition.shell.id ? AgentDefinition.loginShellPath : $0.executableName)
            }
            let installed = await Task.detached(priority: .utility) {
                Set(executables.filter { LoginEnvironment.locate($0.name, inPATH: path) != nil }.map(\.id))
            }.value
            guard let self else { return }
            if installed != self.installedAgentIDs { self.installedAgentIDs = installed }
            // Until the user picks one, the default is an agent that can actually start.
            if let first = AgentDefinition.builtIns.first(where: { $0.acceptsPrompts && installed.contains($0.id) }) {
                self.settings.suggestDefaultAgent(first.id)
            }
        }
    }

    func isInstalled(_ agent: AgentDefinition) -> Bool {
        installedAgentIDs.contains(agent.id)
    }

    /// The tools may have been installed since the launch said they were missing.
    private func lookForGitAgain() {
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { DeveloperTools.isGitInstalled() }.value
            guard found, let self, !self.isGitAvailable else { return }
            self.isGitAvailable = true
            self.refreshBranches()
            self.refreshWorktreeDiscovery()
            self.refreshGitStatus(lookingUpPullRequests: true)
            self.loadProjectIcons()
        }
    }

    /// Called right before another island is selected, while the workspace is still unchanged.
    /// Putting the new island's content on screen keeps the main thread busy for several frames.
    /// The sidebar sends its slide to the screen from here, which only works ahead of the change:
    /// once views are waiting to update, nothing reaches the screen before they all have.
    @ObservationIgnored var islandWillSwitch: ((_ old: Island.ID?, _ new: Island.ID?) -> Void)?

    /// Every mutation that can change which session is on screen goes through
    /// here, so the terminal that left the screen stops rendering and the one
    /// that entered it is started and marked as seen.
    func changingSelection(_ change: (inout Workspace) -> Void) {
        let previous = Set(visibleSessionIDs)
        let previousPlace = (selectedIsland?.id, selectedWorktree?.id)
        if let islandWillSwitch {
            // Tried on a copy first, to know where the change leads before it is made.
            var next = workspace
            change(&next)
            if next.selectedIslandID != previousPlace.0 { islandWillSwitch(previousPlace.0, next.selectedIslandID) }
        }
        mutate(change)
        if showsOnlyNeedsMe { needsMePin = selectedWorktree?.id }
        if previousPlace.1 != selectedWorktree?.id { SidebarTips.worktreeSwitched() }
        if previousPlace != (selectedIsland?.id, selectedWorktree?.id) {
            refreshGitStatus(lookingUpPullRequests: true)
        }
        let current = Set(visibleSessionIDs)
        for id in previous.subtracting(current) { terminals[id]?.setOccluded(true) }
        for id in current {
            ensureRunning(id)
            terminals[id]?.setOccluded(false)
        }
        openVisibleWebPages()
        // Only what came on screen. A session that merely stayed visible while the selection moved
        // elsewhere (the other pane of a split, say) was not looked at because of it.
        for id in current.subtracting(previous) { markViewed(id) }
    }

    /// Creates the page of every web tab on screen, so its view finds the page already there. Making
    /// it in the view's body would change observed state in the middle of a view update.
    private func openVisibleWebPages() {
        for pane in selectedWorktree?.panes ?? [] {
            if let tab = pane.selectedTab, case .web(let url) = tab.content { webPages.open(tab.id, url: url) }
        }
    }

    private func markViewed(_ id: Session.ID) {
        // Without hooks nothing tells us that the user dealt with a request,
        // so looking at the session has to count as dealing with it.
        if hasUnreportedRequest(id), let before = activities[id]?.status {
            activities[id]?.status = .finished
            sessionStatusChanged(id, from: before, to: .finished)
        }
        clearUnread(id)
    }

    /// A request from an agent that will not say when it was answered.
    private func hasUnreportedRequest(_ id: Session.ID) -> Bool {
        activities[id]?.needsUser == true
            && workspace.session(id: id)?.agent.definition.reportsLifecycleThroughHooks == false
    }

    private func clearUnread(_ id: Session.ID) {
        // Observers fire on every write, equal or not, and this runs on every selection change.
        if activities[id]?.unread == true { activities[id]?.markViewed() }
        notifier.clear(sessionID: id)
        refreshDockBadge()
    }

    /// Clears the unread state of a worktree's sessions without opening them. Pending requests
    /// are left alone, since nobody looked at the session to answer them.
    func markRead(worktree id: Worktree.ID) {
        for session in workspace.worktree(id: id)?.sessions ?? [] { clearUnread(session.id) }
    }

    private func isBeingViewed(_ id: Session.ID) -> Bool {
        NSApp.isActive && visibleSessionIDs.contains(id)
    }

    // MARK: Islands

    func addIsland(name: String, symbol: String, tint: Tint) {
        changingSelection { _ = $0.addIsland(name: name, symbol: symbol, tint: tint) }
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
                // Compared with symlinks followed, before adding: `addWorktree` only tells spellings
                // apart, and the same folder picked through a symlink would become a second worktree.
                let key = Self.resolvedKey(folder)
                let tracked = existing.worktrees.first { Self.resolvedKey($0.path) == key }
                changingSelection {
                    $0.updateProject(id: existing.id) { $0.isExpanded = true }
                    if let tracked {
                        $0.selectWorktree(tracked.id)
                    } else {
                        $0.addWorktree(worktree, to: existing.id)
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
        guard isGitAvailable, let entries = try? await git.worktrees(of: folder),
              let main = entries.first, main.isMain,
              entries.dropFirst().contains(where: { Self.resolvedKey($0.path) == Self.resolvedKey(folder) }),
              await git.isRepository(main.path)
        else { return nil }
        return main.path
    }

    func setProject(_ id: Project.ID, expanded: Bool) {
        mutate { $0.updateProject(id: id) { $0.isExpanded = expanded } }
        // Collapsed projects are left out of the status poll, so the rows coming into view are stale.
        if expanded, let project = workspace.project(id: id) {
            refreshGitStatus(of: project.worktrees.map(\.id), lookingUpPullRequests: true)
        }
    }

    func removeProject(_ project: Project) {
        changingSelection { $0.removeProject(id: project.id) }
    }

    /// Switches to the destination island too, so the project doesn't just vanish from the
    /// sidebar. Keeps the selected worktree if it was in this project, otherwise picks its main
    /// checkout.
    func moveProject(_ id: Project.ID, to island: Island.ID) {
        let selected = selectedWorktree?.id
        changingSelection { workspace in
            workspace.moveProject(id: id, to: island)
            guard let project = workspace.project(id: id) else { return }
            let landing = project.worktrees.first { $0.id == selected }
                ?? project.worktrees.first(where: \.isMain)
                ?? project.worktrees.first
            if let landing {
                workspace.selectWorktree(landing.id)
            } else {
                workspace.selectIsland(island)
            }
        }
    }

    // MARK: Worktrees

    /// Git worktrees of the project that are not in the sidebar yet, dismissed ones included.
    /// Prunable ones are left out: their folder is gone, so there is nothing to open.
    func availableWorktrees(for project: Project) async throws -> [GitWorktreeEntry] {
        try requireGit()
        let entries = try await git.worktrees(of: project.folderURL)
        let current = workspace.project(id: project.id) ?? project
        let aligned = Self.aligned(entries, to: current)
        gitWorktrees[project.id] = aligned
        return Self.untracked(aligned ?? Self.withoutBareRepository(entries), in: current)
    }

    /// The branches that are really checked out somewhere, which git refuses to check out a second
    /// time. A worktree whose folder was deleted does not count: `createWorktree` and `switchBranch`
    /// drop the leftover registration before they use its branch. One that is merely out of reach
    /// keeps its branch, see `isLeftover`.
    func checkedOutBranches(of project: Project) async throws -> Set<String> {
        try requireGit()
        return Set(try await git.worktrees(of: project.folderURL).lazy.filter { !Self.isLeftover($0) }.compactMap(\.branch))
    }

    /// Whether git's registration of a worktree is all that is left of it. git says prunable for
    /// any folder it cannot find, which includes every worktree on a volume that is not mounted,
    /// and those must keep their registration and their branch. Touches the disk.
    static func isLeftover(_ entry: GitWorktreeEntry) -> Bool {
        entry.isPrunable && isDeletedWorktree(entry.path)
    }

    /// Whether a worktree's folder was deleted, as far as can be told: it is missing from a place
    /// that is still there, and was not just renamed beside where it used to be. Touches the disk.
    static func isDeletedWorktree(_ path: URL) -> Bool {
        WorktreeLocation.isProvablyGone(path) && WorktreeLocation.movedWorktree(from: path) == nil
    }

    /// Worktrees git still lists although their folder is gone, as of the last refresh.
    func prunableWorktrees(of project: Project.ID) -> [GitWorktreeEntry] {
        (gitWorktrees[project] ?? []).filter(\.isPrunable)
    }

    /// Drops git's registration of a worktree whose folder was deleted, if `branch` is held by one,
    /// so the branch can be checked out again. Does nothing for a branch in a worktree that exists.
    ///
    /// Throws when the worktree holding the branch cannot be reached right now, most likely because
    /// its volume is not mounted. Its registration stays, so git would refuse the branch anyway;
    /// this only says why in words that point at the disk.
    ///
    /// Throws `LeftoverWorktreeError` unless `confirmed`. A folder that was moved somewhere else
    /// looks exactly like a deleted one, and dropping its registration takes its index and HEAD
    /// with it, so that is only done once the user has said the folder is really gone.
    func releasePrunedBranch(_ branch: String, in project: Project, confirmed: Bool) async throws {
        guard isGitAvailable, let entries = try? await git.worktrees(of: project.folderURL) else { return }
        for entry in entries where entry.isPrunable && entry.branch == branch {
            if let moved = WorktreeLocation.movedWorktree(from: entry.path) {
                throw GitError(message: "The branch \(branch) is checked out in a worktree that was moved from \(entry.path.abbreviatedPath) to \(moved.abbreviatedPath). Run \"git worktree repair\" in that folder so git finds it again, then add it from Add Worktree.")
            }
            guard WorktreeLocation.isProvablyGone(entry.path) else {
                throw GitError(message: "The branch \(branch) is checked out in the worktree at \(entry.path.abbreviatedPath), which cannot be reached right now. If it is on an external or network volume, connect that and try again.")
            }
            guard confirmed else { throw LeftoverWorktreeError(branch: branch, path: entry.path.abbreviatedPath) }
            try? await git.removeWorktree(repository: project.folderURL, path: entry.path)
        }
    }

    /// A branch is held by a worktree whose folder is missing, and using it elsewhere means
    /// dropping that worktree for good. The sheets ask before they try again.
    struct LeftoverWorktreeError: LocalizedError, Equatable {
        var branch: String
        /// The missing folder, already shortened for showing.
        var path: String

        var errorDescription: String? {
            "The branch \(branch) is checked out in a worktree at \(path), whose folder is missing."
        }

        /// What the confirmation says. Shared so both sheets put the choice the same way.
        var question: String {
            "git still has \(branch) checked out in a worktree at \(path), and that folder is missing. If you deleted it, release the branch to use it here.\n\nIf you moved or renamed the folder, cancel instead. Releasing the branch would leave the moved worktree broken. Run \"git worktree repair\" inside it so git finds it again."
        }
    }

    static func untracked(_ entries: [GitWorktreeEntry], in project: Project) -> [GitWorktreeEntry] {
        let known = Set(project.worktrees.map { Project.worktreeKey($0.path) })
        return entries.filter { !$0.isPrunable && !known.contains(Project.worktreeKey($0.path)) }
    }

    /// Worktrees are created outside the repository by default so they never
    /// show up as untracked files inside it.
    /// The task running this can be cancelled until git starts adding the worktree; after that the
    /// worktree exists and is shown.
    @discardableResult
    func createWorktree(in project: Project, branch: String, createBranch: Bool, releasingLeftover: Bool = false) async throws -> WorktreeCreation {
        try await createWorktree(in: project, branch: branch, from: createBranch ? .newBranch : .existingBranch(releasingLeftover: releasingLeftover))
    }

    /// A worktree for a branch that so far only exists on a remote, given as `origin/feature`. It
    /// gets a local branch of the same name that tracks the remote one, the way `git switch feature`
    /// would set it up.
    @discardableResult
    func createWorktree(in project: Project, tracking remoteBranch: String) async throws -> WorktreeCreation {
        try requireGit()
        guard let tracking = await git.remoteTrackingBranch(remoteBranch, in: project.folderURL) else {
            throw GitError(message: "\(remoteBranch) is not a remote branch any more, or a local branch has taken its name.")
        }
        return try await createWorktree(in: project, branch: tracking.branch, from: .remoteBranch(tracking.remote))
    }

    private enum WorktreeSource {
        /// `releasingLeftover` is the user's word that a missing worktree holding the branch was deleted.
        case existingBranch(releasingLeftover: Bool)
        /// Off the project's base.
        case newBranch
        /// A new local branch tracking the branch of the same name on this remote.
        case remoteBranch(String)
    }

    private func createWorktree(in project: Project, branch: String, from source: WorktreeSource) async throws -> WorktreeCreation {
        try requireGit()
        // The sheet may have been open while the settings changed.
        let project = workspace.project(id: project.id) ?? project
        let path = worktreePath(for: project, branch: branch)
        // git creates the new branch before it notices the folder is taken, leaving the branch behind
        // after a failed add, so the folder is checked first.
        if FileManager.default.fileExists(atPath: path.path) {
            throw GitError(message: "The folder \(path.abbreviatedPath) already exists. Pick another branch name, or move or delete that folder.")
        }
        var start: (name: String, fetchFailure: String?)?
        switch source {
        case .existingBranch(let releasingLeftover):
            // A worktree whose folder was deleted by hand still holds its branch as far as git is concerned.
            try await releasePrunedBranch(branch, in: project, confirmed: releasingLeftover)
        case .newBranch:
            start = await fetchedWorktreeBase(for: project)
        case .remoteBranch(let remote):
            // What is known of a remote branch is as old as the last fetch, and the worktree should
            // start where the branch is now.
            start = ("\(remote)/\(branch)", await fetchFailure(of: (remote, branch), in: project))
        }
        // The fetch is the slow part, and where a user gives up. Nothing has been created yet.
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch source {
        case .existingBranch:
            try await git.addWorktree(repository: project.folderURL, path: path, branch: branch, createBranch: false)
        case .newBranch:
            try await git.addWorktree(repository: project.folderURL, path: path, branch: branch, createBranch: true, base: start?.name)
        case .remoteBranch:
            try await git.addWorktree(repository: project.folderURL, path: path, branch: branch, tracking: start?.name ?? branch)
        }
        // The project can have been removed while git worked. The folder is then left as it is,
        // like any other worktree of a repository that is not in the sidebar.
        guard workspace.project(id: project.id) != nil else { throw CancellationError() }
        let worktree = Worktree(path: path, branch: branch)
        changingSelection { _ = $0.addWorktree(worktree, to: project.id) }
        if workspace.project(id: project.id)?.scripts.setupCommand != nil {
            startScript(.setup, in: worktree.id)
        }
        return WorktreeCreation(worktreeID: worktree.id, baseFetchFailure: start?.fetchFailure)
    }

    struct WorktreeCreation {
        var worktreeID: Worktree.ID
        /// Git's explanation when the base branch, or the remote branch the worktree tracks, could
        /// not be fetched first. The worktree was still created, from that branch as it was last
        /// fetched, which the user should be told.
        var baseFetchFailure: String?
    }

    /// Where a new worktree's branch starts: the project's base branch, else the remote's default
    /// branch. Worktrees are usually fresh tasks, so they should start from what's merged. Nil means
    /// HEAD, for repositories without a remote.
    func worktreeBase(for project: Project) async -> String? {
        if let configured = project.baseBranch { return configured }
        guard isGitAvailable else { return nil }
        return await git.remoteDefaultBranch(in: project.folderURL)
    }

    /// `worktreeBase`, fetched first when it is a remote-tracking branch. A failed fetch (offline,
    /// expired credentials) does not stop the worktree, since a slightly stale base is better than
    /// none, but it is handed back so the user can be told.
    private func fetchedWorktreeBase(for project: Project) async -> (name: String, fetchFailure: String?)? {
        guard let base = await worktreeBase(for: project) else { return nil }
        guard let tracking = await git.remoteTrackingBranch(base, in: project.folderURL) else { return (base, nil) }
        return (base, await fetchFailure(of: tracking, in: project))
    }

    private func fetchFailure(of tracking: (remote: String, branch: String), in project: Project) async -> String? {
        do {
            try await git.fetch(branch: tracking.branch, from: tracking.remote, in: project.folderURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Takes the worktree out of the sidebar. With `deleteFolder` git removes the folder too,
    /// forcing past uncommitted changes when `force` is set (the sheet only sets it after warning
    /// about them). A folder that is missing only because its volume is not mounted is left
    /// registered with git, so the worktree works again once the volume is back. `deleteBranch` names the branch the user agreed to delete; it is deleted only if
    /// the worktree still had it checked out, and git keeps it when unmerged.
    /// Throws, leaving everything in place, when git refuses to remove the folder. A branch that
    /// cannot be deleted does not throw: the worktree is gone by then, so it is reported instead.
    func removeWorktree(_ id: Worktree.ID, deleteFolder: Bool, deleteBranch: String?, force: Bool) async throws -> BranchRemoval {
        guard let worktree = workspace.worktree(id: id), !worktree.isMain,
              let project = workspace.project(containingWorktree: id)
        else { return .notRequested }
        let folderExists = FileManager.default.fileExists(atPath: worktree.path.path(percentEncoded: false))
        // Missing is not the same as deleted: on an unmounted volume the worktree is all still there.
        let isGone = !folderExists && Self.isDeletedWorktree(worktree.path)
        if deleteFolder, folderExists { try requireGit() }
        // Found before the folder goes, while a file opened through another spelling of its path
        // (`/private/var` for `/var`, say) can still be resolved to this worktree.
        let resolvedRoot = Self.resolvedKey(worktree.path) + "/"
        let unsavedInside = documents.dirtyURLs.filter { Self.resolvedKey($0).hasPrefix(resolvedRoot) }
        var checkedOut: String?
        if deleteFolder, deleteBranch != nil, isGitAvailable {
            checkedOut = if folderExists {
                // Asked fresh because the cached name lags behind checkouts made in the terminal.
                await git.currentBranch(in: worktree.path)
            } else {
                // Nothing to ask in a folder that is gone; git's own record of the worktree knows.
                await registeredBranch(ofWorktreeAt: worktree.path, in: project)
            }
        }
        if isGone {
            // git still lists the worktree, and its branch counts as checked out there, so it could
            // not be used anywhere else. Asked whatever `deleteFolder` says, since there is no folder
            // left to keep. Failing only means there was no such record.
            if isGitAvailable { try? await git.removeWorktree(repository: project.folderURL, path: worktree.path) }
        } else if deleteFolder, folderExists {
            try await git.removeWorktree(repository: project.folderURL, path: worktree.path, force: force)
        }
        // Edits to files that no longer exist cannot be saved anywhere. Kept, they would make every
        // Save All fail and hold up quitting with a prompt nothing can satisfy. Forgotten rather
        // than closed, because a file opened under two paths (`CLAUDE.md` linking to `AGENTS.md`)
        // would keep its buffer for the second one.
        if isGone || (deleteFolder && folderExists) {
            for url in unsavedInside.union(unsavedDocuments(under: worktree.path)) { documents.forget(url) }
        }
        let removal = workspace.removal(ofWorktree: id)
        // A folder that stays on disk would be suggested again right away.
        changingSelection { $0.removeWorktree(id: id, dismiss: !deleteFolder) }
        missingWorktrees.remove(id)
        refreshWorktreeDiscovery()
        if !deleteFolder, !isGone, let removal { registerRestore(removal) }

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

    private func registeredBranch(ofWorktreeAt path: URL, in project: Project) async -> String? {
        let key = Self.resolvedKey(path)
        return (try? await git.worktrees(of: project.folderURL))?.first { Self.resolvedKey($0.path) == key }?.branch
    }

    /// Files with unsaved edits inside `folder`, for warning before the folder is deleted. Compares
    /// paths as spelled and never touches the disk, so a view body can call it.
    func unsavedDocuments(under folder: URL) -> [URL] {
        let root = Project.worktreeKey(folder) + "/"
        return documents.dirtyURLs.filter { $0.path(percentEncoded: false).hasPrefix(root) }
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
        guard isGitAvailable else { return }
        // Activation can come several times in a row. One pass at a time, and one more afterwards
        // for whatever changed while it ran.
        guard !branchRefresh.inFlight else {
            branchRefresh.queued = true
            return
        }
        branchRefresh.inFlight = true
        let worktrees = workspace.allWorktrees
        Task {
            for worktree in worktrees {
                // git answers nothing for a folder it cannot reach, the same as for a detached HEAD.
                // The stored name of a worktree on a disk that is not mounted has to outlive that.
                guard FileManager.default.fileExists(atPath: worktree.path.path) else { continue }
                let generation = branchGenerations[worktree.id]
                let branch = await git.currentBranch(in: worktree.path)
                // A switch made in the app while git was asked has written the newer name already.
                guard generation == branchGenerations[worktree.id],
                      let current = workspace.worktree(id: worktree.id), current.branch != branch
                else { continue }
                mutate { $0.updateWorktree(id: worktree.id) { $0.branch = branch } }
            }
            branchRefresh.inFlight = false
            if branchRefresh.queued {
                branchRefresh.queued = false
                refreshBranches()
            }
        }
    }

    /// Forgets what is kept per worktree or project once that is gone. Runs with the status poll,
    /// so observed state is only written when something was actually removed.
    func pruneRemovedState(keeping worktrees: Set<Worktree.ID>) {
        if !statusPulses.keys.allSatisfy(worktrees.contains) {
            statusPulses = statusPulses.filter { worktrees.contains($0.key) }
        }
        pulsesAwaitingActivation = pulsesAwaitingActivation.filter { worktrees.contains($0.key) }
        branchGenerations = branchGenerations.filter { worktrees.contains($0.key) }
        gitRefresh.diffStatCheckedAt = gitRefresh.diffStatCheckedAt.filter { worktrees.contains($0.key) }
        let projects = Set(workspace.islands.lazy.flatMap(\.projects).map(\.id))
        if !projectPulses.keys.allSatisfy(projects.contains) {
            projectPulses = projectPulses.filter { projects.contains($0.key) }
        }
        if !islandPulses.keys.allSatisfy({ workspace.island(id: $0) != nil }) {
            islandPulses = islandPulses.filter { workspace.island(id: $0.key) != nil }
        }
        if !projectIcons.keys.allSatisfy(projects.contains) {
            projectIcons = projectIcons.filter { projects.contains($0.key) }
        }
        gitRefresh.fetchedAt = gitRefresh.fetchedAt.filter { projects.contains($0.key) }
        // Not while the workspace on screen is a stand-in for one that could not be loaded: its
        // worktrees are not gone, and neither should their comments be. That holds for a workspace
        // that is never saved, and for the empty one after a quarantine until the user adds to it.
        if isStandInWorkspace, !workspace.allWorktrees.isEmpty { isStandInWorkspace = false }
        if canSave, !isStandInWorkspace { reviewComments.retain(only: workspace.allWorktrees.map(\.path)) }
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
        setTitle(ofSession: id, to: title, custom: true)
    }

    // MARK: Tabs

    func openFile(_ url: URL, in worktreeID: Worktree.ID? = nil, preview: Bool) {
        open(.file(url), in: worktreeID, preview: preview)
    }

    func openDiff(path: String, staged: Bool, preview: Bool) {
        open(.diff(path: path, staged: staged), preview: preview)
    }

    /// Opens a web page as a tab, or in the browser when that is the user's choice for web links.
    /// `alternate` flips that choice.
    func openWebLink(_ url: URL, alternate: Bool = false, in worktreeID: Worktree.ID? = nil) {
        let destination = alternate ? settings.webLinkDestination.other : settings.webLinkDestination
        guard destination == .archipel else {
            NSWorkspace.shared.open(url)
            return
        }
        open(.web(url), in: worktreeID, preview: true)
    }

    /// A link ⌘-clicked in a session's terminal opens in that session's worktree.
    private func openTerminalLink(_ link: TerminalLink, alternate: Bool, from sessionID: Session.ID) {
        let worktreeID = workspace.worktree(containing: sessionID)?.id
        switch link {
        case .web(let url):
            openWebLink(url, alternate: alternate, in: worktreeID)
        case .file(let url) where !isDirectory(url):
            let destination = alternate ? settings.fileLinkDestination.other : settings.fileLinkDestination
            if destination == .archipel {
                open(.file(url), in: worktreeID, preview: true)
            } else {
                link.openExternally()
            }
        case .file, .mail:
            // Folders have no tab of their own, so they always go to Finder; mail to the mail app.
            link.openExternally()
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func open(_ content: TabContent, in worktreeID: Worktree.ID? = nil, preview: Bool) {
        guard let worktree = worktreeID.flatMap(workspace.worktree(id:)) ?? selectedWorktree else { return }
        // Read before the change: inside it, `workspace` is exclusively borrowed.
        let isElsewhere = worktree.id != selectedWorktree?.id
        changingSelection { workspace in
            // Opening a preview reuses the pane's preview tab. One with unsaved edits would vanish
            // with its edits still in the buffer and no tab left to save or discard them from.
            for tab in worktree.panes.flatMap(\.tabs) where tab.isPreview {
                if case .file(let url) = tab.content, documents.isDirty(url) { workspace.pinTab(id: tab.id) }
            }
            let tab = workspace.openTab(content, in: worktree.id, preview: preview)
            if let tab, isElsewhere { workspace.selectTab(id: tab) }
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

    /// Closing a session tab ends the session. A file with unsaved edits or a session in the
    /// middle of something is not closed here; the user is asked first.
    func close(tab id: Tab.ID) {
        guard let tab = workspace.tab(id: id) else { return }
        // Only the last tab of a file takes its buffer along. While another tab still shows it the
        // edits are not going anywhere, so there is nothing to ask.
        if case .file(let url) = tab.content, documents.isDirty(url), isLastTab(tab, showing: url) {
            tabAwaitingCloseDecision = tab
            return
        }
        if case .session(let session) = tab.content, let interruption = interruption(of: session, by: .close(tab)) {
            sessionAwaitingInterruptDecision = interruption
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
        } else if isLastTab(tab, showing: url) {
            // The file may have been opened in another tab while the dialog was up; "Don't Save" was
            // about this tab and must not revert what that one shows.
            documents.discardChanges(url)
        }
        closeNow(tab)
    }

    private func isLastTab(_ tab: Tab, showing url: URL) -> Bool {
        // By buffer and not by path: a tab that reached the file through a symlink shows the same
        // edits under another path.
        !workspace.allWorktrees.lazy.flatMap(\.panes).flatMap(\.tabs).contains { other in
            guard other.id != tab.id, case .file(let otherURL) = other.content else { return false }
            return documents.sharesBuffer(otherURL, url)
        }
    }

    /// The file's buffer is released by `mutate` once no tab shows the file any more.
    private func closeNow(_ tab: Tab) {
        let closed = workspace.closedTab(id: tab.id)
        changingSelection { $0.closeTab(id: tab.id) }
        if let closed { registerReopen(closed) }
    }

    func split(tab id: Tab.ID) {
        let before = workspace.placement(ofTab: id)
        changingSelection { _ = $0.splitTab(id: id) }
        registerMove(of: id, from: before, actionName: "Split Pane")
    }

    func move(tab id: Tab.ID, toPane pane: Pane.ID, at index: Int? = nil) {
        let before = workspace.placement(ofTab: id)
        changingSelection { $0.moveTab(id: id, toPane: pane, at: index) }
        registerMove(of: id, from: before, actionName: "Move Tab")
    }

    struct SessionInterruption: Identifiable {
        enum Action {
            case close(Tab)
            case restart(fresh: Bool)
        }

        let sessionID: Session.ID
        let action: Action
        // Worded when the user asked, so the dialog does not change under them when the agent
        // finishes while it is up.
        let title: String
        let message: String
        var id: Session.ID { sessionID }

        var confirmLabel: String {
            switch action {
            case .close: "Close Tab"
            case .restart: "Restart"
            }
        }
    }

    /// Stopping a session that is working or waiting on an answer throws that turn away, and one
    /// with background tasks takes those down with it, so those ask first. Nil for idle, finished
    /// and exited sessions, which have nothing in flight.
    private func interruption(of id: Session.ID, by action: SessionInterruption.Action) -> SessionInterruption? {
        guard let session = workspace.session(id: id), let activity = activities[id],
              activity.hasWorkInFlight
        else { return nil }
        let state = if activity.needsUser {
            "waiting for you"
        } else if activity.isBusy {
            "working"
        } else {
            activity.backgroundTasks == 1 ? "running a background task" : "running background tasks"
        }
        // A script or a shell has no conversation to lose or to come back to.
        let isAgent = scriptSessions[id] == nil && session.agent.definition.acceptsPrompts
        let title: String
        let message: String
        switch action {
        case .close:
            title = "Close \"\(session.displayTitle)\" while it is \(state)?"
            message = isAgent
                ? "The agent will be stopped. Closing the tab removes the session, so its conversation can no longer be resumed in Archipel."
                : "The running command will be stopped."
        case .restart(let fresh):
            title = "Restart \"\(session.displayTitle)\" while it is \(state)?"
            message = if !isAgent {
                "The running command will be stopped and started again."
            } else if fresh || session.agentSessionID == nil {
                "The agent will be stopped and starts again with a new conversation."
            } else {
                "The agent will be stopped. Its conversation is kept and resumes when the session starts again."
            }
        }
        return SessionInterruption(sessionID: id, action: action, title: title, message: message)
    }

    func resolve(_ interruption: SessionInterruption) {
        switch interruption.action {
        case .close(let tab):
            // The tab may have been closed some other way while the dialog was up.
            if workspace.tab(id: tab.id) != nil { closeNow(tab) }
        case .restart(let fresh):
            restartSessionNow(interruption.sessionID, fresh: fresh)
        }
    }

    /// Restarts the session, asking first when that would interrupt it.
    func restartSession(_ id: Session.ID, fresh: Bool = false) {
        if let interruption = interruption(of: id, by: .restart(fresh: fresh)) {
            sessionAwaitingInterruptDecision = interruption
            return
        }
        restartSessionNow(id, fresh: fresh)
    }

    /// Kills the process if there is one and starts again, resuming the
    /// agent's conversation unless `fresh` is set.
    func restartSessionNow(_ id: Session.ID, fresh: Bool = false) {
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

    /// Starts the session's process unless it has one or already ended. A failed launch or an exit
    /// stays on screen with its message until the user asks to try again; `restartSessionNow` clears
    /// that state before it calls this. Without the check every selection change would relaunch it.
    private func ensureRunning(_ id: Session.ID) {
        if launchFailures[id] != nil { return }
        if case .exited? = activities[id]?.status { return }
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

        // Here and not at launch: starting an agent is what gives the question its context.
        if script == nil, definition.acceptsPrompts { notifier.requestAuthorizationIfNeeded() }
        launchFailures[id] = nil
        apply(.launched, to: id)
        launchGenerations[id, default: 0] += 1
        let launch = launchGenerations[id]
        Task {
            let path = await loginPATH.value
            // The session may have been closed, started by another path or asked to start
            // something else while we waited.
            guard launch == launchGenerations[id], terminals[id] == nil, workspace.session(id: id) != nil else { return }
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
                case .openLink(let link, let alternate):
                    self.openTerminalLink(link, alternate: alternate, from: id)
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
            launchGenerations[id] = nil
            scriptSessions[id] = nil
            pendingReviews[id] = nil
            forgetContext(of: id)
        }
        notifier.clear(sessionID: id)
        refreshDockBadge()
    }

    private func receive(_ message: HookMessage) {
        // Limits belong to the account, so a reading counts even if its session was closed meanwhile.
        if let reading = message.usage { recordUsage(reading) }
        guard let session = workspace.session(id: message.sessionID) else { return }
        if let context = message.context {
            recordContext(context, for: session.id)
        } else if message.usage != nil {
            // A status line without a context is one drawn before the first reply, as after /clear.
            forgetContext(of: session.id)
        }
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
        // The turn's last request has made it into the transcript by now.
        if case .turnFinished? = message.event { refreshPromptCache(for: session.id) }
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
                play(pulse, on: pulseTarget(for: worktreeID))
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
        if case .needsAttention = activity.status { bounceDock() }
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

    /// Independent of the banner settings: it is its own opt-in. Held back while sharing the screen
    /// for the same reason banners are.
    private func bounceDock() {
        guard settings.bouncesDockForAttention, !NSApp.isActive else { return }
        if settings.holdsNotificationsWhileSharingScreen, ScreenSharingDetector.isSharing() { return }
        dockAttentionRequest = NSApp.requestUserAttention(.informationalRequest)
    }

    func refreshDockBadge() {
        notifier.setDockBadge(settings.showsDockBadge ? workspaceAttention.needsAttention : 0)
    }

    private func refreshAttention() {
        var total = AttentionSummary.zero
        var islands: [Island.ID: AttentionSummary] = [:]
        for island in workspace.islands {
            let summary = attentionSummary(of: island, activities: activities)
            islands[island.id] = summary
            total = total + summary
        }
        // Runs on every activity write and every mutation, nearly all of which change no count.
        if islands != islandAttention { islandAttention = islands }
        if total != workspaceAttention {
            if total.needsAttention > workspaceAttention.needsAttention { SidebarTips.agentWaited() }
            workspaceAttention = total
        }
    }

    // MARK: Pane focus

    /// The id of the main window's scene, which SwiftUI also gives its NSWindow as the identifier.
    static let mainWindowID = "main"

    /// Tabs, panes and their frames belong to the main window only. Settings and the menu bar panel
    /// are windows of the same app, so anything that acts on "the window" has to check.
    static func isMainWindow(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue == mainWindowID
    }

    /// Whether a sheet may be asked for now, bringing the main window forward if so, since that is
    /// where sheets attach. Menu commands stay enabled under a sheet and with the window closed. A
    /// second sheet would wait and come up after the first is dismissed, and one asked for without
    /// a window would appear whenever that is next opened, by which time what it was for may be gone.
    func readyForSheet() -> Bool {
        if NSApp.windows.contains(where: { Self.isMainWindow($0) && $0.attachedSheet != nil }) { return false }
        if !Self.isMainWindow(NSApp.keyWindow) { showMainWindow() }
        return true
    }

    /// Brings Archipel and its main window forward. The app keeps running without a window while
    /// agents work, so anything that says "show this session" has to be able to bring it back.
    func showMainWindow() {
        NSApp.activate()
        // AppKit keeps a closed SwiftUI window around, hidden, and ordering it front shows it again
        // with its content intact. There is none when the app was launched without its window; only
        // the scene can make one then, and only the app can reach the scene.
        if let window = NSApp.windows.first(where: { Self.isMainWindow($0) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    /// Pane frames in window coordinates with a top-left origin, reported by
    /// the pane views. Not observed: it changes on every layout pass.
    @ObservationIgnored var paneFrames: [Pane.ID: CGRect] = [:]

    /// A terminal is an AppKit view that swallows its own clicks, so SwiftUI gestures on the pane
    /// never see them. Watching mouse-downs is the only way to know which pane the user is in.
    /// Clicking into a pane focuses it and, like typing into a session, counts as having seen what
    /// it finished or asked. Apart from selecting the session, nothing else clears its unread state.
    private func watchSessionInteraction() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // The monitor sees clicks in every window of the app, and a point in Settings or the menu
            // bar panel would otherwise be hit-tested against pane frames of the main window.
            if let self, let window = event.window, Self.isMainWindow(window), window.sheets.isEmpty,
               let content = window.contentView {
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
            // Runs on every key press. Skip the view walk when nothing is unread or waiting.
            if let self, self.activities.values.contains(where: { $0.unread || $0.needsUser }),
               let responder = event.window?.firstResponder as? NSView,
               let id = self.terminals.first(where: { responder.isDescendant(of: $0.value.view) })?.key {
                self.acknowledge(id)
            }
            return event
        }
    }

    /// Cheap enough for every key press: only an unread session does any work, or one whose request
    /// was marked as read without being answered.
    private func acknowledge(_ id: Session.ID) {
        guard activities[id]?.unread == true || hasUnreportedRequest(id) else { return }
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
        webPages.retain(only: webTabIDs)
        refreshAttention()
        SidebarTips.workspaceChanged(workspace)
        // Here rather than in changingSelection so clicking into another pane counts too.
        if let id = focusedTab?.id { recentTabs.visit(id) }
        // Saved once things have been quiet for a moment, but never later than `longestSaveDelay`
        // after the first change: an agent that retitles its terminal several times a second
        // would otherwise push the save back for as long as it works.
        let now = ContinuousClock.now
        let first = unsavedSince ?? now
        unsavedSince = first
        let deadline = min(now.advanced(by: Self.saveQuietTime), first.advanced(by: Self.longestSaveDelay))
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private static let saveQuietTime = Duration.milliseconds(400)
    private static let longestSaveDelay = Duration.seconds(2)

    private var openFileURLs: Set<URL> {
        var urls = Set<URL>()
        for tab in workspace.allWorktrees.lazy.flatMap(\.panes).flatMap(\.tabs) {
            // Standardized like FileDocumentStore's keys, so two spellings of one path count as one file.
            if case .file(let url) = tab.content { urls.insert(url.standardizedFileURL) }
        }
        return urls
    }

    private var webTabIDs: Set<Tab.ID> {
        var ids = Set<Tab.ID>()
        for tab in workspace.allWorktrees.lazy.flatMap(\.panes).flatMap(\.tabs) {
            if case .web = tab.content { ids.insert(tab.id) }
        }
        return ids
    }

    func saveNow() {
        saveTask?.cancel()
        unsavedSince = nil
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
        reviewComments.saveNow()
        hookServer.stop()
        for terminal in terminals.values { terminal.close() }
    }
}
