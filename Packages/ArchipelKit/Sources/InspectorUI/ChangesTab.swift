import GitKit
import SwiftUI
import UISupport

struct ChangeID: Hashable {
    var path: String
    var staged: Bool
}

private struct ListedChange: Identifiable {
    var change: GitFileChange
    var staged: Bool
    var id: ChangeID { ChangeID(path: change.path, staged: staged) }
}

@MainActor @Observable
final class ChangesModel {
    enum Phase { case loading, notRepository, ready }

    let root: URL
    private(set) var status = GitStatus.empty
    private(set) var phase = Phase.loading
    private(set) var refreshError: String?
    var actionError: String?
    var selection: ChangeID?
    private let git = GitClient()
    private var generation = 0

    /// Kept here rather than in the view so switching inspector tabs does not lose a half-written message.
    var message = ""
    private(set) var activity: Activity?
    /// Bumped when a push lands, so the arrow can fly off while the remote info is still refreshing.
    private(set) var completedPushes = 0
    private(set) var hasRemote = false
    private(set) var pullRequestLookup: PullRequestLookup?
    private let searchPATH: @MainActor () async -> String
    private var gitHubTask: Task<GitHubClient?, Never>?
    private var lookupGeneration = 0
    private var lookupBranch: String?
#if DEBUG
    /// Set on preview samples, which have no repository behind them and must never run git.
    @ObservationIgnored fileprivate var isPreviewSample = false
#endif

    enum Activity: Equatable {
        case commit, push, pull, fetch
    }

    init(root: URL, searchPATH: @escaping @MainActor () async -> String) {
        self.root = root
        self.searchPATH = searchPATH
    }

    var commitControl: CommitControl {
        CommitControl(status: status, message: message, isBusy: activity != nil)
    }

    var syncState: SyncState {
        SyncState(status: status, hasRemote: hasRemote, isBusy: activity != nil)
    }

    var primaryAction: PrimaryAction {
        PrimaryAction(commit: commitControl, sync: syncState)
    }

    /// The current branch's pull request. A result for another branch says nothing about this one.
    var pullRequest: GitPullRequest? {
        guard let branch = status.branch, let lookup = pullRequestLookup, lookup.branch == branch,
              case .found(let pullRequest) = lookup.outcome else { return nil }
        return pullRequest
    }

    func refresh() async {
#if DEBUG
        if isPreviewSample { return }
#endif
        // Periodic, activation and post-action refreshes can overlap; only the newest may write.
        generation += 1
        let current = generation
        do {
            let status = try await git.status(in: root)
            guard current == generation else { return }
            update(status: status, phase: .ready, refreshError: nil)
        } catch {
            let isRepository = await git.isRepository(root)
            guard current == generation else { return }
            if isRepository {
                if refreshError != error.localizedDescription { refreshError = error.localizedDescription }
            } else {
                update(status: .empty, phase: .notRepository, refreshError: nil)
            }
        }
    }

    /// Observation fires on every assignment, equal or not, and this runs on a 3 second poll; writing
    /// only what changed keeps an idle tree from rebuilding the whole Changes list each time.
    private func update(status: GitStatus, phase: Phase, refreshError: String?) {
        if self.status != status { self.status = status }
        if self.phase != phase { self.phase = phase }
        if self.refreshError != refreshError { self.refreshError = refreshError }
    }

    func stage(_ change: GitFileChange) {
        perform { try await $0.stage([change.path], in: $1) }
    }

    func unstage(_ change: GitFileChange) {
        // Unstaging only the new name of a rename would leave the old name's deletion staged.
        let paths = [change.path] + [change.originalPath].compactMap(\.self)
        perform { try await $0.unstage(paths, in: $1) }
    }

    func stageAll() {
        perform { try await $0.stageAll(in: $1) }
    }

    func unstageAll() {
        perform { try await $0.unstageAll(in: $1) }
    }

