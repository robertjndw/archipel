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
    @Binding var removing: Worktree?
    @Binding var renaming: RenameTarget?
    @Environment(\.sidebarDensity) private var density
    @State private var isHovered = false

    /// Icon column plus its gap, which is where the title and everything under it starts.
    private static let textInset: CGFloat = 28
    static let iconColumnWidth: CGFloat = textInset - 8
    /// How much further left the list places a section header's content than a row's.
    static let headerAlignmentInset: CGFloat = 3
    /// Worktrees step in from their project, the way Mail nests mailboxes under an account. Only the
    /// content moves; the selection highlight keeps the full width, as it does in Mail. At this step a
    /// worktree's icon starts where its project's tile ends.
    static let indent: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: density.lineSpacing + 1) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                icon
                    .frame(width: Self.iconColumnWidth, alignment: .center)
                    .padding(.trailing, 8)
                VStack(alignment: .leading, spacing: density.lineSpacing) {
                    Text(content.title)
                        .fontWeight(content.isUnread ? .semibold : .regular)
                        .truncationMode(.middle)
                        .lineLimit(1)
                    if density.showsSecondLine {
                        detail
                    }
                }
                // In a compact row the title shares its line with the metadata and wins.
                .layoutPriority(1)
                Spacer(minLength: 6)
                if !density.showsSecondLine, !isMissing {
                    inlineMetadata
                }
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
        .padding(.leading, Self.indent)
        .padding(.vertical, density.rowPadding)
        .help(hiddenMessage ?? "")
        .opacity(isMissing ? 0.6 : 1)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.2), value: content.trailing)
        .statusGlow(model.statusPulses[worktree.id])
    }

    private var isMissing: Bool { model.missingWorktrees.contains(worktree.id) }

    /// The agent's logo when one session runs here, otherwise what the worktree is: a branch or a
    /// plain folder. Logos keep their own color; the glyphs take the project's.
    private var icon: some View {
        Group {
            if let agent = content.agent {
                Image(symbol: agent.definition.symbolName)
                    .accessibilityLabel(agent.definition.displayName)
            } else {
                Image(systemName: worktree.branch == nil ? "folder" : "arrow.triangle.branch")
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(tint)
    }

    /// A compact row has no line for the agent's message, so the pointer brings it up instead.
    private var hiddenMessage: String? {
        guard !density.showsSecondLine, case .message(let message, _) = content.detail else { return nil }
        return message
    }

    /// The compact row's metadata, after the title. Without room for even the sparsest variant it
    /// steps aside rather than squeezing the branch name.
    @ViewBuilder
    private var inlineMetadata: some View {
        let variants = content.metadataVariants
        if !variants.isEmpty, !isHovered {
            ViewThatFits(in: .horizontal) {
                ForEach(variants.indices, id: \.self) { index in
                    SidebarMetadataLine(items: variants[index])
                }
                Color.clear.frame(width: 0, height: 0)
            }
            .padding(.trailing, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.metadataAccessibilityLabel)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if isMissing {
            Text("Folder missing")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            contentDetail
        }
    }

    @ViewBuilder
    private var contentDetail: some View {
        switch content.detail {
        case .message(let message, let needsUser):
            Text(message)
                .font(.subheadline)
                .lineLimit(density.messageLineLimit)
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
            .lineLimit(1)
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
                    SidebarWorktreeMenu(worktree: worktree, removing: $removing)
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
                    .help(help(for: item))
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

    /// The numbers alone are cryptic, so each item explains itself on hover.
    private func help(for item: WorktreeRowContent.MetadataItem) -> String {
        switch item {
        case .pullRequest(let badge):
            badge.title
        case .diff(let insertions, let deletions):
            "\(insertions) \(insertions == 1 ? "line" : "lines") added, \(deletions) removed, not committed yet"
        case .changedFiles(let count):
            count == 1 ? "1 file with uncommitted changes" : "\(count) files with uncommitted changes"
        case .aheadBehind(let ahead, let behind):
            [
                ahead > 0 ? "\(ahead) \(ahead == 1 ? "commit" : "commits") to push" : nil,
                behind > 0 ? "\(behind) \(behind == 1 ? "commit" : "commits") to pull" : nil,
            ].compactMap { $0 }.joined(separator: ", ")
        case .folder(let name):
            "Folder \(name)"
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
}

/// A session inside its worktree's row, shown when the worktree has more than one. A click picks the
/// session; the list itself only ever selects worktrees.
struct SidebarSessionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(SidebarPeekModel.self) private var peek: SidebarPeekModel?
    let content: SessionRowContent
    let isInSelectedWorktree: Bool
    @Binding var renaming: RenameTarget?
    @Environment(\.sidebarDensity) private var density

    var body: some View {
        Button {
            model.select(session: content.id)
        } label: {
            HStack(spacing: 7) {
                Image(symbol: content.agent.definition.symbolName)
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
                SubagentBadge(count: content.activity.subagents.count)
                if content.activity.status != .notStarted {
                    StatusGlyph(activity: content.activity)
                        .controlSize(.mini)
                        .scaleEffect(0.85)
                }
            }
            .frame(height: density.sessionRowHeight)
            .animation(.snappy(duration: 0.25), value: content.activity.subagents.count)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { peek?.hover(session: content.id, $0) }
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
    @Binding var removing: Worktree?

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
        if let editor = model.preferredEditor {
            Button("Open in \(editor.name)", systemImage: "chevron.left.forwardslash.chevron.right") { model.openInEditor(worktree.path) }
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
        Divider()
        if worktree.isMain {
            Button("Primary Checkout Can't Be Removed", systemImage: "lock") {}
                .disabled(true)
        } else {
            Button("Remove Worktree…", systemImage: "minus.circle") { removing = worktree }
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
