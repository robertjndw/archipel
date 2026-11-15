import AgentKit
import ArchipelCore
import EditorUI
import InspectorUI
import SwiftUI

/// The tab row of one pane. With the window's own title bar gone this is the
/// top edge of the content area, so the first and last pane also carry the
/// controls that would otherwise sit in a toolbar.
struct PaneTabBar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showInspector") private var showInspector = true
    let worktree: Worktree
    let pane: Pane
    let isFocused: Bool
    /// Set on the first pane while the sidebar is collapsed: the window
    /// buttons then sit over this bar and need room.
    let showsSidebarToggle: Bool
    let toggleSidebar: () -> Void
    @State private var renaming: RenameTarget?
    @State private var dropSlot: Int?

    static let height: CGFloat = 36
    /// Slight bounce so the selection settles onto the new tab, close to Safari.
    private static let motion = Animation.spring(duration: 0.35, bounce: 0.18)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// With one pane there is nothing to tell apart, so it always reads as active.
    private var isActive: Bool { isFocused || worktree.panes.count == 1 }

    var body: some View {
        HStack(spacing: 6) {
            if showsSidebarToggle {
                GlassToolbarGroup {
                    Button("Show Sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                        .help("Show Sidebar")
                }
                // Leaves the window buttons their corner.
                .padding(.leading, 78)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabButton(
                                tab: tab,
                                label: label(for: tab),
                                isSelected: tab.id == pane.selectedTab?.id,
                                isActive: isActive,
                                select: { model.select(tab: tab.id) },
                                pin: { model.pin(tab: tab.id) },
                                close: { model.close(tab: tab.id) }
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
                    .animation(reduceMotion ? nil : Self.motion, value: pane.tabs.map(\.id))
                    .animation(reduceMotion ? nil : Self.motion, value: pane.selectedTab?.id)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isActive)
                    // The scroll view clips, so the glass shadow needs room inside it.
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                }
                // .hidden still shows a scroller when the system is set to always show them.
                .scrollIndicators(.never)
                // Selecting a tab from elsewhere (Ctrl-Tab, the palette, a notification) can pick one
                // scrolled out of view; without this the bar shows no selection at all.
                .onChange(of: pane.selectedTab?.id) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : Self.motion) { proxy.scrollTo(id) }
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

            GlassToolbarGroup {
                Menu {
                    NewSessionButtons(worktree: worktree.id, pane: pane.id)
                } label: {
                    Image(systemName: "plus")
                }
                .toolbarGroupMenu()
                .help("New session")
                .accessibilityLabel("New session")

                if pane.id == worktree.panes.last?.id {
                    // Only once there is something to run. Setting a script up is rare and lives in
                    // the project settings; ⌘R still leads there.
                    if model.project(ofWorktree: worktree.id)?.scripts.runCommand != nil {
                        Button("Run", systemImage: "play") { model.runProject(in: worktree.id) }
                            .help("Run this project's run script (⌘R)")
                    }
                    Button("Toggle Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                        .help("Show or hide files and changes")
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: Self.height)
        .background(.windowBackground)
        .overlay(alignment: .bottom) { Divider() }
        .renameAlert($renaming)
    }

    private func drop(_ items: [String], at index: Int?) -> Bool {
        guard let id = items.first.flatMap(UUID.init(uuidString:)), model.workspace.tab(id: id) != nil else { return false }
        model.move(tab: id, toPane: pane.id, at: index)
        return true
    }

    private func label(for tab: ArchipelCore.Tab) -> TabLabel {
        switch tab.content {
        case .session(let id):
            let session = worktree.sessions.first { $0.id == id }
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
        }
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
            Button("Rename…", systemImage: "pencil") {
                renaming = RenameTarget(kind: .session(id), name: session.displayTitle)
            }
            Button("Restart", systemImage: "arrow.clockwise") { model.restartSession(id) }
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
        Divider()
        Button("Close Tab", systemImage: "xmark", role: .destructive) { model.close(tab: tab.id) }
    }
}

struct TabLabel {
    var title: String
    var symbol: String
    /// Shown as the tooltip.
    var detail: String?
    var activity: SessionActivity?
    var hasUnsavedChanges = false
    var devServers: [DevServerLink] = []
}

private struct TabButton: View {
    let tab: ArchipelCore.Tab
    let label: TabLabel
    let isSelected: Bool
    /// Whether this tab's pane has focus; only then does the selection get glass.
    let isActive: Bool
    let select: () -> Void
    let pin: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(symbol: label.symbol)
                .foregroundStyle(isSelected && isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(label.title)
                .lineLimit(1)
                .italic(tab.isPreview)
                .fontWeight(label.activity?.unread == true ? .semibold : .regular)
                .foregroundStyle(isSelected && isActive ? .primary : .secondary)
            if !label.devServers.isEmpty {
                DevServerPill(links: label.devServers)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            SubagentBadge(count: label.activity?.subagents.count ?? 0)
            // The close button takes the status glyph's place on hover, so
            // tabs do not change width under the pointer.
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
                .opacity(isHovering ? 0 : 1)
                Button("Close Tab", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .imageScale(.small)
                    .opacity(isHovering ? 1 : 0)
            }
            .frame(width: 18)
        }
        .animation(.snappy(duration: 0.25), value: label.devServers)
        .animation(.snappy(duration: 0.25), value: label.activity?.subagents.count)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minWidth: 96, maxWidth: 220, minHeight: Chrome.controlHeight)
        .background {
            if isHovering && !isSelected {
                Capsule().fill(.quinary)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .contentShape(.capsule)
        .gesture(TapGesture(count: 2).onEnded(pin))
        .simultaneousGesture(TapGesture().onEnded(select))
        .onHover { isHovering = $0 }
        .help(label.detail ?? label.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}

/// The focused pane's selected tab is the one piece of glass in the row,
/// like Safari's compact tabs. An unfocused pane falls back to a flat fill,
/// which is what tells the panes apart at a glance.
///
/// One view that slides under the selected tab instead of glass on every tab.
/// Per-tab glass merged with its neighbours when a tab was opened or closed,
/// which smeared a blurry blob over their labels and sometimes left it there.
private struct SelectionCapsule: View {
    let isActive: Bool

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .opacity(isActive ? 0 : 1)
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
