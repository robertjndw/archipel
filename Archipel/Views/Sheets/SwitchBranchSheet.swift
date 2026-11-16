import ArchipelCore
import GitKit
import SwiftUI

/// Checks out another branch in a worktree's own folder. Works like the Add Worktree sheet: type to
/// find a local or remote branch, or name a new one.
struct SwitchBranchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let worktree: Worktree

    @State private var query = ""
    /// -1 while the field is empty, so a stray Return on an untouched sheet switches nothing.
    @State private var selection = -1
    @State private var createNameInvalid = false
    @FocusState private var queryFocused: Bool
    @State private var current: String?
    @State private var local: [String] = []
    @State private var remote: [String] = []
    /// Branches checked out in other worktrees of the repository, with that worktree's folder. git
    /// refuses to check a branch out twice, so these are offered as a jump to that worktree instead.
    @State private var elsewhere: [String: URL] = [:]
    @State private var isLoaded = false
    @State private var isRepository = true
    @State private var isWorking = false
    @State private var failure: String?
    /// Off only for previews, which fill the sheet themselves and have no repository to ask.
    private var asksGit = true

    private static let rowHeight: CGFloat = 30
    private static let visibleRows = 6

    var body: some View {
        Form {
            if isRepository {
                Section {
                    searchField
                    results
                } header: {
                    currentBranchLabel
                } footer: {
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else {
                        Text("Find a branch, or type a name to create one. Use ↑ and ↓ to choose.")
                    }
                }
                if !warnings.isEmpty {
                    Section {
                        ForEach(warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Label("\(worktree.path.lastPathComponent) is not a git repository, so it has no branches.", systemImage: "exclamationmark.triangle")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .navigationTitle("Switch Branch")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(actionTitle) { Task { await perform() } }
                    .disabled(!canPerform || isWorking)
            }
        }
        .task { if asksGit { await load() } }
    }

    private var currentBranchLabel: some View {
        HStack(spacing: 4) {
            Text("Current:")
            if let current {
                Label(current, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .fontWeight(.medium)
            } else if isLoaded {
                Text("Detached HEAD").fontWeight(.medium)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    /// Shown up front so a running agent or uncommitted work doesn't come as a surprise.
    private var warnings: [String] {
        var warnings: [String] = []
        let busy = model.busySessionCount(in: worktree.id)
        if busy > 0 {
            warnings.append(busy == 1
                ? "An agent is working in this worktree. Its files change under it when you switch."
                : "\(busy) agents are working in this worktree. Their files change under them when you switch.")
        }
        let changed = model.gitSummaries[worktree.id]?.changedFiles ?? 0
        if changed > 0 {
            warnings.append(changed == 1
                ? "The uncommitted change comes along to the new branch. Git refuses the switch if it would be overwritten."
                : "The \(changed) uncommitted changes come along to the new branch. Git refuses the switch if any would be overwritten.")
        }
        return warnings
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Branch", text: $query, prompt: Text("Search branches or name a new one"))
                .labelsHidden()
                .focused($queryFocused)
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onChange(of: query) {
                    selection = query.isEmpty ? -1 : 0
                    failure = nil
                }
                .task(id: createName) { if asksGit { await checkCreateName() } }
                .onAppear { queryFocused = true }
            if isWorking {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: Results

    private var results: some View {
        let rows = suggestions
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        SearchResultRow(
                            symbol: row.symbol,
                            title: title(of: row, isSelected: index == selection),
                            detail: row.kind == .create && createNameInvalid ? "Not a valid branch name" : row.detail,
                            detailIsWarning: row.kind == .create && createNameInvalid,
                            isSelected: index == selection
                        )
                        .opacity(row.isActionable ? 1 : 0.5)
                        .frame(height: Self.rowHeight)
                        .contentShape(.rect)
                        .onTapGesture(count: 2) {
                            selection = index
                            Task { await perform() }
                        }
                        .onTapGesture { selection = index }
                        .help(row.help ?? "")
                    }
                }
            }
            // Fixed for the same reason as in the Add Worktree sheet: a sheet that resizes while you
            // type moves the field away from the pointer.
            .frame(height: Self.rowHeight * CGFloat(Self.visibleRows))
            .overlay {
                if rows.isEmpty { emptyState }
            }
            .onChange(of: selection) { _, selection in
                guard rows.indices.contains(selection) else { return }
                proxy.scrollTo(rows[selection].id)
            }
        }
    }

    private func title(of row: Suggestion, isSelected: Bool) -> Text {
        if row.kind == .create {
            return Text("Create Branch “\(row.title)”")
        }
        return .highlighting(row.title, matches: row.matches, onAccent: isSelected)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !isLoaded {
            ProgressView().controlSize(.small)
        } else {
            Text(query.isEmpty ? "This repository has no other branches." : "No branches match “\(query)”.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: State

    private var baseBranch: String {
        model.project(ofWorktree: worktree.id)?.baseBranch ?? current ?? "HEAD"
    }

    private var selectedSuggestion: Suggestion? {
        let rows = suggestions
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    private var actionTitle: String {
        switch selectedSuggestion?.kind {
        case .create: "Create and Switch"
        case .elsewhere: "Go to Worktree"
        default: "Switch"
        }
    }

    private var canPerform: Bool {
        guard let row = selectedSuggestion, row.isActionable else { return false }
        return row.kind != .create || !createNameInvalid
    }

    private func moveSelection(_ delta: Int) {
        let count = suggestions.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    private var createName: String? {
        guard let name = model.newBranchName(fromTyped: query), !local.contains(name) else { return nil }
        return name
    }

    /// The worktree in the sidebar that has `path` as its folder, if any.
    private func sidebarWorktree(at path: URL) -> Worktree? {
        model.project(ofWorktree: worktree.id)?.worktrees.first {
            $0.path.standardizedFileURL.path == path.standardizedFileURL.path
        }
    }

    private var suggestions: [Suggestion] {
        // Local branches first, then ones checked out in another worktree, then remote-only ones.
        var candidates: [Suggestion] = []
        for branch in local where branch != current {
            if let path = elsewhere[branch] {
                let target = sidebarWorktree(at: path)
                candidates.append(Suggestion(
                    kind: .elsewhere(target?.id),
                    title: branch,
                    detail: "In \(path.lastPathComponent)",
                    help: target == nil
                        ? "Checked out in \(path.abbreviatedPath), which is not in the sidebar. A branch can only be checked out in one worktree."
                        : "Checked out in \(path.abbreviatedPath). A branch can only be checked out in one worktree, so this goes there instead."
                ))
            } else {
                candidates.append(Suggestion(kind: .local, title: branch, detail: "Branch"))
            }
        }
        let localNames = Set(local)
        for branch in remote {
            // origin/feature is offered as feature, unless a local feature already exists.
            guard let slash = branch.firstIndex(of: "/") else { continue }
            let name = String(branch[branch.index(after: slash)...])
            guard !localNames.contains(name) else { continue }
            candidates.append(Suggestion(kind: .remote, title: branch, detail: "Remote", help: "Creates \(name) tracking \(branch)"))
        }
        candidates.sort { $0.order < $1.order }
        if let current {
            candidates.insert(Suggestion(kind: .current, title: current, detail: "Current"), at: 0)
        }

        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = FuzzyMatcher.rank(candidates, query: typed, limit: 50) { $0.title }.map { ranked in
            var row = ranked.item
            row.matches = ranked.match.positions
            return row
        }
        guard let name = createName else { return rows }

        let create = Suggestion(
            kind: .create,
            title: name,
            detail: "from \(baseBranch)",
            help: "Creates \(name) from \(baseBranch) and switches to it"
        )
        // An exact hit beats creating; otherwise Return should do what was typed.
        if let first = rows.first, first.title.caseInsensitiveCompare(typed) == .orderedSame {
            rows.insert(create, at: 1)
        } else {
            rows.insert(create, at: 0)
        }
        return rows
    }

    // MARK: Git

    private func load() async {
        defer { isLoaded = true }
        guard let project = model.project(ofWorktree: worktree.id) else { return }
        isRepository = await model.git.isRepository(worktree.path)
        guard isRepository else { return }
        do {
            try await loadBranches(in: project)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func loadBranches(in project: Project) async throws {
        current = await model.git.currentBranch(in: worktree.path)
        let own = worktree.path.standardizedFileURL.path
        var taken: [String: URL] = [:]
        for entry in try await model.git.worktrees(of: project.folderURL) {
            guard let branch = entry.branch, entry.path.standardizedFileURL.path != own else { continue }
            taken[branch] = entry.path
        }
        elsewhere = taken
        local = try await model.git.localBranches(in: project.folderURL)
        remote = try await model.git.remoteBranches(in: project.folderURL)
    }

    private func checkCreateName() async {
        guard let name = createName, let project = model.project(ofWorktree: worktree.id) else {
            createNameInvalid = false
            return
        }
        // Debounced: one round of git calls per pause in typing, not per keystroke.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        try? await loadBranches(in: project)
        let isValid = await model.git.isValidBranchName(name, in: project.folderURL)
        guard !Task.isCancelled else { return }
        createNameInvalid = !isValid
    }

    private func perform() async {
        guard canPerform, !isWorking, let suggestion = selectedSuggestion else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            switch suggestion.kind {
            case .local:
                try await model.switchBranch(of: worktree.id, to: .local(suggestion.title))
            case .remote:
                try await model.switchBranch(of: worktree.id, to: .remote(suggestion.title))
            case .create:
                let base = model.project(ofWorktree: worktree.id)?.baseBranch
                try await model.switchBranch(of: worktree.id, to: .new(suggestion.title, base: base))
            case .elsewhere(let id):
                guard let id else { return }
                model.select(worktree: id)
            case .current:
                return
            }
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Model

extension SwitchBranchSheet {
    struct Suggestion: Identifiable, Equatable {
        enum Kind: Equatable {
            case current
            case local
            /// Checked out in another worktree; the ID is that worktree's when it is in the sidebar.
            case elsewhere(Worktree.ID?)
            case remote
            case create
        }

        var kind: Kind
        var title: String
        var detail: String
        var help: String? = nil
        var matches: [Int] = []

        var id: String {
            switch kind {
            case .current: "current"
            case .local: "local:\(title)"
            case .elsewhere: "elsewhere:\(title)"
            case .remote: "remote:\(title)"
            case .create: "create"
            }
        }

        var symbol: String {
            switch kind {
            case .current: "checkmark"
            case .local: "arrow.triangle.branch"
            case .elsewhere: "arrow.forward.circle"
            case .remote: "cloud"
            case .create: "plus.circle"
            }
        }

        var isActionable: Bool {
            switch kind {
            case .current, .elsewhere(nil): false
            default: true
            }
        }

        /// Sort order of the groups before ranking. Ranking is stable, so ties keep this order.
        var order: Int {
            switch kind {
            case .current: 0
            case .local: 1
            case .elsewhere: 2
            case .remote: 3
            case .create: 4
            }
        }
    }
}

#if DEBUG
extension SwitchBranchSheet {
    fileprivate init(
        previewing worktree: Worktree,
        query: String = "",
        current: String? = nil,
        local: [String] = [],
        remote: [String] = [],
        elsewhere: [String: URL] = [:],
        isRepository: Bool = true,
        failure: String? = nil
    ) {
        self.worktree = worktree
        asksGit = false
        _query = State(initialValue: query)
        _selection = State(initialValue: query.isEmpty ? -1 : 0)
        _current = State(initialValue: current ?? worktree.branch)
        _local = State(initialValue: local)
        _remote = State(initialValue: remote)
        _elsewhere = State(initialValue: elsewhere)
        _isLoaded = State(initialValue: true)
        _isRepository = State(initialValue: isRepository)
        _failure = State(initialValue: failure)
    }
}

private let previewLocal = ["main", "feat/offline-mode", "fix/login-crash", "release/2.0"]
private let previewRemote = ["origin/main", "origin/feat/sync-status", "origin/release/2.0"]
private let previewElsewhere = ["fix/login-crash": PreviewFixtures.fixWorktree.path]

#Preview("Empty") {
    SwitchBranchSheet(
        previewing: PreviewFixtures.featureWorktree,
        local: previewLocal, remote: previewRemote, elsewhere: previewElsewhere
    )
    .environment(AppModel.preview())
}

#Preview("Typing") {
    SwitchBranchSheet(
        previewing: PreviewFixtures.featureWorktree, query: "sync",
        local: previewLocal, remote: previewRemote, elsewhere: previewElsewhere
    )
    .environment(AppModel.preview())
}

#Preview("Refused") {
    SwitchBranchSheet(
        previewing: PreviewFixtures.featureWorktree, query: "main",
        local: previewLocal, remote: previewRemote,
        failure: "Your local changes to the following files would be overwritten by checkout:\n\tSources/App/Sync.swift\nPlease commit your changes or stash them before you switch branches."
    )
    .environment(AppModel.preview())
}

#Preview("Not a repository") {
    SwitchBranchSheet(previewing: PreviewFixtures.featureWorktree, isRepository: false)
        .environment(AppModel.preview())
}
#endif
