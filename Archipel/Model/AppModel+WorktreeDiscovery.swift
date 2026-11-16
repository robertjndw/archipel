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
        let missing = Set(workspace.allWorktrees
            .filter { !FileManager.default.fileExists(atPath: $0.path.path(percentEncoded: false)) }
            .map(\.id))
        if missing != missingWorktrees { missingWorktrees = missing }
        let projects = workspace.islands.flatMap(\.projects)
        // Refreshes overlap (activation, adding projects, removing a worktree), and a slow older one
        // must not overwrite a newer list with worktrees that have been removed since.
        worktreeDiscoveryGeneration += 1
        let generation = worktreeDiscoveryGeneration
        Task {
            for project in projects {
                // Fails for a plain folder, which has no worktrees; dropping the entry hides any stale suggestion.
                let entries = try? await git.worktrees(of: project.folderURL)
                guard generation == worktreeDiscoveryGeneration else { return }
                let current = workspace.project(id: project.id) ?? project
                gitWorktrees[project.id] = entries.flatMap { Self.aligned($0, to: current) }
            }
            let known = Set(workspace.islands.flatMap(\.projects).map(\.id))
            if !gitWorktrees.keys.allSatisfy(known.contains) {
                gitWorktrees = gitWorktrees.filter { known.contains($0.key) }
            }
        }
    }

    /// git reports folders with symlinks resolved (`/private/var`, a symlinked `~/Developer`) while
    /// we keep whatever spelling the user picked, so a plain key comparison would suggest tracked
    /// worktrees, even the main checkout, as new. Entries for tracked or dismissed folders take our
    /// spelling here, once per refresh, because `untracked` runs in view bodies and must not touch
    /// the disk. Returns nil when the project folder is not itself a worktree root (a subfolder of
    /// a repository), whose repository's worktrees are not this project's to suggest.
    static func aligned(_ entries: [GitWorktreeEntry], to project: Project) -> [GitWorktreeEntry]? {
        var ours: [String: URL] = [:]
        for path in project.dismissedWorktreePaths {
            ours[resolvedKey(URL(filePath: path, directoryHint: .isDirectory))] = URL(filePath: path, directoryHint: .isDirectory)
        }
        for worktree in project.worktrees { ours[resolvedKey(worktree.path)] = worktree.path }
        let folder = resolvedKey(project.folderURL)
        guard entries.contains(where: { resolvedKey($0.path) == folder }) else { return nil }
        return entries.map { entry in
            var entry = entry
            if let path = ours[resolvedKey(entry.path)] { entry.path = path }
            return entry
        }
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
}
