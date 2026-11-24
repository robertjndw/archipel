import AppKit
import ArchipelCore
import Foundation
import GitKit

/// Finds worktrees that exist on disk but are not in the sidebar, the way VS Code lists a
/// repository's worktrees. They are only ever suggested, never added on their own: a repository
/// can have dozens of agent scratch worktrees, and showing all of them is what we want to avoid.
extension AppModel {
    /// Asks git for every project's worktrees and notes tracked ones whose folder has vanished.
    /// Cheap enough to run whenever the app comes to the front.
    func refreshWorktreeDiscovery() {
        refreshMissingWorktrees()
        guard isGitAvailable else { return }
        // Requests come in bursts (activation, adding projects, removing a worktree). One pass runs
        // at a time; a request made while it runs makes it start over, so it neither overlaps a
        // second pass nor finishes with a list from before whatever prompted the request.
        worktreeDiscoveryGeneration += 1
        guard !worktreeDiscoveryInFlight else { return }
        worktreeDiscoveryInFlight = true
        Task {
            var generation: Int
            repeat {
                generation = worktreeDiscoveryGeneration
                for project in workspace.islands.flatMap(\.projects) {
                    // Fails for a plain folder, which has no worktrees; dropping the entry hides any stale suggestion.
                    let entries = try? await git.worktrees(of: project.folderURL)
                    guard generation == worktreeDiscoveryGeneration else { break }
                    let current = workspace.project(id: project.id) ?? project
                    let aligned = entries.flatMap { Self.aligned($0, to: current) }
                    if gitWorktrees[project.id] != aligned { gitWorktrees[project.id] = aligned }
                    if aligned != nil, current.rootCommits == nil { await noteRootCommits(of: current) }
                }
            } while generation != worktreeDiscoveryGeneration
            worktreeDiscoveryInFlight = false
            let known = Set(workspace.islands.flatMap(\.projects).map(\.id))
            if !gitWorktrees.keys.allSatisfy(known.contains) {
                gitWorktrees = gitWorktrees.filter { known.contains($0.key) }
            }
        }
    }

    /// Notes the repository's root commits while its folder is there, so Locate Folder can tell a
    /// moved copy from an unrelated repository once it is gone. Once per project: they never change.
    private func noteRootCommits(of project: Project) async {
        guard let roots = await git.rootCommits(in: project.folderURL), !roots.isEmpty,
              let current = workspace.project(id: project.id), current.rootCommits == nil,
              current.folderURL == project.folderURL
        else { return }
        mutate { $0.updateProject(id: project.id) { $0.rootCommits = roots } }
    }

    /// The missing-folder check, run on activation and by the status timer: a folder deleted or
    /// moved without git would otherwise look healthy until the app is next brought to the front.
    ///
    /// Asking about a folder on a network volume that went away can hang for minutes. So the
    /// asking happens on a serial queue of its own rather than the Swift concurrency pool, which a
    /// few hung checks would use up for every other task in the app, and a request made while a
    /// check runs is folded into one more check afterwards instead of queueing behind it.
    func refreshMissingWorktrees() {
        guard !missingFolderCheckInFlight else {
            missingFolderCheckRequested = true
            return
        }
        missingFolderCheckInFlight = true
        missingFolderCheckRequested = false
        let worktrees = workspace.allWorktrees.map { (id: $0.id, path: $0.path.path(percentEncoded: false)) }
        Task { [weak self] in
            let missing = await withCheckedContinuation { continuation in
                Self.missingFolderQueue.async {
                    continuation.resume(returning: Set(worktrees.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id)))
                }
            }
            guard let self else { return }
            missingFolderCheckInFlight = false
            defer { if missingFolderCheckRequested { refreshMissingWorktrees() } }
            // The workspace may have changed while the disk was asked. Only worktrees still at the
            // path that was checked take the answer; the rest keep what they had.
            let checked = Dictionary(worktrees.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
            let current = Set(workspace.allWorktrees.lazy.filter { checked[$0.id] == $0.path.path(percentEncoded: false) }.map(\.id))
            let tracked = Set(workspace.allWorktrees.map(\.id))
            let updated = missingWorktrees.subtracting(current).union(missing.intersection(current)).intersection(tracked)
            if updated != missingWorktrees { missingWorktrees = updated }
        }
    }

    nonisolated private static let missingFolderQueue = DispatchQueue(label: "Archipel.missing-folder-check", qos: .utility)

    /// A project whose repository folder is gone can only be located again or removed.
    func isPrimaryCheckoutMissing(of project: Project) -> Bool {
        project.worktrees.contains { $0.isMain && missingWorktrees.contains($0.id) }
    }

    /// The worktree when a session can start in it: one whose folder is missing has nowhere to run.
    func worktreeForNewSession(_ id: Worktree.ID?) -> Worktree? {
        guard let id, !missingWorktrees.contains(id) else { return nil }
        return workspace.worktree(id: id)
    }

