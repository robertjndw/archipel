import ArchipelCore
import InspectorUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Binding var isAddingProject: Bool
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView(isAddingProject: $isAddingProject)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
                .toolbar {
                    ToolbarItem {
                        Button("Add Project", systemImage: "folder.badge.plus") { isAddingProject = true }
                            .help("Add a folder to this island")
                    }
                }
        } detail: {
            SessionDetailView()
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(root: model.selectedWorktree?.path)
                .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem {
                Button("Toggle Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                    .help("Show or hide files and changes")
            }
        }
        .tint(model.selectedIsland?.tint.color)
        .fileImporter(isPresented: $isAddingProject, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { model.addProject(folder: url) }
            }
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

    private var hasProblem: Binding<Bool> {
        Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
    }
}
