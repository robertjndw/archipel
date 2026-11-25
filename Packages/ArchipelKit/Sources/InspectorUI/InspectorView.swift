import GitKit
import SwiftUI
import UISupport

public struct InspectorView: View {
    private let git: GitWorktreeState?
    private let actions: InspectorActions
    @Binding private var focusCommitMessage: Bool
    @AppStorage(InspectorView.selectedTabKey) private var tab: Tab = .files

    /// The host shares this key to switch tabs from its own commands (Show Files, Show Changes, Commit…).
    public static let selectedTabKey = "InspectorUI.selectedTab"

    /// `git` is the selected worktree's state, the same object the host's sidebar and menus read,
    /// and its root is the folder shown; nil shows an empty state. The view fully resets when it
    /// changes. A single click or arrow key opens a preview (`preview` true); a double click or
    /// Return opens for keeps.
    /// Setting `focusCommitMessage` puts the cursor in the commit message field once the Changes tab
    /// shows it; the inspector sets it back to false.
    /// With `onSwitchBranch`, the branch name in the Changes tab becomes a button that calls it.
    public init(
        git: GitWorktreeState?,
        focusCommitMessage: Binding<Bool> = .constant(false),
        onOpenFile: @escaping (_ url: URL, _ preview: Bool) -> Void,
        onOpenDiff: @escaping (_ path: String, _ staged: Bool, _ preview: Bool) -> Void,
        onSwitchBranch: (() -> Void)? = nil,
        onTrash: @escaping (_ urls: [URL]) -> Void = { _ in },
        onProblem: @escaping (_ message: String) -> Void = { _ in }
    ) {
        self.git = git
        _focusCommitMessage = focusCommitMessage
        actions = InspectorActions(openFile: onOpenFile, openDiff: onOpenDiff, switchBranch: onSwitchBranch, didTrash: onTrash, reportProblem: onProblem)
    }

