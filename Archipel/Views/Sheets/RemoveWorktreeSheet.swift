import ArchipelCore
import EditorUI
import GitKit
import SwiftUI

/// Takes a worktree out of the sidebar, optionally deleting its folder and branch. A sheet rather than
/// a confirmation dialog because the choices are checkboxes.
struct RemoveWorktreeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let worktree: Worktree

    @State private var deleteFolder = false
    @State private var deleteBranch = false
    @State private var changeCount: Int?
    @State private var isWorking = false
    @State private var failure: String?
    @State private var outcome: AppModel.BranchRemoval?

    private var isMissing: Bool { model.missingWorktrees.contains(worktree.id) }
    /// A missing folder that may only be out of reach, on a volume that is not mounted. Looked up
    /// once in `loadStatus()`, because telling the two apart touches the disk.
    @State private var isUnavailable = false
    private var deletesFromDisk: Bool { deleteFolder && !isMissing }
    private var lostChanges: Int { deletesFromDisk ? changeCount ?? 0 : 0 }

    /// Removing closes the worktree's sessions and tabs whether or not the folder is deleted.
    private var warnings: [String] {
        var warnings: [String] = []
        let busy = model.busySessionCount(in: worktree.id)
        if busy > 0 {
            warnings.append(busy == 1
                ? "An agent is working in this worktree. Removing it stops that agent."
                : "\(busy) agents are working in this worktree. Removing it stops them.")
        }
        let idle = worktree.sessions.count - busy
        if idle > 0 {
            // "Other" only reads right after the line about the busy ones.
            let other = busy > 0 ? "other " : ""
            warnings.append(idle == 1 ? "Its \(other)session is closed too." : "Its \(idle) \(other)sessions are closed too.")
        }
        if deletesFromDisk, worktree.branch == nil {
            warnings.append("This worktree is on a detached HEAD. Commits made here are not on any branch, and are only reachable through the reflog once the folder is deleted.")
        }
        let unsaved = model.unsavedDocuments(under: worktree.path).count
        if unsaved > 0 {
            // What `AppModel.removeWorktree` does with them: edits to files that are deleted or
            // already gone are dropped, edits to files that stay are kept for Save All and the
            // prompt at quit.
            let count = unsaved == 1 ? "1 file has unsaved changes in the editor." : "\(unsaved) files have unsaved changes in the editor."
            let fate = if deletesFromDisk {
                "Deleting the folder discards them."
            } else if isMissing, !isUnavailable {
                "The folder is gone, so removing the worktree discards them."
            } else {
                "Their tabs close, but the changes are kept until you save them with Save All or quit."
            }
            warnings.append("\(count) \(fate)")
        }
        return warnings
    }

    var body: some View {
        Form {
            if let note {
                Label(note, systemImage: "info.circle")
            } else {
                options
                if !warnings.isEmpty {
                    Section {
                        ForEach(warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .navigationTitle("Remove \(worktree.displayName)")
        .toolbar {
            if note != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                // Done is the only button and takes Return. Escape needs one of its own, which
                // does not have to be seen to work.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            } else {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .untinted()
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) { confirmButton }
                if isWorking {
                    ToolbarItem(placement: .status) { ProgressView().controlSize(.small) }
                }
            }
        }
        // Closing mid-removal would lose the outcome, such as a branch that was kept.
        .interactiveDismissDisabled(isWorking)
        .task { await loadStatus() }
    }

    @ViewBuilder
    private var options: some View {
        if isMissing {
            Section {
                Label(
                    isUnavailable
                        ? "The folder cannot be reached right now. It may be on a volume that is not connected."
                        : "The folder is already gone, so there is nothing to delete from disk.",
                    systemImage: "questionmark.folder"
                )
                .foregroundStyle(.secondary)
            } footer: {
                Text(isUnavailable
                    ? "Removing it closes its sessions and takes it out of the sidebar. The worktree itself is left as it is, and you can add it back from Add Worktree once the folder is reachable."
                    : "Removing it closes its sessions and takes it out of the sidebar.")
            }
        } else {
            Section {
                Toggle(isOn: $deleteFolder) {
                    Text("Also delete the folder from disk")
                    Text(worktree.path.abbreviatedPath)
                }
                if let branch = worktree.branch {
                    Toggle("Also delete the branch \(branch)", isOn: $deleteBranch)
                        .padding(.leading, 20)
                        .disabled(!deleteFolder)
                }
                if lostChanges > 0 {
                    Label(
                        lostChanges == 1 ? "1 uncommitted change will be lost" : "\(lostChanges) uncommitted changes will be lost",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                }
            } footer: {
                if !deleteFolder {
                    Text("The folder and branch stay on disk. You can add the worktree back from Add Worktree.")
                } else if worktree.branch != nil {
                    Text("The branch is kept unless git finds it fully merged, which includes being pushed to its upstream.")
                }
            }
        }
    }

    // Return only ever takes the safe path: the default action is dropped once the button deletes.
    @ViewBuilder
    private var confirmButton: some View {
        if deletesFromDisk {
            Button("Delete", role: .destructive) { Task { await remove() } }
                .disabled(isWorking)
        } else {
            Button("Remove") { Task { await remove() } }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
        }
    }

    /// Shown instead of the options once the worktree is gone but something is left to report.
    private var note: String? {
        switch outcome {
        case .keptUnmerged(let branch):
            "The worktree was removed. The branch \(branch) was kept because it has commits that are not merged or pushed."
        case .failed(let branch, let message):
            "The worktree was removed, but the branch \(branch) could not be deleted: \(message)"
        default:
            nil
        }
    }

    private func loadStatus() async {
        isUnavailable = isMissing && !AppModel.isDeletedWorktree(worktree.path)
        // Without git there is nothing to count, and asking would bring up the system's offer to install it.
        guard !isMissing, model.isGitAvailable, let status = try? await model.git.status(in: worktree.path) else { return }
        changeCount = Set((status.staged + status.unstaged).map(\.path)).count
    }

    private func remove() async {
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            let result = try await model.removeWorktree(
                worktree.id,
                deleteFolder: deletesFromDisk,
                deleteBranch: deletesFromDisk && deleteBranch ? worktree.branch : nil,
                force: lostChanges > 0
            )
            switch result {
            case .keptUnmerged, .failed: outcome = result
            default: dismiss()
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}

#if DEBUG
extension RemoveWorktreeSheet {
    /// The fixture folders do not exist, so `loadStatus()` finds nothing and the count has to be given.
    fileprivate init(
        previewing worktree: Worktree,
        deleteFolder: Bool = false,
        deleteBranch: Bool = false,
        changeCount: Int? = nil,
        outcome: AppModel.BranchRemoval? = nil
    ) {
        self.worktree = worktree
        _deleteFolder = State(initialValue: deleteFolder)
        _deleteBranch = State(initialValue: deleteBranch)
        _changeCount = State(initialValue: changeCount)
        _outcome = State(initialValue: outcome)
    }
}

#Preview("Keep folder") {
    RemoveWorktreeSheet(worktree: PreviewFixtures.featureWorktree)
        .environment(AppModel.preview())
}

#Preview("Delete folder and branch, clean") {
    RemoveWorktreeSheet(previewing: PreviewFixtures.featureWorktree, deleteFolder: true, deleteBranch: true, changeCount: 0)
        .environment(AppModel.preview())
}

#Preview("Delete folder, uncommitted changes") {
    RemoveWorktreeSheet(previewing: PreviewFixtures.featureWorktree, deleteFolder: true, changeCount: 7)
        .environment(AppModel.preview())
}

#Preview("Folder already gone") {
    let model = AppModel.preview()
    model.missingWorktrees = [PreviewFixtures.fixWorktreeID]
    return RemoveWorktreeSheet(worktree: PreviewFixtures.fixWorktree)
        .environment(model)
}

#Preview("Branch kept, not merged") {
    RemoveWorktreeSheet(previewing: PreviewFixtures.featureWorktree, outcome: .keptUnmerged("feat/offline-mode"))
        .environment(AppModel.preview())
}
#endif
