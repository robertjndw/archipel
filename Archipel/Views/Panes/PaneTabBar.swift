import AgentKit
import ArchipelCore
import EditorUI
import InspectorUI
import SwiftUI

/// The tab row of one pane. With the window's own title bar gone this is the
/// top edge of the content area, so the first and last pane also carry the
/// controls that would otherwise sit in a toolbar.
///
/// The row is part of the pane, not of the window: it takes the color of what
/// the pane shows and has no line under it, so row and content read as one
/// surface. Only the focused pane's selected tab gets glass.
struct PaneTabBar: View {
    @Environment(AppModel.self) private var model
    @AppStorage(LayoutDefaults.showsInspector) private var showInspector = true
    let worktree: Worktree
    let pane: Pane
    let isFocused: Bool
    /// Set on the first pane while the sidebar is collapsed: the window
    /// buttons then sit over this bar and need room.
    let showsSidebarToggle: Bool
    let toggleSidebar: () -> Void
    /// The color of what the pane shows, which the row is filled with.
    let background: Color
    @State private var renaming: RenameTarget?
    @State private var dropSlot: Int?
    /// Width of the scrolling part of the row, which the tabs share.
    @State private var rowWidth: CGFloat = 0

    static let height: CGFloat = 36
    /// Below this a tab stops shrinking and the row scrolls instead. It leaves the icon, the
    /// status glyph and a few characters of title, and three tabs still fit in a pane of half a
    /// default window (about 370pt).
    static let minimumTabWidth: CGFloat = 100
    private static let tabSpacing: CGFloat = 2
    /// Inside the scroll view, so the selected tab's glass shadow is not clipped.
    private static let rowInset = EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.showsWindowButtons) private var showsWindowButtons

    /// With one pane there is nothing to tell apart, so it always reads as active.
    private var isActive: Bool { isFocused || worktree.panes.count == 1 }

    private var leadingRoomForWindowButtons: CGFloat {
        let style = model.settings.paneStyle
        return WindowButtons.trailingEdge(for: style) - WindowButtons.topInset(for: style)
    }

    /// Tabs split the row evenly, like the system window tab bar, down to `minimumTabWidth`.
    /// A single tab fills the row too, so opening a second one halves it instead of moving it.
    private var tabWidth: CGFloat {
        let count = CGFloat(max(pane.tabs.count, 1))
        let available = rowWidth - Self.rowInset.leading - Self.rowInset.trailing - Self.tabSpacing * (count - 1)
        return max(Self.minimumTabWidth, (available / count).rounded(.down))
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsSidebarToggle {
                TabRowControls {
                    Button("Show Sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                        .help("Show Sidebar")
                }
                // Leaves the window buttons their corner. The bar starts at the card's edge, which
                // the top gap also keeps from the window's edge.
                .padding(.leading, showsWindowButtons ? leadingRoomForWindowButtons : 4)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: Self.tabSpacing) {
                        ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabButton(
                                tab: tab,
                                session: session(of: tab),
                                isSelected: tab.id == pane.selectedTab?.id,
                                isActive: isActive,
                                width: tabWidth
                            )
                            .anchorPreference(key: TabFrames.self, value: .bounds) { [tab.id: $0] }
                            .transition(reduceMotion ? .opacity : .tab)
                            .contextMenu { tabMenu(tab) }
                            .draggable(tab.id.uuidString)
                            .modifier(TabDropTarget(tab: tab) { targeted in
                                // One tick per slot the drag moves into, not one per drag event.
                                if targeted, dropSlot != index {
                                    dropSlot = index
                                    Haptics.levelChange()
                                } else if !targeted, dropSlot == index {
                                    dropSlot = nil
                                }
                            } moveTab: {
                                dropSlot = nil
                                _ = drop([$0.uuidString], at: index)
                            })
                        }
                    }
                    .backgroundPreferenceValue(TabFrames.self) { frames in
                        GeometryReader { geometry in
                            if let id = pane.selectedTab?.id, let anchor = frames[id] {
                                let frame = geometry[anchor]
                                SelectionCapsule(isActive: isActive)
                                    .frame(width: frame.width, height: frame.height)
                                    .offset(x: frame.minX, y: frame.minY)
                            }
                        }
                    }
                    // The model mutates tabs without animation, so the row animates them itself.
                    .animation(reduceMotion ? nil : Motion.selection, value: pane.tabs.map(\.id))
                    .animation(reduceMotion ? nil : Motion.selection, value: pane.selectedTab?.id)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isActive)
                    .padding(Self.rowInset)
                }
                // .hidden still shows a scroller when the system is set to always show them.
                .scrollIndicators(.never)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
                .tabRowEdgeFade(background)
                // Selecting a tab from elsewhere (Ctrl-Tab, the palette, a notification) can pick one
                // scrolled out of view; without this the bar shows no selection at all.
                .onChange(of: pane.selectedTab?.id) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : Motion.selection) { proxy.scrollTo(id) }
                }
                .onAppear {
                    // On appear the row has not been laid out yet and scrolling does nothing.
                    Task { @MainActor in
                        if let id = pane.selectedTab?.id { proxy.scrollTo(id) }
                    }
                }
            }
            // Dropping on the empty part of the bar appends.
            .dropDestination(for: String.self) { items, _ in
                return drop(items, at: nil)
            }

            TabRowControls {
                Menu {
                    NewSessionButtons(worktree: worktree.id, pane: pane.id)
                } label: {
                    Image(systemName: "plus")
                }
                .toolbarGroupMenu()
                // A borderless menu draws its label in the tint, which would make it the loudest
                // thing in the row.
                .tint(.secondary)
                .help("New Session")
                .accessibilityLabel("New Session")
                .accessibilityIdentifier("pane.newSession")

                if pane.id == worktree.panes.last?.id {
                    // Only once there is something to run. Setting a script up is rare and lives in
                    // the project settings; ⌘R still leads there.
                    if model.project(ofWorktree: worktree.id)?.scripts.runCommand != nil {
                        Button("Run", systemImage: "play") { model.runProject(in: worktree.id) }
                            .help("Run this project's run script (⌘R)")
                    }
                    Button(showInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                        // The one tinted button in the group: it is a toggle, and the tint is its "on".
                        .foregroundStyle(showInspector ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .help(showInspector ? "Hide Inspector (⌥⌘0)" : "Show Inspector (⌥⌘0)")
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: Self.height)
        .background(background)
        .renameAlert($renaming)
    }

    private func drop(_ items: [String], at index: Int?) -> Bool {
        guard let id = items.first.flatMap(UUID.init(uuidString:)), model.workspace.tab(id: id) != nil else { return false }
        model.move(tab: id, toPane: pane.id, at: index)
        return true
    }

    /// Sessions come from the worktree the bar already holds, so a tab does not have to read the
    /// whole workspace for its title.
    private func session(of tab: ArchipelCore.Tab) -> Session? {
        guard case .session(let id) = tab.content else { return nil }
        return worktree.sessions.first { $0.id == id }
    }

    @ViewBuilder
    private func tabMenu(_ tab: ArchipelCore.Tab) -> some View {
        Button("Split Right", systemImage: "rectangle.split.2x1") { model.split(tab: tab.id) }
            .disabled(pane.tabs.count < 2)
        if tab.isPreview {
            Button("Keep Open", systemImage: "pin") { model.pin(tab: tab.id) }
        }
        if case .session(let id) = tab.content, let session = worktree.sessions.first(where: { $0.id == id }) {
            Divider()
            Button("Rename Session…", systemImage: "pencil") {
                renaming = RenameTarget(kind: .session(id), name: session.displayTitle)
            }
            Button("Restart Session", systemImage: "arrow.clockwise") { model.restartSession(id) }
            if session.agentSessionID != nil {
                Button("Restart with a New Conversation", systemImage: "plus.bubble") {
                    model.restartSession(id, fresh: true)
                }
            }
        }
        if case .file(let url) = tab.content {
            Divider()
            Button("Show in Finder", systemImage: "folder") { model.revealInFinder(url) }
            if let editor = model.preferredEditor {
                Button("Open in \(editor.name)", systemImage: "chevron.left.forwardslash.chevron.right") { model.openInEditor(url) }
            }
            Button("Open in Default App", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
        }
        if case .web(let url) = tab.content {
            Divider()
            Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
            Button("Copy URL", systemImage: "document.on.document") { model.copyToPasteboard(url.absoluteString) }
        }
        Divider()
        Button("Close Tab", systemImage: "xmark") { model.close(tab: tab.id) }
    }
}

struct TabLabel: Equatable {
    var title: String
    var symbol: String
    /// Shown as the tooltip.
    var detail: String?
    var activity: SessionActivity?
    var hasUnsavedChanges = false
    var devServers: [DevServerLink] = []
}

/// Reads the model for this tab alone. The bar above it stays out of activity, dev servers, unsaved
/// state and page titles, so a tick in one session re-evaluates only these few lookups, and
/// `TabButtonContent` is skipped unless its own label came out different.
private struct TabButton: View {
    @Environment(AppModel.self) private var model
    let tab: ArchipelCore.Tab
    /// The session a session tab shows; nil for every other kind of tab.
    let session: Session?
    let isSelected: Bool
    /// Whether this tab's pane has focus; only then does the selection get glass.
    let isActive: Bool
    let width: CGFloat

    var body: some View {
        TabButtonContent(tab: tab, label: label, isSelected: isSelected, isActive: isActive, width: width)
            .equatable()
    }


    private var label: TabLabel {
        switch tab.content {
        case .session(let id):
            return TabLabel(
                title: session?.displayTitle ?? "Session",
                symbol: (session?.agent.definition ?? .shell).symbolName,
                detail: nil,
                activity: model.activity(for: id),
                devServers: model.devServers.links[id] ?? []
            )
        case .file(let url):
            return TabLabel(
                title: url.lastPathComponent,
                symbol: FileIcon.symbol(for: url.lastPathComponent),
                detail: url.path,
                activity: nil,
                hasUnsavedChanges: model.documents.isDirty(url)
            )
        case .diff(let path, let staged):
            let name = (path as NSString).lastPathComponent
            return TabLabel(
                title: "\(name) (\(staged ? "Staged" : "Working Tree"))",
                symbol: "plus.forwardslash.minus",
                detail: path,
                activity: nil
            )
        case .web(let url):
            let title = model.webPages.title(for: tab.id)
            return TabLabel(
                title: title ?? url.host() ?? url.absoluteString,
                symbol: "globe",
                detail: url.absoluteString,
                activity: nil
            )
        }
    }
}

/// Everything a tab draws, from values only. No closures come in: they never compare equal, and one
/// would make every tab redraw whenever the bar does. The actions go to the model directly.
private struct TabButtonContent: View, Equatable {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tab: ArchipelCore.Tab
    let label: TabLabel
    let isSelected: Bool
    let isActive: Bool
    let width: CGFloat
    @State private var isHovered = false
    @State private var isOverClose = false
    /// Width of the badges on the trailing side, so the title can stay centered without running
    /// under them.
    @State private var trailingWidth: CGFloat = 0

    private static let iconSlot: CGFloat = 18
    /// The narrowest tab that still shows its badges and dev server link next to a readable title.
    private static let badgeWidth: CGFloat = 170
    /// Below this the title is no longer kept centered, so it can use the space the badges leave.
    private static let centeredWidth: CGFloat = 160
    private static let edgePadding: CGFloat = 8
    private static let gap: CGFloat = 6

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tab == rhs.tab && lhs.label == rhs.label && lhs.isSelected == rhs.isSelected
            && lhs.isActive == rhs.isActive && lhs.width == rhs.width
    }

    var body: some View {
        // The title is centered on the whole tab, as in the system tab bar, so it keeps the same
        // distance from both sides whatever the badges add. A tab squeezed near its minimum
        // width gives that up and lets the title use the room the badges leave free.
        let leadingInset = Self.edgePadding + Self.iconSlot + Self.gap
        let trailingInset = Self.edgePadding + (trailingWidth > 0 ? trailingWidth + Self.gap : 0)
        let isCentered = width >= Self.centeredWidth
        let insets = EdgeInsets(
            top: 0,
            leading: isCentered ? max(leadingInset, trailingInset) : leadingInset,
            bottom: 0,
            trailing: isCentered ? max(leadingInset, trailingInset) : trailingInset
        )
        Text(label.title)
            .lineLimit(1)
            .truncationMode(.tail)
            .italic(tab.isPreview)
            .fontWeight(label.activity?.unread == true ? .semibold : .regular)
            // In a pane without focus the selected tab is told apart by its text alone.
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(insets)
            .frame(width: width, height: Chrome.controlHeight)
            .overlay(alignment: .leading) { leading.padding(.leading, Self.edgePadding) }
            .overlay(alignment: .trailing) {
                trailing
                    .padding(.trailing, Self.edgePadding)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width - Self.edgePadding } action: { trailingWidth = $0 }
            }
            .animation(.snappy(duration: 0.25), value: label.devServers)
            .animation(.snappy(duration: 0.25), value: label.activity?.subagents.count)
            .animation(.snappy(duration: 0.25), value: label.activity?.backgroundTasks)
            // The same curve the sidebar row uses for this change, so a session's two glyphs move together.
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: label.activity?.status)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: label.activity?.unread)
            .background {
                if isHovered && !isSelected {
                    Capsule().fill(.quinary)
                }
            }
            .animation(Motion.hover, value: isHovered)
            .contentShape(.capsule)
            // The tab-wide taps also fire for a click on the close button, which would select the tab
            // being closed and make closing it pick a neighbour. A background tap target would not
            // work instead: the title and icon sit on top of it and swallow the click.
            .gesture(TapGesture(count: 2).onEnded { if !isOverClose { model.pin(tab: tab.id) } })
            .simultaneousGesture(TapGesture().onEnded { if !isOverClose { model.select(tab: tab.id) } })
            .onHover { isHovered = $0 }
            .help(label.detail ?? label.title)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label.title)
            // The label above replaces what the children would say, the dot's and the badges' included.
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("pane.tab")
            .accessibilityAction(.default) { model.select(tab: tab.id) }
    }

    /// The tab's icon, which gives way to the close button under the pointer, the way Safari swaps
    /// a page's icon. Both share one slot so nothing moves.
    private var leading: some View {
        ZStack {
            Image(symbol: label.symbol)
                .foregroundStyle(isSelected && isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .opacity(isHovered ? 0 : 1)
            Button("Close Tab", systemImage: "xmark") { model.close(tab: tab.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .opacity(isHovered ? 1 : 0)
                .onHover { isOverClose = $0 }
        }
        .frame(width: Self.iconSlot)
    }

    /// What the tab reports about itself. Always on the trailing side, so a status change never
    /// moves the title.
    private var trailing: some View {
        HStack(spacing: 4) {
            // A narrow tab keeps only the status glyph. The counts and the dev server link would
            // take all of its room; the sidebar row and VoiceOver still report them.
            if width >= Self.badgeWidth {
                if !label.devServers.isEmpty {
                    DevServerPill(links: label.devServers)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                BackgroundTaskBadge(count: label.activity?.backgroundTasks ?? 0)
                SubagentBadge(count: label.activity?.subagents.count ?? 0)
            }
            if let activity = label.activity {
                if StatusGlyph.isVisible(for: activity) {
                    StatusGlyph(activity: activity)
                }
            } else if label.hasUnsavedChanges {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Unsaved changes")
            }
        }
        .fixedSize()
    }

    private var accessibilityValue: String {
        if label.hasUnsavedChanges { return "Unsaved changes" }
        let tasks = label.activity?.backgroundTasks ?? 0
        let subagents = label.activity?.subagents.count ?? 0
        return [
            tasks > 0 ? BackgroundTaskBadge.description(tasks) : nil,
            subagents > 0 ? SubagentBadge.description(subagents) : nil,
        ].compactMap(\.self).joined(separator: ", ")
    }
}

/// Fades the leading or trailing edge of the tab row while tabs are cut off there, the way the
/// inspector's lists fade (`scrollEdgeFade` in InspectorUI, which is vertical only and uses the
/// inspector's background).
private struct TabRowEdgeFade: ViewModifier {
    /// What the row is filled with, so the fade lands on the same color.
    let background: Color
    @State private var clipped = ClippedEdges()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width: CGFloat = 24

    struct ClippedEdges: Equatable {
        var leading = false
        var trailing = false
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ClippedEdges.self) { geometry in
                // Half a point of slack so rubber-banding and rounding do not flicker the fade.
                let leading = geometry.contentOffset.x + geometry.contentInsets.leading > 0.5
                let trailing = geometry.visibleRect.maxX < geometry.contentSize.width - 0.5
                return ClippedEdges(leading: leading, trailing: trailing)
            } action: { _, edges in
                withAnimation(reduceMotion ? nil : Motion.hover) { clipped = edges }
            }
            // An overlay rather than a mask: a mask would also cut into the selected tab's glass.
            .overlay(alignment: .leading) { fade(from: .leading).opacity(clipped.leading ? 1 : 0) }
            .overlay(alignment: .trailing) { fade(from: .trailing).opacity(clipped.trailing ? 1 : 0) }
    }

    private func fade(from edge: HorizontalEdge) -> some View {
        LinearGradient(
            stops: [
                .init(color: background, location: 0),
                .init(color: background, location: 0.3),
                .init(color: background.opacity(0), location: 1),
            ],
            startPoint: edge == .leading ? .leading : .trailing,
            endPoint: edge == .leading ? .trailing : .leading
        )
        .frame(width: Self.width)
        .allowsHitTesting(false)
    }
}

private extension View {
    func tabRowEdgeFade(_ background: Color) -> some View {
        modifier(TabRowEdgeFade(background: background))
    }
}

/// Icon buttons at the ends of the tab row, drawn straight onto the pane's color. Glass here would
/// compete with the selected tab's glass. The squares match
/// `GlassToolbarGroup`, so the buttons sit where they did.
private struct TabRowControls<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
                .labelStyle(.iconOnly)
                .buttonStyle(GlyphButtonStyle())
                .foregroundStyle(.secondary)
                // For the menu, which the button style does not reach.
                .frame(width: Chrome.controlHeight + 4, height: Chrome.controlHeight)
        }
    }
}