    /// git reports folders with symlinks resolved (`/private/var`, a symlinked `~/Developer`) while
    /// we keep whatever spelling the user picked, so a plain key comparison would suggest tracked
    /// worktrees, even the main checkout, as new. Entries for tracked or dismissed folders take our
    /// spelling here, once per refresh, because `untracked` runs in view bodies and must not touch
    /// the disk. Returns nil when the project folder is not itself a worktree root (a subfolder of
    /// a repository), whose repository's worktrees are not this project's to suggest.
    ///
    /// A bare repository is left out as well: git lists it first, as if it were the main checkout,
    /// but it has no files to open a session on.
    static func aligned(_ entries: [GitWorktreeEntry], to project: Project) -> [GitWorktreeEntry]? {
        var ours: [String: URL] = [:]
        for path in project.dismissedWorktreePaths {
            ours[resolvedKey(URL(filePath: path, directoryHint: .isDirectory))] = URL(filePath: path, directoryHint: .isDirectory)
        }
        for worktree in project.worktrees { ours[resolvedKey(worktree.path)] = worktree.path }
        let folder = resolvedKey(project.folderURL)
        guard entries.contains(where: { resolvedKey($0.path) == folder }) else { return nil }
        return withoutBareRepository(entries).map { entry in
            var entry = entry
            if let path = ours[resolvedKey(entry.path)] { entry.path = path }
            return entry
        }
    }

    /// git says which entry is the bare repository; only the first one can be.
    static func withoutBareRepository(_ entries: [GitWorktreeEntry]) -> [GitWorktreeEntry] {
        entries.filter { !$0.isBare }
    }

    /// Touches the disk, so keep it out of view bodies.
    static func resolvedKey(_ url: URL) -> String {
        Project.worktreeKey(url.resolvingSymlinksInPath())
    }

    /// Worktrees worth offering in the sidebar: on disk, not tracked yet, not dismissed.
    func suggestedWorktrees(for project: Project) -> [GitWorktreeEntry] {
        Self.untracked(gitWorktrees[project.id] ?? [], in: project)
            .filter { !project.dismissedWorktreePaths.contains(Project.worktreeKey($0.path)) }
    }

    func addExistingWorktrees(_ entries: [GitWorktreeEntry], to project: Project.ID) {
        changingSelection { workspace in
            for entry in entries {
                workspace.addWorktree(Worktree(path: entry.path, branch: entry.branch), to: project)
            }
        }
    }

    func dismissSuggestedWorktree(_ entry: GitWorktreeEntry, in project: Project.ID) {
        mutate { $0.dismissWorktree(path: entry.path, in: project) }
    }

    func restoreDismissedWorktrees(in project: Project.ID) {
        mutate { $0.restoreDismissedWorktrees(in: project) }
    }

    // MARK: Locating a moved folder

