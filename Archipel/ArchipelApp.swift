import AgentKit
import ArchipelCore
import SwiftUI

@main
struct ArchipelApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()
    @State private var isAddingProject = false

    var body: some Scene {
        Window("Archipel", id: "main") {
            RootView(isAddingProject: $isAddingProject)
                .environment(model)
                .frame(minWidth: 720, minHeight: 420)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
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
                if let session = model.selectedSessionID {
                    Divider()
                    Button("Close Session", systemImage: "xmark") { model.removeSession(session) }
                        .keyboardShortcut("w")
                }
            }
            CommandMenu("Islands") {
                ForEach(Array(model.workspace.islands.prefix(9).enumerated()), id: \.element.id) { index, island in
                    Button(island.name, systemImage: island.symbol) { model.selectIsland(at: index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control)
                }
            }
            CommandMenu("Session") {
                Button("Next Session", systemImage: "chevron.right") { model.selectAdjacentSession(offset: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Session", systemImage: "chevron.left") { model.selectAdjacentSession(offset: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                Button("Next Session Needing Attention", systemImage: "bell.badge") { model.selectNextNeedingAttention() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasWorkingSessions else { return .terminateNow }
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
