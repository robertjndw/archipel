import AgentKit
import ArchipelCore
import InspectorUI
import SwiftUI

/// The menu bar. Every menu's items are a view of their own that reads the model in its own body:
/// read in the App's scene body instead, any change to the model would rebuild every menu.
struct AppCommands: Commands {
    let model: AppModel
    let palette: CommandPaletteModel
    let switcher: TabSwitcherModel
    let updater: Updater
    @Binding var isAddingProject: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        // Handed over here because the menu bar is the one thing that is built at launch and stays
        // for as long as the app runs. A view of the main window could not do it: the app keeps
        // running after that window is closed, and may be launched without it.
        let _ = model.openMainWindow = { [openWindow] in openWindow(id: AppModel.mainWindowID) }
        let actions = AppActions(
            model: model,
            palette: palette,
            switcher: switcher,
            updater: updater,
            isAddingProject: $isAddingProject,
            openSettings: { [openSettings] in openSettings() }
        )
        SidebarCommands()
        CommandGroup(after: .appInfo) { UpdateMenuItem(updater: updater) }
        CommandGroup(replacing: .newItem) { FileMenuItems(model: model, actions: actions) }
        CommandGroup(replacing: .saveItem) { SaveMenuItems(model: model, actions: actions) }
        CommandGroup(after: .sidebar) { InspectorMenuItems(actions: actions) }
        CommandMenu("Go") { GoMenuItems(model: model, actions: actions) }
        CommandMenu("Project") { ProjectMenuItems(model: model, actions: actions) }
        CommandMenu("Islands") { IslandMenuItems(model: model) }
        CommandMenu("Tab") { TabMenuItems(model: model, actions: actions) }
        // The default item only leads to the system's "help isn't available" message.
        CommandGroup(replacing: .help) {
            Button("Archipel Help", systemImage: "questionmark.circle") { NSWorkspace.shared.open(AppActions.helpURL) }
        }
    }
}

/// What both the menu bar and the command palette do, so the two cannot drift apart.
struct AppActions {
    let model: AppModel
    let palette: CommandPaletteModel
    let switcher: TabSwitcherModel
    let updater: Updater
    let isAddingProject: Binding<Bool>
    let openSettings: () -> Void

    static let helpURL = URL(string: "https://github.com/robertjndw/archipel#readme")!

    func addProject() {
        isAddingProject.wrappedValue = true
    }

    // MARK: Palette

    func present(_ mode: CommandPaletteModel.Mode) {
        // The palette is drawn over the main window. With that closed, or behind Settings, it
        // would come up where nobody sees it and take the keyboard along.
        let key = NSApp.keyWindow
        if !AppModel.isMainWindow(key), !AppModel.isMainWindow(key?.sheetParent) { model.showMainWindow() }
        palette.present(mode, app: model, commands: PaletteCommand.standard(model: model, actions: self))
    }

    // MARK: Tabs and files

    /// ⌘W belongs to whatever is in front. Tabs live in the main window, so only with that as the
    /// key window does it close one; with Settings, the menu bar panel or a sheet in front it must
    /// not end a session in the window behind.
    func closeTabOrWindow() {
        let key = NSApp.keyWindow
        if AppModel.isMainWindow(key), key?.attachedSheet == nil, let tab = model.focusedTab {
            model.close(tab: tab.id)
        } else {
            key?.performClose(nil)
        }
    }

    /// The file in the focused tab, when it has edits to save.
    var unsavedFocusedFile: URL? {
        guard case .file(let url)? = model.focusedTab?.content, model.documents.isDirty(url) else { return nil }
        return url
    }