/// A plain glyph with a faint round highlight under the pointer, like a borderless toolbar item.
/// For icon buttons that sit straight on a surface: the ends of the tab rows, the new island button.
struct GlyphButtonStyle: ButtonStyle {
    /// The height of the controls around it, so the hover highlight matches them.
    var height = Chrome.controlHeight

    func makeBody(configuration: Configuration) -> some View {
        GlyphButton(configuration: configuration, height: height)
    }

    private struct GlyphButton: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(width: height + 4, height: height)
                .background {
                    Capsule()
                        .fill(.quinary)
                        .opacity(configuration.isPressed ? 1 : isHovered ? 0.7 : 0)
                }
                .contentShape(.capsule)
                .onHover { isHovered = $0 }
                .animation(Motion.hover, value: isHovered)
        }
    }
}

/// The focused pane's selected tab is the one piece of glass in the row,
/// like Safari's compact tabs. An unfocused pane shows none: its dimmed content
/// already tells the panes apart.
///
/// One view that slides under the selected tab instead of glass on every tab.
/// Per-tab glass merges with its neighbours when a tab opens or closes and
/// smears a blurry blob over their labels, which sometimes stays there.
private struct SelectionCapsule: View {
    let isActive: Bool

    var body: some View {
        Capsule()
            .fill(.clear)
            .glassEffect(isActive ? .regular : .identity, in: .capsule)
    }
}

