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

/// The Changes tab's own state: what is selected, the message being written, errors to show and the
/// queue of git commands started here. Everything git says about the worktree, and whether a push,
/// pull, fetch or commit runs in it, is in the shared `GitWorktreeState`, which the sidebar and the
/// menus read too.
@MainActor @Observable
final class ChangesModel {
    enum Phase { case loading, notRepository, ready }

    let state: GitWorktreeState
    var root: URL { state.root }
    var actionError: String? {
        didSet { updateRetention() }
    }
    var selection: ChangeID?
    private let git = GitClient()

    /// Kept outside the view so switching inspector tabs does not lose a half-written message, and
    /// in `CommitMessageDrafts` rather than in the model so switching worktrees does not either.
    /// Read from there every time instead of copied once: a commit can finish in a model that the
    /// inspector has already replaced, and its successor must not keep showing the committed text.
    var message: String {
        get { CommitMessageDrafts.shared.draft(for: root) }
        set { CommitMessageDrafts.shared.set(newValue, for: root) }
    }
    /// Set while the operation in `state` is one this model started, which is the one whose error
    /// it has to deliver.
    @ObservationIgnored private var runsOperation = false {
        didSet { updateRetention() }
    }
    /// Bumped when a push or pull lands, so its arrow can fly off before the label changes.
    private(set) var syncCompletion = SyncCompletion(count: 0, direction: .up)
    /// Bumped when a commit lands, for the commit button's checkmark.
    private(set) var commitCompletions = 0
    /// The newest git command started from here: a stage, unstage or discard, and the git part of a
    /// commit, push, pull or fetch. Each one waits for the one before, since two git processes
    /// writing the index at once make the second fail on index.lock.
    private var pendingChange: Task<Void, Never>?
    /// Stages, unstages and discards that have not finished. They show no progress of their own,
    /// but one that fails has an error to deliver, see `ChangesModelStore`.
    @ObservationIgnored private var changesInFlight = 0
    /// What the last stage, unstage or discard left in `actionError`: its failure or its notice.
    /// The next one that works takes only that away again. Anything put there since, such as the
    /// reason a discard was turned down, was never its to clear.
    @ObservationIgnored private var changeMessage: String?
    /// Set when the worktree is gone. Git may still be running for it, and what that ends with
    /// must not put the model back in the store for the next worktree at the same path to find.
    @ObservationIgnored fileprivate var isRetired = false
    /// The folder this model was made for, see `ChangesModelStore.model(for:)`.
    @ObservationIgnored fileprivate let folder: FolderIdentity?
#if DEBUG
    /// Set on preview samples, which have no repository behind them and must never run git.
    @ObservationIgnored fileprivate var isPreviewSample = false
#endif

    typealias Activity = GitOperation

    init(state: GitWorktreeState) {
        self.state = state
        folder = FolderIdentity(of: state.root)
    }

    /// What the tab lists. Empty until the first read.
    var status: GitStatus { state.status ?? .empty }

    var phase: Phase {
        if state.status != nil { return .ready }
        return state.isRepository == false ? .notRepository : .loading
    }

    var refreshError: String? { state.refreshError }

    /// Whatever runs in the worktree, also when the Project menu or the palette started it.
    var activity: Activity? { state.operation }

    var commitControl: CommitControl {
        CommitControl(status: status, message: message, isBusy: activity != nil)
    }

    var syncState: SyncState { state.syncState }

    /// While git still runs for this model, or it holds an error nobody dismissed, the store keeps
    /// it for the inspector to pick up again. Otherwise the inspector's reference is the only one.
    private func updateRetention() {
#if DEBUG
        if isPreviewSample { return }
#endif
        if isRetired { return }
        if runsOperation || changesInFlight > 0 || actionError != nil {
            ChangesModelStore.shared.keep(self)
        } else {
            ChangesModelStore.shared.release(self)
        }
    }

    var primaryAction: PrimaryAction {
        PrimaryAction(commit: commitControl, sync: syncState)
    }

    /// The current branch's pull request, see `GitWorktreeState.pullRequest`.
    var pullRequest: GitPullRequest? { state.pullRequest }