    func save() {
        // NSDocument.save(_:) is the standard saveDocument: selector. Sent up the responder chain
        // first, where the editor's text view answers it when it has the keyboard focus.
        if NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) { return }
        // Nobody took it: the focus is in the sidebar or the inspector, say. The focused tab's file
        // is still what Save means. A failure shows in the editor, which reads the buffer's error.
        if let url = unsavedFocusedFile { try? model.documents.save(url) }
    }

    var focusedSession: Session? {
        model.focusedSessionID.flatMap { model.workspace.session(id: $0) }
    }

    func renameFocusedSession() {
        guard let session = focusedSession, model.readyForSheet() else { return }
        model.renameRequest = RenameTarget(kind: .session(session.id), name: session.displayTitle)
    }

    func restartFocusedSession(fresh: Bool = false) {
        if let id = model.focusedSessionID { model.restartSession(id, fresh: fresh) }
    }

    var focusedWebTab: ArchipelCore.Tab? {
        guard let tab = model.focusedTab, case .web = tab.content else { return nil }
        return tab
    }

    func reloadFocusedPage() {
        guard let tab = focusedWebTab else { return }
        _ = model.webPages.page(for: tab.id)?.reload()
    }

    // MARK: Worktrees

    /// The primary checkout is the project itself and cannot be removed.
    var removableWorktree: Worktree? {
        guard let worktree = model.selectedWorktree, !worktree.isMain else { return nil }
        return worktree
    }

    func removeSelectedWorktree() {
        if let worktree = removableWorktree, model.readyForSheet() { model.worktreeAwaitingRemoval = worktree }
    }

    var selectedWorktreeHasUnread: Bool {
        guard let worktree = model.selectedWorktree else { return false }
        return worktree.sessions.contains { model.activities[$0.id]?.unread == true }
    }

    func markSelectedWorktreeRead() {
        if let worktree = model.selectedWorktree { model.markRead(worktree: worktree.id) }
    }

    /// The project the Add Worktree sheet would open for. Nil without git, which the sheet needs
    /// for everything it shows.
    var projectForNewWorktree: Project? {
        model.isGitAvailable ? model.project(ofWorktree: model.selectedWorktree?.id) : nil
    }

    func addWorktree() {
        if let project = projectForNewWorktree, model.readyForSheet() { model.addWorktreeProjectID = project.id }
    }

    var worktreeForBranchSwitch: Worktree? {
        guard model.isGitAvailable, let worktree = model.selectedWorktree, !model.missingWorktrees.contains(worktree.id) else { return nil }
        return worktree
    }

    func switchBranch() {
        if let worktree = worktreeForBranchSwitch, model.readyForSheet() { model.switchBranchWorktreeID = worktree.id }
    }

    func sync(_ action: SyncAction) {
        if let worktree = model.selectedWorktree { model.sync(action, worktree: worktree.id) }
    }

    // MARK: Inspector and sidebar

    var isInspectorShown: Bool {
        UserDefaults.standard.object(forKey: LayoutDefaults.showsInspector) as? Bool ?? true
    }

    func toggleInspector() {
        UserDefaults.standard.set(!isInspectorShown, forKey: LayoutDefaults.showsInspector)
    }

    func revealInspector(_ tab: InspectorView.Tab) {
        // Both written straight to the defaults the window's and the inspector's AppStorage read. An
        // @AppStorage for the tab on the App itself made the App body depend on it, and the window
        // locked up re-rendering on launch.
        UserDefaults.standard.set(true, forKey: LayoutDefaults.showsInspector)
        UserDefaults.standard.set(tab.rawValue, forKey: InspectorView.selectedTabKey)
    }

    var isSidebarCollapsed: Bool {
        UserDefaults.standard.bool(forKey: LayoutDefaults.collapsesSidebar)
    }

    func toggleSidebar() {
        UserDefaults.standard.set(!isSidebarCollapsed, forKey: LayoutDefaults.collapsesSidebar)
    }

    var canCommit: Bool {
        model.isGitAvailable && model.selectedWorktree != nil
    }

    /// Commit… from the keyboard: the Changes tab with the cursor in the message field, so the rest
    /// (type, ⌘↩) needs no mouse either.
    func startCommit() {
        guard canCommit else { return }
        revealInspector(.changes)
        model.focusCommitMessageRequest = true
        // A folder that is not a repository has no commit field to take the request, and a request
        // left standing would grab the cursor later, in some other worktree.
        Task { [model] in
            try? await Task.sleep(for: .seconds(1))
            model.focusCommitMessageRequest = false
        }
    }
}

// MARK: - Menus

private struct UpdateMenuItem: View {
    let updater: Updater

    var body: some View {
        Button("Check for Updates…", systemImage: "arrow.down.circle") { updater.checkForUpdates() }
            .disabled(!Updater.isEnabled || !updater.canCheckForUpdates)
    }
}