    public var body: some View {
        // A plain stack instead of safeAreaBar or safeAreaInset. With a bar the system draws a
        // hairline on hover, and with an inset the rows show through the header.
        VStack(spacing: 0) {
            InspectorTabSwitcher(selection: $tab)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                // Lines the switcher up with the app's pane tab row, 36pt tall.
                .frame(height: 36)
            content
        }
        .background(Color.inspectorBackground)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let git {
                // A new identity per worktree throws away the old models, tasks and expansion
                // state. Except a Changes model with git still running: see `ChangesModelStore`.
                InspectorContent(
                    git: git,
                    tab: tab,
                    actions: actions,
                    focusCommitMessage: $focusCommitMessage
                )
                    .id(ObjectIdentifier(git))
            } else {
                ContentUnavailableView(
                    "No Worktree Selected",
                    systemImage: "sidebar.right",
                    description: Text("Select a worktree to browse its files and changes.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Drops what the inspector keeps for worktrees beyond their time on screen (a Changes model
    /// with an error still to show, an unsent commit message) for all but `roots`. A removed
    /// worktree's path can be reused, and the new worktree must not start with the old one's state.
    ///
    /// Cheap enough to call on a timer: it does nothing while nothing is kept.
    @MainActor
    public static func forgetWorktrees(except roots: some Sequence<URL>) {
        guard !ChangesModelStore.shared.isEmpty || !CommitMessageDrafts.shared.isEmpty else { return }
        let keys = Set(roots.map(\.pathKey))
        ChangesModelStore.shared.forget(except: keys)
        CommitMessageDrafts.shared.forget(except: keys)
    }

    public enum Tab: String, CaseIterable, Identifiable {
        case files, changes
        public var id: Self { self }
        var title: LocalizedStringKey { self == .files ? "Files" : "Changes" }
        var symbol: String { self == .files ? "folder" : "plus.forwardslash.minus" }
    }
}

/// Files / Changes as one glass capsule with a selection that slides between the two, the same
/// shape the island switcher has at the other end of the window. A segmented picker stays flat here.
private struct InspectorTabSwitcher: View {
    @Binding var selection: InspectorView.Tab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Both segments switch together so the capsule never shows one label and one icon. The text
        // variant is fixed to its ideal width, so it reports "does not fit" instead of wrapping.
        ViewThatFits(in: .horizontal) {
            segments(showsTitle: true)
            segments(showsTitle: false)
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 240)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }

    private func segments(showsTitle: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(InspectorView.Tab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    withAnimation(reduceMotion ? nil : Motion.selection) { selection = tab }
                } label: {
                    Group {
                        if showsTitle {
                            Label(tab.title, systemImage: tab.symbol)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        } else {
                            Image(systemName: tab.symbol)
                        }
                    }
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .anchorPreference(key: SelectedTabBounds.self, value: .bounds) { isSelected ? $0 : nil }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        // One highlight behind the row, placed on the selected segment's frame, as in the island
        // switcher. A matchedGeometryEffect would be declared in both ViewThatFits variants, and the
        // two sources fight over the frame mid-animation.
        .backgroundPreferenceValue(SelectedTabBounds.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let rect = proxy[anchor]
                    // A fill, not a second layer of glass on the capsule's glass.
                    Capsule()
                        .fill(.tint.opacity(0.18))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }
}

private struct SelectedTabBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Owns both models so switching tabs keeps the file tree's expansion and the last known status.
private struct InspectorContent: View {
    let git: GitWorktreeState
    let tab: InspectorView.Tab
    let actions: InspectorActions
    @Binding var focusCommitMessage: Bool
    /// Made on appear rather than in init: the parent rebuilds this struct on every update, and a
    /// model made in init would be allocated, along with its GitClient, each time and thrown away.
    @State private var models: Models?

    private struct Models {
        let files: FileTreeModel
        let changes: ChangesModel
    }

    init(
        git: GitWorktreeState,
        tab: InspectorView.Tab,
        actions: InspectorActions,
        focusCommitMessage: Binding<Bool>
    ) {
        self.git = git
        self.tab = tab
        self.actions = actions
        _focusCommitMessage = focusCommitMessage
    }

    var body: some View {
        Group {
            if let models {
                switch tab {
                case .files: FilesTab(model: models.files, actions: actions)
                case .changes:
                    ChangesTab(model: models.changes, actions: actions, focusCommitMessage: $focusCommitMessage)
                }
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard models == nil else { return }
            // The Changes model of an earlier visit, if it still has a commit, push or pull running
            // or an error from one to show.
            models = Models(files: FileTreeModel(root: git.root), changes: ChangesModelStore.shared.model(for: git))
        }
    }
}

/// Where the sidebar sends the user: files and diffs open in the app's own tabs.
struct InspectorActions {
    var openFile: (_ url: URL, _ preview: Bool) -> Void
    var openDiff: (_ path: String, _ staged: Bool, _ preview: Bool) -> Void
    var switchBranch: (() -> Void)? = nil
    /// Lets the app close tabs for whatever was just trashed.
    var didTrash: (_ urls: [URL]) -> Void = { _ in }
    var reportProblem: (_ message: String) -> Void = { _ in }
}

/// The strip under the picker: what is being shown on the left, a refresh control on the right.
/// `accessory` sits just before Refresh, for tab-specific controls like the sync menu.
struct InspectorHeader<Title: View, Accessory: View>: View {
    let refresh: () -> Void
    let title: Title
    let accessory: Accessory
    /// Bumped on every click to spin the icon once. A refresh is usually too quick to show progress.
    @State private var spins = 0

    init(refresh: @escaping () -> Void, @ViewBuilder title: () -> Title, @ViewBuilder accessory: () -> Accessory) {
        self.refresh = refresh
        self.title = title()
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 6) {
            title
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            accessory
            Button("Refresh", systemImage: "arrow.clockwise") {
                spins += 1
                refresh()
            }
                .labelStyle(.iconOnly)
                .symbolEffect(.rotate.clockwise.wholeSymbol, value: spins)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Refresh")
        }
        .font(.callout)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        // Extra space on top so the title doesn't stick to the picker.
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

extension InspectorHeader where Accessory == EmptyView {
    init(refresh: @escaping () -> Void, @ViewBuilder title: () -> Title) {
        self.init(refresh: refresh, title: title, accessory: { EmptyView() })
    }
}

#if DEBUG
#Preview("No Worktree") {
    InspectorView(git: nil, onOpenFile: { _, _ in }, onOpenDiff: { _, _, _ in })
        .frame(width: 300, height: 560)
}

// InspectorView builds its models from a real worktree, so this assembles the same stack from
// sample models instead.
#Preview("Worktree") {
    @Previewable @State var tab = InspectorView.Tab.changes
    @Previewable @State var files = PreviewSamples.fileTree(expanding: ["Sources", "Sources/App"])
    @Previewable @State var changes = ChangesModel.previewSample(message: "Add previews to the inspector")
    VStack(spacing: 0) {
        InspectorTabSwitcher(selection: $tab)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .frame(height: 36)
        switch tab {
        case .files: FilesTab(model: files, actions: PreviewSamples.actions)
        case .changes: ChangesTab(model: changes, actions: PreviewSamples.actions, focusCommitMessage: .constant(false))
        }
    }
    .frame(width: 300, height: 600)
    .background(Color.inspectorBackground)
}

#Preview("No Worktree, Dark") {
    InspectorView(git: nil, onOpenFile: { _, _ in }, onOpenDiff: { _, _, _ in })
        .frame(width: 300, height: 560)
        .preferredColorScheme(.dark)
}
#endif
