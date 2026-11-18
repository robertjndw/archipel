import ArchipelCore
import GitKit
import SwiftUI

/// The quiet last row of a project: worktrees git knows about that the sidebar does not show yet. It
/// has no tag, so the list never selects it.
struct DetectedWorktreesRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let entries: [GitWorktreeEntry]
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label(
                entries.count == 1 ? "1 more worktree on disk" : "\(entries.count) more worktrees on disk",
                systemImage: "plus.rectangle.on.folder"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, SidebarWorktreeRow.indent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .selectionDisabled()
        .popover(isPresented: $isPresented, arrowEdge: .trailing) { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(entries, id: \.path) { entry in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.branch ?? "detached")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(entry.path.abbreviatedPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 12)
                    Button("Add") { model.addExistingWorktrees([entry], to: project.id) }
                    Button("Don't suggest this worktree again", systemImage: "xmark") {
                        model.dismissSuggestedWorktree(entry, in: project.id)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Don't suggest this worktree again")
                }
            }
            if entries.count > 1 {
                Divider()
                Button("Add All") { model.addExistingWorktrees(entries, to: project.id) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

#if DEBUG
#Preview {
    let worktrees = PreviewFixtures.root.appending(path: "orbit-worktrees", directoryHint: .isDirectory)
    let one = [GitWorktreeEntry(path: worktrees.appending(path: "spike-graphql", directoryHint: .isDirectory), branch: "spike/graphql", isMain: false)]
    let several = one + [
        GitWorktreeEntry(
            path: worktrees.appending(path: "refactor-sync", directoryHint: .isDirectory),
            branch: "refactor/sync-engine-conflict-resolution-for-offline-edits", isMain: false
        ),
        GitWorktreeEntry(path: worktrees.appending(path: "detached", directoryHint: .isDirectory), branch: nil, isMain: false),
    ]
    List {
        Section("One") {
            DetectedWorktreesRow(project: PreviewFixtures.appProject, entries: one)
        }
        Section("Several (click for the list)") {
            DetectedWorktreesRow(project: PreviewFixtures.appProject, entries: several)
        }
    }
    .listStyle(.sidebar)
    .frame(width: 260, height: 200)
    .environment(AppModel.preview())
}
#endif
