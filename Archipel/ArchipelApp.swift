import AgentKit
import ArchipelCore
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
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                if let worktree = model.selectedWorktree {
                    Button("New Claude Code Session", systemImage: AgentDefinition.claude.symbolName) {
                        model.newSession(in: worktree.id, agent: .claude)
                    }
                    .keyboardShortcut("t")
                    Button("New Codex Session", systemImage: AgentDefinition.codex.symbolName) {
                        model.newSession(in: worktree.id, agent: .codex)
                    }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    Button("New Shell Session", systemImage: AgentDefinition.shell.symbolName) {
                        model.newSession(in: worktree.id, agent: .shell)
                    }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    Divider()
                }
                Button("Add Project…", systemImage: "folder.badge.plus") { isAddingProject = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                if let tab = model.focusedTab {
                    Divider()
                    Button("Close Tab", systemImage: "xmark") { model.close(tab: tab.id) }
                        .keyboardShortcut("w")
                }
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
    }
}

extension ArchipelApp {
    private func present(_ mode: CommandPaletteModel.Mode) {
        let commands = PaletteCommand.standard(
            model: model,
            addProject: { isAddingProject = true },
            toggleInspector: { showInspector.toggle() }
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
        guard model.hasWorkingSessions else { return .terminateNow }
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
