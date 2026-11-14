import AgentKit
import ArchipelCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var isAddingProject: Bool
    let toggleSidebar: () -> Void
    @State private var renaming: RenameTarget?
    @State private var addingWorktreeTo: Project?
    @State private var deleting: Worktree?
    @State private var islandEditor: IslandEditor.Mode?

    var body: some View {
        let island = model.selectedIsland
        List(selection: selection) {
            ForEach(island?.projects ?? []) { project in
                Section(isExpanded: expansion(of: project)) {
                    let tint = model.tint(of: project).color
                    ForEach(project.worktrees) { worktree in
                        SidebarWorktreeRow(
                            worktree: worktree,
                            content: model.rowContent(for: worktree),
                            tint: tint,
                            deleting: $deleting
                        )
                        .tag(worktree.id)
                        let isSelected = worktree.id == model.selectedWorktree?.id
                        ForEach(model.sessionRows(for: worktree)) { session in
                            SidebarSessionRow(content: session, isInSelectedWorktree: isSelected, renaming: $renaming)
                        }
                    }
                } header: {
                    SidebarProjectHeader(project: project, renaming: $renaming, addingWorktreeTo: $addingWorktreeTo)
                }
            }
        }
        // Right-clicking a row passes its id; right-clicking empty space passes none.
        .contextMenu(forSelectionType: Worktree.ID.self) { ids in
            if let id = ids.first, let worktree = model.workspace.worktree(id: id) {
                SidebarWorktreeMenu(worktree: worktree, deleting: $deleting)
            } else {
                Button("Add Project…", systemImage: "folder.badge.plus") { isAddingProject = true }
                Button("New Island…", systemImage: "plus.square.on.square") { islandEditor = .create }
            }
        }
        .overlay {
            if let island, island.projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder")
                } description: {
                    Text("Add a folder to \(island.name) to start running agents in it.")
                } actions: {
                    Button("Add Project…") { isAddingProject = true }
                }
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            SidebarHeader(isAddingProject: $isAddingProject, toggleSidebar: toggleSidebar)
        }
        // An inset, not a bar: as a bar the system draws a hairline across the sidebar above the
        // switcher whenever the pointer is over it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            IslandSwitcher()
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .renameAlert($renaming)
        .sheet(item: $addingWorktreeTo) { project in
            WorktreeSheet(project: project)
        }
        .sheet(item: $islandEditor) { mode in
            IslandEditor(mode: mode)
        }
        .confirmationDialog(
            "Delete the worktree \(deleting?.displayName ?? "")?",
            isPresented: isDeleting,
            presenting: deleting
        ) { worktree in
            Button("Delete Worktree", role: .destructive) {
                model.removeWorktree(worktree.id, deleteFromDisk: true)
            }
        } message: { worktree in
            Text("The folder \(worktree.path.path) is removed and its sessions are closed. The branch is kept. Git refuses if the worktree has uncommitted changes.")
        }
    }

    private var selection: Binding<Worktree.ID?> {
        Binding(
            get: { model.selectedWorktree?.id },
            set: { model.select(worktree: $0) }
        )
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func expansion(of project: Project) -> Binding<Bool> {
        Binding(
            get: { project.isExpanded },
            set: { model.setProject(project.id, expanded: $0) }
        )
    }
}

/// Sits in the strip next to the window buttons, where a toolbar would be, the way Xcode's navigator
/// and Finder's sidebar keep their controls up there.
private struct SidebarHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var isAddingProject: Bool
    let toggleSidebar: () -> Void

    var body: some View {
        let waiting = attentionSummary(of: model.workspace, activities: model.activities).needsAttention
        HStack(spacing: 4) {
            // No title: the switcher at the bottom already names the island.
            Spacer(minLength: 0)
            if waiting > 0 {
                // Jumps anywhere, other islands included, so it counts the whole workspace.
                Button {
                    model.selectNextNeedingAttention()
                } label: {
                    Label("Next Session Waiting for You", systemImage: "bell.badge.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.orange, .secondary)
                        .symbolEffect(.bounce, options: .nonRepeating, value: waiting)
                }
                .help(waiting == 1 ? "1 session is waiting for you (⇧⌘U)" : "\(waiting) sessions are waiting for you (⇧⌘U)")
                .accessibilityValue("\(waiting) waiting")
                .transition(.scale.combined(with: .opacity))
            }
            Button("Add Project", systemImage: "folder.badge.plus") { isAddingProject = true }
                .help("Add a folder to this island (⇧⌘O)")
            Button("Hide Sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                .help("Hide Sidebar")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.large)
        .animation(.snappy, value: waiting > 0)
        // Leaves the window buttons their corner.
        .padding(.leading, 78)
        .padding(.trailing, 10)
        .frame(height: PaneTabBar.height)
    }
}

struct NewSessionButtons: View {
    @Environment(AppModel.self) private var model
    let worktree: Worktree.ID
    var pane: Pane.ID?

    var body: some View {
        ForEach(AgentDefinition.builtIns) { agent in
            Button("New \(agent.displayName) Session", systemImage: agent.symbolName) {
                model.newSession(in: worktree, agent: agent, pane: pane)
            }
        }
    }
}