private struct FileMenuItems: View {
    let model: AppModel
    let actions: AppActions

    private static let newSessionModifiers: [EventModifiers] = [.command, [.command, .option], [.command, .shift]]

    var body: some View {
        let worktree = model.selectedWorktree
        ForEach(Array(zip(model.agentsInMenuOrder, Self.newSessionModifiers)), id: \.0.id) { agent, modifiers in
            Button("New \(agent.displayName) Session", symbol: agent.symbolName) {
                if let worktree { model.newSession(in: worktree.id, agent: agent) }
            }
            .keyboardShortcut("t", modifiers: modifiers)
            .disabled(worktree == nil || !model.canStartSession(with: agent))
        }
        ForEach(model.agentsInMenuOrder) { agent in
            NewSessionWithMenu(model: model, agent: agent, worktree: worktree?.id)
        }
        Divider()
        Button("Add Project…", systemImage: "folder.badge.plus") { actions.addProject() }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        Divider()
        Button(model.focusedTab == nil ? "Close" : "Close Tab", systemImage: "xmark") { actions.closeTabOrWindow() }
            .keyboardShortcut("w")
    }
}

private struct SaveMenuItems: View {
    let model: AppModel
    let actions: AppActions

    var body: some View {
        Button("Save", systemImage: "square.and.arrow.down") { actions.save() }
            .keyboardShortcut("s")
            .disabled(actions.unsavedFocusedFile == nil)
        Button("Save All", systemImage: "square.and.arrow.down.on.square") { model.saveAllDocuments() }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(model.documents.dirtyURLs.isEmpty)
    }
}

private struct InspectorMenuItems: View {
    let actions: AppActions
    @AppStorage(LayoutDefaults.showsInspector) private var showInspector = true

    var body: some View {
        Button(showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
            .keyboardShortcut("0", modifiers: [.command, .option])
        Button("Show Files", systemImage: "folder") { actions.revealInspector(.files) }
            .keyboardShortcut("1", modifiers: [.command, .option])
        Button("Show Changes", systemImage: "plus.forwardslash.minus") { actions.revealInspector(.changes) }
            .keyboardShortcut("2", modifiers: [.command, .option])
    }
}

private struct GoMenuItems: View {
    let model: AppModel
    let actions: AppActions

    var body: some View {
        Button("Go to…", systemImage: "arrow.right.circle") { actions.present(.goTo) }
            .keyboardShortcut("k")
        Button("Open Quickly…", systemImage: "doc.text.magnifyingglass") { actions.present(.openFile) }
            .keyboardShortcut("p")
            .disabled(model.selectedWorktree == nil)
        Divider()
        // The shortcut is shown for discoverability only; the key monitor takes Ctrl-Tab
        // first so it can keep the panel up while Control is held.
        Button("Switch to Recent Tab", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
            actions.switcher.press(offset: 1, app: model)
            actions.switcher.commit()
        }
        .keyboardShortcut(.tab, modifiers: .control)
    }
}

private struct ProjectMenuItems: View {
    let model: AppModel
    let actions: AppActions

    var body: some View {
        let worktree = model.selectedWorktree
        let project = model.project(ofWorktree: worktree?.id)
        Button("Run", systemImage: "play") {
            if let worktree { model.runProject(in: worktree.id) }
        }
        .keyboardShortcut("r")
        .disabled(worktree == nil)
        Button("Run Setup Script", systemImage: "wrench.and.screwdriver") {
            if let worktree { model.startScript(.setup, in: worktree.id) }
        }
        .disabled(project?.scripts.setupCommand == nil)
        Divider()
        Button(model.preferredEditor.map { "Open in \($0.name)" } ?? "Open in Editor", systemImage: "chevron.left.forwardslash.chevron.right") {
            if let worktree { model.openInEditor(worktree.path) }
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(worktree == nil || model.preferredEditor == nil)
        Divider()
        Button("Add Worktree…", systemImage: "plus") { actions.addWorktree() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(actions.projectForNewWorktree == nil)
        Button("Switch Branch…", systemImage: "arrow.triangle.swap") { actions.switchBranch() }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(actions.worktreeForBranchSwitch == nil)
        Button("Remove Worktree…", systemImage: "minus.circle") { actions.removeSelectedWorktree() }
            .disabled(actions.removableWorktree == nil)
        Divider()
        Button("Commit…", systemImage: "checkmark.circle") { actions.startCommit() }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!actions.canCommit)
        SyncMenuItems(model: model, actions: actions)
        Divider()
        Button("Mark as Read", systemImage: "envelope.open") { actions.markSelectedWorktreeRead() }
            .disabled(!actions.selectedWorktreeHasUnread)
        Button("Project Settings…", systemImage: "gearshape") {
            if let project { model.openProjectSettings(project.id) }
        }
        .disabled(project == nil)
    }
}

private struct SyncMenuItems: View {
    let model: AppModel
    let actions: AppActions

