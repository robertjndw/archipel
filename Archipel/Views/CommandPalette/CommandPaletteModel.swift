import AgentKit
import AppKit
import ArchipelCore
import EditorUI
import Foundation
import Observation

/// An action offered next to the destinations in the palette.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// Display only. The real shortcut lives on the menu item.
    var shortcutHint: String? = nil
    /// Evaluated when the palette opens, so unavailable commands are left out instead of shown disabled.
    var isAvailable = true
    /// False for a command that puts the keyboard somewhere itself (Commit… focuses the message field,
    /// others open a sheet or another window), which the palette's usual hand-back to the focused tab
    /// would undo.
    var refocusesTab = true
    /// Words the command is also found by but does not show, such as the name it used to have.
    var alias: String? = nil
    let perform: @MainActor () -> Void

    /// What a query is matched against. The alias comes last, so the positions of a title match
    /// are positions in the title.
    var searchKey: String { alias.map { title + " " + $0 } ?? title }

    /// The palette shows these in this order when the query is empty. They do what the menu items of
    /// the same name do, through the same `AppActions`.
    static func standard(model: AppModel, actions: AppActions) -> [PaletteCommand] {
        let worktree = model.selectedWorktree
        let worktreeID = worktree?.id
        let hasSelection = worktreeID != nil
        let project = model.project(ofWorktree: worktreeID)
        let session = actions.focusedSession
        let publishes = model.pushPublishes(worktreeID)

        let newSessions = zip(model.agentsInMenuOrder, ["⌘T", "⌥⌘T", "⇧⌘T"]).map { agent, hint in
            PaletteCommand(
                id: "new-\(agent.id)",
                title: "New \(agent.displayName) Session",
                symbol: agent.symbolName,
                shortcutHint: hint,
                isAvailable: hasSelection && model.canStartSession(with: agent)
            ) {
                if let worktreeID { model.newSession(in: worktreeID, agent: agent) }
            }
        }

        // Flat entries rather than a submenu, so typing a preset's name finds the command.
        let presetSessions = model.presetsInMenuOrder.enumerated().map { index, entry in
            PaletteCommand(
                id: "new-preset-\(entry.preset.id.uuidString)",
                title: "New \(entry.agent.displayName) Session: \(entry.preset.title)",
                symbol: entry.agent.symbolName,
                shortcutHint: index < 9 ? "⌃⌘\(index + 1)" : nil,
                isAvailable: hasSelection && model.canStartSession(with: entry.agent)
            ) {
                if let worktreeID { model.newSession(in: worktreeID, agent: entry.agent, preset: entry.preset) }
            }
        }

        let stayAwake = model.stayAwake
        let stayAwakeModes = StayAwake.Mode.allCases.map { mode in
            PaletteCommand(
                id: "stay-awake-\(mode.rawValue)",
                title: "Stay Awake: \(mode.title)",
                symbol: mode == .off ? "cup.and.saucer" : "cup.and.heat.waves.fill",
                isAvailable: stayAwake.mode != mode
            ) { stayAwake.mode = mode }
        }

        return newSessions + [
            PaletteCommand(id: "add-project", title: "Add Project…", symbol: "folder.badge.plus", shortcutHint: "⇧⌘O", refocusesTab: false) { actions.addProject() },
            PaletteCommand(id: "new-island", title: "New Island…", symbol: "plus.square.on.square", refocusesTab: false) {
                if model.readyForSheet() { model.isCreatingIsland = true }
            },
            PaletteCommand(
                id: "toggle-inspector",
                title: actions.isInspectorShown ? "Hide Inspector" : "Show Inspector",
                symbol: "sidebar.trailing",
                shortcutHint: "⌥⌘0",
                // The title names what it will do now; people still look for it by what it is.
                alias: "Toggle Inspector"
            ) { actions.toggleInspector() },
            PaletteCommand(id: "show-files", title: "Show Files", symbol: "folder", shortcutHint: "⌥⌘1") { actions.revealInspector(.files) },
            PaletteCommand(id: "show-changes", title: "Show Changes", symbol: "plus.forwardslash.minus", shortcutHint: "⌥⌘2") {
                actions.revealInspector(.changes)
            },
            PaletteCommand(
                id: "toggle-sidebar",
                title: actions.isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar",
                symbol: "sidebar.leading",
                shortcutHint: "⌃⌘S"
            ) { actions.toggleSidebar() },
            PaletteCommand(
                id: "split-right",
                title: "Split Right",
                symbol: "rectangle.split.2x1",
                shortcutHint: "⌘\\",
                isAvailable: (worktree?.focusedPane?.tabs.count ?? 0) >= 2
            ) {
                if let tab = model.focusedTab { model.split(tab: tab.id) }
            },
            PaletteCommand(id: "close-tab", title: "Close Tab", symbol: "xmark", shortcutHint: "⌘W", isAvailable: model.focusedTab != nil) {
                if let tab = model.focusedTab { model.close(tab: tab.id) }
            },
            PaletteCommand(id: "reload-page", title: "Reload Page", symbol: "arrow.clockwise", isAvailable: actions.focusedWebTab != nil) {
                actions.reloadFocusedPage()
            },
            PaletteCommand(id: "save", title: "Save", symbol: "square.and.arrow.down", shortcutHint: "⌘S", isAvailable: actions.unsavedFocusedFile != nil) {
                // Not `actions.save()`: that asks the first responder first, which is the palette's
                // own text field while this runs.
                if let url = actions.unsavedFocusedFile { try? model.documents.save(url) }
            },
            PaletteCommand(
                id: "save-all",
                title: "Save All",
                symbol: "square.and.arrow.down.on.square",
                shortcutHint: "⌥⌘S",
                isAvailable: !model.documents.dirtyURLs.isEmpty
            ) { model.saveAllDocuments() },
            PaletteCommand(
                id: "rename-session",
                title: "Rename Session…",
                symbol: "pencil",
                isAvailable: session != nil,
                refocusesTab: false
            ) { actions.renameFocusedSession() },
            PaletteCommand(id: "restart-session", title: "Restart Session", symbol: "arrow.clockwise", isAvailable: session != nil) {
                actions.restartFocusedSession()
            },
            PaletteCommand(
                id: "restart-session-fresh",
                title: "Restart with a New Conversation",
                symbol: "plus.bubble",
                isAvailable: session?.agentSessionID != nil
            ) { actions.restartFocusedSession(fresh: true) },
            PaletteCommand(
                id: "next-attention",
                title: "Next Session Needing Attention",
                symbol: "bell.badge",
                shortcutHint: "⇧⌘U"
            ) { model.selectNextNeedingAttention() },
            PaletteCommand(
                id: "needs-me-filter",
                title: model.needsMeFilterTitle,
                symbol: model.needsMeFilterSymbol,
                shortcutHint: "⌥⌘U"
            ) { model.showsOnlyNeedsMe.toggle() },
            PaletteCommand(id: "mark-read", title: "Mark as Read", symbol: "envelope.open", isAvailable: actions.selectedWorktreeHasUnread) {
                actions.markSelectedWorktreeRead()
            },
            PaletteCommand(id: "run", title: "Run", symbol: "play", shortcutHint: "⌘R", isAvailable: hasSelection) {
                if let worktreeID { model.runProject(in: worktreeID) }
            },
            PaletteCommand(
                id: "run-setup",
                title: "Run Setup Script",
                symbol: "wrench.and.screwdriver",
                isAvailable: project?.scripts.setupCommand != nil
            ) {
                if let worktreeID { model.startScript(.setup, in: worktreeID) }
            },
            PaletteCommand(
                id: "commit",
                title: "Commit…",
                symbol: "checkmark.circle",
                shortcutHint: "⌥⌘C",
                isAvailable: actions.canCommit,
                refocusesTab: false
            ) { actions.startCommit() },
            PaletteCommand(id: "pull", title: "Pull", symbol: "arrow.down", isAvailable: model.canSync(.pull, worktreeID)) { actions.sync(.pull) },
            PaletteCommand(
                id: "push",
                title: publishes ? "Publish Branch" : "Push",
                symbol: publishes ? "icloud.and.arrow.up" : "arrow.up",
                isAvailable: model.canSync(.push, worktreeID)
            ) { actions.sync(.push) },
            PaletteCommand(id: "fetch", title: "Fetch", symbol: "arrow.triangle.2.circlepath", isAvailable: model.canSync(.fetch, worktreeID)) { actions.sync(.fetch) },
            PaletteCommand(
                id: "open-in-editor",
                title: model.preferredEditor.map { "Open in \($0.name)" } ?? "Open in Editor",
                symbol: "chevron.left.forwardslash.chevron.right",
                shortcutHint: "⇧⌘E",
                isAvailable: hasSelection && model.preferredEditor != nil
            ) {
                if let worktree { model.openInEditor(worktree.path) }
            },
            PaletteCommand(id: "show-in-finder", title: "Show in Finder", symbol: "folder", isAvailable: hasSelection) {
                if let worktree { model.revealInFinder(worktree.path) }
            },
            PaletteCommand(id: "open-in-terminal", title: "Open in Terminal", symbol: "apple.terminal", isAvailable: hasSelection) {
                if let worktree { model.openInTerminal(worktree.path) }
            },
            PaletteCommand(
                id: "copy-branch-name",
                title: "Copy Branch Name",
                symbol: "arrow.triangle.branch",
                isAvailable: worktree?.branch != nil
            ) {
                if let branch = worktree?.branch { model.copyToPasteboard(branch) }
            },
            PaletteCommand(
                id: "add-worktree",
                title: "Add Worktree…",
                symbol: "plus",
                shortcutHint: "⇧⌘N",
                isAvailable: actions.projectForNewWorktree != nil,
                refocusesTab: false
            ) { actions.addWorktree() },
            PaletteCommand(
                id: "switch-branch",
                title: "Switch Branch…",
                symbol: "arrow.triangle.swap",
                shortcutHint: "⇧⌘B",
                isAvailable: actions.worktreeForBranchSwitch != nil,
                refocusesTab: false
            ) { actions.switchBranch() },
            PaletteCommand(
                id: "remove-worktree",
                title: "Remove Worktree…",
                symbol: "minus.circle",
                isAvailable: actions.removableWorktree != nil,
                refocusesTab: false
            ) { actions.removeSelectedWorktree() },
            PaletteCommand(id: "project-settings", title: "Project Settings…", symbol: "gearshape", isAvailable: project != nil, refocusesTab: false) {
                if let project { model.openProjectSettings(project.id) }
            },
        ] + stayAwakeModes + [
            PaletteCommand(id: "settings", title: "Settings…", symbol: "gearshape", shortcutHint: "⌘,", refocusesTab: false) { actions.openSettings() },
            PaletteCommand(
                id: "check-for-updates",
                title: "Check for Updates…",
                symbol: "arrow.down.circle",
                isAvailable: Updater.isEnabled && actions.updater.canCheckForUpdates,
                refocusesTab: false
            ) { actions.updater.checkForUpdates() },
            PaletteCommand(id: "help", title: "Archipel Help", symbol: "questionmark.circle", refocusesTab: false) {
                NSWorkspace.shared.open(AppActions.helpURL)
            },
        ] + presetSessions
    }
}

