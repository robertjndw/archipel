import ArchipelCore
import InspectorUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(CommandPaletteModel.self) private var palette
    @Environment(TabSwitcherModel.self) private var switcher
    @Binding var isAddingProject: Bool
    @AppStorage("showInspector") private var showInspector = true
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(isAddingProject: $isAddingProject, toggleSidebar: toggleSidebar)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
                .toolbar(removing: .sidebarToggle)
                .ignoresSafeArea(.container, edges: .top)
        } detail: {
            // Not a bottom safeAreaInset: the panes sit in an NSSplitView that ignores it,
            // so the terminal would extend under the status bar and hide its last row.
            VStack(spacing: 0) {
                WorktreeContentView(isSidebarCollapsed: columns == .detailOnly, toggleSidebar: toggleSidebar)
                    // The tab row replaces the title bar, so the content has to
                    // reach the top edge of the window.
                    .ignoresSafeArea(edges: .top)
                StatusBar()
            }
        }
        .inspector(isPresented: $showInspector) {
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
            .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
            .ignoresSafeArea(.container, edges: .top)
        }
        .overlay { CommandPalette() }
        .overlay { TabSwitcher() }
        .background(TabSwitcherKeyMonitor(switcher: switcher, model: model, isBlocked: { [palette] in palette.isPresented }))
        .toolbar(removing: .title)
        .navigationTitle(windowTitle)
        .tint(model.selectedIsland?.tint.color)
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
        .sheet(item: projectInSettings) { project in
            ProjectSettingsSheet(project: project)
        }
        .sheet(item: projectAddingWorktree) { project in
            WorktreeSheet(project: project)
        }
        .sheet(item: worktreeSwitchingBranch) { worktree in
            SwitchBranchSheet(worktree: worktree)
        }
        .alert("Archipel ran into a problem", item: $model.problem) { _ in
            Button("OK") {}
        } message: { problem in
            Text(problem)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.appDidBecomeActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.appDidResignActive()
        }
    }

    /// Not drawn anywhere in the window, but still what Mission Control and
    /// the Window menu show.
    private var windowTitle: String {
        guard let worktree = model.selectedWorktree else { return "Archipel" }
        let project = model.workspace.project(containingWorktree: worktree.id)?.name
        return [project, worktree.branch].compactMap(\.self).joined(separator: " - ")
    }

    private func toggleSidebar() {
        withAnimation(reduceMotion ? nil : .default) { columns = columns == .detailOnly ? .all : .detailOnly }
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
// The inspector and the activation handler reach for git, but the fixture paths do not exist, so
// no git process can start in them.
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