/// Tab frames, so the selection capsule knows where to go.
private struct TabFrames: PreferenceKey {
    static let defaultValue: [ArchipelCore.Tab.ID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [ArchipelCore.Tab.ID: Anchor<CGRect>], nextValue: () -> [ArchipelCore.Tab.ID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Scale, fade and blur for tabs being opened or closed.
private struct TabTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : 0.8)
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity ? 0 : 6)
    }
}

private extension AnyTransition {
    static var tab: AnyTransition { AnyTransition(TabTransition()) }
}

#if DEBUG
/// Worktrees with hand-made panes for the tab bar and pane previews.
enum PanePreviews {
    static let serverSessionID = UUID(uuidString: "00000000-0000-0000-0000-0000000005E7")!

    /// The feature worktree with every kind of tab: sessions in several states, a file, a diff,
    /// a preview tab and a session running a dev server.
    static func mixedTabs() -> Worktree {
        var worktree = PreviewFixtures.featureWorktree
        worktree.sessions.append(Session(id: serverSessionID, title: "Dev Server", hasCustomTitle: true, agent: .shell))
        let tabs = [
            ArchipelCore.Tab(content: .session(PreviewFixtures.codexSessionID)),
            ArchipelCore.Tab(content: .session(PreviewFixtures.reviewSessionID)),
            ArchipelCore.Tab(content: .file(worktree.path.appending(path: "Sources/Sync/SyncEngine.swift"))),
            ArchipelCore.Tab(content: .diff(path: "Sources/Cache/ResponseCache.swift", staged: false)),
            ArchipelCore.Tab(content: .session(serverSessionID)),
            ArchipelCore.Tab(content: .file(worktree.path.appending(path: "README.md")), isPreview: true),
        ]
        worktree.panes = [Pane(tabs: tabs, selectedTabID: tabs[0].id)]
        worktree.focusedPaneID = worktree.panes[0].id
        return worktree
    }