/// One line in the palette, already matched and ready to draw.
struct PaletteRow: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let titleMatches: Set<Int>
    let subtitle: String?
    let subtitleMatches: Set<Int>
    let activity: SessionActivity?
    let shortcutHint: String?
    var refocusesTab = true
    let perform: @MainActor () -> Void
}

@Observable
final class CommandPaletteModel {
    enum Mode {
        case goTo
        case openFile
    }

    private(set) var isPresented = false
    private(set) var mode = Mode.goTo
    private(set) var query = ""
    private(set) var rows: [PaletteRow] = []
    private(set) var isLoadingFiles = false
    var selection = 0

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var commands: [PaletteCommand] = []
    @ObservationIgnored private var destinations: [WorkspaceDestinationEntry] = []
    @ObservationIgnored private var files: [String] = []
    @ObservationIgnored private var filesRoot: URL?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var rankTask: Task<Void, Never>?
    /// Bumped whenever results become stale, so a ranking that finishes late is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private weak var previousResponder: NSResponder?

    private static let destinationLimit = 200
    nonisolated private static let fileLimit = 60
    nonisolated private static let chunkSize = 5_000
    nonisolated private static let maxEnumeratedFiles = 20_000

    // MARK: Presenting

    func present(_ mode: Mode, app: AppModel, commands: [PaletteCommand]) {
        if isPresented {
            if self.mode == mode {
                dismiss()
                return
            }
        } else {
            previousResponder = NSApp.keyWindow?.firstResponder
        }
        self.app = app
        self.commands = commands.filter(\.isAvailable)
        destinations = app.workspace.destinationEntries()
        self.mode = mode
        query = ""
        selection = 0
        rows = []
        files = []
        filesRoot = nil
        loadTask?.cancel()
        isLoadingFiles = false
        isPresented = true
        if mode == .openFile { loadFiles(for: app) }
        refresh()
    }

