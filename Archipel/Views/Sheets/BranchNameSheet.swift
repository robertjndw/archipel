import ArchipelCore
import GitKit
import SwiftUI

/// Names a worktree's branch before it is published: Rename Branch… for any unpublished branch,
/// and Publish for one that still has the name the app made up. Not the shared rename alert, which
/// cannot say while typing that a name is taken or not valid.
struct BranchNameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let worktree: Worktree
    let purpose: BranchNameRequest.Purpose

    @State private var typed = ""
    @FocusState private var fieldFocused: Bool
    /// What the last check found for `resolvedName`. Nil while unchecked, so nothing is flagged on
    /// a name the user is still typing.
    @State private var problem: NameProblem?
    @State private var isWorking = false
    @State private var failure: String?
    /// Off only for previews, which have no repository to ask.
    private var asksGit = true

    init(worktree: Worktree, purpose: BranchNameRequest.Purpose) {
        self.worktree = worktree
        self.purpose = purpose
        // A rename starts from the name it changes, like renaming a file. Publishing starts empty:
        // the generated name is only the prompt, so a Return out of habit cannot publish it.
        _typed = State(initialValue: purpose == .rename ? worktree.branch ?? "" : "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $typed, prompt: Text(currentBranch))
                    .focused($fieldFocused)
                    .disabled(isWorking)
                    .onChange(of: typed) {
                        failure = nil
                        problem = nil
                    }
                    .task(id: resolvedName) { if asksGit { await checkName() } }
                    .onAppear { fieldFocused = true }
                    .accessibilityIdentifier("branchName.field")
            } footer: {
                footer
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(purpose == .publish ? "Publish Branch" : "Rename Branch")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .untinted()
                    .disabled(isWorking)
                    .accessibilityIdentifier("branchName.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(purpose == .publish ? "Publish" : "Rename") { Task { await confirm() } }
                    .disabled(!canConfirm)
                    .accessibilityIdentifier("branchName.confirm")
            }
            if isWorking {
                ToolbarItem(placement: .status) { ProgressView().controlSize(.small) }
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let message = failure ?? problem?.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let resolvedName, resolvedName != typed.trimmingCharacters(in: .whitespacesAndNewlines) {
                // The prefix setting and the dash for spaces would otherwise come as a surprise on the remote.
                Text("The branch will be called \(resolvedName).")
            } else if purpose == .publish {
                Text("Name the branch before it goes to the remote.")
            } else {
                Text("The branch has not been published, so only the name here changes.")
            }
            if purpose == .publish {
                Spacer(minLength: 0)
                // Its own button, with no key, so keeping the generated name is always a choice.
                Button("Use \(currentBranch)") { Task { await keepGeneratedName() } }
                    .buttonStyle(.link)
                    .disabled(isWorking)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("branchName.keepGenerated")
            }
        }
    }

    // MARK: State

    /// What the worktree is on now, which a terminal can have changed since the sheet opened.
    private var currentBranch: String {
        model.workspace.worktree(id: worktree.id)?.branch ?? worktree.branch ?? ""
    }

    /// The branch the typed text would make, with the prefix setting applied as everywhere else.
    private var resolvedName: String? {
        model.newBranchName(fromTyped: typed)
    }

    private var canConfirm: Bool {
        guard !isWorking, let resolvedName, problem == nil else { return false }
        // Renaming to the same name has nothing to do. Publishing under it is the same as keeping it.
        return purpose == .publish || resolvedName != currentBranch
    }

    private enum NameProblem: Equatable {
        case invalid
        case taken(String)

        var message: String {
            switch self {
            case .invalid: "Not a valid branch name."
            case .taken(let name): "A branch named \(name) already exists, here or on a remote."
            }
        }
    }

    // MARK: Git

    private func checkName() async {
        guard let name = resolvedName, name != currentBranch,
              let project = model.project(ofWorktree: worktree.id)
        else {
            problem = nil
            return
        }
        // Debounced: one round of git calls per pause in typing, not per keystroke.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let isValid = await model.git.isValidBranchName(name, in: project.folderURL)
        guard !Task.isCancelled else { return }
        guard isValid else {
            problem = .invalid
            return
        }
        // A list that cannot be read leaves the check to git, which refuses a taken name anyway.
        var taken = (try? await model.takenBranchNames(in: project)) ?? []
        guard !Task.isCancelled else { return }
        taken.remove(currentBranch)
        problem = GitClient.branchNameConflicts(name, with: taken) ? .taken(name) : nil
    }

    private func confirm() async {
        guard canConfirm, let name = resolvedName else { return }
        if name == currentBranch {
            await keepGeneratedName()
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.renameBranch(of: worktree.id, to: name)
        } catch {
            failure = error.localizedDescription
            return
        }
        if purpose == .publish { model.publishBranch(of: worktree.id) }
        dismiss()
    }

    private func keepGeneratedName() async {
        guard !isWorking else { return }
        model.keepGeneratedBranchName(of: worktree.id)
        model.publishBranch(of: worktree.id)
        dismiss()
    }
}

#if DEBUG
extension BranchNameSheet {
    fileprivate init(previewing worktree: Worktree, purpose: BranchNameRequest.Purpose, typed: String? = nil) {
        self.init(worktree: worktree, purpose: purpose)
        asksGit = false
        if let typed { _typed = State(initialValue: typed) }
    }
}

private let previewPlaceholder = Worktree(
    path: PreviewFixtures.root.appending(path: "quiet-harbor"),
    branch: "quiet-harbor",
    placeholderBranch: "quiet-harbor"
)

#Preview("Publish") {
    BranchNameSheet(previewing: previewPlaceholder, purpose: .publish)
        .environment(AppModel.preview())
}

#Preview("Publish, typed") {
    BranchNameSheet(previewing: previewPlaceholder, purpose: .publish, typed: "fix login")
        .environment(AppModel.preview())
}

#Preview("Rename") {
    BranchNameSheet(previewing: PreviewFixtures.featureWorktree, purpose: .rename)
        .environment(AppModel.preview())
}
#endif
