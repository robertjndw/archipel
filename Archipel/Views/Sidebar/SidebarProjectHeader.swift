import ArchipelCore
import SwiftUI

/// A project's section header: its icon in the project color, its name, and at the trailing edge either
/// the add button (on hover) or, while collapsed, whatever its hidden rows would be signalling.
struct SidebarProjectHeader: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Binding var renaming: RenameTarget?
    @Environment(\.sidebarDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        let summary = attentionSummary(of: project, activities: model.activities)
        HStack(spacing: 8) {
            // The rows' icon column, so a worktree sits exactly one indent step right of its project.
            ProjectIconView(project: project, size: density.projectIconSize)
                .frame(width: SidebarWorktreeRow.iconColumnWidth)
            // Primary, unlike a plain section title: the project is an item with an icon of its
            // own, the way a project or an account heads its group in Xcode and Mail.
            Text(project.name)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("sidebar.project")
            Spacer(minLength: 4)
            trailing(summary: summary)
        }
        .padding(.vertical, density.projectHeaderPadding)
        // Section headers sit a few points further left than rows; this lines the columns up.
        .padding(.leading, SidebarWorktreeRow.headerAlignmentInset)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .animation(.smooth, value: summary)
        .accessibilityElement(children: .contain)
        .accessibilityValue(project.isExpanded ? "" : summary.accessibilityDescription)
        // VoiceOver can't hover, so it gets the add button as an action instead.
        .accessibilityAction(named: "Add Worktree") { model.addWorktreeProjectID = project.id }
        .contextMenu { menu }
        .confirmationDialog("Remove the project \(project.name)?", isPresented: $isConfirmingRemoval) {
            Button("Remove Project", role: .destructive) { model.removeProject(project) }
        } message: {
            Text(removalMessage)
        }
    }

    private var removalMessage: String {
        let sessions = project.worktrees.flatMap(\.sessions)
        let working = sessions.count { model.activity(for: $0.id).hasWorkInFlight }
        let closing = switch working {
        case 0: sessions.isEmpty ? "" : " and its sessions are closed"
        case 1: " and its sessions are closed, including an agent that is still running"
        default: " and its sessions are closed, including \(working) agents that are still running"
        }
        return "The project is removed from Archipel\(closing). Nothing is deleted from disk."
    }

    /// Both states stay in the tree, stacked in one slot and cross-faded, so the project name does
    /// not re-truncate under the pointer when the add button appears.
    private func trailing(summary: AttentionSummary) -> some View {
        ZStack(alignment: .trailing) {
            collapsedSignal(summary: summary)
                .opacity(isHovered ? 0 : 1)
            Button("Add Worktree", systemImage: "plus") { model.addWorktreeProjectID = project.id }
                // Also while hidden: full keyboard access would otherwise stop on a button nobody can see.
                .disabled(!model.isGitAvailable || !isHovered)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                // Drawn like the disclosure chevron beside it: same gray, same stroke weight, and a
                // gap so the two read as separate buttons. Gray also matches the buttons above the sidebar.
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
                .help("Add a worktree to \(project.name)")
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                // Hidden from accessibility even while hovered. Otherwise SwiftUI merges its name
                // into the title's label ("fixture, Add Worktree"). The header's action covers it.
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func collapsedSignal(summary: AttentionSummary) -> some View {
        // Expanded, the rows say all of this themselves.
        if !project.isExpanded {
            if let signal = summary.dominant {
                SidebarAttentionBadge(signal: signal)
            } else if project.worktrees.count > 1 {
                Text(project.worktrees.count, format: .number)
                    .font(.caption)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(project.worktrees.count)))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: project.worktrees.count)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("\(project.worktrees.count) worktrees")
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Add Worktree…", systemImage: "plus") { model.addWorktreeProjectID = project.id }
            .disabled(!model.isGitAvailable)
        if !project.dismissedWorktreePaths.isEmpty {
            Button("Show Dismissed Worktrees", systemImage: "eye") { model.restoreDismissedWorktrees(in: project.id) }
        }
        Divider()
        Button("Rename…", systemImage: "pencil") {
            renaming = RenameTarget(kind: .project(project.id), name: project.name)
        }
        Button("Project Settings…", systemImage: "gearshape") { model.openProjectSettings(project.id) }
        Divider()
        FolderActions(folder: project.folderURL)
        let others = model.workspace.islands.filter { $0.id != model.selectedIsland?.id }
        if !others.isEmpty {
            Divider()
            Menu("Move to Island", systemImage: "arrow.right.square") {
                ForEach(others) { island in
                    Button(island.name, systemImage: island.symbol) {
                        model.moveProject(project.id, to: island.id)
                    }
                }
            }
        }
        Divider()
        Button("Remove Project…", systemImage: "trash", role: .destructive) { isConfirmingRemoval = true }
    }
}

