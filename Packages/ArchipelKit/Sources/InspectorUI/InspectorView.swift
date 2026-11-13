import SwiftUI

public struct InspectorView: View {
    private let root: URL?
    private let actions: InspectorActions
    private let searchPATH: @MainActor () async -> String
    @AppStorage("InspectorUI.selectedTab") private var tab: Tab = .files

    /// `root` is the selected worktree's folder; nil shows an empty state. The view fully resets when root changes.
    /// A single click or arrow key opens a preview (`preview` true); a double click or Return opens for keeps.
    /// `searchPATH` supplies the user's login-shell PATH, which is where `gh` is found.
    public init(
        root: URL?,
        searchPATH: @escaping @MainActor () async -> String,
        onOpenFile: @escaping (_ url: URL, _ preview: Bool) -> Void,
        onOpenDiff: @escaping (_ path: String, _ staged: Bool, _ preview: Bool) -> Void
    ) {
        self.root = root
        self.searchPATH = searchPATH
        actions = InspectorActions(openFile: onOpenFile, openDiff: onOpenDiff)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let root {
                // A new identity per root throws away the old models, tasks and expansion state.
                InspectorContent(root: root, tab: tab, actions: actions, searchPATH: searchPATH)
                    .id(root)
            } else {
                ContentUnavailableView(
                    "No Worktree Selected",
                    systemImage: "sidebar.right",
                    description: Text("Select a worktree to browse its files and changes.")
                )
                .frame(maxHeight: .infinity)
            }
        }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case files, changes
        var id: Self { self }
        var title: LocalizedStringKey { self == .files ? "Files" : "Changes" }
    }
}

/// Owns both models so switching tabs keeps the file tree's expansion and the last known status.
private struct InspectorContent: View {
    let tab: InspectorView.Tab
    let actions: InspectorActions
    @State private var files: FileTreeModel
    @State private var changes: ChangesModel

    init(root: URL, tab: InspectorView.Tab, actions: InspectorActions, searchPATH: @escaping @MainActor () async -> String) {
        self.tab = tab
        self.actions = actions
        files = FileTreeModel(root: root)
        changes = ChangesModel(root: root, searchPATH: searchPATH)
    }

    var body: some View {
        switch tab {
        case .files: FilesTab(model: files, actions: actions)
        case .changes: ChangesTab(model: changes, actions: actions)
        }
    }
}

/// Where the sidebar sends the user: files and diffs open in the app's own tabs.
struct InspectorActions {
    var openFile: (_ url: URL, _ preview: Bool) -> Void
    var openDiff: (_ path: String, _ staged: Bool, _ preview: Bool) -> Void
}

/// The strip under the picker: what is being shown on the left, a refresh control on the right.
struct InspectorHeader<Title: View>: View {
    let refresh: () -> Void
    @ViewBuilder let title: Title

    var body: some View {
        HStack(spacing: 6) {
            title
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Refresh")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
