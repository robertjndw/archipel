import ArchipelCore
import GitKit
import SwiftUI

/// Adds a worktree to a project: on a new branch, on an existing branch, or
/// by picking up a worktree that already exists on disk.
struct WorktreeSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case newBranch = "New Branch"
        case existingBranch = "Existing Branch"
        case existingWorktree = "Existing Worktree"

        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var mode = Mode.newBranch
    @State private var newBranch = ""
    @State private var branches: [String] = []
    @State private var existingBranch = ""
    @State private var worktrees: [GitWorktreeEntry] = []
    @State private var existingWorktree: URL?
    @State private var isRepository = true
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        Form {
            if isRepository {
                Picker("Add", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch mode {
                case .newBranch:
                    TextField("Branch", text: $newBranch, prompt: Text("feature/my-change"))
                    Text("Creates the branch from the current HEAD in a new folder under ~/.archipel/worktrees.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .existingBranch:
                    if branches.isEmpty {
                        Text("Every local branch is already checked out in a worktree.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Branch", selection: $existingBranch) {
                            ForEach(branches, id: \.self) { Text($0).tag($0) }
                        }
                    }
                case .existingWorktree:
                    if worktrees.isEmpty {
                        Text("This repository has no other worktrees.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Worktree", selection: $existingWorktree) {
                            ForEach(worktrees, id: \.path) { entry in
                                Text("\(entry.branch ?? "detached") (\(entry.path.lastPathComponent))")
                                    .tag(Optional(entry.path))
                            }
                        }
                    }
                }
            } else {
                Label("\(project.name) is not a git repository, so it cannot have worktrees.", systemImage: "exclamationmark.triangle")
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await add() } }
                    .disabled(!canAdd || isWorking)
            }
        }
        .task { await load() }
    }

    private var trimmedBranch: String {
        newBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        guard isRepository else { return false }
        return switch mode {
        case .newBranch: !trimmedBranch.isEmpty
        case .existingBranch: !existingBranch.isEmpty
        case .existingWorktree: existingWorktree != nil
        }
    }

    private func load() async {
        isRepository = await model.git.isRepository(project.folderURL)
        guard isRepository else { return }
        do {
            let all = try await model.git.worktrees(of: project.folderURL)
            let checkedOut = Set(all.compactMap(\.branch))
            branches = try await model.git.localBranches(in: project.folderURL).filter { !checkedOut.contains($0) }
            existingBranch = branches.first ?? ""
            worktrees = try await model.availableWorktrees(for: project)
            existingWorktree = worktrees.first?.path
        } catch {
            failure = error.localizedDescription
        }
    }

    private func add() async {
        isWorking = true
        defer { isWorking = false }
        do {
            switch mode {
            case .newBranch:
                try await model.createWorktree(in: project, branch: trimmedBranch, createBranch: true)
            case .existingBranch:
                try await model.createWorktree(in: project, branch: existingBranch, createBranch: false)
            case .existingWorktree:
                guard let entry = worktrees.first(where: { $0.path == existingWorktree }) else { return }
                model.addExistingWorktree(entry, to: project.id)
            }
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
