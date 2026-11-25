import AgentKit
import AppKit
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
private typealias TabSlot = ReorderDifference<ArchipelCore.Tab.ID, ReorderableSingleCollectionIdentifier>.Destination.Position

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
    /// Width of the scrolling part of the row, which the tabs share.
    @State private var rowWidth: CGFloat = 0
    /// Pinned while you close tabs with the pointer in the bar, so the next close button lands
    /// under the pointer (Safari does the same). Cleared when the pointer leaves.
    @State private var frozenTabWidth: CGFloat?
    @State private var isPointerInRow = false
    @State private var dragSlot: TabSlot?
    @State private var scrollPosition = ScrollPosition()
    @State private var scroll = HorizontalScroll()

    static let height: CGFloat = 36
    /// Below this a tab stops shrinking and the row scrolls instead. It leaves the icon, the
    /// status glyph and a few characters of title, and three tabs still fit in a pane of half a
    /// default window (about 370pt).
    static let minimumTabWidth: CGFloat = 100
    /// Fits a long title plus the badges and a dev server link.
    static let maximumTabWidth: CGFloat = 240
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

    /// Tabs share the row evenly, clamped to the min and max width. Leftover space stays empty.
    /// Without the cap a single tab stretches across the pane and looks like a title bar.
    private var tabWidth: CGFloat {
        frozenTabWidth ?? tabWidth(forCount: pane.tabs.count)
    }

    private func tabWidth(forCount tabCount: Int) -> CGFloat {
        let count = CGFloat(max(tabCount, 1))
        let available = rowWidth - Self.rowInset.leading - Self.rowInset.trailing - Self.tabSpacing * (count - 1)
        return min(Self.maximumTabWidth, max(Self.minimumTabWidth, (available / count).rounded(.down)))
    }

    /// Parent folder for file and diff tabs whose names clash, like Xcode and VS Code show it.
    /// Tabs with a unique name aren't in the result.
    private var subtitles: [ArchipelCore.Tab.ID: String] {
        let paths: [(id: ArchipelCore.Tab.ID, path: String, staged: Bool?)] = pane.tabs.compactMap { tab in
            switch tab.content {
            case .file(let url): (tab.id, url.path, nil)
            case .diff(let path, let staged): (tab.id, path, staged)
            case .session, .web: nil
            }
        }
        let byName = Dictionary(grouping: paths) { ($0.path as NSString).lastPathComponent }
        var result: [ArchipelCore.Tab.ID: String] = [:]
        for group in byName.values where group.count > 1 {
            for entry in group {
                // Staged and working tree diffs of the same file have the same folder, so show
                // the side instead.
                let sameDiffTwice = entry.staged != nil
                    && group.contains { $0.id != entry.id && $0.staged != nil && $0.path == entry.path }
                if sameDiffTwice, let staged = entry.staged {
                    result[entry.id] = staged ? "Staged" : "Working Tree"
                } else {
                    let folder = ((entry.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                    if !folder.isEmpty { result[entry.id] = folder }
                }
            }
        }
        return result
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
                    let subtitles = subtitles
                    HStack(spacing: Self.tabSpacing) {
                        ForEach(pane.tabs) { tab in
                            TabButton(
                                tab: tab,
                                session: session(of: tab),
                                subtitle: subtitles[tab.id],
                                isSelected: tab.id == pane.selectedTab?.id,
                                isActive: isActive,
                                width: tabWidth
                            )
                            .anchorPreference(key: TabFrames.self, value: .bounds) { [tab.id: $0] }
                            .transition(reduceMotion ? .opacity : .tab)
                            .contextMenu { tabMenu(tab) }
                            .modifier(TabDropTarget(tab: tab))
                        }
                        .reorderable()
                    }
                    // The drag and reorder containers below give the row accessibility of its own. With
                    // no element to hold it, SwiftUI folds it into the first tab, which then reports
                    // the whole row's frame, and a click on its center lands on another tab.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Tabs")
                    .reorderContainer(for: ArchipelCore.Tab.self) { difference in
                        move(difference.sources, to: difference.destination.position)
                    }
                    .dragContainer(for: TabDragItem.self) { ids in ids.map(TabDragItem.init) }
                    // reorderContainer only handles this pane's tabs. This picks up tabs
                    // dragged in from other panes.
                    .dropDestination(for: TabDragItem.self) { items, session in
                        let foreign = items.map(\.id).filter { id in !pane.tabs.contains { $0.id == id } }
                        move(foreign, to: session.reorderDestination(for: ArchipelCore.Tab.self)?.position ?? .end)
                    }
                    // One tick per slot the insertion point passes through, never while it stays put.
                    .onDropSessionUpdated { session in
                        let slot = session.reorderDestination(for: ArchipelCore.Tab.self)?.position
                        guard slot != dragSlot else { return }
                        if case .active = session.phase, dragSlot != nil, slot != nil { Haptics.alignment() }
                        dragSlot = slot
                    }
                    // Left-aligns the tabs and makes the empty area a drop target for appending.
                    .frame(minWidth: max(0, rowWidth - Self.rowInset.leading - Self.rowInset.trailing), alignment: .leading)
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
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: HorizontalScroll.self) { geometry in
                    HorizontalScroll(
                        offset: geometry.contentOffset.x,
                        maxOffset: max(0, geometry.contentSize.width - geometry.containerSize.width)
                    )
                } action: { _, new in scroll = new }
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

            TabRowControls {
                NewSessionMenu(worktree: worktree.id, pane: pane.id)

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
        .onHover { inside in
            isPointerInRow = inside
            if !inside, frozenTabWidth != nil {
                withAnimation(reduceMotion ? nil : Motion.selection) { frozenTabWidth = nil }
            }
        }
        .localEventMonitor(.scrollWheel, while: isPointerInRow, handle: scrollSideways)
        .onChange(of: pane.tabs.count) { old, new in
            if new < old, isPointerInRow {
                frozenTabWidth = frozenTabWidth ?? tabWidth(forCount: old)
            } else if new > old {
                frozenTabWidth = nil
            }
        }
        .renameAlert($renaming)
    }

    /// `position` refers to the order before the move, so the index is looked up with the moved
    /// tab already taken out.
    private func move(_ ids: [ArchipelCore.Tab.ID], to position: TabSlot) {
        dragSlot = nil
        var landed = false
        for id in ids {
            switch position {
            case .before(let anchor):
                // Dropped on itself.
                guard anchor != id else { continue }
                let current = model.workspace.worktree(containingPane: pane.id)?.panes.first { $0.id == pane.id }?.tabs ?? pane.tabs
                let index = current.filter { $0.id != id }.firstIndex { $0.id == anchor }
                model.move(tab: id, toPane: pane.id, at: index)
                landed = true
            case .end:
                model.move(tab: id, toPane: pane.id, at: nil)
                landed = true
            }
        }
        if landed { Haptics.alignment() }
    }

    /// SwiftUI doesn't turn a vertical mouse wheel into horizontal scrolling, so do it by hand
    /// while the pointer is over the bar. Trackpads and the Magic Mouse send precise deltas and
    /// can already scroll sideways, so they're skipped.
    private func scrollSideways(_ event: NSEvent) -> Bool {
        guard !event.hasPreciseScrollingDeltas, event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
              scroll.maxOffset > 0 else { return false }
        // Non-precise deltas are in lines. 24pt per line is roughly what a list scrolls.
        let x = min(max(scroll.offset - event.scrollingDeltaY * 24, 0), scroll.maxOffset)
        scrollPosition.scrollTo(x: x)
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
        movesToPane(tab)
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
            Button("Copy Path", systemImage: "document.on.document") { model.copyToPasteboard(url.path) }
        }
        if case .diff(let path, _) = tab.content {
            let url = worktree.path.appending(path: path)
            Divider()
            Button("Open File", systemImage: "doc.text") { model.openFile(url, preview: false) }
                // A deleted file has nothing to open or reveal.
                .disabled(!FileManager.default.fileExists(atPath: url.path))
            Button("Show in Finder", systemImage: "folder") { model.revealInFinder(url) }
                .disabled(!FileManager.default.fileExists(atPath: url.path))
            Button("Copy Path", systemImage: "document.on.document") { model.copyToPasteboard(url.path) }
        }
        if case .web(let url) = tab.content {
            Divider()
            Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
            Button("Copy URL", systemImage: "document.on.document") { model.copyToPasteboard(url.absoluteString) }
        }
        Divider()
        Button("Close Tab", systemImage: "xmark") { model.close(tab: tab.id) }
        let others = pane.tabs.filter { $0.id != tab.id }
        let right = pane.tabs.drop { $0.id != tab.id }.dropFirst()
        Button("Close Other Tabs") { model.close(tabs: others.map(\.id)) }
            .disabled(others.isEmpty)
        Button("Close Tabs to the Right") { model.close(tabs: right.map(\.id)) }
            .disabled(right.isEmpty)
    }

    /// One button when there is a single other pane, a submenu when there are several.
    @ViewBuilder
    private func movesToPane(_ tab: ArchipelCore.Tab) -> some View {
        let others = worktree.panes.enumerated().filter { $0.element.id != pane.id }
        if others.count == 1, let other = others.first {
            Button("Move to Other Pane", systemImage: "rectangle.righthalf.inset.filled.arrow.right") {
                model.move(tab: tab.id, toPane: other.element.id)
            }
        } else if others.count > 1 {
            Menu("Move to Pane", systemImage: "rectangle.righthalf.inset.filled.arrow.right") {
                ForEach(others, id: \.element.id) { index, other in
                    Button("Pane \(index + 1)") { model.move(tab: tab.id, toPane: other.id) }
                }
            }
        }
    }
}

