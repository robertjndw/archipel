import ArchipelCore
import InspectorUI
import SwiftUI
import UniformTypeIdentifiers

/// Where the window's layout is kept in the defaults. The menu bar and the palette change it by
/// writing these keys, since they have no way to reach the window's own state.
enum LayoutDefaults {
    static let showsInspector = "showInspector"
    static let collapsesSidebar = "sidebarCollapsed"
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(CommandPaletteModel.self) private var palette
    @Environment(TabSwitcherModel.self) private var switcher
    @Binding var isAddingProject: Bool
    @AppStorage(LayoutDefaults.showsInspector) private var showInspector = true
    @AppStorage(LayoutDefaults.collapsesSidebar) private var isSidebarCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var window = WindowMetrics()

    var body: some View {
        @Bindable var model = model
        layout
        .windowButtons(center: WindowButtons.center(for: model.settings.paneStyle), metrics: $window)
        .environment(\.showsWindowButtons, !window.isFullScreen)
        .environment(\.windowCornerRadius, window.cornerRadius)
        .overlay { CommandPalette() }
        .overlay { TabSwitcher() }
        .background {
            TabSwitcherKeyMonitor(switcher: switcher, model: model, isBlocked: { [palette] in palette.isPresented })
        }
        .toolbar(removing: .title)
        .navigationTitle(windowTitle)
        .fileImporter(isPresented: $isAddingProject, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.addProjects(folders: urls)
            }
        }
        .confirmationDialog(
            "Do you want to save the changes you made to \(closingFileName)?",
            item: $model.tabAwaitingCloseDecision
        ) { tab in
            Button("Save") { model.resolveClose(of: tab, saving: true) }
            Button("Don't Save", role: .destructive) { model.resolveClose(of: tab, saving: false) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your changes will be lost if you don't save them.")
        }
        .confirmationDialog(
            model.sessionAwaitingInterruptDecision?.title ?? "",
            item: $model.sessionAwaitingInterruptDecision
        ) { interruption in
            Button(interruption.confirmLabel, role: .destructive) { model.resolve(interruption) }
            Button("Cancel", role: .cancel) {}
        } message: { interruption in
            Text(interruption.message)
        }
        .sheet(item: projectInSettings) { project in
            ProjectSettingsSheet(project: project)
        }
        .sheet(item: projectAddingWorktree) { project in
            WorktreeSheet(project: project)
        }
        .sheet(item: worktreeSwitchingBranch) { worktree in
            SwitchBranchSheet(worktree: worktree)
        }
        // These three are what the menu bar and the palette ask for. The sidebar and the tab bar
        // present the same from their own context menus.
        .sheet(item: $model.worktreeAwaitingRemoval) { worktree in
            RemoveWorktreeSheet(worktree: worktree)
        }
        .sheet(isPresented: $model.isCreatingIsland) {
            IslandEditor(mode: .create)
        }
        .renameAlert($model.renameRequest)
        .customModelAlert($model.customModelRequest)
        .alert("Archipel ran into a problem", item: $model.problem) { _ in
            Button("OK") {}
        } message: { problem in
            Text(problem)
        }
        // Below everything presented above: a sheet takes its tint from the view it is attached to,
        // and attached outside this it would show the system accent instead of the island's color.
        .tint(model.selectedIsland?.tint.color)
    }

