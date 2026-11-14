import Foundation

/// Where a new worktree's folder goes.
public enum WorktreeLocation {
    /// A branch name as one path component: `feature/login` must not create a nested folder.
    public static func folderName(forBranch branch: String) -> String {
        String(branch.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" })
    }

    /// A project with its own folder gets the worktrees directly inside it. The shared default root
    /// holds every project, so there the project name is a level of its own.
    public static func path(for project: Project, branch: String, defaultRoot: URL) -> URL {
        let parent = project.worktreesDirectory
            ?? defaultRoot.appending(path: project.name, directoryHint: .isDirectory)
        return parent.appending(path: folderName(forBranch: branch), directoryHint: .isDirectory)
    }
}
