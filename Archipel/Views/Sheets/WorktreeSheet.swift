import ArchipelCore
import GitKit
import SwiftUI

/// Adds a worktree to a project from one search field: it finds existing branches and worktrees
/// as you type, and offers to create a new branch from whatever was typed.
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
    @State private var worktrees: [GitWorktreeEntry] = []
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
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(actionTitle) { Task { await add() } }
                    .disabled(!canAdd || isWorking)
            }
        }
        .task { if asksGit { await load() } }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Branch", text: $query, prompt: Text(filter.prompt))
                .labelsHidden()
                .focused($queryFocused)
                .help("Type to find an existing branch or worktree. A name that does not exist yet becomes a new branch.")
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

    private var results: some View {
        let rows = suggestions
        return ScrollViewReader { proxy in
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
                            Task { await add() }
                        }
                        .onTapGesture { selection = index }
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
        (model.workspace.project(id: project.id) ?? project).baseBranch ?? "the current HEAD"
    }

    private var selectedSuggestion: Suggestion? {
        let rows = suggestions
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    private var actionTitle: String {
        switch selectedSuggestion?.kind {
        case .create: "Create"
        case .open: "Open"
        default: "Add"
        }
    }

    private var canAdd: Bool {
        switch selectedSuggestion?.kind {
        case nil: false
        case .create: !createNameInvalid
        default: true
        }
    }

    private func moveSelection(_ delta: Int) {
        let count = suggestions.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    /// What typing would create. Spaces become dashes so "fix login" is usable as is, and the
    /// configured prefix is added unless the name already carries a prefix of its own.
    private var createName: String? {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")
        guard !typed.isEmpty else { return nil }
        let prefix = model.settings.branchPrefix
        let name = prefix.isEmpty || typed.hasPrefix(prefix) || typed.contains("/") ? typed : prefix + typed
        return allBranches.contains(name) ? nil : name
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
        isRepository = await model.git.isRepository(project.folderURL)
        guard isRepository else { return }
        do {
            try await loadBranches()
            worktrees = try await model.availableWorktrees(for: project)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func loadBranches() async throws {
        let all = try await model.git.worktrees(of: project.folderURL)
        let checkedOut = Set(all.compactMap(\.branch))
        let local = try await model.git.localBranches(in: project.folderURL)
        allBranches = Set(local)
        branches = local.filter { !checkedOut.contains($0) }
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

    private func add() async {
        guard canAdd, !isWorking, let suggestion = selectedSuggestion else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            switch suggestion.kind {
            case .create:
                try await model.createWorktree(in: project, branch: suggestion.title, createBranch: true)
            case .branch:
                try await model.createWorktree(in: project, branch: suggestion.title, createBranch: false)
            case .worktree(let path):
                guard let entry = worktrees.first(where: { $0.path == path }) else { return }
                model.addExistingWorktrees([entry], to: project.id)
            case .open(let id):
                model.select(worktree: id)
            }
            dismiss()
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
            case .worktree(let path): "worktree:\(path.path)"
            case .open(let id): "open:\(id)"
            }
        }

        var symbol: String {
            switch kind {
            case .create: "plus.circle"
            case .branch: "arrow.triangle.branch"
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
        HStack(spacing: 8) {
            Image(systemName: suggestion.symbol)
                .frame(width: 18)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            title
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(isInvalid ? "Not a valid branch name" : suggestion.detail)
                .font(.callout)
                .foregroundStyle(detailStyle)
                .lineLimit(1)
                // The branch name is the part worth truncating.
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background {
            if isSelected {
                // Full accent like Open Quickly, since this is the row Return acts on.
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.tint)
            }
        }
    }

    private var detailStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white.opacity(0.85)) }
        return isInvalid ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)
    }

    private var title: Text {
        if suggestion.kind == .create {
            return Text("Create Branch “\(suggestion.title)”")
        }
        return highlighted(suggestion.title, Set(suggestion.matches))
    }

    /// Bolds and tints matched characters. Built per run so long names don't create one Text per letter.
    private func highlighted(_ string: String, _ matches: Set<Int>) -> Text {
        guard !matches.isEmpty else { return Text(string) }
        var result = AttributedString()
        var run = ""
        var runMatches = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if runMatches {
                piece.inlinePresentationIntent = .stronglyEmphasized
                // Accent-colored letters would disappear on the selected row's accent background.
                if !isSelected { piece.foregroundColor = .accentColor }
            }
            result += piece
            run = ""
        }
        for (index, character) in string.enumerated() {
            let isMatch = matches.contains(index)
            if isMatch != runMatches { flush() }
            runMatches = isMatch
            run.append(character)
        }
        flush()
        return Text(result)
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
        worktrees: [GitWorktreeEntry] = [],
        isLoaded: Bool = true,
        isRepository: Bool = true,
        failure: String? = nil
    ) {
        self.project = project
        asksGit = false
        _query = State(initialValue: query)
        _filter = State(initialValue: filter)
        _selection = State(initialValue: query.isEmpty ? -1 : 0)
        _createNameInvalid = State(initialValue: createNameInvalid)
        _branches = State(initialValue: branches)
        _allBranches = State(initialValue: Set(branches))
        _worktrees = State(initialValue: worktrees)
        _isLoaded = State(initialValue: isLoaded)
        _isRepository = State(initialValue: isRepository)
        _failure = State(initialValue: failure)
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
