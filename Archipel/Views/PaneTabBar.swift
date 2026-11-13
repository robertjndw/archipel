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

    static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebarToggle {
                Button("Show Sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(.leading, 78)
                    .padding(.trailing, 4)
                    .help("Show Sidebar")
            }

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabButton(
                            tab: tab,
                            label: label(for: tab),
                            isSelected: tab.id == pane.selectedTab?.id,
                            isFocused: isFocused,
                            select: { model.select(tab: tab.id) },
                            pin: { model.pin(tab: tab.id) },
                            close: { model.close(tab: tab.id) }
                        )
                        .contextMenu { tabMenu(tab) }
                        .draggable(tab.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, at: index)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            // Dropping on the empty part of the bar appends.
            .dropDestination(for: String.self) { items, _ in
                drop(items, at: nil)
            }

            Menu {
                NewSessionButtons(worktree: worktree.id, pane: pane.id)
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 8)
            .help("New session")
            .accessibilityLabel("New session")

            if pane.id == worktree.panes.last?.id {
                let hasRunScript = model.project(ofWorktree: worktree.id)?.scripts.runCommand != nil
                Button("Run", systemImage: "play") { model.runProject(in: worktree.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(.trailing, 10)
                    .help(hasRunScript ? "Run this project's run script (⌘R)" : "Set up a run script for this project")
                Button("Toggle Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(.trailing, 10)
                    .help("Show or hide files and changes")
            }
        }
        .frame(height: Self.height)
        .background(.bar)
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
                symbol: session.flatMap { AgentDefinition.builtIn(id: $0.agent.rawValue)?.symbolName } ?? "terminal",
                detail: nil,
                activity: model.activity(for: id)
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
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
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
}

private struct TabButton: View {
    let tab: ArchipelCore.Tab
    let label: TabLabel
    let isSelected: Bool
    let isFocused: Bool
    let select: () -> Void
    let pin: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: label.symbol)
                .foregroundStyle(isSelected && isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(label.title)
                .lineLimit(1)
                .italic(tab.isPreview)
                .fontWeight(label.activity?.unread == true ? .semibold : .regular)
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
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minWidth: 96, maxWidth: 220, minHeight: 26)
        .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
        .contentShape(.rect(cornerRadius: 7))
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
