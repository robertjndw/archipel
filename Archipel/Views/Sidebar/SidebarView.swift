import AgentKit
import ArchipelCore
import GitKit
import SwiftUI
import TipKit

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
        let needsMe = model.showsOnlyNeedsMe ? model.needsMeGroups() : []
        List(selection: selection) {
            if model.showsOnlyNeedsMe {
                ForEach(needsMe) { group in
                    Section {
                        ForEach(group.projects) { entry in
                            let tint = model.tint(of: entry.project).color
                            SidebarProjectHeader(project: entry.project, renaming: $renaming)
                                .selectionDisabled()
                                .listRowSeparator(.hidden)
                            ForEach(entry.worktrees) { worktree in
                                worktreeRow(worktree, tint: tint)
                            }
                        }
                    } header: {
                        NeedsMeIslandHeader(island: group.island)
                    }
                }
            }
            // Empty while filtered, when the groups above stand in for the island.
            ForEach(model.showsOnlyNeedsMe ? [] : island?.projects ?? []) { project in
                Section(isExpanded: expansion(of: project)) {
                    let tint = model.tint(of: project).color
                    ForEach(project.worktrees) { worktree in
                        worktreeRow(worktree, tint: tint)
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
        .accessibilityIdentifier("sidebar")
        .environment(\.sidebarDensity, model.settings.sidebarDensity)
        .animation(.snappy, value: model.settings.sidebarDensity)
        .background { SidebarPeekKeyMonitor(peek: peek, model: model) }
        .environment(peek)
        .onChange(of: model.selectedIsland?.id) { peek.close() }
        .popoverTip(SidebarTips.group.currentTip as? PeekTip, arrowEdge: .trailing)
        .tipViewStyle(CompactTipStyle())
        .onChange(of: model.workspace.islands.count, initial: true) { SidebarTips.islandCount = model.workspace.islands.count }
        .onChange(of: model.workspace.islands.reduce(0) { $0 + $1.projects.reduce(0) { $0 + $1.worktrees.count } }, initial: true) { _, count in
            SidebarTips.worktreeCount = count
        }
        // Before the swipe content, so an empty island's placeholder moves with the list.
        .overlay {
            if model.showsOnlyNeedsMe {
                if needsMe.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing Needs You", systemImage: "bell.slash")
                    } description: {
                        Text("Sessions that wait for an answer or have a result you have not read show up here, from every island.")
                    }
                    .accessibilityIdentifier("sidebar.needsMe.empty")
                }
            } else if let island, island.projects.isEmpty {
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
            // Hidden rather than disabled: while the list spans every island there is no current one to move from.
            if !model.showsOnlyNeedsMe {
                IslandSwitcher()
                    .popoverTip(SidebarTips.group.currentTip as? IslandSwipeTip, arrowEdge: .top)
                    .tipViewStyle(CompactTipStyle())
            }
        }
        .islandSwipe(swipe, isEnabled: !model.showsOnlyNeedsMe)
        .folderDropsAddProjects(to: model)
        .renameAlert($renaming)
        .sheet(item: $islandEditor) { mode in
            IslandEditor(mode: mode)
        }
        .sheet(item: $removing) { worktree in
            RemoveWorktreeSheet(worktree: worktree)
        }
    }

    private func worktreeRow(_ worktree: Worktree, tint: Color) -> some View {
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

/// Names the island a group of the "Needs Me" list belongs to, in its symbol and color.
private struct NeedsMeIslandHeader: View {
    let island: Island

    var body: some View {
        Label(island.name, systemImage: island.symbol)
            .foregroundStyle(island.tint.color)
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("sidebar.needsMe.island")
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
            withAnimation(reduceMotion ? nil : Motion.disclosure) { model.setAllProjects(expanded: !collapses) }
        }
        .contentTransition(.symbolEffect(.replace))
        // Its own animation, since the state also flips when a single project is opened by hand.
        .animation(reduceMotion ? nil : Motion.disclosure, value: collapses)
        .help(collapses ? "Collapse All Projects" : "Expand All Projects")
        .disabled(model.selectedIsland?.projects.isEmpty ?? true)
    }
}

/// Sits in the strip next to the window buttons, where a toolbar would be, the way Xcode's navigator
/// and Finder's sidebar keep their controls up there.
private struct SidebarHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.showsWindowButtons) private var showsWindowButtons
    @Binding var isAddingProject: Bool
    let toggleSidebar: () -> Void

    /// Fixed slots, like toolbar items. Sized to their glyphs, the narrow collapse arrows and the
    /// wide badged folder end up with visibly uneven gaps.
    private static let slotWidth: CGFloat = 22

    var body: some View {
        let waiting = model.workspaceAttention.needsAttention
        HStack(spacing: 4) {
            // No title: the switcher at the bottom already names the island.
            Spacer(minLength: 0)
            Button {
                model.showsOnlyNeedsMe.toggle()
            } label: {
                Label("Show Only What Needs Me", systemImage: model.showsOnlyNeedsMe ? "bell.fill" : "bell")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(model.showsOnlyNeedsMe ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .help(model.showsOnlyNeedsMe ? "Show everything again (⌥⌘U)" : "Show only the worktrees that need you, from every island (⌥⌘U)")
            .popoverTip(SidebarTips.group.currentTip as? NeedsMeTip, arrowEdge: .bottom)
            .tipViewStyle(CompactTipStyle())
            .accessibilityIdentifier("sidebar.needsMe")
            .accessibilityValue(model.showsOnlyNeedsMe ? "On" : "Off")
            .frame(width: Self.slotWidth)
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
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
            ProjectsDisclosureButton()
                .labelStyle(.iconOnly)
                .frame(width: Self.slotWidth)
                // Its target is the selected island, which the filtered list does not show.
                .disabled(model.showsOnlyNeedsMe)
            Button("Add Project", systemImage: "folder.badge.plus") { isAddingProject = true }
                .help("Add a folder to this island (⇧⌘O)")
                // The badge shifts the drawn folder about 1.3pt right of and 0.3pt below the symbol's
                // center, which puts it close to the sidebar icon and below its neighbours.
                .offset(x: -1.5, y: -0.5)
                .disabled(model.showsOnlyNeedsMe)
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
        .padding(.leading, showsWindowButtons ? WindowButtons.trailingEdge(for: model.settings.paneStyle) : 0)
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
            let canStart = model.canStartSession(with: agent)
            Button("New \(agent.displayName) Session", symbol: agent.symbolName) {
                model.newSession(in: worktree, agent: agent, pane: pane)
            }
            .disabled(!canStart)
            .help(canStart ? "" : agent.missingCommandHint)
        }
    }
}

extension AgentDefinition {
    /// The tooltip on a start button that is disabled because the agent's executable is missing.
    var missingCommandHint: String {
        "The \"\(executableName)\" command was not found on your PATH"
    }
}

#if DEBUG
private struct SidebarPreview: View {
    @State var model: AppModel
    @State private var isAddingProject = false

    var body: some View {
        SidebarView(isAddingProject: $isAddingProject, toggleSidebar: {})
            .listStyle(.sidebar)
            .environment(model)
            .frame(width: 260, height: 640)
    }
}

#Preview("Populated") {
    SidebarPreview(model: .preview())
}

#Preview("Compact") {
    let model = AppModel.preview()
    model.settings.sidebarDensity = .compact
    return SidebarPreview(model: model)
}