    /// Asks where a worktree whose folder is missing went, and points it there once the folder
    /// checks out as the same worktree (or, for the primary checkout, the same repository).
    func locateFolder(of id: Worktree.ID) {
        guard let worktree = workspace.worktree(id: id) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Locate"
        panel.message = worktree.isMain
            ? "Choose the folder the repository \(worktree.path.lastPathComponent) was moved to."
            : "Choose the folder the worktree \(worktree.displayName) was moved to."
        // A worktree renamed in Finder is usually right next to where it was.
        let moved = worktree.isMain ? nil : WorktreeLocation.movedWorktree(from: worktree.path)
        panel.directoryURL = moved ?? Self.nearestExistingFolder(above: worktree.path)
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            Task { await self?.relocate(id, to: folder) }
        }
    }

    private static func nearestExistingFolder(above url: URL) -> URL {
        var folder = url.standardizedFileURL.deletingLastPathComponent()
        while folder.pathComponents.count > 1, !FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            folder = folder.deletingLastPathComponent()
        }
        return folder
    }

    func relocate(_ id: Worktree.ID, to folder: URL) async {
        guard let worktree = workspace.worktree(id: id), let project = workspace.project(containingWorktree: id) else { return }
        switch await relocationCheck(of: worktree, in: project, to: folder) {
        case .fine:
            break
        case .problem(let problem):
            self.problem = problem
            return
        case .unverified(let question, let detail):
            guard await Self.confirm(question, detail: detail, action: "Use Folder") else { return }
        }
        // Checked again: git was asked in between, and the worktree may have changed or gone.
        guard workspace.worktree(id: id)?.path == worktree.path else { return }
        var changes: [(old: URL, new: URL)] = []
        mutate { changes = $0.relocateWorktree(id: id, to: folder) }
        // Comments are kept by folder, and would be dropped as belonging to a worktree that is gone.
        for change in changes {
            reviewComments.move(from: change.old, to: change.new)
        }
        if isGitAvailable {
            // git still has the old places on record on both sides of the move. Failing only
            // leaves that as it was, which finding the folder again does not depend on.
            if worktree.isMain {
                let linked = (workspace.project(id: project.id)?.worktrees ?? []).filter { !$0.isMain }.map(\.path)
                    .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
                try? await git.repairWorktrees(in: folder, paths: linked)
            } else {
                try? await git.repairWorktrees(in: folder)
            }
        }
        if worktree.isMain, let moved = workspace.project(id: project.id) { loadIcon(of: moved) }
        // The folder was just picked, so it is there; the check below only confirms it a moment later.
        missingWorktrees.remove(id)
        refreshBranches()
        refreshWorktreeDiscovery()
        refreshGitStatus(lookingUpPullRequests: true)
        syncGitWatchers(retryingUnwatchable: true)
    }

    private enum RelocationCheck {
        case fine
        case problem(String)
        /// Nothing contradicts the folder, but nothing proves it either.
        case unverified(question: String, detail: String)
    }

    private func relocationCheck(of worktree: Worktree, in project: Project, to folder: URL) async -> RelocationCheck {
        if let problem = await relocationProblem(of: worktree, in: project, to: folder) { return .problem(problem) }
        guard worktree.isMain, project.worktrees.allSatisfy(\.isMain), worktree.branch != nil || project.rootCommits != nil else {
            return .fine
        }
        var candidateRoots: [String]?
        var candidateBranches: [String]?
        if isGitAvailable {
            candidateRoots = await git.rootCommits(in: folder)
            candidateBranches = try? await git.localBranches(in: folder)
        }
        let name = folder.lastPathComponent
        switch WorktreeLocation.primaryCheckoutMatch(
            linkedWorktreesRegistered: nil,
            recordedRoots: project.rootCommits,
            candidateRoots: candidateRoots,
            branch: worktree.branch,
            candidateBranches: candidateBranches
        ) {
        case .same:
            return .fine
        case .differentHistory:
            return .problem("\(name) is not the repository of \(project.name): it shares no history with it.")
        case .missingBranch(let branch):
            return .problem("\(name) has no branch \(branch), so it is not the repository of \(project.name).")
        case .worktreesNotRegistered:
            return .problem("\(name) is not the repository of \(project.name): its worktrees are not registered there.")
        case .unverified:
            return .unverified(
                question: "Use \(name) for \(project.name)?",
                detail: "Archipel could not verify that \(name) is the same repository as \(project.name). If it is another repository, the project's sessions, status and review comments move to it."
            )
        }
    }

    /// Asks on the window the request came from, or as a free-standing alert without one.
    private static func confirm(_ question: String, detail: String, action: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    /// Why `folder` cannot stand in for the worktree's missing one, or nil when it can. For a
    /// primary checkout without linked worktrees, `relocationCheck` weighs the rest.
    private func relocationProblem(of worktree: Worktree, in project: Project, to folder: URL) async -> String? {
        let name = folder.lastPathComponent
        if workspace.allWorktrees.contains(where: { $0.id != worktree.id && WorktreeLocation.isSameFolder($0.path, folder) }) {
            return "\(name) is already in the sidebar."
        }
        let linked = project.worktrees.filter { !$0.isMain }
        if worktree.isMain {
            var isMainCheckout = false
            if isGitAvailable, let main = (try? await git.worktrees(of: folder))?.first {
                isMainCheckout = main.isMain && !main.isBare && WorktreeLocation.isSameFolder(main.path, folder)
            }
            guard isMainCheckout else {
                // A project that never was a repository is a plain folder, and any folder will do.
                let wasRepository = worktree.branch != nil || !linked.isEmpty || project.rootCommits != nil
                let isRepository = isGitAvailable ? await git.isRepository(folder) : false
                if !wasRepository, !isRepository { return nil }
                return "\(name) is not the main checkout of a git repository."
            }
            // The linked worktrees stay where they are, so a repository that has them registered is
            // this one. Without any, `relocationCheck` goes by the history and the branch.
            if !linked.isEmpty {
                let registered = WorktreeLocation.registeredWorktreeFolders(ofRepositoryAt: folder)
                let isSame = linked.contains { worktree in registered.contains { WorktreeLocation.isSameFolder($0, worktree.path) } }
                return isSame ? nil : "\(name) is not the repository of \(project.name): its worktrees are not registered there."
            }
            return nil
        }
        guard let recorded = WorktreeLocation.recordedFolder(ofWorktreeAt: folder) else {
            return "\(name) is not a linked git worktree."
        }
        // Until it is repaired, a moved worktree's registration still names its old folder.
        if WorktreeLocation.isSameFolder(recorded, worktree.path) { return nil }
        // Repaired already: then it has to be of this repository and on the same branch.
        if WorktreeLocation.isSameFolder(recorded, folder), isGitAvailable,
           let common = await git.commonDirectory(of: folder),
           let projectCommon = await git.commonDirectory(of: project.folderURL),
           WorktreeLocation.isSameFolder(common, projectCommon) {
            guard let expected = worktree.branch else { return nil }
            if await git.currentBranch(in: folder) == expected { return nil }
        }
        return "\(name) is a different worktree than \(worktree.displayName)."
    }
}