    /// Reads into the shared state, so the sidebar row moves with the list. With a status already
    /// on screen a failed read keeps the list, and without one the tab shows that loading failed,
    /// see `ChangesTab.content`.
    func refresh() async {
#if DEBUG
        if isPreviewSample { return }
#endif
        await state.refresh()
    }

    /// The remotes and the branch's pull request, which change slowly. Driven by tab appearance,
    /// app activation and branch or upstream changes; the poll leaves the remotes alone while the
    /// branch has an upstream. An answer younger than half a minute is not asked again, the same
    /// as when the app comes forward.
    func refreshRemoteInfo() async {
#if DEBUG
        if isPreviewSample { return }
#endif
        await state.refresh(GitRefreshRequest(readsRemotes: true, pullRequestAge: .seconds(30)))
    }

    func stage(_ change: GitFileChange) {
        perform { try await $0.stage([change.path], in: $1) }
    }

    func unstage(_ change: GitFileChange) {
        // Unstaging only the new name of a rename would leave the old name's deletion staged.
        let paths = [change.path] + [change.originalPath].compactMap(\.self)
        perform { try await $0.unstage(paths, in: $1) }
    }

    /// Everything except unmerged files. `git add -A` would mark those as resolved with their
    /// conflict markers still in them, which is what `CommitControl` keeps Commit All from doing.
    /// Staging one of them stays a deliberate click on its own row.
    func stageAll() {
        perform { git, root in
            // Asked now rather than read off the screen, where a merge an agent started a moment
            // ago may not have arrived yet.
            let status = try await git.status(in: root)
            guard status.unstaged.contains(where: { $0.kind == .conflicted }) else {
                return try await git.stageAll(in: root)
            }
            let rest = status.unstaged.filter { $0.kind != .conflicted }
            try await git.stage(rest.flatMap { [$0.path] + [$0.originalPath].compactMap(\.self) }, in: root)
        }
    }

    func unstageAll() {
        perform { try await $0.unstageAll(in: $1) }
    }

    /// What the files of some changes look like on disk right now, to hand back to `discard` or
    /// `discardAll` once the user has answered.
    func stamps(of changes: [GitFileChange]) -> [String: FileStamp] {
        Dictionary(changes.map { ($0.path, FileStamp(of: root.appending(path: $0.path))) }) { first, _ in first }
    }

    /// An agent can rewrite a file while the confirmation is open without its entry changing at
    /// all, and what it wrote was never agreed to.
    private func isUntouched(_ change: GitFileChange, since seen: [String: FileStamp]?) -> Bool {
        guard let seen else { return true }
        return seen[change.path] == FileStamp(of: root.appending(path: change.path))
    }

