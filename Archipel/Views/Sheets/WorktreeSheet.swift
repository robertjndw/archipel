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
    @State private var allBranches: Set<String> = []
    @State private var nameProblem: NameProblem?
    @State private var existingBranch = ""
    @State private var worktrees: [GitWorktreeEntry] = []
    @State private var existingWorktree: URL?
    @State private var isRepository = true
    @State private var isWorking = false
    @State private var failure: String?
    /// Off only for previews, which fill the form themselves and have no repository to ask.
    private var asksGit = true

    var body: some View {
        VStack(spacing: 0) {
            // Above the form rather than in it, as in Project Settings. Inside a grouped form the
            // picker gets a row background around it.
            if isRepository {
                Picker("Add", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                // Large draws as a capsule on macOS 26+, matching the app's other pill-shaped switchers.
                .controlSize(.large)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            form
        }
        .frame(width: 460)
        .navigationTitle("Add Worktree")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await add() } }
                    .disabled(!canAdd || isWorking)
            }
        }
        .task { if asksGit { await load() } }
    }

    private var form: some View {
        Form {
            if isRepository {
                switch mode {
                case .newBranch:
                    Section {
                        TextField("Branch", text: $newBranch, prompt: Text("feature/my-change"))
                        if let nameProblem {
                            nameProblemRow(nameProblem)
                        }
                    } footer: {
                        Text(newBranchFooter)
                    }
                    .task(id: trimmedBranch) { if asksGit { await checkNewBranch() } }
                    // A git error from the last attempt is about the old name.
                    .onChange(of: trimmedBranch) { failure = nil }
                case .existingBranch:
                    if branches.isEmpty {
                        Text("Every local branch is already checked out in a worktree.")
                            .foregroundStyle(.secondary)
                    } else {
                        Section {
                            Picker("Branch", selection: $existingBranch) {
                                ForEach(branches, id: \.self) { Text($0).tag($0) }
                            }
                        } footer: {
                            Text("Checks the branch out in a new folder in \(destinationFolder).")
                        }
                    }
                case .existingWorktree:
                    if worktrees.isEmpty {
                        Text("This repository has no other worktrees.")
                            .foregroundStyle(.secondary)
                    } else {
                        Section {
                            Picker("Worktree", selection: $existingWorktree) {
                                ForEach(worktrees, id: \.path) { entry in
                                    Text("\(entry.branch ?? "detached") (\(entry.path.lastPathComponent))")
                                        .tag(Optional(entry.path))
                                }
                            }
                        } footer: {
                            Text("Adds a worktree that already exists on disk. Nothing is moved or copied.")
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
    }

    private var trimmedBranch: String {
        newBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var newBranchFooter: String {
        let base = project.baseBranch.map { "\($0)" } ?? "the current HEAD"
        let path = model.worktreePath(for: project, branch: trimmedBranch.isEmpty ? "branch-name" : trimmedBranch)
        return "Creates the branch from \(base) in a new folder at \(path.abbreviatedPath)."
    }

    private var destinationFolder: String {
        model.worktreesFolder(for: project).abbreviatedPath
    }

    private var canAdd: Bool {
        guard isRepository else { return false }
        return switch mode {
        // The prefilled prefix alone is not a branch name yet.
        case .newBranch: !trimmedBranch.isEmpty && trimmedBranch != model.settings.branchPrefix && nameProblem == nil
        case .existingBranch: !existingBranch.isEmpty
        case .existingWorktree: existingWorktree != nil
        }
    }

    private func load() async {
        if newBranch.isEmpty { newBranch = model.settings.branchPrefix }
        isRepository = await model.git.isRepository(project.folderURL)
        guard isRepository else { return }
        do {
            try await loadBranches()
            existingBranch = branches.first ?? ""
            worktrees = try await model.availableWorktrees(for: project)
            existingWorktree = worktrees.first?.path
        } catch {
            failure = error.localizedDescription
        }
    }

    enum NameProblem: Equatable {
        case invalid
        /// The branch exists; `available` is false when it is already checked out in a worktree.
        case exists(available: Bool)
    }

    @ViewBuilder
    private func nameProblemRow(_ problem: NameProblem) -> some View {
        switch problem {
        case .invalid:
            Label("Not a valid branch name. Branch names cannot contain spaces or ~ ^ : ? * [ \\ and cannot start with a dash.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .exists(available: true):
            HStack {
                Label("A branch with this name already exists.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Spacer()
                Button("Use Existing Branch") {
                    existingBranch = trimmedBranch
                    mode = .existingBranch
                }
            }
        case .exists(available: false):
            Label("A branch with this name already exists and is checked out in another worktree.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    /// Checked while typing, so a bad name shows up before Add is pressed instead of as a git error.
    private func checkNewBranch() async {
        let name = trimmedBranch
        guard !name.isEmpty, name != model.settings.branchPrefix else {
            nameProblem = nil
            return
        }
        if allBranches.contains(name) {
            nameProblem = .exists(available: branches.contains(name))
            return
        }
        // Debounced: one round of git calls per pause in typing, not per keystroke.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        // Reloaded because branches made in a terminal while the sheet is open count too.
        try? await loadBranches()
        let isValid = await model.git.isValidBranchName(name, in: project.folderURL)
        guard !Task.isCancelled else { return }
        if allBranches.contains(name) {
            nameProblem = .exists(available: branches.contains(name))
        } else {
            nameProblem = isValid ? nil : .invalid
        }
    }

    private func loadBranches() async throws {
        let all = try await model.git.worktrees(of: project.folderURL)
        let checkedOut = Set(all.compactMap(\.branch))
        let local = try await model.git.localBranches(in: project.folderURL)
        allBranches = Set(local)
        branches = local.filter { !checkedOut.contains($0) }
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
                model.addExistingWorktrees([entry], to: project.id)
            }
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

#if DEBUG
extension WorktreeSheet {
    fileprivate init(
        previewing project: Project,
        mode: Mode = .newBranch,
        newBranch: String = "",
        nameProblem: NameProblem? = nil,
        branches: [String] = [],
        worktrees: [GitWorktreeEntry] = [],
        isRepository: Bool = true,
        failure: String? = nil
    ) {
        self.project = project
        asksGit = false
        _mode = State(initialValue: mode)
        _newBranch = State(initialValue: newBranch)
        _nameProblem = State(initialValue: nameProblem)
        _branches = State(initialValue: branches)
        _allBranches = State(initialValue: Set(branches))
        _existingBranch = State(initialValue: branches.first ?? "")
        _worktrees = State(initialValue: worktrees)
        _existingWorktree = State(initialValue: worktrees.first?.path)
        _isRepository = State(initialValue: isRepository)
        _failure = State(initialValue: failure)
    }
}

#Preview("New branch, empty") {
    WorktreeSheet(previewing: PreviewFixtures.appProject)
        .environment(AppModel.preview())
}

#Preview("New branch, filled") {
    WorktreeSheet(previewing: PreviewFixtures.appProject, newBranch: "feat/sync-status")
        .environment(AppModel.preview())
}

#Preview("New branch, already exists") {
    WorktreeSheet(
        previewing: PreviewFixtures.appProject,
        newBranch: "release/2.0",
        nameProblem: .exists(available: true),
        branches: ["release/2.0"]
    )
    .environment(AppModel.preview())
}

#Preview("New branch, invalid name") {
    WorktreeSheet(previewing: PreviewFixtures.appProject, newBranch: "my new branch", nameProblem: .invalid)
        .environment(AppModel.preview())
}

#Preview("New branch, git failed") {
    WorktreeSheet(
        previewing: PreviewFixtures.appProject,
        newBranch: "feat/sync-status",
        failure: "fatal: '/tmp/archipel-preview/orbit-worktrees/feat-sync-status' already exists"
    )
    .environment(AppModel.preview())
}

#Preview("Existing branch") {
    WorktreeSheet(
        previewing: PreviewFixtures.appProject,
        mode: .existingBranch,
        branches: ["develop", "release/2.0", "spike/metal-renderer"]
    )
    .environment(AppModel.preview())
}

#Preview("Existing branch, none left") {
    WorktreeSheet(previewing: PreviewFixtures.appProject, mode: .existingBranch)
        .environment(AppModel.preview())
}

#Preview("Existing worktree") {
    WorktreeSheet(
        previewing: PreviewFixtures.appProject,
        mode: .existingWorktree,
        worktrees: [
            GitWorktreeEntry(path: PreviewFixtures.root.appending(path: "orbit-hotfix"), branch: "hotfix/2.0.1", isMain: false),
            GitWorktreeEntry(path: PreviewFixtures.root.appending(path: "orbit-bisect"), branch: nil, isMain: false),
        ]
    )
    .environment(AppModel.preview())
}

#Preview("Not a repository") {
    WorktreeSheet(previewing: PreviewFixtures.blogProject, isRepository: false)
        .environment(AppModel.preview())
}
#endif