    func discard(_ change: GitFileChange, staged: Bool) {
        let changes = [change]
        perform { git, root in
            if staged {
                try await git.discardStaged(changes, in: root)
            } else {
                try await git.discardUnstaged(changes, in: root)
            }
        }
    }

    /// Only the unstaged section: staged work is never thrown away in bulk.
    func discardAll() {
        let changes = status.unstaged.filter(\.isDiscardable)
        guard !changes.isEmpty else { return }
        perform { try await $0.discardUnstaged(changes, in: $1) }
    }

    func commit() {
        let control = commitControl
        guard control.isEnabled else { return }
        let text = message
        let stagesFirst = control.mode == .commitAll
        run(.commit) { [git, root] in
            if stagesFirst { try await git.stageAll(in: root) }
            do {
                try await git.commit(message: text, in: root)
            } catch where stagesFirst {
                // Without this the user would see only the hook output and not know the files moved to staged.
                throw GitError(message: "All changes were staged, but the commit failed. They remain staged.\n\(error.localizedDescription)")
            }
        } onSuccess: { [self] in
            // The user may have kept typing while git ran.
            if message == text { message = "" }
        }
    }

    func performPrimaryAction() {
        switch primaryAction {
        case .commit: commit()
        case .pull: pull()
        case .push, .publish: push()
        }
    }

    func push() {
        guard syncState.canPush else { return }
        run(.push) { [git, root] in try await git.push(in: root) } onSuccess: { [self] in
            completedPushes += 1
            await refreshRemoteInfo()
        }
    }

    func pull() {
        guard syncState.canPull else { return }
        run(.pull) { [git, root] in try await git.pull(in: root) } onSuccess: {}
    }

    func fetch() {
        guard syncState.canFetch else { return }
        run(.fetch) { [git, root] in try await git.fetch(in: root) } onSuccess: {}
    }

    /// Network and process work that changes slowly: the remote list and the branch's pull request.
    /// Driven by tab appearance, app activation and branch or upstream changes, never the status poll.
    func refreshRemoteInfo() async {
#if DEBUG
        if isPreviewSample { return }
#endif
        async let pullRequest: Void = lookUpPullRequest()
        hasRemote = await git.hasRemote(in: root)
        await pullRequest
    }

    private func resolveGitHub() async -> GitHubClient? {
        if gitHubTask == nil {
            let searchPATH = searchPATH
            gitHubTask = Task { GitHubClient(searchPATH: await searchPATH()) }
        }
        let client = await gitHubTask?.value
        // A missing gh is retried next time, since the user may install it while the app runs.
        if client == nil { gitHubTask = nil }
        return client
    }

    private func lookUpPullRequest() async {
        guard let client = await resolveGitHub(), let branch = status.branch else { return }
        // One lookup per branch at a time; a switch to another branch supersedes the old one.
        guard lookupBranch != branch else { return }
        lookupGeneration += 1
        let current = lookupGeneration
        lookupBranch = branch
        defer { if current == lookupGeneration { lookupBranch = nil } }
        let outcome: PullRequestLookup.Outcome
        do {
            outcome = try await client.pullRequest(in: root).map { .found($0) } ?? .none
        } catch {
            // Not signed in or not a GitHub remote: the control just stays away instead of nagging.
            outcome = .unavailable
        }
        guard current == lookupGeneration, status.branch == branch else { return }
        pullRequestLookup = PullRequestLookup(branch: branch, outcome: outcome)
    }

    /// One action at a time; the checks and the work share a single task so nothing can interleave.
    private func run(
        _ activity: Activity,
        work: @escaping @Sendable () async throws -> Void,
        onSuccess: @escaping () async -> Void
    ) {
        guard self.activity == nil else { return }
#if DEBUG
        if isPreviewSample { return }
#endif
        self.activity = activity
        actionError = nil
        Task {
            do {
                try await work()
                await onSuccess()
            } catch {
                actionError = error.localizedDescription
            }
            // Refresh before going idle: the other order briefly offers the action that just ran again,
            // which after a push would also bring the sent-off arrow back for a moment.
            await refresh()
            self.activity = nil
        }
    }

