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
    private(set) var activities: [Session.ID: SessionActivity] = [:]
    private(set) var terminals: [Session.ID: TerminalSession] = [:]
    private(set) var launchFailures: [Session.ID: String] = [:]
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
    let settings = AppSettings()
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
    @ObservationIgnored var gitRefresh = GitRefreshState()
    private let store: WorkspaceStore
    private let terminalApp: TerminalApp?
    private let hookServer: HookServer
    private let notifier = AttentionNotifier()
    private let hookExecutableURL: URL
    private var loginPATH: Task<String, Never>
    private var eventTasks: [Session.ID: Task<Void, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    /// False when the workspace file could not be read. Saving then would
    /// replace the user's real data with the empty default.
    private var canSave = true

    init() {
        // The override lets a development build run next to the installed app
        // without the two sharing a workspace file and hook socket.
        let support = ProcessInfo.processInfo.environment["ARCHIPEL_SUPPORT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.applicationSupportDirectory.appending(path: "Archipel", directoryHint: .isDirectory)
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
        notifier.start()
        Task { [weak self, messages = hookServer.messages] in
            for await message in messages {
                self?.receive(message)
            }
        }
        for id in visibleSessionIDs { ensureRunning(id) }
        refreshBranches()
        refreshGitStatus(lookingUpPullRequests: true)
        loadProjectIcons()
        watchPaneClicks()
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
        for id in visibleSessionIDs { markViewed(id) }
        refreshBranches()
        refreshGitStatus(lookingUpPullRequests: true, minimumPullRequestAge: .seconds(30))
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
        if workspace.session(id: id)?.agent != .claude, activities[id]?.needsUser == true {
            activities[id]?.status = .finished
        }
        activities[id]?.markViewed()
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
        guard workspace.islands.count > 1, let island = workspace.island(id: id) else { return }
        for session in island.projects.flatMap(\.worktrees).flatMap(\.sessions) { tearDown(session.id) }
        changingSelection { _ = $0.removeIsland(id: id) }
    }

    // MARK: Projects

    func addProject(folder: URL) {
        guard let island = selectedIsland else { return }
        let main = Worktree(path: folder, isMain: true)
        let project = Project(name: folder.lastPathComponent, folderURL: folder, worktrees: [main])
        changingSelection {
            _ = $0.addProject(project, to: island.id)
            $0.selectWorktree(main.id)
        }
        refreshBranches()
        loadIcon(of: project)
    }

    func renameProject(_ id: Project.ID, to name: String) {
        mutate { $0.renameProject(id: id, to: name) }
    }

    func setProject(_ id: Project.ID, expanded: Bool) {
        mutate { $0.updateProject(id: id) { $0.isExpanded = expanded } }
    }

    func removeProject(_ project: Project) {
        for session in project.worktrees.flatMap(\.sessions) { tearDown(session.id) }
        changingSelection { $0.removeProject(id: project.id) }
    }

    func moveProject(_ id: Project.ID, to island: Island.ID) {
        changingSelection { $0.moveProject(id: id, to: island) }
    }

    // MARK: Worktrees

    /// Git worktrees of the project that are not in the sidebar yet.
    func availableWorktrees(for project: Project) async throws -> [GitWorktreeEntry] {
        let known = Set(project.worktrees.map { $0.path.standardizedFileURL.path })
        return try await git.worktrees(of: project.folderURL)
            .filter { !known.contains($0.path.standardizedFileURL.path) }
    }

    func addExistingWorktree(_ entry: GitWorktreeEntry, to project: Project.ID) {
        let worktree = Worktree(path: entry.path, branch: entry.branch)
        changingSelection { _ = $0.addWorktree(worktree, to: project) }
    }

    /// Worktrees are created outside the repository by default so they never
    /// show up as untracked files inside it.
    func createWorktree(in project: Project, branch: String, createBranch: Bool) async throws {
        // The sheet may have been open while the settings changed.
        let project = workspace.project(id: project.id) ?? project
        let path = worktreePath(for: project, branch: branch)
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

    /// Takes the worktree out of the sidebar. With `deleteFromDisk` the folder
    /// is removed through git as well, which refuses when it has uncommitted
    /// changes; the branch is always kept.
    func removeWorktree(_ id: Worktree.ID, deleteFromDisk: Bool) {
        guard let worktree = workspace.worktree(id: id), !worktree.isMain,
              let project = workspace.project(containingWorktree: id)
        else { return }
        Task {
            if deleteFromDisk {
                do {
                    try await git.removeWorktree(repository: project.folderURL, path: worktree.path)
                } catch {
                    problem = "The worktree was not removed. \(error.localizedDescription)"
                    return
                }
            }
            for session in worktree.sessions { tearDown(session.id) }
            changingSelection { $0.removeWorktree(id: id) }
        }
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
        changingSelection { _ = $0.openTab(content, in: worktree.id, preview: preview) }
    }

    func pin(tab id: Tab.ID) {
        mutate { $0.pinTab(id: id) }
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

    private func closeNow(_ tab: Tab) {
        switch tab.content {
        case .session(let session):
            tearDown(session)
        case .file(let url):
            documents.close(url)
        case .diff:
            break
        }
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
        activities.values.contains { $0.status == .working }
    }

    // MARK: Running sessions

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

        // Claude lets us choose the conversation id up front. It is only
        // persisted once a hook confirms it, so a session that never really
        // started is not "resumed" into an error on the next launch.
        let presetID = definition.presetsAgentSessionID ? UUID().uuidString.lowercased() : nil
        let context = LaunchContext(
            archipelSessionID: id,
            agentSessionID: session.agentSessionID ?? presetID,
            hookExecutableURL: hookExecutableURL,
            socketURL: hookServer.socketURL,
            workingDirectory: worktree.path
        )
        var command = definition.launchCommand(for: context)
        if session.agentSessionID != nil, let resume = definition.resumeCommand(for: context) {
            command = resume
        }
        if script == nil, definition.id != AgentDefinition.shell.id {
            command.arguments += settings.extraArguments(for: definition.id)
        }
        command = command.adding(location)
        if let script { command = ScriptLaunch.command(script: script.command, context: context, worktree: location) }

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
                } else if definition.id != AgentDefinition.claude.id {
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
        switch workspace.session(id: id)?.agent {
        case .claude?:
            // Claude's hooks report the same moments with more detail, and its
            // "waiting for input" notification would turn a finished turn
            // back into an attention state.
            break
        case .codex?:
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
    }

    private func apply(_ event: AgentEvent, to id: Session.ID) {
        guard let session = workspace.session(id: id) else { return }
        var activity = activities[id] ?? SessionActivity()
        let before = activity
        activity.apply(event, isBeingViewed: isBeingViewed(id))
        activities[id] = activity

        if activity.unread, activity.status != before.status {
            notify(session: session, activity: activity)
        }
        refreshDockBadge()
        if activity.status != before.status {
            sessionStatusChanged(id, from: before.status, to: activity.status)
        }
    }

    private func notify(session: Session, activity: SessionActivity) {
        let headline: String
        switch activity.status {
        case .needsAttention(.permission): headline = "Needs your approval"
        case .needsAttention: headline = "Waiting for you"
        case .finished: headline = "Finished"
        case .exited(let code): headline = code == 0 ? "Ended" : "Exited with code \(code)"
        case .notStarted, .starting, .working: return
        }
        let enabled = switch activity.status {
        case .needsAttention: settings.notifiesWhenAttentionNeeded
        case .finished: settings.notifiesWhenFinished
        default: settings.notifiesWhenExited
        }
        guard enabled else { return }
        if settings.suppressesNotificationsWhileActive, NSApp.isActive { return }
        let location = [
            workspace.island(containing: session.id)?.name,
            workspace.project(containing: session.id)?.name,
            workspace.worktree(containing: session.id)?.branch,
        ]
        notifier.post(
            sessionID: session.id,
            title: "\(session.displayTitle): \(headline)",
            subtitle: location.compactMap(\.self).joined(separator: " / "),
            body: activity.lastMessage,
            playsSound: settings.playsNotificationSound
        )
    }

    func refreshDockBadge() {
        notifier.setDockBadge(settings.showsDockBadge ? attentionSummary(of: workspace, activities: activities).needsAttention : 0)
    }

    // MARK: Pane focus

    /// Pane frames in window coordinates with a top-left origin, reported by
    /// the pane views. Not observed: it changes on every layout pass.
    @ObservationIgnored var paneFrames: [Pane.ID: CGRect] = [:]

    /// A terminal is an AppKit view that swallows its own clicks, so SwiftUI
    /// gestures on the pane never see them. Watching mouse-downs is the one
    /// way to learn which pane the user is working in.
    private func watchPaneClicks() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, let window = event.window, window.sheets.isEmpty, let content = window.contentView {
                let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
                let panes = Set(self.selectedWorktree?.panes.map(\.id) ?? [])
                if let hit = self.paneFrames.first(where: { panes.contains($0.key) && $0.value.contains(point) }) {
                    self.focus(pane: hit.key)
                }
            }
            return event
        }
    }

    // MARK: Persistence

    func mutate(_ change: (inout Workspace) -> Void) {
        change(&workspace)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard canSave else { return }
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