#if DEBUG
private enum ProjectHeaderSamples {
    static let root = PreviewFixtures.root

    static let unreadSession = Session(title: "Claude Code", agent: .claude)
    static let workingSession = Session(title: "Codex", agent: .codex)

    static let waiting = {
        var project = PreviewFixtures.appProject
        project.isExpanded = false
        return project
    }()
    static let unread = Project(
        name: "Blog",
        folderURL: root.appending(path: "blog", directoryHint: .isDirectory),
        isExpanded: false,
        worktrees: [Worktree(path: root.appending(path: "blog", directoryHint: .isDirectory), branch: "main", isMain: true, sessions: [unreadSession])],
        tint: .orange
    )
    static let working = Project(
        name: "Infra",
        folderURL: root.appending(path: "infra", directoryHint: .isDirectory),
        isExpanded: false,
        worktrees: [Worktree(path: root.appending(path: "infra", directoryHint: .isDirectory), branch: "main", isMain: true, sessions: [workingSession])],
        tint: .teal,
        icon: .symbol("server.rack")
    )
    static let quiet = Project(
        name: "Design System Tokens and Component Library",
        folderURL: root.appending(path: "tokens", directoryHint: .isDirectory),
        isExpanded: false,
        worktrees: ["main", "feat/dark-mode", "fix/contrast"].map {
            Worktree(path: root.appending(path: "tokens-\($0)", directoryHint: .isDirectory), branch: $0, isMain: $0 == "main")
        },
        tint: .purple
    )
    static let expanded = PreviewFixtures.blogProject

    static let projects = [waiting, unread, working, quiet, expanded]

    static func model() -> AppModel {
        var activities = PreviewFixtures.activities
        activities[unreadSession.id] = SessionActivity(status: .finished, unread: true, completedTurn: true)
        activities[workingSession.id] = SessionActivity(status: .working)
        return AppModel(preview: Workspace(islands: [Island(name: "Work", projects: projects)]), activities: activities)
    }
}

private struct ProjectHeadersPreview: View {
    @State private var model = ProjectHeaderSamples.model()

    var body: some View {
        List {
            ForEach(ProjectHeaderSamples.projects) { project in
                Section(isExpanded: .constant(project.isExpanded)) {
                    Text("Worktree").padding(.leading, SidebarWorktreeRow.indent)
                } header: {
                    SidebarProjectHeader(project: project, renaming: .constant(nil))
                }
            }
        }
        .listStyle(.sidebar)
        .environment(model)
    }
}

// Collapsed headers show, in order: a waiting count, an unread dot, a spinner, a worktree count.
#Preview("Comfortable") {
    ProjectHeadersPreview()
        .frame(width: 260, height: 300)
}

#Preview("Compact") {
    ProjectHeadersPreview()
        .environment(\.sidebarDensity, .compact)
        .frame(width: 260, height: 260)
}

#Preview("Spacious") {
    ProjectHeadersPreview()
        .environment(\.sidebarDensity, .spacious)
        .frame(width: 260, height: 340)
}

#Preview("Dark") {
    ProjectHeadersPreview()
        .frame(width: 260, height: 300)
        .preferredColorScheme(.dark)
}
#endif