    func change(for id: ChangeID) -> GitFileChange? {
        (id.staged ? status.staged : status.unstaged).first { $0.path == id.path }
    }

    func url(for change: GitFileChange) -> URL {
        root.appending(path: change.path)
    }

    private func perform(_ action: @escaping @Sendable (GitClient, URL) async throws -> Void) {
#if DEBUG
        if isPreviewSample { return }
#endif
        let git = git
        let root = root
        Task {
            do {
                try await action(git, root)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
            await refresh()
        }
    }
}

extension GitFileChange {
    /// Conflicts need resolving, and discarding one would silently pick a side.
    var isDiscardable: Bool { kind != .conflicted }
}

/// What the confirmation dialog is asking about. Lives on the model so rows, menus and the
/// section header can all raise the one dialog.
enum DiscardRequest: Equatable {
    case file(GitFileChange, staged: Bool)
    case allUnstaged(count: Int)

    var title: String {
        switch self {
        case .file(let change, _): "Discard changes to \((change.path as NSString).lastPathComponent)?"
        case .allUnstaged(let count): "Discard all \(count) unstaged changes?"
        }
    }

    var message: String {
        switch self {
        case .file(let change, let staged):
            if change.kind == .untracked { return "This file is not tracked by Git. It will be moved to the Trash." }
            if staged { return "Staged and unstaged changes to this file will be lost. This can't be undone." }
            return "This can't be undone."
        case .allUnstaged:
            return "Untracked files will be moved to the Trash. Changes to tracked files can't be recovered. Staged changes are kept."
        }
    }
}

struct ChangesTab: View {
    @Bindable var model: ChangesModel
    let actions: InspectorActions
    @Binding var focusCommitMessage: Bool
    @State private var showsStaged = true
    @State private var showsUnstaged = true
    @State private var discardRequest: DiscardRequest?

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(refresh: refresh) {
                if let branch = model.status.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                } else if model.phase == .ready {
                    Label("Detached HEAD", systemImage: "arrow.triangle.branch")
                }
            } accessory: {
                if model.phase == .ready { SyncMenu(model: model) }
            }
            if let message = model.actionError ?? model.refreshError {
                ErrorBanner(message: message, dismiss: model.actionError == nil ? nil : { model.actionError = nil })
            }
            content
                .frame(maxHeight: .infinity)
            if model.phase == .ready {
                CommitArea(model: model, focusRequest: $focusCommitMessage)
            }
        }
        .refreshing(every: .seconds(3)) { await model.refresh() }
        .task { await model.refreshRemoteInfo() }
        .onChange(of: model.status.branch) { refreshRemoteInfo() }
        .onChange(of: model.status.upstream) { refreshRemoteInfo() }
        .onAppActivation(perform: refreshRemoteInfo)
        .confirmationDialog(
            discardRequest?.title ?? "",
            isPresented: Binding(get: { discardRequest != nil }, set: { if !$0 { discardRequest = nil } }),
            presenting: discardRequest
        ) { request in
            Button("Discard", role: .destructive) {
                switch request {
                case .file(let change, let staged): model.discard(change, staged: staged)
                case .allUnstaged: model.discardAll()
                }
            }
        } message: { request in
            Text(request.message)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .notRepository:
            ContentUnavailableView(
                "Not a Git Repository",
                systemImage: "arrow.triangle.branch",
                description: Text("This folder isn't tracked by Git.")
            )
        case .ready where model.status.staged.isEmpty && model.status.unstaged.isEmpty:
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text("The working tree is clean.")
            )
        case .ready:
            List(selection: $model.selection) {
                if !model.status.staged.isEmpty {
                    section("Staged Changes", changes: model.status.staged, staged: true, isExpanded: $showsStaged)
                }
                if !model.status.unstaged.isEmpty {
                    section("Changes", changes: model.status.unstaged, staged: false, isExpanded: $showsUnstaged)
                }
            }
            .listStyle(.sidebar)
            .compactRows()
            .scrollEdgeFade()
            .contextMenu(forSelectionType: ChangeID.self) { ids in
                if let id = ids.first, let change = model.change(for: id) {
                    ChangeContextMenu(change: change, staged: id.staged, model: model, actions: actions) {
                        discardRequest = .file(change, staged: id.staged)
                    }
                }
            } primaryAction: { ids in
                for id in ids { actions.openDiff(id.path, id.staged, false) }
            }
            .onChange(of: model.selection) { _, selection in
                if let selection { actions.openDiff(selection.path, selection.staged, true) }
            }
        }
    }

    private func section(_ title: LocalizedStringKey, changes: [GitFileChange], staged: Bool, isExpanded: Binding<Bool>) -> some View {
        // Section(isExpanded:) gets a hover-only chevron on the trailing edge in sidebar lists,
        // which pushes the header buttons left right when you try to click them.
        Section {
            if isExpanded.wrappedValue {
                // Identified by path and side: a partially staged file is listed in both
                // sections of the same List, and identical ids would make SwiftUI drop a row.
                ForEach(changes.map { ListedChange(change: $0, staged: staged) }) { row in
                    ChangeRow(change: row.change, staged: staged, model: model) {
                        discardRequest = .file(row.change, staged: staged)
                    }
                        .tag(row.id)
                }
            }
        } header: {
            HStack {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                            .accessibilityHidden(true)
                        Text(title)
                        Text(changes.count, format: .number)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded.wrappedValue ? "Collapses the section" : "Expands the section")
                Spacer()
                if !staged {
                    let discardable = changes.filter(\.isDiscardable).count
                    if discardable > 0 {
                        Button("Discard All Changes", systemImage: "arrow.uturn.backward") {
                            discardRequest = .allUnstaged(count: discardable)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Discard All Changes")
                    }
                }
                Button(staged ? "Unstage All" : "Stage All", systemImage: staged ? "minus" : "plus") {
                    staged ? model.unstageAll() : model.stageAll()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(staged ? "Unstage All Changes" : "Stage All Changes")
            }
        }
    }

    private func refresh() {
        Task { await model.refresh() }
    }

    private func refreshRemoteInfo() {
        Task { await model.refreshRemoteInfo() }
    }
}