private struct HorizontalScroll: Equatable {
    var offset: CGFloat = 0
    var maxOffset: CGFloat = 0
}

struct TabLabel: Equatable {
    var title: String
    /// Shown dimmed after the title when another tab has the same name.
    var subtitle: String?
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
    /// Non-nil when another tab in this pane has the same name.
    let subtitle: String?
    let isSelected: Bool
    /// Whether this tab's pane has focus; only then does the selection get glass.
    let isActive: Bool
    let width: CGFloat

    var body: some View {
        TabButtonContent(tab: tab, label: label, isSelected: isSelected, isActive: isActive, width: width)
            .equatable()
    }

    private var label: TabLabel {
        var label = baseLabel
        label.subtitle = subtitle
        return label
    }

    private var baseLabel: TabLabel {
        switch tab.content {
        case .session(let id):
            let title = session?.displayTitle ?? "Session"
            return TabLabel(
                title: title,
                symbol: (session.map { model.effectiveAgent(for: $0).adapter } ?? ShellAdapter()).symbolName,
                detail: model.sessionContexts[id].map {
                    title + "\n" + ContextFormat.summary(of: $0, cache: model.promptCaches[id], at: .now)
                },
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
            // No "(Working Tree)" suffix: the icon marks it as a diff and the diff header shows
            // the side. It just ate into the file name.
            return TabLabel(
                title: (path as NSString).lastPathComponent,
                symbol: "plus.forwardslash.minus",
                detail: path + "\n" + (staged ? "Staged changes" : "Working tree changes"),
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
    /// Incremented when the session finishes, to trigger one bounce.
    @State private var finishBounce = 0

    private static let iconSlot: CGFloat = 18
    /// The narrowest tab that still shows its badges and dev server link next to a readable title.
    private static let badgeWidth: CGFloat = 170

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tab == rhs.tab && lhs.label == rhs.label && lhs.isSelected == rhs.isSelected
            && lhs.isActive == rhs.isActive && lhs.width == rhs.width
    }

    var body: some View {
        HStack(spacing: 6) {
            leading
            title
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: Chrome.controlHeight)
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
        .onHover { hovering in
            isHovered = hovering
        }
        // SwiftUI has no middle-click gesture.
        .localEventMonitor(.otherMouseUp, while: isHovered) { event in
            guard event.buttonNumber == 2 else { return false }
            model.close(tab: tab.id)
            return true
        }
        .help(label.detail ?? label.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label.subtitle.map { "\(label.title), \($0)" } ?? label.title)
        // The label above replaces what the children would say, the dot's and the badges' included.
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("pane.tab")
        // On macOS 27.0.1 the activation point lands on the status glyph, right where the close
        // button shows up on hover, so XCUITest and VoiceOver clicks closed the tab.
        .accessibilityActivationPoint(.center)
        .accessibilityAction(.default) { model.select(tab: tab.id) }
        .accessibilityAction(named: "Close Tab") { model.close(tab: tab.id) }
    }

    private var title: some View {
        HStack(spacing: 5) {
            Text(label.title)
                .italic(tab.isPreview)
                // Not semibold for unread: bold text is wider, so the title would shift every time
                // unread toggles.
                .foregroundStyle(isSelected || label.activity?.unread == true ? .primary : .secondary)
                // Truncate the folder before the file name.
                .layoutPriority(1)
            if let subtitle = label.subtitle {
                Text(subtitle)
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var leading: some View {
        Image(symbol: label.symbol)
            .foregroundStyle(isSelected && isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .symbolEffect(.bounce, options: .nonRepeating, value: finishBounce)
            .frame(width: Self.iconSlot)
            // Only on the switch to finished. Bouncing on every status change gets noisy with a
            // few agents running.
            .onChange(of: label.activity?.status == .finished) { _, finished in
                if finished, !reduceMotion { finishBounce += 1 }
            }
    }

    /// Badges and status, pinned to the trailing edge so new badges cut into the end of the
    /// title instead of shifting it.
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
            closeSlot
        }
        .fixedSize()
    }

    /// The close button replaces the status glyph on hover, like Chrome and Xcode. The slot is
    /// reserved even when it's empty so the title doesn't get shorter on hover.
    private var closeSlot: some View {
        ZStack {
            Group {
                if let activity = label.activity {
                    StatusGlyph(activity: activity)
                } else if label.hasUnsavedChanges {
                    Image(systemName: "circle.fill")
                        .imageScale(.small)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Unsaved changes")
                }
            }
            .modifier(SwapEffect(isShown: !isHovered, reduceMotion: reduceMotion))
            Button { model.close(tab: tab.id) } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    // The whole slot is the target, not just the glyph, so a click a little off
                    // does not select the tab instead.
                    .frame(width: Self.iconSlot, height: Chrome.controlHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close Tab")
            .modifier(SwapEffect(isShown: isHovered, reduceMotion: reduceMotion))
            .onHover { isOverClose = $0 }
        }
        .frame(width: Self.iconSlot)
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

/// Approximates `.contentTransition(.symbolEffect(.replace))` with scale, blur and opacity. The real
/// thing only works between two SF Symbols, and the status can be a spinner or a dot.
private struct SwapEffect: ViewModifier {
    let isShown: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .scaleEffect(isShown || reduceMotion ? 1 : 0.5)
            .blur(radius: isShown || reduceMotion ? 0 : 2)
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

/// Only the focused pane's selected tab gets glass, like Safari's compact tabs.
/// Unfocused panes get the faint hover fill so their selection is still visible.
///
/// One view that slides under the selected tab instead of glass on every tab.
/// Per-tab glass merges with its neighbours when a tab opens or closes and
/// smears a blurry blob over their labels, which sometimes stays there.
private struct SelectionCapsule: View {
    let isActive: Bool

    var body: some View {
        Capsule()
            .fill(.quinary)
            .opacity(isActive ? 0 : 1)
            .glassEffect(isActive ? .regular : .identity, in: .capsule)
            // Over a black terminal the glass looks like a flat gray block. The hairline
            // border helps.
            .overlay {
                Capsule()
                    .strokeBorder(.separator, lineWidth: 0.5)
                    .opacity(isActive ? 1 : 0)
            }
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
    /// a preview tab, a session running a dev server and two tabs with the same file name.
    static func mixedTabs() -> Worktree {
        var worktree = PreviewFixtures.featureWorktree
        worktree.sessions.append(Session(id: serverSessionID, title: "Dev Server", hasCustomTitle: true, agent: .shell))
        let tabs = [
            ArchipelCore.Tab(content: .session(PreviewFixtures.codexSessionID)),
            ArchipelCore.Tab(content: .session(PreviewFixtures.reviewSessionID)),
            ArchipelCore.Tab(content: .file(worktree.path.appending(path: "Sources/Sync/SyncEngine.swift"))),
            ArchipelCore.Tab(content: .diff(path: "Sources/Cache/ResponseCache.swift", staged: false)),
            ArchipelCore.Tab(content: .diff(path: "Sources/Sync/SyncEngine.swift", staged: true)),
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
        model.showGitForPreview(PreviewFixtures.gitSummaries, pullRequests: PreviewFixtures.pullRequests)
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

/// Pops an AppKit menu instead of using a SwiftUI `Menu`. SwiftUI rewrites the items of an open
/// `Menu` on every render of the window, and rewriting the presets item closes its submenu. With a
/// session printing output that happens all the time, so the presets were nearly impossible to reach.
///
/// Same items as `NewSessionButtons`. Change one, change the other.
private struct NewSessionMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let worktree: Worktree.ID
    let pane: Pane.ID
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button("New Session", systemImage: "plus", action: showMenu)
            .background(MenuAnchorView(anchor: anchor))
            .help("New Session")
            .accessibilityIdentifier("pane.newSession")
    }

    private func showMenu() {
        guard let view = anchor.view else { return }
        let actions = MenuActions()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for agent in model.enabledAgents {
            let canStart = model.canStartSession(with: agent)
            let item = actions.item("New \(agent.displayName) Session", enabled: canStart) {
                model.newSession(in: worktree, agent: agent, pane: pane)
            }
            if !canStart { item.toolTip = agent.missingCommandHint }
            menu.addItem(item)
        }
        let presets = model.presetsInMenuOrder
        if !presets.isEmpty {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for entry in presets {
                submenu.addItem(actions.item("\(entry.agent.displayName): \(entry.preset.title)", enabled: model.canStartSession(with: entry.agent)) {
                    model.newSession(in: worktree, agent: entry.agent, preset: entry.preset, pane: pane)
                })
            }
            submenu.addItem(.separator())
            submenu.addItem(actions.item("Edit Presets…") {
                SettingsView.select(.agents)
                openSettings()
            })
            let presetsItem = NSMenuItem(title: "New Session with Preset", action: nil, keyEquivalent: "")
            presetsItem.submenu = submenu
            // The File menu has an item with the same title. The UI tests look this one up by identifier.
            presetsItem.identifier = NSUserInterfaceItemIdentifier("pane.newSession.presets")
            menu.addItem(.separator())
            menu.addItem(presetsItem)
        }
        // Opens below the button like a pull-down. popUp blocks until the menu closes, so `actions`
        // lives long enough.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
    }
}

/// NSMenuItem holds its target weakly, so the caller has to keep this around.
@MainActor
private final class MenuActions: NSObject {
    private var actions: [() -> Void] = []

    func item(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        item.isEnabled = enabled
        actions.append(action)
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) {
        actions[sender.tag]()
    }
}

/// Gives the menu an NSView to position itself against.
private final class MenuAnchor {
    weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }

    /// Flipped so `bounds.maxY` is the bottom edge of the button. Returns nil from hitTest so clicks
    /// go to the button.
    private final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
