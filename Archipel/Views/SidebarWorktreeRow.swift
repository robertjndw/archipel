import AgentKit
import ArchipelCore
import SwiftUI

/// One worktree in the sidebar. Everything it shows comes from `WorktreeRowContent`; this only lays it
/// out and swaps the trailing state for a few actions while the pointer is over the row.
struct SidebarWorktreeRow: View {
    @Environment(AppModel.self) private var model
    let worktree: Worktree
    let content: WorktreeRowContent
    /// The worktree's sessions when it has several. They are part of this row, so the selection
    /// highlight holds a worktree together with what runs in it.
    let sessions: [SessionRowContent]
    let isSelected: Bool
    let tint: Color
    @Binding var deleting: Worktree?
    @Binding var renaming: RenameTarget?
    @State private var isHovered = false

    /// Icon column plus its gap, which is where the title and everything under it starts.
    private static let textInset: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: Self.textInset - 8, alignment: .center)
                    .padding(.trailing, 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(content.title)
                        .fontWeight(content.isUnread ? .semibold : .regular)
                        .truncationMode(.middle)
                    detail
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                trailing
            }
            if !sessions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(sessions) { session in
                        SidebarSessionRow(content: session, isInSelectedWorktree: isSelected, renaming: $renaming)
                    }
                }
                .padding(.leading, Self.textInset)
            }
        }
        .padding(.vertical, 6)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.2), value: content.trailing)
    }

    private var symbol: String {
        worktree.branch == nil ? "folder" : "arrow.triangle.branch"
    }

    @ViewBuilder
    private var detail: some View {
        switch content.detail {
        case .message(let message, let needsUser):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(needsUser ? AnyShapeStyle(.primary.opacity(0.75)) : AnyShapeStyle(.secondary))
                .help(message)
        case .metadata(let variants):
            // The first variant that fits wins, so the least important items disappear one by one as
            // the sidebar narrows instead of everything truncating at once.
            ViewThatFits(in: .horizontal) {
                ForEach(variants.indices, id: \.self) { index in
                    SidebarMetadataLine(items: variants[index])
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.metadataAccessibilityLabel)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isHovered {
            HStack(spacing: 2) {
                Button("New \(model.defaultAgent.displayName) Session", systemImage: "plus") {
                    model.newSession(in: worktree.id, agent: model.defaultAgent)
                }
                .help("New \(model.defaultAgent.displayName) Session")
                Menu("More", systemImage: "ellipsis") {
                    SidebarWorktreeMenu(worktree: worktree, deleting: $deleting)
                }
                .menuIndicator(.hidden)
                .help("More")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .menuStyle(.button)
            .imageScale(.small)
            .fixedSize()
        } else if case .status(let activity) = content.trailing {
            StatusGlyph(activity: activity)
        }
    }
}

/// The compact second line: pull request, line counts, files, ahead and behind, agents.
struct SidebarMetadataLine: View {
    let items: [WorktreeRowContent.MetadataItem]
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 7) {
            ForEach(items) { item in
                view(for: item)
            }
        }
        .font(.subheadline)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    /// On a selected row the background is the accent color, where green and red text would clash.
    private var isProminent: Bool { prominence == .increased }

    @ViewBuilder
    private func view(for item: WorktreeRowContent.MetadataItem) -> some View {
        switch item {
        case .pullRequest(let badge):
            Text(badge.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isProminent ? AnyShapeStyle(.primary) : AnyShapeStyle(badge.state.color))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(badge.state.color.opacity(isProminent ? 0.3 : 0.15), in: .capsule)
                .fixedSize()
        case .diff(let insertions, let deletions):
            HStack(spacing: 3) {
                if insertions > 0 {
                    Text(verbatim: "+\(insertions)")
                        .foregroundStyle(isProminent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                }
                if deletions > 0 {
                    Text(verbatim: "-\(deletions)")
                        .foregroundStyle(isProminent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
            }
            .fixedSize()
        case .changedFiles(let count):
            symbolAndCount("doc", count)
        case .aheadBehind(let ahead, let behind):
            HStack(spacing: 3) {
                if ahead > 0 { symbolAndCount("arrow.up", ahead) }
                if behind > 0 { symbolAndCount("arrow.down", behind) }
            }
        case .agents(let agents):
            HStack(spacing: 2) {
                ForEach(agents, id: \.self) { agent in
                    Image(systemName: Self.symbol(for: agent))
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                // A lone glyph on a line of its own reads as a rendering glitch, so one agent is named.
                if agents.count == 1, let name = AgentDefinition.builtIn(id: agents[0].rawValue)?.displayName {
                    Text(name).padding(.leading, 1)
                }
            }
        case .folder(let name):
            HStack(spacing: 3) {
                Image(systemName: "folder")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                Text(name)
                    .truncationMode(.middle)
            }
        }
    }

    private func symbolAndCount(_ symbol: String, _ value: Int) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(.tertiary)
            Text(value, format: .number)
        }
        .fixedSize()
    }

    static func symbol(for agent: AgentKind) -> String {
        AgentDefinition.builtIn(id: agent.rawValue)?.symbolName ?? AgentDefinition.shell.symbolName
    }
}

/// A session inside its worktree's row, shown when the worktree has more than one. A click picks the
/// session; the list itself only ever selects worktrees.
struct SidebarSessionRow: View {
    @Environment(AppModel.self) private var model
    let content: SessionRowContent
    let isInSelectedWorktree: Bool
    @Binding var renaming: RenameTarget?

    var body: some View {
        Button {
            model.select(session: content.id)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: SidebarMetadataLine.symbol(for: content.agent))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(content.title)
                    .font(.callout)
                    .fontWeight(isCurrent ? .medium : .regular)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                // A session that was never started has nothing to report; a glyph on every such
                // line would only be noise.
                if content.activity.status != .notStarted {
                    StatusGlyph(activity: content.activity)
                        .controlSize(.mini)
                        .scaleEffect(0.85)
                }
            }
            .frame(height: 24)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .contextMenu {
            Button("Show Session", systemImage: "terminal") { model.select(session: content.id) }
            Button("Rename…", systemImage: "pencil") {
                renaming = RenameTarget(kind: .session(content.id), name: content.title)
            }
            Divider()
            Button("Restart Session", systemImage: "arrow.clockwise") { model.restartSession(content.id) }
        }
    }

    private var isCurrent: Bool { isInSelectedWorktree && content.isFocused }
}

/// Shared by the row's context menu and its hover "More" button.
struct SidebarWorktreeMenu: View {
    @Environment(AppModel.self) private var model
    let worktree: Worktree
    @Binding var deleting: Worktree?

    var body: some View {
        NewSessionButtons(worktree: worktree.id)
        Divider()
        let project = model.project(ofWorktree: worktree.id)
        Button("Run", systemImage: "play") { model.runProject(in: worktree.id) }
        if project?.scripts.setupCommand != nil {
            Button("Run Setup Script", systemImage: "wrench.and.screwdriver") { model.startScript(.setup, in: worktree.id) }
        }
        Divider()
        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([worktree.path])
        }
        Button("Open in Terminal", systemImage: "apple.terminal") { model.openInTerminal(worktree.path) }
        Button("Copy Path", systemImage: "document.on.document") { model.copyToPasteboard(worktree.path.path) }
        if let branch = worktree.branch {
            Button("Copy Branch Name", systemImage: "arrow.triangle.branch") { model.copyToPasteboard(branch) }
        }
        if attentionSummary(of: worktree, activities: model.activities).unread > 0 {
            Divider()
            Button("Mark as Read", systemImage: "envelope.open") { model.markRead(worktree: worktree.id) }
        }
        if let project {
            Divider()
            Button("Project Settings…", systemImage: "gearshape") { model.openProjectSettings(project.id) }
        }
        if !worktree.isMain {
            Divider()
            Button("Remove from Sidebar", systemImage: "minus.circle") {
                model.removeWorktree(worktree.id, deleteFromDisk: false)
            }
            Button("Delete Worktree…", systemImage: "trash", role: .destructive) { deleting = worktree }
        }
    }
}

extension PullRequestBadge.State {
    var color: Color {
        switch self {
        case .open: .green
        case .draft: .gray
        case .merged: .purple
        case .closed: .red
        }
    }
}