private struct ChangeRow: View {
    let change: GitFileChange
    let staged: Bool
    let model: ChangesModel
    let requestDiscard: () -> Void
    @State private var isHovering = false

    var body: some View {
        let name = (change.path as NSString).lastPathComponent
        let directory = (change.path as NSString).deletingLastPathComponent

        HStack(spacing: 6) {
            Image(systemName: FileIcon.symbol(for: name))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(name)
                .strikethrough(change.kind == .deleted)
                .lineLimit(1)
                .layoutPriority(1)
            Text(directory)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if isHovering {
                if change.isDiscardable {
                    Button("Discard Changes", systemImage: "arrow.uturn.backward", action: requestDiscard)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Discard Changes")
                }
                Button(staged ? "Unstage Changes" : "Stage Changes", systemImage: staged ? "minus" : "plus", action: toggleStage)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(staged ? "Unstage Changes" : "Stage Changes")
            }
            Text(change.kind.letter)
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(change.kind.color)
                .frame(minWidth: 14)
                .accessibilityLabel(change.kind.description)
        }
        .onHover { isHovering = $0 }
        .modifier(FileDragModifier(url: change.kind == .deleted ? nil : model.url(for: change)))
        .help(change.originalPath.map { "\(change.path), renamed from \($0)" } ?? change.path)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: staged ? "Unstage" : "Stage", toggleStage)
        .accessibilityAction(named: "Discard") { if change.isDiscardable { requestDiscard() } }
    }

    private func toggleStage() {
        staged ? model.unstage(change) : model.stage(change)
    }
}

/// A deleted file has nothing on disk to hand over.
private struct FileDragModifier: ViewModifier {
    let url: URL?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let url {
            content.draggable(url)
        } else {
            content
        }
    }
}

