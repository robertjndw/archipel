import ArchipelCore
import SwiftUI

/// A project's section header: its icon in the project color, its name, and at the trailing edge either
/// the add button (on hover) or, while collapsed, whatever its hidden rows would be signalling.
struct SidebarProjectHeader: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Binding var renaming: RenameTarget?
    @Binding var addingWorktreeTo: Project?
    @State private var isHovered = false

    var body: some View {
        let summary = attentionSummary(of: project, activities: model.activities)
        let tint = model.tint(of: project).color
        HStack(spacing: 8) {
            ProjectIconView(project: project, size: 20)
            // Primary, unlike a plain section title: the project is an item with an icon of its
            // own, the way a project or an account heads its group in Xcode and Mail.
            Text(project.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            trailing(summary: summary, tint: tint)
        }
        // Room above, so each project reads as a group of its own.
        .padding(.top, 8)
        .padding(.bottom, 4)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.2), value: isHovered)
        .animation(.smooth, value: summary)
        .accessibilityElement(children: .contain)
        .accessibilityValue(project.isExpanded ? "" : summary.accessibilityDescription)
        .contextMenu { menu }
    }

    @ViewBuilder
    private func trailing(summary: AttentionSummary, tint: Color) -> some View {
        if isHovered {
            Button("Add Worktree", systemImage: "plus") { addingWorktreeTo = project }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Add a worktree to \(project.name)")
        } else if !project.isExpanded {
            // Expanded, the rows say all of this themselves.
            if let signal = summary.dominant {
                SidebarAttentionBadge(signal: signal, tint: tint)
            } else if project.worktrees.count > 1 {
                Text(project.worktrees.count, format: .number)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("\(project.worktrees.count) worktrees")
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Add Worktree…", systemImage: "plus") { addingWorktreeTo = project }
        if !project.dismissedWorktreePaths.isEmpty {
            Button("Show Dismissed Worktrees", systemImage: "eye") { model.restoreDismissedWorktrees(in: project.id) }
        }
        Divider()
        Button("Rename…", systemImage: "pencil") {
            renaming = RenameTarget(kind: .project(project.id), name: project.name)
        }
        Button("Project Settings…", systemImage: "gearshape") { model.openProjectSettings(project.id) }
        Divider()
        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
        }
        Button("Open in Terminal", systemImage: "apple.terminal") { model.openInTerminal(project.folderURL) }
        Button("Copy Path", systemImage: "document.on.document") { model.copyToPasteboard(project.folderURL.path) }
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
        Button("Remove Project", systemImage: "trash", role: .destructive) { model.removeProject(project) }
    }
}
