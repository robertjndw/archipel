import ArchipelCore
import EditorUI
import GitKit
import SwiftUI

/// Removes several worktrees picked together in the sidebar, with the same choices as
/// `RemoveWorktreeSheet` applied to all of them. Mostly used to clean up after pull requests were
/// merged, so each row shows its pull request and can be unchecked.
struct RemoveWorktreesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Never the primary checkout: the callers leave it out.
    let worktrees: [Worktree]

    @State private var included: Set<Worktree.ID>
    @State private var deleteFolders = false
    @State private var deleteBranches = false
    /// Uncommitted changes per worktree, for the ones whose folder could be asked.
    @State private var changeCounts: [Worktree.ID: Int] = [:]
    @State private var progress: Int?
    /// What is left to tell once the removals ran: branches git kept, worktrees it refused to remove.
    @State private var notes: [String]?

    init(worktrees: [Worktree]) {
        self.worktrees = worktrees
        _included = State(initialValue: Set(worktrees.map(\.id)))
    }

    private var chosen: [Worktree] { worktrees.filter { included.contains($0.id) } }

    private func isMissing(_ worktree: Worktree) -> Bool { model.missingWorktrees.contains(worktree.id) }
    private func deletesFromDisk(_ worktree: Worktree) -> Bool { deleteFolders && !isMissing(worktree) }
    private func lostChanges(in worktree: Worktree) -> Int {
        deletesFromDisk(worktree) ? changeCounts[worktree.id] ?? 0 : 0
    }

    private var withLostChanges: Int { chosen.count { lostChanges(in: $0) > 0 } }
    private var deletesAnything: Bool { chosen.contains(where: deletesFromDisk) }
    private var isWorking: Bool { progress != nil }
    /// Only worth a line per row when the worktrees come from more than one project.
    private var spansProjects: Bool {
        Set(worktrees.compactMap { model.project(ofWorktree: $0.id)?.id }).count > 1
    }

    private var title: String {
        chosen.count == 1 ? "Remove 1 Worktree" : "Remove \(chosen.count) Worktrees"
    }

    private var warnings: [String] {
        var warnings: [String] = []
        let busy = chosen.reduce(0) { $0 + model.busySessionCount(in: $1.id) }
        if busy > 0 {
            warnings.append(busy == 1
                ? "An agent is working in one of these worktrees. Removing it stops that agent."
                : "\(busy) agents are working in these worktrees. Removing them stops the agents.")
        }
        let unsaved = chosen.reduce(0) { $0 + model.unsavedDocuments(under: $1.path).count }
        if unsaved > 0 {
            let count = unsaved == 1 ? "1 file has unsaved changes in the editor." : "\(unsaved) files have unsaved changes in the editor."
            let fate = deleteFolders
                ? "Edits to files in deleted folders are discarded."
                : "Their tabs close, but the changes are kept until you save them with Save All or quit."
            warnings.append("\(count) \(fate)")
        }
        return warnings
    }

    var body: some View {
        Form {
            if let notes {
                Section {
                    ForEach(notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                    }
                }
            } else {
                list
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(maxHeight: 600)
        .navigationTitle(title)
        .toolbar {
            if notes != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                // Same as the single sheet: Done takes Return, and Escape needs a button of its own.
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
                if let progress {
                    ToolbarItem(placement: .status) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("\(min(progress + 1, chosen.count)) of \(chosen.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
        .task { await loadStatus() }
    }

    private var list: some View {
        Section {
            ForEach(worktrees) { worktree in
                Toggle(isOn: inclusion(of: worktree)) {
                    row(worktree)
                }
                .toggleStyle(.checkbox)
                .disabled(isWorking)
                .accessibilityIdentifier("removeWorktrees.worktree")
            }
        } footer: {
            if let unfinished = unfinishedFooter {
                Text(unfinished)
            }
        }
    }

    private func row(_ worktree: Worktree) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let details = details(of: worktree)
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(lostChanges(in: worktree) > 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let badge = model.pullRequestBadge(for: worktree.id) {
                PullRequestCapsule(badge: badge)
            }
        }
        // Dimmed rather than hidden, so a row unchecked by mistake is easy to find again.
        .opacity(included.contains(worktree.id) ? 1 : 0.5)
    }

    /// The project, when the worktrees come from several, and what removing the worktree would lose.
    private func details(of worktree: Worktree) -> [String] {
        var details: [String] = []
        if spansProjects, let project = model.project(ofWorktree: worktree.id) { details.append(project.name) }
        if isMissing(worktree) {
            details.append("Folder missing")
        } else if let count = changeCounts[worktree.id], count > 0 {
            let changes = count == 1 ? "1 uncommitted change" : "\(count) uncommitted changes"
            details.append(lostChanges(in: worktree) > 0 ? "\(changes) will be lost" : changes)
        }
        return details
    }

    /// A batch is usually cleanup after merging, so an open pull request is likely picked by mistake.
    private var unfinishedFooter: String? {
        let open = chosen.count { worktree in
            switch model.pullRequestBadge(for: worktree.id)?.state {
            case .open?, .draft?: true
            default: false
            }
        }
        guard open > 0 else { return nil }
        return open == 1
            ? "1 of these has a pull request that is still open."
            : "\(open) of these have pull requests that are still open."
    }

    private func inclusion(of worktree: Worktree) -> Binding<Bool> {
        Binding(
            get: { included.contains(worktree.id) },
            set: { isOn in
                if isOn { included.insert(worktree.id) } else { included.remove(worktree.id) }
            }
        )
    }

    private var options: some View {
        Section {
            Toggle("Also delete the folders from disk", isOn: $deleteFolders)
            if worktrees.contains(where: { $0.branch != nil }) {
                Toggle("Also delete their branches", isOn: $deleteBranches)
                    .padding(.leading, 20)
                    .disabled(!deleteFolders)
            }
            if withLostChanges > 0 {
                Label(
                    withLostChanges == 1
                        ? "1 worktree has uncommitted changes that will be lost"
                        : "\(withLostChanges) worktrees have uncommitted changes that will be lost",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.red)
            }
        } footer: {
            if !deleteFolders {
                Text("The folders and branches stay on disk. You can add the worktrees back from Add Worktree.")
            } else {
                Text("Branches with commits that are not merged are kept. Missing folders are only taken out of the sidebar.")
            }
        }
        .disabled(isWorking)
    }

    // As in the single sheet, Return only ever takes the safe path.
    @ViewBuilder
    private var confirmButton: some View {
        if deletesAnything {
            Button("Delete", role: .destructive) { Task { await remove() } }
                .disabled(isWorking || chosen.isEmpty)
        } else {
            Button("Remove") { Task { await remove() } }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || chosen.isEmpty)
        }
    }

    private func loadStatus() async {
        guard model.isGitAvailable else { return }
        for worktree in worktrees where !isMissing(worktree) {
            guard let status = try? await model.git.status(in: worktree.path) else { continue }
            changeCounts[worktree.id] = Set((status.staged + status.unstaged).map(\.path)).count
        }
    }

    /// One after the other: they usually share a repository, and git takes a lock on it for each
    /// removal. A worktree git refuses to remove does not stop the others.
    private func remove() async {
        let chosen = chosen
        var notes: [String] = []
        for (index, worktree) in chosen.enumerated() {
            progress = index
            let fromDisk = deletesFromDisk(worktree)
            do {
                let result = try await model.removeWorktree(
                    worktree.id,
                    deleteFolder: fromDisk,
                    deleteBranch: fromDisk && deleteBranches ? worktree.branch : nil,
                    force: lostChanges(in: worktree) > 0
                )
                switch result {
                case .keptUnmerged(let branch):
                    notes.append("The branch \(branch) was kept because it has commits that are not merged.")
                case .failed(let branch, let message):
                    notes.append("The branch \(branch) could not be deleted: \(message)")
                case .notRequested, .deleted:
                    break
                }
            } catch {
                notes.append("\(worktree.displayName) was not removed: \(error.localizedDescription)")
            }
        }
        progress = nil
        if notes.isEmpty {
            dismiss()
        } else {
            self.notes = notes
        }
    }
}

/// A pull request's state and number, in the colors the sidebar uses for it.
private struct PullRequestCapsule: View {
    let badge: PullRequestBadge

    var body: some View {
        Text(verbatim: "\(badge.state.name) \(badge.title)")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(badge.state.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badge.state.color.opacity(0.15), in: .capsule)
            .fixedSize()
            .accessibilityLabel(badge.accessibilityLabel)
    }
}

extension PullRequestBadge.State {
    fileprivate var name: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}

#if DEBUG
#Preview("Merged and open") {
    let model = AppModel.preview()
    let merged = Worktree(
        path: PreviewFixtures.root.appending(path: "orbit-worktrees/bump-deps", directoryHint: .isDirectory),
        branch: "chore/bump-deps"
    )
    model.gitSummaries[merged.id] = GitSummary(branch: "chore/bump-deps", upstream: "origin/chore/bump-deps", ahead: 0, behind: 0, changedFiles: 0)
    model.pullRequests[merged.id] = PullRequestLookup(
        branch: "chore/bump-deps",
        pullRequest: GitPullRequest(
            number: 117, url: URL(string: "https://github.com/example/orbit/pull/117")!,
            title: "Bump dependencies", state: .merged, isDraft: false
        ),
        checkedAt: .now
    )
    return RemoveWorktreesSheet(worktrees: [merged, PreviewFixtures.featureWorktree, PreviewFixtures.fixWorktree])
        .environment(model)
}
#endif