    /// The sidebar and the content with the inspector next to them.
    ///
    /// Before macOS 27.2 the inspector is a plain pane of a fixed width. A system inspector beside
    /// a NavigationSplitView sends AppKit into an endless round of constraint updates there, and
    /// the app goes down with "more Update Constraints in Window passes than there are views in the
    /// window" once a worktree is on screen. 27.0.1 does it and 27.2.1 does not; 27.1 was never
    /// tried, so it gets the pane too.
    @ViewBuilder
    private var layout: some View {
        if #available(macOS 27.2, *) {
            columns
                .inspector(isPresented: $showInspector) {
                    inspector
                        .modifier(TopLineInset())
                        .inspectorColumnWidth(min: 220, ideal: RootView.inspectorWidth, max: 420)
                        .ignoresSafeArea(.container, edges: .top)
                        // The inspector already paints the window surface; its divider would be the
                        // only line between it and the content. Dragging still resizes the column.
                        .hidesSplitDivider(true)
                }
        } else {
            // No divider before the inspector: it sits on the same surface as the content, and the
            // gap around the pane cards already sets them apart.
            HStack(spacing: 0) {
                columns
                if showInspector {
                    inspector
                        .modifier(TopLineInset())
                        .frame(width: RootView.inspectorWidth)
                        .ignoresSafeArea(.container, edges: .top)
                }
            }
        }
    }

    static let inspectorWidth: CGFloat = 280

    /// Room for the sidebar, one pane and the inspector at their narrowest. The pane that stands in
    /// for the inspector before macOS 27.2 cannot shrink, so the window has to stay wider there.
    static var minimumWindowWidth: CGFloat {
        if #available(macOS 27.2, *) { 720 } else { 780 }
    }

    private var columns: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(isAddingProject: $isAddingProject, toggleSidebar: toggleSidebar)
                // Same background as the inspector and the space around the panes instead of the
                // system's sidebar material. The divider is hidden for the same reason and can
                // still be dragged.
                .scrollContentBackground(.hidden)
                .modifier(TopLineInset())
                .background { Chrome.windowSurface.ignoresSafeArea() }
                .hidesSplitDivider(true)
                // The column width below is not enough on its own: with no saved split positions
                // (a first launch) the sidebar came up about 160 points wide, well under its minimum.
                .frame(minWidth: 220)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
                .toolbar(removing: .sidebarToggle)
                .ignoresSafeArea(.container, edges: .top)
        } detail: {
            // Not a bottom safeAreaInset: the panes sit in an NSSplitView that ignores it,
            // so the terminal would extend under the status bar and hide its last row.
            VStack(spacing: 0) {
                WorktreeContentView(isSidebarCollapsed: isSidebarCollapsed, toggleSidebar: toggleSidebar)
                    // The tab row replaces the title bar, so the content has to
                    // reach the top edge of the window.
                    .ignoresSafeArea(edges: .top)
                StatusBar()
            }
        }
    }

    @ViewBuilder
    private var inspector: some View {
        @Bindable var model = model
        if model.isGitAvailable {
            InspectorView(
                root: model.selectedWorktree?.path,
                searchPATH: { await model.toolSearchPATH() },
                focusCommitMessage: $model.focusCommitMessageRequest,
                onOpenFile: { url, preview in model.openFile(url, preview: preview) },
                onOpenDiff: { path, staged, preview in model.openDiff(path: path, staged: staged, preview: preview) },
                onSwitchBranch: {
                    if let worktree = model.selectedWorktree { model.switchBranchWorktreeID = worktree.id }
                }
            )
        } else {
            // The inspector starts git as soon as it is on screen, and without the developer
            // tools every git call brings up the system's install dialog.
            ContentUnavailableView {
                Label("Git Is Not Installed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(AppModel.gitMissingMessage)
            }
        }
    }

    /// Stored as a flag, like the inspector's, so the sidebar comes back the way it was left.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { isSidebarCollapsed ? .detailOnly : .all },
            set: { isSidebarCollapsed = $0 == .detailOnly }
        )
    }

    /// Not drawn anywhere in the window, but still what Mission Control and
    /// the Window menu show.
    private var windowTitle: String {
        guard let worktree = model.selectedWorktree else { return "Archipel" }
        let project = model.workspace.project(containingWorktree: worktree.id)?.name
        return [project, worktree.branch].compactMap(\.self).joined(separator: " - ")
    }

    private func toggleSidebar() {
        withAnimation(reduceMotion ? nil : .default) { isSidebarCollapsed.toggle() }
    }

    private var closingFileName: String {
        if case .file(let url)? = model.tabAwaitingCloseDecision?.content { return url.lastPathComponent }
        return "this file"
    }

    private var projectAddingWorktree: Binding<Project?> {
        Binding(
            get: { model.addWorktreeProjectID.flatMap { model.workspace.project(id: $0) } },
            set: { model.addWorktreeProjectID = $0?.id }
        )
    }

    private var worktreeSwitchingBranch: Binding<Worktree?> {
        Binding(
            get: { model.switchBranchWorktreeID.flatMap { model.workspace.worktree(id: $0) } },
            set: { model.switchBranchWorktreeID = $0?.id }
        )
    }

    private var projectInSettings: Binding<Project?> {
        Binding(
            get: { model.projectSettingsID.flatMap { model.workspace.project(id: $0) } },
            set: { model.projectSettingsID = $0?.id }
        )
    }
}

#if DEBUG
// The inspector reaches for git, but the fixture paths do not exist, so no git process can start
// in them.
private func previewRoot(_ model: AppModel) -> some View {
    RootView(isAddingProject: .constant(false))
        .environment(model)
        .environment(CommandPaletteModel())
        .environment(TabSwitcherModel())
        .frame(width: 1280, height: 800)
}

#Preview("Populated") {
    previewRoot(AppModel.preview())
}

#Preview("Populated, Dark") {
    previewRoot(AppModel.preview())
        .preferredColorScheme(.dark)
}

#Preview("Fresh Install") {
    previewRoot(AppModel.emptyPreview())
}
#endif

/// Moves a column's header down to the top line of the window, the middle of the tab rows, which
/// sits lower when the pane cards keep a gap above them.
private struct TopLineInset: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .padding(.top, WindowButtons.topInset(for: model.settings.paneStyle))
            .background(Chrome.windowSurface)
    }
}