    func discard(_ change: GitFileChange, staged: Bool, seen: [String: FileStamp]? = nil) {
        // The poll keeps running while the confirmation is open. An entry that has since gone or
        // changed kind is not the one that was agreed to, as in `discardAll`.
        guard change.isDiscardable else { return }
        let listed = staged ? status.staged : status.unstaged
        guard listed.contains(change), isUntouched(change, since: seen) else {
            // Otherwise the dialog closes and nothing says why the file is as it was.
            let name = (change.path as NSString).lastPathComponent
            if listed.contains(where: { $0.path == change.path }) {
                actionError = "Nothing was discarded: \(name) changed while the question was open. Look at it again before you discard it."
            } else {
                // Committed, staged or reverted behind the dialog, by an agent as a rule.
                actionError = staged
                    ? "Nothing was discarded: \(name) is no longer staged."
                    : "Nothing was discarded: \(name) has no unstaged changes any more."
            }
            return
        }
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
    /// went away or changed kind in the meantime are dropped rather than discarded blind, and so
    /// are files written to since `seen` was taken.
    func discardAll(_ confirmed: [GitFileChange], seen: [String: FileStamp]? = nil) {
        let current = Dictionary(status.unstaged.map { ($0.path, $0) }) { first, _ in first }
        let agreed = confirmed.filter(\.isDiscardable)
        let changes = agreed.filter { current[$0.path] == $0 && isUntouched($0, since: seen) }
        let gone = agreed.count { current[$0.path] == nil }
        let notice = Self.skippedNotice(changed: agreed.count - changes.count - gone, gone: gone, discardedAny: !changes.isEmpty)
        guard !changes.isEmpty else {
            if let notice { actionError = notice }
            return
        }
        perform(notice: notice) { try await $0.discardUnstaged(changes, in: $1) }
    }

    /// What to say about the files a Discard All left out. `changed` are still listed but are not
    /// what the dialog asked about; `gone` left the section altogether, typically because the
    /// agent committed them, and saying that they "changed" would send the user looking for edits.
    nonisolated static func skippedNotice(changed: Int, gone: Int, discardedAny: Bool) -> String? {
        let skipped = changed + gone
        guard skipped > 0 else { return nil }
        let single = skipped == 1
        let reason = if gone == 0 {
            "changed while the question was open"
        } else if changed == 0 {
            single ? "has no unstaged changes any more" : "have no unstaged changes any more"
        } else {
            "changed or lost their unstaged changes while the question was open"
        }
        if discardedAny {
            return "\(single ? "1 file" : "\(skipped) files") \(reason) and \(single ? "was" : "were") not discarded."
        }
        let advice = changed == 0 ? "" : " Look at \(single ? "it" : "them") again before you discard \(single ? "it" : "them")."
        return "Nothing was discarded: the \(single ? "file" : "files") \(reason).\(advice)"
    }

    /// Whether the entry stands for a folder. A staged nested repository is listed without the
    /// trailing slash that marks an untracked one, so only the disk can tell.
    func isFolder(_ change: GitFileChange) -> Bool {
        if change.isDirectory { return true }
        // Not followed: a link to a folder is a file as far as git and the Trash are concerned.
        let type = try? FileManager.default.attributesOfItem(atPath: url(for: change).path)[.type] as? FileAttributeType
        return type == .typeDirectory
    }

    func commit() {
        let control = commitControl
        guard control.isEnabled else { return }
        let text = message
        let offered = control.mode
        run(.commit) { [git, root] in
            // Asked now, with the stages queued before this commit done. The status on screen can
            // still be the one from before a stage click, with nothing staged, and going by that
            // would turn "commit the file I just staged" into "commit everything".
            let status = try await git.status(in: root)
            let fresh = CommitControl(status: status, message: text, isBusy: false)
            // A merge an agent started since the click would otherwise be staged, markers and all.
            // And the other way round from the stage click above: the button said Commit for what
            // was staged, the agent has since committed or reset it, and staging everything now
            // would commit files the user never offered, untracked ones included.
            guard fresh.isEnabled, !(offered == .commit && fresh.mode == .commitAll) else {
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
            // A push can create the remote branch a pull request is opened from.
            await sendOffArrow(.up) { await state.refresh(GitRefreshRequest(readsRemotes: true, pullRequestAge: .zero)) }
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
        run(.fetch) { [git, root] in try await git.fetch(in: root, userInitiated: true) } onSuccess: {}
    }

    /// One action at a time per worktree, counting those started from the menus; the checks and
    /// the work share a single task so nothing can interleave.
    private func run(
        _ activity: Activity,
        work: @escaping @Sendable () async throws -> Void,
        onSuccess: @escaping () async -> Void
    ) {
#if DEBUG
        if isPreviewSample { return }
#endif
        guard state.begin(activity) else { return }
        runsOperation = true
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
            state.end(activity)
            runsOperation = false
        }
    }

    func change(for id: ChangeID) -> GitFileChange? {
        (id.staged ? status.staged : status.unstaged).first { $0.path == id.path }
    }

    func url(for change: GitFileChange) -> URL {
        root.appending(path: change.path)
    }

    /// `notice` is shown once the action has worked, for what it left out on purpose. Without one,
    /// success clears the message of the action before it and nothing else, see `changeMessage`.
    private func perform(notice: String? = nil, _ action: @escaping @Sendable (GitClient, URL) async throws -> Void) {
#if DEBUG
        if isPreviewSample { return }
#endif
        let git = git
        let root = root
        let previous = pendingChange
        changesInFlight += 1
        updateRetention()
        pendingChange = Task {
            await previous?.value
            do {
                try await action(git, root)
                if let notice {
                    actionError = notice
                } else if let changeMessage, actionError == changeMessage {
                    actionError = nil
                }
                changeMessage = notice
            } catch {
                actionError = error.localizedDescription
                changeMessage = actionError
            }
            await refresh()
            changesInFlight -= 1
            updateRetention()
        }
    }
}

/// The models that still have something to show for a worktree the inspector has left: a commit,
/// push or pull in progress, or an error it ended with. The inspector builds its models anew for
/// every worktree it turns to, and a fresh one would show idle buttons while git still runs, let
/// the same commit be started twice, and never report a rejected push.
@MainActor
final class ChangesModelStore {
    static let shared = ChangesModelStore()

    private var kept: [String: ChangesModel] = [:]

    func model(for state: GitWorktreeState) -> ChangesModel {
        let root = state.root
        if let model = kept[root.pathKey] {
            // The path alone does not make it the same worktree: one that was removed, whether
            // or not anyone said so, can have a successor in the same place.
            if model.state === state, let folder = FolderIdentity(of: root), folder == model.folder { return model }
            forget(root)
        }
        return ChangesModel(state: state)
    }

    /// For a worktree that was removed. Its path can be given to a new worktree, which would
    /// otherwise open on the old one's error and list.
    func forget(_ root: URL) {
        kept.removeValue(forKey: root.pathKey)?.isRetired = true
    }

    func forget(except roots: Set<String>) {
        for (key, model) in kept where !roots.contains(key) {
            kept[key] = nil
            model.isRetired = true
        }
    }

    var isEmpty: Bool { kept.isEmpty }

    fileprivate func keep(_ model: ChangesModel) {
        kept[model.root.pathKey] = model
    }

    fileprivate func release(_ model: ChangesModel) {
        let key = model.root.pathKey
        if kept[key] === model { kept[key] = nil }
    }
}

/// Which folder a path leads to right now. Removing a worktree and creating another at its path
/// leaves the path as it was and changes this.
struct FolderIdentity: Equatable {
    private var volume: Int
    private var file: Int

    /// Nil when there is nothing at `url`.
    init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let volume = (attributes[.systemNumber] as? NSNumber)?.intValue,
              let file = (attributes[.systemFileNumber] as? NSNumber)?.intValue else { return nil }
        self.volume = volume
        self.file = file
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

    /// A message half written for a removed worktree is not a draft for the next one at its path.
    func forget(except roots: Set<String>) {
        // Only written when something goes: this is observed by the message field.
        if !drafts.keys.allSatisfy(roots.contains) { drafts = drafts.filter { roots.contains($0.key) } }
    }

    var isEmpty: Bool { drafts.isEmpty }
}

extension GitFileChange {
    /// Conflicts need resolving, and discarding one would silently pick a side. A folder is a
    /// nested repository or a linked worktree, which can have agents working in it: it is not one
    /// change, it does not count towards Discard All, and removing it is up to the user.
    var isDiscardable: Bool { kind != .conflicted && !isDirectory }
}

/// Enough of a file's state on disk to notice that it was written to. A missing file has neither.
struct FileStamp: Equatable {
    var modified: Date?
    var size: Int?

    init(of url: URL) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        modified = values?.contentModificationDate
        size = values?.fileSize
    }
}

/// What the confirmation dialog is asking about. Lives on the model so rows, menus and the
/// section header can all raise the one dialog.
enum DiscardRequest: Equatable {
    /// `isFolder` for an entry that stands for a nested repository, see `ChangesModel.isFolder`.
    case file(GitFileChange, staged: Bool, isFolder: Bool = false)
    /// The discardable unstaged entries as they were when the dialog was raised.
    case allUnstaged([GitFileChange])

