import SwiftUI

public struct InspectorView: View {
    private let root: URL?
    @AppStorage("InspectorUI.selectedTab") private var tab: Tab = .files

    /// `root` is the selected worktree's folder; nil shows an empty state. The view fully resets when root changes.
    public init(root: URL?) {
        self.root = root
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
                InspectorContent(root: root, tab: tab)
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
    @State private var files: FileTreeModel
    @State private var changes: ChangesModel

    init(root: URL, tab: InspectorView.Tab) {
        self.tab = tab
        files = FileTreeModel(root: root)
        changes = ChangesModel(root: root)
    }

    var body: some View {
        switch tab {
        case .files: FilesTab(model: files)
        case .changes: ChangesTab(model: changes)
        }
    }
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
