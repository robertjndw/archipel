import ArchipelCore
import GitKit
import SwiftUI

/// Adds a worktree to a project from one search field: it finds existing branches, local and
/// remote, and worktrees as you type, and offers to create a new branch from whatever was typed.
struct WorktreeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var query = ""
    @State private var filter = Filter.all
    /// -1 while the field is empty, so a stray Return on an untouched sheet adds nothing.
    @State private var selection = -1
    @State private var createNameInvalid = false
    @FocusState private var queryFocused: Bool
    @State private var branches: [String] = []
    @State private var allBranches: Set<String> = []
    /// Remote branches without a local branch of their name, as `origin/name`. Adding one creates
    /// that local branch, tracking it.
    @State private var remoteBranches: [String] = []
    /// What the local branches of `remoteBranches` would be called. Set wherever that is.
    @State private var remoteOnlyNames: Set<String> = []
    @State private var worktrees: [GitWorktreeEntry] = []
    @State private var isLoaded = false
    @State private var isRepository = true
    @State private var isWorking = false
    /// What the spinner is for, so a slow create does not look like a hang.
    @State private var workingLabel = "Creating Worktree…"
    /// Held so Cancel and closing the sheet stop a create that is still running.
    @State private var addTask: Task<Void, Never>?
    /// Where a new branch starts when the project names no base branch. Nil means HEAD.
    @State private var remoteDefaultBranch: String?
    @State private var failure: String?
    /// Something to tell the user about a worktree that was created all the same. Shown instead of
    /// the search, with Done as the only way on.
    @State private var note: String?
    /// Off only for previews, which fill the sheet themselves and have no repository to ask.
    private var asksGit = true

    private static let rowHeight: CGFloat = 30
    private static let visibleRows = 6

    var body: some View {
        // Ranked once per evaluation; the rows, the selection and the toolbar all read the same list.
        let rows = suggestions
        let selected = rows.indices.contains(selection) ? rows[selection] : nil
        return Form {
            if let note {
                Label(note, systemImage: "info.circle")
                    .textSelection(.enabled)
            } else if isRepository {
                Section {
                    searchField(rows: rows)
                    results(rows: rows)
                } footer: {
                    // Replaces the hint instead of adding a row, so the sheet height stays about the same.
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Text("Find a branch or worktree, or type a name to create a new branch. Use ↑ and ↓ to choose.")
                    }
                }
            } else {
                Label("\(project.name) is not a git repository, so it cannot have worktrees.", systemImage: "exclamationmark.triangle")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .navigationTitle("Add Worktree")
        .toolbar {
            if note != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            } else {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        addTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle(for: selected)) { startAdd() }
                        .disabled(!canAdd(selected) || isWorking)
                }
            }
        }
        .task { if asksGit { await load() } }
        .onDisappear { addTask?.cancel() }
    }

    // MARK: Search field

    private func searchField(rows: [Suggestion]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Branch", text: $query, prompt: Text(filter.prompt))
                .labelsHidden()
                .focused($queryFocused)
                .help("Type to find an existing branch or worktree. A name that does not exist yet becomes a new branch.")
                .onKeyPress(.downArrow) { moveSelection(1, count: rows.count); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1, count: rows.count); return .handled }
                .onChange(of: query) {
                    selection = query.isEmpty ? -1 : 0
                    failure = nil
                }
                .task(id: createName) { if asksGit { await checkCreateName() } }
                .onAppear { queryFocused = true }
            if isWorking {
                Text(workingLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            }
            filterMenu
        }
    }

    /// Narrows the list to one kind of result. Most of the time you just type, so it stays out of the way.
    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { filter in
                    Label(filter.title, systemImage: filter.symbol).tag(filter)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                if filter != .all {
                    Text(filter.title)
                }
                Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .foregroundStyle(filter == .all ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show only some kinds of results")
        .accessibilityLabel("Filter: \(filter.title)")
        .onChange(of: filter) {
            selection = query.isEmpty ? -1 : 0
            queryFocused = true
        }
    }

    // MARK: Results

    private func results(rows: [Suggestion]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        SuggestionRow(
                            suggestion: row,
                            isSelected: index == selection,
                            isInvalid: row.kind == .create && createNameInvalid
                        )
                        .frame(height: Self.rowHeight)
                        .contentShape(.rect)
                        .onTapGesture(count: 2) {
                            selection = index
                            startAdd()
                        }
                        .onTapGesture { selection = index }
                        .accessibilityAddTraits(index == selection ? [.isButton, .isSelected] : .isButton)
                        .help(row.help ?? "")
                    }
                }
            }
            // Fixed so the sheet never changes height while typing or filtering; macOS keeps sheets
            // vertically centred, so any resize would move the field away from the pointer.
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

    @ViewBuilder
    private var emptyState: some View {
        if !isLoaded {
            ProgressView().controlSize(.small)
        } else {
            Text(query.isEmpty ? filter.emptyMessage : "No \(filter.noun) match “\(query)”.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: State

    private var baseBranch: String {
        (model.workspace.project(id: project.id) ?? project).baseBranch ?? remoteDefaultBranch ?? "the current HEAD"
    }

    private var selectedSuggestion: Suggestion? {
        let rows = suggestions
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    private func actionTitle(for selected: Suggestion?) -> String {
        switch selected?.kind {
        case .create: "Create"
        case .open: "Open"
        default: "Add"
        }
    }

    private func canAdd(_ selected: Suggestion?) -> Bool {
        switch selected?.kind {
        case nil: false
        case .create: !createNameInvalid
        default: true
        }
    }

    private func moveSelection(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    /// What typing would create, or nil when that branch already exists. A remote branch counts as
    /// existing, with or without the configured prefix: someone who types its name means that
    /// branch, not a new and unrelated one off the base.
    private var createName: String? {
        guard let name = model.newBranchName(fromTyped: query), !allBranches.contains(name) else { return nil }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return remoteOnlyNames.contains(name) || remoteOnlyNames.contains(typed) ? nil : name
    }

    /// `origin/feature` is offered as the local branch `feature`.
    private static func localName(ofRemoteBranch branch: String) -> String? {
        branch.firstIndex(of: "/").map { String(branch[branch.index(after: $0)...]) }
    }

    private var suggestions: [Suggestion] {
        let current = model.workspace.project(id: project.id) ?? project
        // What can be added comes before what is already in the sidebar, which is only listed so
        // typing its name jumps there instead of offering to create a duplicate.
        var candidates: [Suggestion] = []
        if filter.includes(.worktree) {
            candidates += worktrees.map { entry in
                Suggestion(
                    kind: .worktree(entry.path),
                    title: entry.branch ?? entry.path.lastPathComponent,
                    detail: "Worktree on disk",
                    help: entry.path.abbreviatedPath
                )
            }
        }
        if filter.includes(.branch) {
            candidates += branches.map { Suggestion(kind: .branch, title: $0, detail: "Branch") }
            candidates += remoteBranches.map { branch in
                let name = Self.localName(ofRemoteBranch: branch) ?? branch
                return Suggestion(
                    kind: .remoteBranch,
                    title: branch,
                    detail: "Remote",
                    help: "Creates \(name) tracking \(branch)"
                )
            }
        }
        if filter.includes(.open) {
            candidates += current.worktrees.map {
                Suggestion(kind: .open($0.id), title: $0.displayName, detail: "In the sidebar", help: $0.path.abbreviatedPath)
            }
        }

        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = FuzzyMatcher.rank(candidates, query: typed, limit: 50) { $0.title }.map { ranked in
            var row = ranked.item
            row.matches = ranked.match.positions
            return row
        }
        guard filter.includes(.create), let name = createName else { return rows }

        let create = Suggestion(
            kind: .create,
            title: name,
            detail: "from \(baseBranch)",
            help: "Creates \(name) from \(baseBranch) in \(model.worktreePath(for: current, branch: name).abbreviatedPath)"
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
        // Every call below would bring up the system's install dialog.
        guard model.isGitAvailable else {
            failure = AppModel.gitMissingMessage
            return
        }
        isRepository = await model.git.isRepository(project.folderURL)
        guard isRepository else { return }
        remoteDefaultBranch = await model.git.remoteDefaultBranch(in: project.folderURL)
        do {
            try await loadBranches()
            worktrees = try await model.availableWorktrees(for: project)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func loadBranches() async throws {
        let checkedOut = try await model.checkedOutBranches(of: project)
        let local = try await model.git.localBranches(in: project.folderURL)
        let localNames = Set(local)
        let remote = try await model.git.remoteBranches(in: project.folderURL).filter { branch in
            Self.localName(ofRemoteBranch: branch).map { !localNames.contains($0) } ?? false
        }
        allBranches = localNames
        branches = local.filter { !checkedOut.contains($0) }
        remoteBranches = remote
        remoteOnlyNames = Set(remote.compactMap(Self.localName(ofRemoteBranch:)))
    }

    /// Checked while typing, so a bad name shows up in the list instead of as a git error after Return.
    private func checkCreateName() async {
        guard let name = createName else {
            createNameInvalid = false
            return
        }
        // Debounced: one round of git calls per pause in typing, not per keystroke.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        // Picks up branches made in a terminal while the sheet is open, which turns the create row into a match.
        try? await loadBranches()
        let isValid = await model.git.isValidBranchName(name, in: project.folderURL)
        guard !Task.isCancelled else { return }
        createNameInvalid = !isValid
    }

    private func startAdd() {
        guard !isWorking else { return }
        addTask = Task { await add() }
    }

    private func add() async {
        guard let suggestion = selectedSuggestion, canAdd(suggestion), !isWorking else { return }
        workingLabel = switch suggestion.kind {
        case .create, .branch, .remoteBranch: "Creating Worktree…"
        case .worktree, .open: "Adding Worktree…"
        }
        isWorking = true
        defer { isWorking = false }
        do {
            var creation: AppModel.WorktreeCreation?
            switch suggestion.kind {
            case .create:
                creation = try await model.createWorktree(in: project, branch: suggestion.title, createBranch: true)
            case .branch:
                creation = try await model.createWorktree(in: project, branch: suggestion.title, createBranch: false)
            case .remoteBranch:
                creation = try await model.createWorktree(in: project, tracking: suggestion.title)
            case .worktree(let path):
                guard let entry = worktrees.first(where: { $0.path == path }) else { return }
                model.addExistingWorktrees([entry], to: project.id)
            case .open(let id):
                model.select(worktree: id)
            }
            if let fetchFailure = creation?.baseFetchFailure {
                // The worktree exists and is selected behind the sheet; this only says what it is based on.
                note = "The worktree was created, but its starting point could not be fetched first, so it starts from what the last fetch brought.\n\n\(fetchFailure)"
            } else {
                dismiss()
            }
        } catch is CancellationError {
            // Cancel was pressed, or the project went away meanwhile. Nothing to report either way.
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Model

extension WorktreeSheet {
    enum Filter: String, CaseIterable, Identifiable {
        case all, branches, worktrees, sidebar

        var id: Self { self }

        var title: String {
            switch self {
            case .all: "Everything"
            case .branches: "Branches"
            case .worktrees: "Worktrees on Disk"
            case .sidebar: "In the Sidebar"
            }
        }

        var noun: String {
            switch self {
            case .all: "results"
            case .branches: "branches"
            case .worktrees: "worktrees"
            case .sidebar: "sidebar items"
            }
        }

        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .branches: "arrow.triangle.branch"
            case .worktrees: "folder"
            case .sidebar: "sidebar.left"
            }
        }

        var prompt: String {
            switch self {
            case .all: "Search branches or name a new one"
            case .branches: "Search branches or name a new one"
            case .worktrees: "Search worktrees on disk"
            case .sidebar: "Search the sidebar"
            }
        }

        var emptyMessage: String {
            switch self {
            case .all, .branches: "Type a name to create a new branch."
            case .worktrees: "This repository has no other worktrees."
            case .sidebar: "Nothing from this project is in the sidebar."
            }
        }

        /// Creating is offered wherever branches are, since that is what it makes.
        func includes(_ kind: Suggestion.Category) -> Bool {
            switch (self, kind) {
            case (.all, _): true
            case (.branches, .branch), (.branches, .create): true
            case (.worktrees, .worktree): true
            case (.sidebar, .open): true
            default: false
            }
        }
    }

    struct Suggestion: Identifiable, Equatable {
        enum Kind: Equatable {
            case create
            case branch
            /// Only on a remote so far; the title is `origin/name`.
            case remoteBranch
            case worktree(URL)
            case open(Worktree.ID)
        }

        enum Category { case create, branch, worktree, open }

        var kind: Kind
        var title: String
        var detail: String
        /// Shown on hover; usually the full path, which is too long for the row.
        var help: String? = nil
        var matches: [Int] = []

        var id: String {
            switch kind {
            case .create: "create"
            case .branch: "branch:\(title)"
            case .remoteBranch: "remote:\(title)"
            case .worktree(let path): "worktree:\(path.path)"
            case .open(let id): "open:\(id)"
            }
        }

        var symbol: String {
            switch kind {
            case .create: "plus.circle"
            case .branch: "arrow.triangle.branch"
            case .remoteBranch: "cloud"
            case .worktree: "folder"
            case .open: "arrow.forward.circle"
            }
        }
    }
}

// MARK: - Rows

private struct SuggestionRow: View {
    let suggestion: WorktreeSheet.Suggestion
    let isSelected: Bool
    let isInvalid: Bool

    var body: some View {
        SearchResultRow(
            symbol: suggestion.symbol,
            title: title,
            detail: isInvalid ? "Not a valid branch name" : suggestion.detail,
            detailIsWarning: isInvalid,
            isSelected: isSelected
        )
    }

    private var title: Text {
        if suggestion.kind == .create {
            return Text("Create Branch “\(suggestion.title)”")
        }
        return .highlighting(suggestion.title, matches: suggestion.matches)
    }
}

#if DEBUG
extension WorktreeSheet {
    fileprivate init(
        previewing project: Project,
        query: String = "",
        filter: Filter = .all,
        createNameInvalid: Bool = false,
        branches: [String] = [],
        remoteBranches: [String] = [],
        worktrees: [GitWorktreeEntry] = [],
        isLoaded: Bool = true,
        isRepository: Bool = true,
        failure: String? = nil,
        note: String? = nil
    ) {
        self.project = project
        asksGit = false
        _query = State(initialValue: query)
        _filter = State(initialValue: filter)
        _selection = State(initialValue: query.isEmpty ? -1 : 0)
        _createNameInvalid = State(initialValue: createNameInvalid)
        _branches = State(initialValue: branches)
        _allBranches = State(initialValue: Set(branches))
        _remoteBranches = State(initialValue: remoteBranches)
        _remoteOnlyNames = State(initialValue: Set(remoteBranches.compactMap(Self.localName(ofRemoteBranch:))))
        _worktrees = State(initialValue: worktrees)
        _isLoaded = State(initialValue: isLoaded)
        _isRepository = State(initialValue: isRepository)
        _failure = State(initialValue: failure)
        _note = State(initialValue: note)
    }
}

private let previewBranches = ["develop", "release/2.0", "spike/metal-renderer"]
private let previewWorktrees = [
    GitWorktreeEntry(path: PreviewFixtures.root.appending(path: "orbit-hotfix"), branch: "hotfix/2.0.1", isMain: false),
]

#Preview("Empty") {
    WorktreeSheet(previewing: PreviewFixtures.appProject, branches: previewBranches, worktrees: previewWorktrees)
        .environment(AppModel.preview())
}

#Preview("Typing") {
    WorktreeSheet(previewing: PreviewFixtures.appProject, query: "rel", branches: previewBranches, worktrees: previewWorktrees)
        .environment(AppModel.preview())
}

#Preview("Remote branch") {
    WorktreeSheet(
        previewing: PreviewFixtures.appProject,
        query: "sync",
        branches: previewBranches,
        remoteBranches: ["origin/feat/sync-status", "origin/sync"]
    )
    .environment(AppModel.preview())
}

#Preview("Created without fetching") {
    WorktreeSheet(
        previewing: PreviewFixtures.appProject,
        note: "The worktree was created, but its starting point could not be fetched first, so it starts from what the last fetch brought.\n\nCould not resolve host: github.com"
    )
    .environment(AppModel.preview())
}

#Preview("Filtered to branches") {
    WorktreeSheet(previewing: PreviewFixtures.appProject, filter: .branches, branches: previewBranches, worktrees: previewWorktrees)
        .environment(AppModel.preview())
}

#Preview("Invalid name") {
    WorktreeSheet(previewing: PreviewFixtures.appProject, query: "my~branch", createNameInvalid: true, branches: previewBranches)
        .environment(AppModel.preview())
}

#Preview("No matches in filter") {
    WorktreeSheet(previewing: PreviewFixtures.appProject, query: "zzz", filter: .worktrees)
        .environment(AppModel.preview())
}

#Preview("Git failed") {
    WorktreeSheet(
        previewing: PreviewFixtures.appProject,
        query: "feat/sync-status",
        branches: previewBranches,
        failure: "fatal: '/tmp/archipel-preview/orbit-worktrees/feat-sync-status' already exists"
    )
    .environment(AppModel.preview())
}

#Preview("Loading") {
    WorktreeSheet(previewing: PreviewFixtures.appProject, isLoaded: false)
        .environment(AppModel.preview())
}

#Preview("Not a repository") {
    WorktreeSheet(previewing: PreviewFixtures.blogProject, isRepository: false)
        .environment(AppModel.preview())
}
#endif