    /// The feature worktree split in two, the left pane focused.
    static func split() -> Worktree {
        var worktree = PreviewFixtures.featureWorktree
        let left = ArchipelCore.Tab(content: .session(PreviewFixtures.codexSessionID))
        let right = ArchipelCore.Tab(content: .session(PreviewFixtures.reviewSessionID))
        worktree.panes = [Pane(tabs: [left], selectedTabID: left.id), Pane(tabs: [right], selectedTabID: right.id)]
        worktree.focusedPaneID = worktree.panes[0].id
        return worktree
    }

    /// The fixture workspace with `worktree` swapped in and selected.
    static func model(selecting worktree: Worktree) -> AppModel {
        var workspace = PreviewFixtures.workspace
        workspace.updateWorktree(id: worktree.id) { $0 = worktree }
        if let island = workspace.island(containingWorktree: worktree.id) {
            workspace.selectedIslandID = island.id
            workspace.selectedWorktreeIDByIsland[island.id] = worktree.id
        }
        var activities = PreviewFixtures.activities
        activities[serverSessionID] = SessionActivity(status: .working)
        let model = AppModel(preview: workspace, activities: activities)
        model.gitSummaries = PreviewFixtures.gitSummaries
        model.pullRequests = PreviewFixtures.pullRequests
        model.usage = PreviewFixtures.usage
        model.devServers.showForPreview([serverSessionID: [
            DevServerLink(url: URL(string: "http://localhost:8080")!)!,
            DevServerLink(url: URL(string: "http://localhost:5173/")!)!,
        ]])
        return model
    }
}

