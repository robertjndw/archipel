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

    /// Kept outside the view so switching inspector tabs does not lose a half-written message, and
    /// in `CommitMessageDrafts` rather than in the model so switching worktrees does not either.
    /// Read from there every time instead of copied once: a commit can finish in a model that the
    /// inspector has already replaced, and its successor must not keep showing the committed text.
    var message: String {
        get { CommitMessageDrafts.shared.draft(for: root) }
        set { CommitMessageDrafts.shared.set(newValue, for: root) }
    }
    private(set) var activity: Activity?
    /// Bumped when a push or pull lands, so its arrow can fly off before the label changes.
    private(set) var syncCompletion = SyncCompletion(count: 0, direction: .up)
    /// Bumped when a commit lands, for the commit button's checkmark.
    private(set) var commitCompletions = 0
    private(set) var hasRemote = false
    private(set) var pullRequestLookup: PullRequestLookup?
    private let searchPATH: @MainActor () async -> String
    private var gitHubTask: Task<GitHubClient?, Never>?
    private var lookupGeneration = 0
    private var lookupBranch: String?
    /// The newest git command started from here: a stage, unstage or discard, and the git part of a
    /// commit, push, pull or fetch. Each one waits for the one before, since two git processes
    /// writing the index at once make the second fail on index.lock.
    private var pendingChange: Task<Void, Never>?
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
        // The poll keeps running while the confirmation is open. An entry that has since gone or
        // changed kind is not the one that was agreed to, as in `discardAll`.
        guard (staged ? status.staged : status.unstaged).contains(change) else { return }
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
    ///
    /// `confirmed` is the list the dialog asked about. The poll keeps running while the dialog is
    /// open, so the section may have grown since; anything new was never agreed to. Entries that
    /// went away or changed kind in the meantime are dropped rather than discarded blind.
    func discardAll(_ confirmed: [GitFileChange]) {
        let current = Dictionary(status.unstaged.map { ($0.path, $0) }) { first, _ in first }
        let changes = confirmed.filter { $0.isDiscardable && current[$0.path] == $0 }
        guard !changes.isEmpty else { return }
        perform { try await $0.discardUnstaged(changes, in: $1) }
    }

    func commit() {
        let control = commitControl
        guard control.isEnabled else { return }
        let text = message
        run(.commit) { [git, root] in
            // Asked now, with the stages queued before this commit done. The status on screen can
            // still be the one from before a stage click, with nothing staged, and going by that
            // would turn "commit the file I just staged" into "commit everything".
            let status = try await git.status(in: root)
            let fresh = CommitControl(status: status, message: text, isBusy: false)
            // A merge an agent started since the click would otherwise be staged, markers and all.
            guard fresh.isEnabled else {
                throw GitError(message: "The changes are no longer what the list showed, so nothing was committed. Look at them again before you commit.")
            }
            let stagesFirst = fresh.mode == .commitAll
            if stagesFirst { try await git.stageAll(in: root) }
            do {
                try await git.commit(message: text, in: root)
            } catch where stagesFirst {
                // Without this the user would see only the hook output and not know the files moved to staged.
                throw GitError(message: "All changes were staged, but the commit failed. They remain staged.\n\(error.localizedDescription)")
            }
        } onSuccess: { [self] in
            commitCompletions += 1
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
            await sendOffArrow(.up) { await refreshRemoteInfo() }
        }
    }

    func pull() {
        guard syncState.canPull else { return }
        run(.pull) { [git, root] in try await git.pull(in: root) } onSuccess: { [self] in
            await sendOffArrow(.down) {}
        }
    }

    /// Returns once the arrow has flown off. The refresh afterwards usually removes the arrow, and
    /// with a fast remote that would cut the flight short.
    private func sendOffArrow(_ direction: SyncDirection, while work: () async -> Void) async {
        syncCompletion = SyncCompletion(count: syncCompletion.count + 1, direction: direction)
        async let flight: Void? = try? Task.sleep(for: SyncArrow.sendOffDuration)
        await work()
        _ = await flight
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
        let previous = pendingChange
        let outcome = Task { () -> (any Error)? in
            // A commit right after a quick stage click would otherwise race it for the index.
            await previous?.value
            do {
                try await work()
                return nil
            } catch {
                return error
            }
        }
        // Only the git command is a link in the chain, so a stage clicked while a pre-commit hook
        // runs waits for the commit. What follows (the arrow's flight, the pull request lookup)
        // leaves the index alone and need not hold anything up.
        pendingChange = Task { _ = await outcome.value }
        Task {
            if let error = await outcome.value {
                actionError = error.localizedDescription
            } else {
                await onSuccess()
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
        let previous = pendingChange
        pendingChange = Task {
            await previous?.value
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

/// Unsent commit messages by worktree, for as long as the app runs. The inspector rebuilds its
/// models whenever the selected worktree changes, so the model alone would lose a draft on every switch.
@MainActor @Observable
final class CommitMessageDrafts {
    static let shared = CommitMessageDrafts()

    private var drafts: [String: String] = [:]

    func draft(for root: URL) -> String {
        drafts[root.pathKey] ?? ""
    }

    func set(_ message: String, for root: URL) {
        let message = message.isEmpty ? nil : message
        // Called on every keystroke, and an equal write would still redraw the field.
        if drafts[root.pathKey] != message { drafts[root.pathKey] = message }
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
    /// The discardable unstaged entries as they were when the dialog was raised.
    case allUnstaged([GitFileChange])

    var title: String {
        switch self {
        case .file(let change, _): "Discard changes to \((change.path as NSString).lastPathComponent)?"
        case .allUnstaged(let changes): "Discard all \(changes.count) unstaged changes?"
        }
    }

    var message: String {
        switch self {
        case .file(let change, let staged):
            if change.kind == .untracked { return "This file is not tracked by Git. It will be moved to the Trash." }
            if staged { return "Staged and unstaged changes to this file will be lost. This can't be undone." }
            // Unstaged and added means `git add -N`: git holds no content for it, so it is trashed like an untracked file.
            if change.kind == .added { return "Git has no copy of this file yet. It will be moved to the Trash." }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            InspectorHeader(refresh: refresh) {
                branchTitle
            } accessory: {
                if model.phase == .ready { SyncMenu(model: model) }
            }
            if let message = bannerMessage {
                ErrorBanner(message: message, dismiss: model.actionError == nil ? nil : { model.actionError = nil })
                    .transition(.opacity)
            }
            content
                .frame(maxHeight: .infinity)
            if model.phase == .ready {
                CommitArea(model: model, focusRequest: $focusCommitMessage)
            }
        }
        // The banner pushes the list down, so its arrival only animates without Reduce Motion.
        .animation(reduceMotion ? nil : Motion.disclosure, value: bannerMessage != nil)
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
                case .allUnstaged(let changes): model.discardAll(changes)
                }
            }
        } message: { request in
            Text(request.message)
        }
    }

    private var bannerMessage: String? {
        model.actionError ?? model.refreshError
    }

    @ViewBuilder
    private var branchTitle: some View {
        if model.phase == .ready, let switchBranch = actions.switchBranch {
            // Plain button with a chevron, like Xcode's branch picker. A bordered one is too heavy
            // for this header.
            Button(action: switchBranch) {
                HStack(spacing: 3) {
                    branchLabel
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Switch Branch…")
        } else {
            branchLabel
        }
    }

    @ViewBuilder
    private var branchLabel: some View {
        if let branch = model.status.branch {
            Label(branch, systemImage: "arrow.triangle.branch")
        } else if model.phase == .ready {
            Label("Detached HEAD", systemImage: "arrow.triangle.branch")
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
                    // Keep the HStack. With ChangeRow directly in the ForEach, a few thousand changes froze
                    // the app for 40 seconds after a branch switch, and Xcode Previews crashed on a SwiftUI
                    // assertion. List templates its row ids from the ForEach content's structure, and a
                    // custom view whose body ends in a conditional (FileDragModifier) could be any number
                    // of rows, so List has to build every ChangeRow to count them. An HStack is always
                    // exactly one row.
                    HStack {
                        ChangeRow(change: row.change, staged: staged, model: model) {
                            discardRequest = .file(row.change, staged: staged)
                        }
                    }
                    .tag(row.id)
                }
            }
        } header: {
            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : Motion.disclosure) { isExpanded.wrappedValue.toggle() }
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
                            .contentTransition(.numericText(value: Double(changes.count)))
                            .animation(reduceMotion ? nil : .smooth, value: changes.count)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
                .accessibilityHint(isExpanded.wrappedValue ? "Collapses the section" : "Expands the section")
                Spacer()
                if !staged {
                    let discardable = changes.filter(\.isDiscardable)
                    if !discardable.isEmpty {
                        Button("Discard All Changes", systemImage: "arrow.uturn.backward") {
                            discardRequest = .allUnstaged(discardable)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Discard All Changes")
                    }
                }
                Button(staged ? "Unstage All" : "Stage All", systemImage: staged ? "minus" : "plus") {
                    staged ? model.unstageAll() : model.stageAll()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
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
    @State private var isHovered = false

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
            // Always in the tree and faded by opacity, so the directory does not re-truncate
            // under the pointer when the buttons appear.
            HStack(spacing: 6) {
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
            .foregroundStyle(.secondary)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .accessibilityHidden(!isHovered)
            Text(change.kind.letter)
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(change.kind.color)
                .frame(minWidth: 14)
                .accessibilityLabel(change.kind.description)
        }
        .onHover { isHovered = $0 }
        .animation(Motion.hover, value: isHovered)
        .modifier(FileDragModifier(url: change.kind == .deleted ? nil : model.url(for: change)))
        .help(change.originalPath.map { "\(change.path), renamed from \($0)" } ?? change.path)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(staged ? "changes.staged" : "changes.unstaged")
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
        Button(staged ? "Unstage Changes" : "Stage Changes", systemImage: staged ? "minus" : "plus") {
            staged ? model.unstage(change) : model.stage(change)
        }
        if change.isDiscardable {
            Button("Discard Changes…", systemImage: "arrow.uturn.backward", role: .destructive, action: requestDiscard)
        }
        Divider()
        Button("Open File", systemImage: "doc") { actions.openFile(model.url(for: change), false) }
            .disabled(change.kind == .deleted)
        Button("Open in Default App", systemImage: "arrow.up.forward.app") { FileActions.open([model.url(for: change)]) }
            .disabled(change.kind == .deleted)
        Button("Show in Finder", systemImage: "folder") { FileActions.reveal([model.url(for: change)]) }
            .disabled(change.kind == .deleted)
        Button("Copy Relative Path", systemImage: "document.on.document") { FileActions.copy([change.path]) }
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: (() -> Void)?
    @State private var showsDetails = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Always offered: a failing hook or rejected push prints far more than four lines, and
            // whether the text above is cut off depends on the inspector's width.
            Button("Show Details", systemImage: "text.page") { showsDetails = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Show Details")
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    ErrorDetails(message: message)
                }
            if let dismiss {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
            }
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

/// The whole output of a failed git command, which is mostly what a hook or the remote printed.
private struct ErrorDetails: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Text(verbatim: message)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Spacer()
                Button("Copy", systemImage: "document.on.document") { FileActions.copy([message]) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 440)
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