    var changes: [GitFileChange] {
        switch self {
        case .file(let change, _, _): [change]
        case .allUnstaged(let changes): changes
        }
    }

    var title: String {
        switch self {
        case .file(let change, _, _): "Discard changes to \((change.path as NSString).lastPathComponent)?"
        case .allUnstaged(let changes): "Discard all \(changes.count) unstaged changes?"
        }
    }

    var message: String {
        switch self {
        case .file(let change, let staged, let isFolder):
            if change.kind == .untracked { return "This file is not tracked by Git. It will be moved to the Trash." }
            if staged {
                // Files no commit holds go to the Trash, see `GitClient.discardStaged`.
                switch change.kind {
                case .added, .copied:
                    // But never a folder: that is a repository of its own, which only loses its entry.
                    if isFolder { return "This folder is a Git repository of its own. Its entry will be removed from the index. The folder and everything in it stay where they are." }
                    return "This file has never been committed. It will be removed from the index and moved to the Trash."
                case .renamed:
                    let original = change.originalPath.map { ($0 as NSString).lastPathComponent } ?? "The old name"
                    return "\(original) comes back as it was last committed. This file, with any changes made since the rename, will be moved to the Trash."
                default:
                    return "Staged and unstaged changes to this file will be lost. This can't be undone."
                }
            }
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
    /// The files of `discardRequest` as they were when the question was asked.
    @State private var discardStamps: [String: FileStamp] = [:]
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
                case .file(let change, let staged, _): model.discard(change, staged: staged, seen: discardStamps)
                case .allUnstaged(let changes): model.discardAll(changes, seen: discardStamps)
                }
            }
        } message: { request in
            Text(request.message)
        }
        .onChange(of: discardRequest) { _, request in
            if let request { discardStamps = model.stamps(of: request.changes) }
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
        case .loading where model.refreshError != nil:
            // The banner above has git's message. A spinner under it would turn forever.
            ContentUnavailableView(
                "Can't Load Changes",
                systemImage: "exclamationmark.triangle",
                description: Text("Archipel tries again every few seconds while this tab is open.")
            )
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
                        discardRequest = .file(change, staged: id.staged, isFolder: model.isFolder(change))
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
                            discardRequest = .file(row.change, staged: staged, isFolder: model.isFolder(row.change))
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
            Image(systemName: change.isDirectory ? FileIcon.folder : FileIcon.symbol(for: name))
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
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(staged ? "changes.staged" : "changes.unstaged")
        .accessibilityAction(named: staged ? "Unstage" : "Stage", toggleStage)
        .accessibilityAction(named: "Discard") { if change.isDiscardable { requestDiscard() } }
    }

