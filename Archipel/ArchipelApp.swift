import AgentKit
import ArchipelCore
import InspectorUI
import SwiftUI

@main
struct ArchipelApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()
    @State private var palette = CommandPaletteModel()
    @State private var isAddingProject = false
    @AppStorage("showInspector") private var showInspector = true

    var body: some Scene {
        Window("Archipel", id: "main") {
            RootView(isAddingProject: $isAddingProject)
                .environment(model)
                .environment(palette)
                .frame(minWidth: 720, minHeight: 420)
                .onAppear {
                    delegate.model = model
                    applyAppearance()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                if let worktree = model.selectedWorktree {
                    let modifiers: [EventModifiers] = [.command, [.command, .option], [.command, .shift]]
                    ForEach(Array(zip(model.agentsInMenuOrder, modifiers)), id: \.0.id) { agent, modifiers in
                        newSessionButton(agent, in: worktree.id).keyboardShortcut("t", modifiers: modifiers)
                    }
                    Divider()
                }
                Button("Add Project…", systemImage: "folder.badge.plus") { isAddingProject = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button(model.focusedTab == nil ? "Close" : "Close Tab", systemImage: "xmark") { closeTabOrWindow() }
                    .keyboardShortcut("w")
            }
            CommandGroup(replacing: .saveItem) {
                // Sent up the responder chain so it reaches whichever editor has the keyboard focus.
                Button("Save", systemImage: "square.and.arrow.down") {
                    NSApp.sendAction(Selector(("saveDocument:")), to: nil, from: nil)
                }
                .keyboardShortcut("s")
                Button("Save All") {
                    do {
                        try model.documents.saveAll()
                    } catch {
                        model.problem = "Not every file could be saved. \(error.localizedDescription)"
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.documents.dirtyURLs.isEmpty)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Button("Show Files", systemImage: "folder") { revealInspector(.files) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Show Changes", systemImage: "plus.forwardslash.minus") { revealInspector(.changes) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Commit…", systemImage: "checkmark.circle") { startCommit() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(model.selectedWorktree == nil)
            }
            CommandMenu("Go") {
                Button("Go to…", systemImage: "arrow.right.circle") { present(.goTo) }
                    .keyboardShortcut("k")
                Button("Open Quickly…", systemImage: "doc.text.magnifyingglass") { present(.openFile) }
                    .keyboardShortcut("p")
            }
            CommandMenu("Project") {
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
                Button("Add Worktree…", systemImage: "plus") {
                    if let project { model.addWorktreeProjectID = project.id }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(project == nil)
                Button("Project Settings…", systemImage: "gearshape") {
                    if let project { model.openProjectSettings(project.id) }
                }
                .disabled(project == nil)
            }
            CommandMenu("Islands") {
                ForEach(Array(model.workspace.islands.prefix(9).enumerated()), id: \.element.id) { index, island in
                    Button(island.name, systemImage: island.symbol) { model.selectIsland(at: index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control)
                }
            }
            CommandMenu("Tab") {
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
                Divider()
                Button("Next Session Needing Attention", systemImage: "bell.badge") { model.selectNextNeedingAttention() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra(isInserted: Binding(get: { model.settings.showsMenuBarExtra }, set: { model.settings.showsMenuBarExtra = $0 })) {
            MenuBarExtraContent()
                .environment(model)
        } label: {
            MenuBarExtraLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView()
                .environment(model)
                // Here and not on the main window, which may be closed while Settings is open.
                .onChange(of: model.settings.appearance) { applyAppearance() }
                .onChange(of: model.settings.showsDockBadge) { model.refreshDockBadge() }
        }
    }
}

extension ArchipelApp {
    /// ⌘W belongs to whatever is in front: with Settings as the key window it must not end a
    /// session in the main window behind it.
    private func closeTabOrWindow() {
        let key = NSApp.keyWindow
        let isSettings = key?.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
        if !isSettings, let tab = model.focusedTab {
            model.close(tab: tab.id)
        } else {
            key?.performClose(nil)
        }
    }

    private func applyAppearance() {
        NSApp.appearance = switch model.settings.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func newSessionButton(_ agent: AgentDefinition, in worktree: Worktree.ID) -> some View {
        Button("New \(agent.displayName) Session", systemImage: agent.symbolName) {
            model.newSession(in: worktree, agent: agent)
        }
    }

    private func revealInspector(_ tab: InspectorView.Tab) {
        showInspector = true
        // Written straight to the defaults the inspector's AppStorage reads. An @AppStorage for this key on
        // the App itself made the App body depend on it, and the window locked up re-rendering on launch.
        UserDefaults.standard.set(tab.rawValue, forKey: InspectorView.selectedTabKey)
    }

    /// Commit… from the keyboard: the Changes tab with the cursor in the message field, so the rest
    /// (type, ⌘↩) needs no mouse either.
    private func startCommit() {
        guard model.selectedWorktree != nil else { return }
        revealInspector(.changes)
        model.focusCommitMessageRequest = true
        // A folder that is not a repository has no commit field to take the request, and a request
        // left standing would grab the cursor later, in some other worktree.
        Task {
            try? await Task.sleep(for: .seconds(1))
            model.focusCommitMessageRequest = false
        }
    }

    private func present(_ mode: CommandPaletteModel.Mode) {
        let commands = PaletteCommand.standard(
            model: model,
            addProject: { isAddingProject = true },
            toggleInspector: { showInspector.toggle() },
            startCommit: startCommit
        )
        palette.present(mode, app: model, commands: commands)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if !model.documents.dirtyURLs.isEmpty {
            let count = model.documents.dirtyURLs.count
            let alert = NSAlert()
            alert.messageText = count == 1 ? "You have a file with unsaved changes." : "You have \(count) files with unsaved changes."
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save All")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Changes")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    try model.documents.saveAll()
                } catch {
                    model.problem = "Not every file could be saved. \(error.localizedDescription)"
                    return .terminateCancel
                }
            case .alertSecondButtonReturn:
                return .terminateCancel
            default:
                break
            }
        }
        guard model.hasWorkingSessions, model.settings.confirmsQuitWhileWorking else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Archipel while agents are working?"
        alert.informativeText = "Running agents will be stopped. Their conversations are kept and resume the next time you open the session."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutDown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
