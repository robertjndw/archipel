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

    var body: some View {
        let island = model.selectedIsland
        List(selection: selection) {
            ForEach(island?.projects ?? []) { project in
                Section(isExpanded: expansion(of: project)) {
                    ForEach(project.worktrees) { worktree in
                        WorktreeRow(worktree: worktree, activity: model.activity(for: worktree))
                            .tag(worktree.id)
                            .contextMenu { worktreeMenu(worktree) }
                    }
                } header: {
                    ProjectHeader(project: project, renaming: $renaming, addingWorktreeTo: $addingWorktreeTo)
                }
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
        .safeAreaInset(edge: .top, spacing: 0) {
            header(island)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            IslandSwitcher()
        }
        .renameAlert($renaming)
        .sheet(item: $addingWorktreeTo) { project in
            WorktreeSheet(project: project)
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

    /// Sits in the strip next to the window buttons, where a toolbar would be.
    private func header(_ island: Island?) -> some View {
        HStack(spacing: 10) {
            Text(island?.name ?? "Archipel")
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Add Project", systemImage: "folder.badge.plus") { isAddingProject = true }
                .help("Add a folder to this island")
            Button("Hide Sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                .help("Hide Sidebar")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        // Leaves the window buttons their corner.
        .padding(.leading, 78)
        .padding(.trailing, 12)
        .frame(height: PaneTabBar.height)
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

    @ViewBuilder
    private func worktreeMenu(_ worktree: Worktree) -> some View {
        NewSessionButtons(worktree: worktree.id)
        Divider()
        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([worktree.path])
        }
        if !worktree.isMain {
            Divider()
            Button("Remove from Sidebar", systemImage: "minus.circle") {
                model.removeWorktree(worktree.id, deleteFromDisk: false)
            }
            Button("Delete Worktree…", systemImage: "trash", role: .destructive) { deleting = worktree }
        }
    }
}

private struct ProjectHeader: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Binding var renaming: RenameTarget?
    @Binding var addingWorktreeTo: Project?

    var body: some View {
        HStack {
            Text(project.name)
            Spacer()
            Button("Add Worktree", systemImage: "plus") { addingWorktreeTo = project }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Add a worktree to \(project.name)")
        }
        .contextMenu {
            Button("Add Worktree…", systemImage: "plus") { addingWorktreeTo = project }
            Divider()
            Button("Rename…", systemImage: "pencil") {
                renaming = RenameTarget(kind: .project(project.id), name: project.name)
            }
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
            }
            let others = model.workspace.islands.filter { $0.id != model.selectedIsland?.id }
            if !others.isEmpty {
                Menu("Move to Island", systemImage: "arrow.right.square") {
                    ForEach(others) { island in
                        Button(island.name, systemImage: island.symbol) {
                            model.moveProject(project.id, to: island.id)
                        }
                    }
                }
            }
            Divider()
            Button("Remove Project", systemImage: "trash", role: .destructive) { model.removeProject(project) }
        }
    }
}

private struct WorktreeRow: View {
    let worktree: Worktree
    let activity: SessionActivity?

    var body: some View {
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(worktree.displayName)
                        .fontWeight(activity?.unread == true ? .semibold : .regular)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            } icon: {
                Image(systemName: worktree.branch == nil ? "folder" : "arrow.triangle.branch")
            }
            Spacer(minLength: 0)
            if let activity {
                StatusGlyph(activity: activity)
            } else if !worktree.sessions.isEmpty {
                Text(worktree.sessions.count, format: .number)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("\(worktree.sessions.count) sessions")
            }
        }
    }

    /// What the agent last said while it wants the user; otherwise the folder,
    /// but only when the first line already shows the branch instead.
    private var detail: String? {
        if let activity, activity.needsUser, let message = activity.lastMessage, !message.isEmpty {
            return message
        }
        if worktree.isMain { return nil }
        return worktree.branch == nil ? nil : worktree.path.lastPathComponent
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