    var body: some View {
        let id = model.selectedWorktree?.id
        let publishes = model.pushPublishes(id)
        Button("Pull", systemImage: "arrow.down") { actions.sync(.pull) }
            .disabled(!model.canSync(.pull, id))
        Button(publishes ? "Publish Branch" : "Push", systemImage: publishes ? "icloud.and.arrow.up" : "arrow.up") { actions.sync(.push) }
            .disabled(!model.canSync(.push, id))
        Button("Fetch", systemImage: "arrow.triangle.2.circlepath") { actions.sync(.fetch) }
            .disabled(!model.canSync(.fetch, id))
    }
}

private struct IslandMenuItems: View {
    let model: AppModel

    var body: some View {
        let islands = model.workspace.islands
        Button("New Island…", systemImage: "plus.square.on.square") {
            if model.readyForSheet() { model.isCreatingIsland = true }
        }
        Divider()
        Button("Next Island", systemImage: "chevron.right") { model.selectAdjacentIsland(offset: 1) }
            .keyboardShortcut("]", modifiers: [.command, .control])
            .disabled(islands.count < 2)
        Button("Previous Island", systemImage: "chevron.left") { model.selectAdjacentIsland(offset: -1) }
            .keyboardShortcut("[", modifiers: [.command, .control])
            .disabled(islands.count < 2)
        Divider()
        ForEach(Array(islands.prefix(9).enumerated()), id: \.element.id) { index, island in
            Button(island.name, systemImage: island.symbol) { model.selectIsland(at: index) }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control)
        }
    }
}

private struct TabMenuItems: View {
    let model: AppModel
    let actions: AppActions

    var body: some View {
        let session = actions.focusedSession
        Button("Next Tab", systemImage: "chevron.right") { model.selectAdjacentTab(offset: 1) }
            .keyboardShortcut("]", modifiers: [.command, .shift])
        Button("Previous Tab", systemImage: "chevron.left") { model.selectAdjacentTab(offset: -1) }
            .keyboardShortcut("[", modifiers: [.command, .shift])
        Divider()
        Button("Split Right", systemImage: "rectangle.split.2x1") {
            if let tab = model.focusedTab { model.split(tab: tab.id) }
        }
        .keyboardShortcut("\\")
        .disabled((model.selectedWorktree?.focusedPane?.tabs.count ?? 0) < 2)
        Button("Reload Page", systemImage: "arrow.clockwise") { actions.reloadFocusedPage() }
            .disabled(actions.focusedWebTab == nil)
        Divider()
        Section("Session") {
            Button("Rename Session…", systemImage: "pencil") { actions.renameFocusedSession() }
                .disabled(session == nil)
            Button("Restart Session", systemImage: "arrow.clockwise") { actions.restartFocusedSession() }
                .disabled(session == nil)
            // Without a conversation there is nothing a plain restart would resume.
            Button("Restart with a New Conversation", systemImage: "plus.bubble") { actions.restartFocusedSession(fresh: true) }
                .disabled(session?.agentSessionID == nil)
        }
        Divider()
        Button("Next Session Needing Attention", systemImage: "bell.badge") { model.selectNextNeedingAttention() }
            .keyboardShortcut("u", modifiers: [.command, .shift])
        Button(model.needsMeFilterTitle, systemImage: model.needsMeFilterSymbol) { model.showsOnlyNeedsMe.toggle() }
            .keyboardShortcut("u", modifiers: [.command, .option])
    }
}