private struct PaneTabBarPreview: View {
    let model: AppModel
    var paneIndex = 0
    var showsSidebarToggle = false
    var background = Color(nsColor: .textBackgroundColor)

    var body: some View {
        if let worktree = model.selectedWorktree {
            let pane = worktree.panes[paneIndex]
            PaneTabBar(
                worktree: worktree,
                pane: pane,
                isFocused: pane.id == worktree.focusedPane?.id,
                showsSidebarToggle: showsSidebarToggle,
                toggleSidebar: {},
                background: background
            )
            .environment(model)
        }
    }
}

private func previewTabBars() -> some View {
    VStack(spacing: 12) {
        PaneTabBarPreview(model: PanePreviews.model(selecting: PanePreviews.mixedTabs()))
        PaneTabBarPreview(model: AppModel.preview())
        PaneTabBarPreview(model: PanePreviews.model(selecting: PreviewFixtures.fixWorktree))
        PaneTabBarPreview(model: AppModel.preview(), showsSidebarToggle: true)
    }
    .frame(width: 1100)
    .padding(.vertical)
}

#Preview("Tab Bars") {
    previewTabBars()
}

#Preview("Tab Bars, Dark") {
    previewTabBars()
        .preferredColorScheme(.dark)
}

#Preview("On a Black Terminal") {
    PaneTabBarPreview(model: PanePreviews.model(selecting: PanePreviews.mixedTabs()), background: .black)
        .environment(\.colorScheme, .dark)
        .frame(width: 1100)
}

#Preview("Overflowing") {
    PaneTabBarPreview(model: PanePreviews.model(selecting: PanePreviews.mixedTabs()))
        .frame(width: 520)
}

#Preview("Split, Focused and Not") {
    let model = PanePreviews.model(selecting: PanePreviews.split())
    HStack(spacing: 1) {
        PaneTabBarPreview(model: model, paneIndex: 0)
        PaneTabBarPreview(model: model, paneIndex: 1)
    }
    .frame(width: 900)
}

#Preview("Unsaved File") {
    let url = PreviewFixtures.mainWorktree.path.appending(path: "Package.swift")
    let tab = ArchipelCore.Tab(content: .file(url))
    let label = TabLabel(title: "Package.swift", symbol: FileIcon.symbol(for: "Package.swift"), detail: url.path)
    var unsaved = label
    unsaved.hasUnsavedChanges = true
    return HStack(spacing: 4) {
        TabButtonContent(tab: tab, label: label, isSelected: false, isActive: true, width: 180)
        TabButtonContent(tab: tab, label: unsaved, isSelected: false, isActive: true, width: 180)
    }
    .padding()
    .environment(AppModel.preview())
}
#endif