#Preview("Spacious") {
    let model = AppModel.preview()
    model.settings.sidebarDensity = .spacious
    return SidebarPreview(model: model)
}

#Preview("Empty") {
    SidebarPreview(model: .emptyPreview())
}

#Preview("Collapsed projects") {
    var workspace = PreviewFixtures.workspace
    workspace.updateProject(id: PreviewFixtures.appProjectID) { $0.isExpanded = false }
    let model = AppModel(preview: workspace, activities: PreviewFixtures.activities)
    return SidebarPreview(model: model)
}

#Preview("Detected and missing worktrees") {
    let model = AppModel.preview()
    let worktrees = PreviewFixtures.root.appending(path: "orbit-worktrees", directoryHint: .isDirectory)
    model.gitWorktrees[PreviewFixtures.appProjectID] = [
        GitWorktreeEntry(path: worktrees.appending(path: "spike-graphql", directoryHint: .isDirectory), branch: "spike/graphql", isMain: false),
        GitWorktreeEntry(path: worktrees.appending(path: "detached", directoryHint: .isDirectory), branch: nil, isMain: false),
    ]
    model.missingWorktrees = [PreviewFixtures.fixWorktreeID]
    return SidebarPreview(model: model)
}

#Preview("Dark") {
    SidebarPreview(model: .preview())
        .preferredColorScheme(.dark)
}
#endif