private struct ChangeContextMenu: View {
    let change: GitFileChange
    let staged: Bool
    let model: ChangesModel
    let actions: InspectorActions
    let requestDiscard: () -> Void

    var body: some View {
        Button(staged ? "Unstage Changes" : "Stage Changes") {
            staged ? model.unstage(change) : model.stage(change)
        }
        if change.isDiscardable {
            Button("Discard Changes…", role: .destructive, action: requestDiscard)
        }
        Divider()
        Button("Open File") { actions.openFile(model.url(for: change), false) }
            .disabled(change.kind == .deleted)
        Button("Open in Default App") { FileActions.open([model.url(for: change)]) }
            .disabled(change.kind == .deleted)
        Button("Reveal in Finder") { FileActions.reveal([model.url(for: change)]) }
            .disabled(change.kind == .deleted)
        Button("Copy Relative Path") { FileActions.copy([change.path]) }
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
        .padding(8)
        .background(.yellow.opacity(0.12), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

extension GitChangeKind {
    var letter: String {
        switch self {
        case .modified, .typeChanged: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }

    var color: Color {
        switch self {
        case .modified, .typeChanged: .orange
        case .added, .untracked: .green
        case .deleted, .conflicted: .red
        case .renamed, .copied: .blue
        }
    }

    var description: LocalizedStringKey {
        switch self {
        case .modified: "Modified"
        case .typeChanged: "Type Changed"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        }
    }
}

#if DEBUG
extension ChangesModel {
    /// A model frozen in the given state. It never runs git, so buttons that would do so do nothing.
    static func previewSample(
        _ status: GitStatus = PreviewSamples.mixed,
        phase: Phase = .ready,
        message: String = "",
        activity: Activity? = nil,
        hasRemote: Bool = true,
        pullRequest: GitPullRequest? = nil,
        refreshError: String? = nil,
        actionError: String? = nil
    ) -> ChangesModel {
        let model = ChangesModel(root: PreviewSamples.root, searchPATH: { "" })
        model.isPreviewSample = true
        model.status = status
        model.phase = phase
        model.message = message
        model.activity = activity
        model.hasRemote = hasRemote
        if let pullRequest, let branch = status.branch {
            model.pullRequestLookup = PullRequestLookup(branch: branch, outcome: .found(pullRequest))
        }
        model.refreshError = refreshError
        model.actionError = actionError
        return model
    }
}

@MainActor
private func previewChanges(_ model: ChangesModel) -> some View {
    ChangesTab(model: model, actions: PreviewSamples.actions, focusCommitMessage: .constant(false))
        .frame(width: 300, height: 560)
        .background(Color.inspectorBackground)
}

#Preview("Staged, Unstaged, Untracked and Conflicted") {
    previewChanges(.previewSample(message: "Add previews to the inspector"))
}

#Preview("Staged, Unstaged, Untracked and Conflicted, Dark") {
    previewChanges(.previewSample(message: "Add previews to the inspector"))
        .preferredColorScheme(.dark)
}

#Preview("No Changes") {
    previewChanges(.previewSample(PreviewSamples.clean))
}

#Preview("Action Failed") {
    previewChanges(.previewSample(
        PreviewSamples.stagedOnly,
        message: "Fix the session switcher",
        actionError: "All changes were staged, but the commit failed. They remain staged.\nhusky - pre-commit hook exited with code 1"
    ))
}

#Preview("Refresh Failed, Detached HEAD") {
    previewChanges(.previewSample(
        GitStatus(branch: nil, staged: [], unstaged: PreviewSamples.unstagedOnly.unstaged),
        refreshError: "fatal: Unable to create '.git/index.lock': File exists."
    ))
}

#Preview("Not a Repository") {
    previewChanges(.previewSample(.empty, phase: .notRepository))
}

#Preview("Loading") {
    previewChanges(.previewSample(.empty, phase: .loading))
}
#endif
