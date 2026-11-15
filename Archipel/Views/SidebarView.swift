import AgentKit
import ArchipelCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var isAddingProject: Bool
    let toggleSidebar: () -> Void
    @State private var renaming: RenameTarget?
    @State private var removing: Worktree?
    @State private var islandEditor: IslandEditor.Mode?
    @State private var swipe = IslandSwipeState()
    @State private var peek = SidebarPeekModel()

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
                            sessions: model.sessionRows(for: worktree),
                            isSelected: worktree.id == model.selectedWorktree?.id,
                            tint: tint,
                            removing: $removing,
                            renaming: $renaming
                        )
                        .tag(worktree.id)
                        .contextMenu { SidebarWorktreeMenu(worktree: worktree, removing: $removing) }
                        .sidebarPeek(peek, worktree: worktree.id)
                    }
                    let suggested = model.suggestedWorktrees(for: project)
                    if !suggested.isEmpty {
                        DetectedWorktreesRow(project: project, entries: suggested)
                    }
                } header: {
                    SidebarProjectHeader(project: project, renaming: $renaming)
                }
            }
        }
        .background(SidebarPeekKeyMonitor(peek: peek, model: model))
        .environment(peek)
        .onChange(of: model.selectedIsland?.id) { peek.close() }
        // Before the swipe content, so an empty island's placeholder moves with the list.
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
        .islandSwipeContent(swipe)
        // For the empty part of the list. Rows and project headers bring their own menus, which a
        // list-wide selection menu would replace on the headers.
        .contextMenu {
            Button("Add Project…", systemImage: "folder.badge.plus") { isAddingProject = true }
            Button("New Island…", systemImage: "plus.square.on.square") { islandEditor = .create }
            Divider()
            ProjectsDisclosureButton()
        }
        // Insets, not bars: as a bar the system draws a hairline across the sidebar next to the
        // header or the switcher whenever the pointer is over it.
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarHeader(isAddingProject: $isAddingProject, toggleSidebar: toggleSidebar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            IslandSwitcher()
        }
        .islandSwipe(swipe)
        .folderDropsAddProjects(to: model)
        .renameAlert($renaming)
        .sheet(item: $islandEditor) { mode in
            IslandEditor(mode: mode)
        }
        .sheet(item: $removing) { worktree in
            RemoveWorktreeSheet(worktree: worktree)
        }
    }

    private var selection: Binding<Worktree.ID?> {
        Binding(
            get: { model.selectedWorktree?.id },
            set: { model.select(worktree: $0) }
        )
    }

    private func expansion(of project: Project) -> Binding<Bool> {
        Binding(
            get: { project.isExpanded },
            set: { model.setProject(project.id, expanded: $0) }
        )
    }
}

/// Collapses every project of the island, or expands them all again once none is open.
private struct ProjectsDisclosureButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let collapses = model.hasExpandedProjects
        Button(
            collapses ? "Collapse All Projects" : "Expand All Projects",
            systemImage: collapses ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
        ) {
            withAnimation(reduceMotion ? nil : .snappy) { model.setAllProjects(expanded: !collapses) }
        }
        .help(collapses ? "Collapse All Projects" : "Expand All Projects")
        .disabled(model.selectedIsland?.projects.isEmpty ?? true)
    }
}

/// Sits in the strip next to the window buttons, where a toolbar would be, the way Xcode's navigator
/// and Finder's sidebar keep their controls up there.
private struct SidebarHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var isAddingProject: Bool
    let toggleSidebar: () -> Void

    /// Fixed slots, like toolbar items. Sized to their glyphs, the narrow collapse arrows and the
    /// wide badged folder end up with visibly uneven gaps.
    private static let slotWidth: CGFloat = 22

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
                .frame(width: Self.slotWidth)
                .transition(.scale.combined(with: .opacity))
            }
            ProjectsDisclosureButton()
                .labelStyle(.iconOnly)
                .frame(width: Self.slotWidth)
            Button("Add Project", systemImage: "folder.badge.plus") { isAddingProject = true }
                .help("Add a folder to this island (⇧⌘O)")
                // The badge shifts the drawn folder about 1.3pt right of and 0.3pt below the symbol's
                // center, which puts it close to the sidebar icon and below its neighbours.
                .offset(x: -1.5, y: -0.5)
                .frame(width: Self.slotWidth)
            Button("Hide Sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                .help("Hide Sidebar")
                .frame(width: Self.slotWidth)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        // Monochrome like the buttons over Xcode's navigator; the accent color stays with the content.
        .foregroundStyle(.secondary)
        .animation(.snappy, value: waiting > 0)
        // Leaves the window buttons their corner.
        .padding(.leading, 78)
        // Keeps the sidebar glyph 10pt from the edge; its slot is wider than the glyph.
        .padding(.trailing, 6.5)
        .frame(height: PaneTabBar.height)
    }
}

struct NewSessionButtons: View {
    @Environment(AppModel.self) private var model
    let worktree: Worktree.ID
    var pane: Pane.ID?

    var body: some View {
        ForEach(AgentDefinition.builtIns) { agent in
            Button("New \(agent.displayName) Session", symbol: agent.symbolName) {
                model.newSession(in: worktree, agent: agent, pane: pane)
            }
        }
    }
}
