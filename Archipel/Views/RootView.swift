import ArchipelCore
import InspectorUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Binding var isAddingProject: Bool
    @AppStorage("showInspector") private var showInspector = true
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(isAddingProject: $isAddingProject, toggleSidebar: toggleSidebar)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
                .toolbar(removing: .sidebarToggle)
                .ignoresSafeArea(.container, edges: .top)
        } detail: {
            WorktreeContentView(isSidebarCollapsed: columns == .detailOnly, toggleSidebar: toggleSidebar)
                // The tab row replaces the title bar, so the content has to
                // reach the top edge of the window.
                .ignoresSafeArea(edges: .top)
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(
                root: model.selectedWorktree?.path,
                onOpenFile: { url, preview in model.openFile(url, preview: preview) },
                onOpenDiff: { path, staged, preview in model.openDiff(path: path, staged: staged, preview: preview) }
            )
            .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
            .ignoresSafeArea(.container, edges: .top)
        }
        .toolbar(removing: .title)
        .navigationTitle(windowTitle)
        .tint(model.selectedIsland?.tint.color)
        .fileImporter(isPresented: $isAddingProject, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { model.addProject(folder: url) }
            }
        }
        .confirmationDialog(
            "Do you want to save the changes you made to \(closingFileName)?",
            isPresented: isDecidingClose,
            presenting: model.tabAwaitingCloseDecision
        ) { tab in
            Button("Save") { model.resolveClose(of: tab, saving: true) }
            Button("Don't Save", role: .destructive) { model.resolveClose(of: tab, saving: false) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your changes will be lost if you don't save them.")
        }
        .alert("Archipel ran into a problem", isPresented: hasProblem) {
            Button("OK") { model.problem = nil }
        } message: {
            Text(model.problem ?? "")
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
        withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
    }

    private var closingFileName: String {
        if case .file(let url)? = model.tabAwaitingCloseDecision?.content { return url.lastPathComponent }
        return "this file"
    }

    private var isDecidingClose: Binding<Bool> {
        Binding(get: { model.tabAwaitingCloseDecision != nil }, set: { if !$0 { model.tabAwaitingCloseDecision = nil } })
    }

    private var hasProblem: Binding<Bool> {
        Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
    }
}
