import ArchipelCore
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
    private var deletesFromDisk: Bool { deleteFolder && !isMissing }
    private var lostChanges: Int { deletesFromDisk ? changeCount ?? 0 : 0 }

    var body: some View {
        Form {
            if let note {
                Label(note, systemImage: "info.circle")
            } else {
                options
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
            } else {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) { confirmButton }
                if isWorking {
                    ToolbarItem(placement: .status) { ProgressView().controlSize(.small) }
                }
            }
        }
        .task { await loadStatus() }
    }

    @ViewBuilder
    private var options: some View {
        if isMissing {
            Section {
                Label("The folder is already gone, so there is nothing to delete from disk.", systemImage: "questionmark.folder")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Removing it closes its sessions and takes it out of the sidebar.")
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
                    Text("The folder and branch stay on disk. You can add the worktree back from Add Worktree > Existing Worktree.")
                } else if worktree.branch != nil {
                    Text("A branch with commits that are not merged is kept.")
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
            "The worktree was removed. The branch \(branch) was kept because it has commits that are not merged."
        case .failed(let branch, let message):
            "The worktree was removed, but the branch \(branch) could not be deleted: \(message)"
        default:
            nil
        }
    }

    private func loadStatus() async {
        guard !isMissing, let status = try? await model.git.status(in: worktree.path) else { return }
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