    func dismiss(restoringFocus: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        loadTask?.cancel()
        rankTask?.cancel()
        generation += 1
        // Keep the rows until the next present. The panel is still fading out at this point and an
        // empty list would flash "No results".
        files = []
        destinations = []
        if restoringFocus { restoreFocus() }
    }

    func activate(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        // Dismiss first so the action sees a window without the palette's text field in it.
        dismiss(restoringFocus: false)
        row.perform()
        if row.refocusesTab { focusFocusedSession() }
    }

    func activateSelection() { activate(selection) }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + delta + rows.count) % rows.count
    }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        refresh()
    }

    // MARK: Focus

    /// The palette's text field takes first responder, so closing it without navigating has to hand the keyboard
    /// back, or a terminal that had it would stay deaf until clicked.
    private func restoreFocus() {
        let previous = previousResponder
        Task { @MainActor [weak self] in
            guard let self, let window = NSApp.keyWindow else { return }
            if let view = previous as? NSView, view.window === window {
                window.makeFirstResponder(view)
            } else {
                focusFocusedSession()
            }
        }
    }

    private func focusFocusedSession() {
        app?.focusFocusedTabSoon()
    }

    // MARK: Ranking

    private func refresh() {
        rankTask?.cancel()
        generation += 1
        let restrictsToCommands = query.hasPrefix(">")
        let text = restrictsToCommands ? String(query.dropFirst()) : query

        if restrictsToCommands {
            rows = commandRows(matching: text, limit: 50)
            selection = 0
        } else if mode == .goTo {
            rows = goToRows(matching: text)
            selection = 0
        } else {
            rankFiles(matching: text)
        }
    }

    private func commandRows(matching text: String, limit: Int) -> [PaletteRow] {
        FuzzyMatcher.rank(commands, query: text, limit: limit, key: \.searchKey).map { command, match in
            row(for: command, matches: match)
        }
    }

    private func goToRows(matching text: String) -> [PaletteRow] {
        guard let app else { return [] }
        let isEmpty = text.allSatisfy(\.isWhitespace)

        if isEmpty {
            var attention: [PaletteRow] = []
            var rest: [PaletteRow] = []
            for entry in destinations.prefix(Self.destinationLimit) {
                let row = row(for: entry, matches: nil, app: app)
                if case .session(let id) = entry.destination, app.activity(for: id).needsUser {
                    attention.append(row)
                } else {
                    rest.append(row)
                }
            }
            return attention + rest + commands.map { row(for: $0, matches: nil) }
        }

        // The subtitle rides along at the end of the key, so it matches too, but the title's start and boundary
        // bonuses make a title hit outrank a context-only hit.
        let ranked = FuzzyMatcher.rank(destinations, query: text, limit: Self.destinationLimit) { $0.title + " " + $0.subtitle }
        let rankedCommands = FuzzyMatcher.rank(commands, query: text, limit: 20, key: \.searchKey)

        var merged: [(score: Int, row: PaletteRow)] = []
        for (entry, match) in ranked { merged.append((match.score, row(for: entry, matches: match, app: app))) }
        for (command, match) in rankedCommands { merged.append((match.score, row(for: command, matches: match))) }
        // Swift's sort is not guaranteed stable, so equal scores fall back to the order they were appended in.
        let order = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($1.row.id, $0) })
        merged.sort { $0.score != $1.score ? $0.score > $1.score : order[$0.row.id]! < order[$1.row.id]! }
        return merged.map(\.row)
    }

    private func row(for command: PaletteCommand, matches match: FuzzyMatch?) -> PaletteRow {
        PaletteRow(
            id: "command:\(command.id)",
            symbol: command.symbol,
            title: command.title,
            // A hit in the alias has nothing in the title to highlight.
            titleMatches: Set((match?.positions ?? []).filter { $0 < command.title.count }),
            subtitle: nil,
            subtitleMatches: [],
            activity: nil,
            shortcutHint: command.shortcutHint,
            refocusesTab: command.refocusesTab,
            perform: command.perform
        )
    }

    private func row(for entry: WorkspaceDestinationEntry, matches match: FuzzyMatch?, app: AppModel) -> PaletteRow {
        let titleCount = entry.title.count
        let positions = match?.positions ?? []
        let titleMatches = Set(positions.filter { $0 < titleCount })
        // The key was "title subtitle", so subtitle offsets are shifted by the title and the joining space.
        let subtitleMatches = Set(positions.filter { $0 > titleCount }.map { $0 - titleCount - 1 })

        let id: String
        let symbol: String
        var activity: SessionActivity?
        let perform: @MainActor () -> Void
        switch entry.destination {
        case .island(let islandID):
            id = "island:\(islandID)"
            symbol = app.workspace.island(id: islandID)?.symbol ?? "square.stack.3d.up"
            perform = { app.select(island: islandID) }
        case .worktree(let worktreeID):
            id = "worktree:\(worktreeID)"
            symbol = "arrow.triangle.branch"
            activity = app.workspace.worktree(id: worktreeID).flatMap { app.activity(for: $0) }
            perform = { app.select(worktree: worktreeID) }
        case .session(let sessionID):
            id = "session:\(sessionID)"
            symbol = (app.effectiveAgent(for: sessionID)?.definition ?? .shell).symbolName
            activity = app.activity(for: sessionID)
            perform = { app.select(session: sessionID) }
        }
        return PaletteRow(
            id: id,
            symbol: symbol,
            title: entry.title,
            titleMatches: titleMatches,
            subtitle: entry.subtitle,
            subtitleMatches: subtitleMatches,
            activity: activity,
            shortcutHint: nil,
            perform: perform
        )
    }

    // MARK: Files

    private func loadFiles(for app: AppModel) {
        guard let root = app.selectedWorktree?.path else { return }
        filesRoot = root
        isLoadingFiles = true
        let git = app.git
        loadTask = Task { [weak self] in
            let listed: [String]
            do {
                // Without git even asking would bring up the system's install dialog.
                guard app.isGitAvailable else { throw CancellationError() }
                listed = try await git.listFiles(in: root)
            } catch {
                // Not a repository (or git failed): walk the folder instead.
                let walk = Task.detached(priority: .userInitiated) { Self.enumerateFiles(in: root, limit: Self.maxEnumeratedFiles) }
                listed = await withTaskCancellationHandler { await walk.value } onCancel: { walk.cancel() }
            }
            guard !Task.isCancelled, let self else { return }
            files = listed
            isLoadingFiles = false
            refresh()
        }
    }

    private func rankFiles(matching text: String) {
        guard let root = filesRoot, !files.isEmpty else {
            rows = []
            return
        }
        let paths = files
        let current = generation
        rankTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let hits = Self.rank(paths, query: text, limit: Self.fileLimit) else { return }
            await self?.applyFileHits(hits, root: root, generation: current)
        }
    }

    private func applyFileHits(_ hits: [FileHit], root: URL, generation hitGeneration: Int) {
        guard isPresented, hitGeneration == generation, let app else { return }
        rows = hits.map { hit in
            let url = root.appending(path: hit.path)
            let characters = Array(hit.path)
            let slash = characters.lastIndex(of: "/")
            let nameStart = slash.map { $0 + 1 } ?? 0
            let directory = slash.map { String(characters[..<$0]) }
            return PaletteRow(
                id: "file:\(hit.path)",
                symbol: "doc.text",
                title: String(characters[nameStart...]),
                titleMatches: Set(hit.positions.filter { $0 >= nameStart }.map { $0 - nameStart }),
                subtitle: directory,
                subtitleMatches: Set(hit.positions.filter { $0 < nameStart - 1 }),
                activity: nil,
                shortcutHint: nil,
                perform: { app.openFile(url, preview: false) }
            )
        }
        selection = 0
    }

    nonisolated struct FileHit: Sendable {
        let path: String
        let positions: [Int]
    }

    /// `FuzzyMatcher.rank` cannot be cancelled, so a long list is ranked in chunks and the top hits of each chunk
    /// are merged. Returns nil when the surrounding task was cancelled.
    nonisolated private static func rank(_ paths: [String], query: String, limit: Int) -> [FileHit]? {
        if query.allSatisfy(\.isWhitespace) {
            return paths.prefix(limit).map { FileHit(path: $0, positions: []) }
        }
        var candidates: [(score: Int, order: Int, hit: FileHit)] = []
        var start = 0
        var sequence = 0
        while start < paths.count {
            if Task.isCancelled { return nil }
            let end = min(start + chunkSize, paths.count)
            let chunk = Array(paths[start..<end])
            // Each chunk comes back best first and in input order for ties, so `sequence` keeps that order globally.
            for (path, match) in FuzzyMatcher.rank(chunk, query: query, limit: limit, key: { $0 }) {
                candidates.append((match.score, sequence, FileHit(path: path, positions: match.positions)))
                sequence += 1
            }
            start = end
        }
        if Task.isCancelled { return nil }
        candidates.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return candidates.prefix(limit).map(\.hit)
    }

    nonisolated private static let skippedDirectories: Set<String> = ["node_modules", ".build", "DerivedData"]

    /// Paths relative to `root`, skipping hidden directories and build output, capped so a huge tree stays cheap.
    nonisolated private static func enumerateFiles(in root: URL, limit: Int) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        let prefix = root.standardizedFileURL.path + "/"
        var result: [String] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled || result.count >= limit { break }
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: Set(keys)).isDirectory) == true
            if isDirectory {
                if name.hasPrefix(".") || skippedDirectories.contains(name) { enumerator.skipDescendants() }
                continue
            }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(prefix) { result.append(String(path.dropFirst(prefix.count))) }
        }
        return result.sorted()
    }
}
