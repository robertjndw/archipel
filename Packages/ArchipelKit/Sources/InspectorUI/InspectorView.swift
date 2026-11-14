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
        Group {
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A bar rather than a stacked header, so the lists scroll under it with
        // the system's edge effect instead of stopping at a divider.
        .safeAreaBar(edge: .top, spacing: 0) {
            InspectorTabSwitcher(selection: $tab)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                // Lines the switcher up with the app's pane tab row, 36pt tall.
                .frame(height: 36)
        }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case files, changes
        var id: Self { self }
        var title: LocalizedStringKey { self == .files ? "Files" : "Changes" }
        var symbol: String { self == .files ? "folder" : "plus.forwardslash.minus" }
    }
}

/// Files / Changes as one glass capsule with a selection that slides between the two, the same
/// shape the island switcher has at the other end of the window. A segmented picker stays flat here.
private struct InspectorTabSwitcher: View {
    @Binding var selection: InspectorView.Tab
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorView.Tab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { selection = tab }
                } label: {
                    Label(tab.title, systemImage: tab.symbol)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background {
                            if isSelected {
                                // A fill, not a second layer of glass on the capsule's glass.
                                Capsule()
                                    .fill(.tint.opacity(0.18))
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 240)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
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
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
    }
}