    private var help: String {
        if change.isDirectory {
            // Says why this row has no Discard button, which every other untracked row has.
            return "\(change.path) is a Git repository or worktree of its own. Discard leaves it alone; remove the folder yourself if it should go."
        }
        return change.originalPath.map { "\(change.path), renamed from \($0)" } ?? change.path
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
        let state = GitWorktreeState.preview(
            root: PreviewSamples.root,
            status: phase == .ready ? status : nil,
            isRepository: phase == .notRepository ? false : phase == .ready ? true : nil,
            refreshError: refreshError,
            remotes: hasRemote ? ["origin"] : [],
            pullRequest: pullRequest.flatMap { pullRequest in
                status.branch.map { PullRequestLookup(branch: $0, pullRequest: pullRequest, checkedAt: .now) }
            },
            operation: activity
        )
        let model = ChangesModel(state: state)
        model.isPreviewSample = true
        model.message = message
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

#Preview("Loading Failed") {
    previewChanges(.previewSample(
        .empty,
        phase: .loading,
        refreshError: "fatal: Unable to create '.git/index.lock': File exists."
    ))
}

#Preview("Nested Repository") {
    previewChanges(.previewSample(GitStatus(
        branch: "main",
        staged: [],
        unstaged: [
            GitFileChange(path: "Sources/App/AppModel.swift", kind: .modified),
            GitFileChange(path: ".claude/worktrees/fix-login/", kind: .untracked),
        ],
        upstream: "origin/main"
    )))
}
#endif
