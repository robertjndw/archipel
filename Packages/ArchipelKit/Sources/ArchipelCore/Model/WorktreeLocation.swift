import Foundation

/// Where a new worktree's folder goes.
public enum WorktreeLocation {
    /// A branch name as one path component: `feature/login` must not create a nested folder.
    public static func folderName(forBranch branch: String) -> String {
        String(branch.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" })
    }

    /// A project name as one path component. Projects are named freely, so only what would leave or
    /// nest the folder is replaced: a name the user already has worktrees under keeps its folder.
    public static func folderName(forProject name: String) -> String {
        let cleaned = String(name.map { character in
            let breaksPath = character == "/" || character == ":" || character.isNewline
                || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
            return breaksPath ? "-" : character
        }).trimmingCharacters(in: .whitespaces)
        // "." and ".." are the root itself and its parent.
        return cleaned.allSatisfy { $0 == "." } ? "project" : cleaned
    }

    /// `projects` is every project of the workspace; see `defaultParentFolder`.
    public static func path(for project: Project, branch: String, defaultRoot: URL, among projects: [Project] = []) -> URL {
        parentFolder(for: project, defaultRoot: defaultRoot, among: projects)
            .appending(path: folderName(forBranch: branch), directoryHint: .isDirectory)
    }

    /// A project with its own folder gets the worktrees directly inside it.
    public static func parentFolder(for project: Project, defaultRoot: URL, among projects: [Project] = []) -> URL {
        project.worktreesDirectory ?? defaultParentFolder(for: project, defaultRoot: defaultRoot, among: projects)
    }

    /// The shared default root holds every project, so there the project name is a level of its own.
    ///
    /// Two projects can have the same name. The folder then belongs to whichever already keeps
    /// worktrees in it, and the other gets `name-2` (and so on). Going by where worktrees are, and
    /// not by the order of the projects, keeps the answer the same when the sidebar is reordered and
    /// never asks for an existing worktree to move.
    public static func defaultParentFolder(for project: Project, defaultRoot: URL, among projects: [Project] = []) -> URL {
        let name = folderName(forProject: project.name)
        func candidate(_ number: Int) -> URL {
            defaultRoot.appending(path: number == 1 ? name : "\(name)-\(number)", directoryHint: .isDirectory)
        }
        // A folder the project already keeps worktrees in comes first, whatever its number. The
        // numbers below it can be free again (their projects were removed or renamed), and counting
        // up from 1 would then hand out one of those and split the project over two folders.
        let own = worktreeFolders(of: project)
        let prefix = folderKey(defaultRoot) + "/" + name.lowercased()
        let ownNumbers = own.compactMap { key -> Int? in
            guard key.hasPrefix(prefix) else { return nil }
            let suffix = key.dropFirst(prefix.count)
            if suffix.isEmpty { return 1 }
            guard suffix.hasPrefix("-"), let number = Int(suffix.dropFirst()), number > 1, suffix == "-\(number)" else { return nil }
            return number
        }
        if let number = ownNumbers.min() { return candidate(number) }

        let taken = projects.lazy.filter { $0.id != project.id }.reduce(into: Set<String>()) { $0.formUnion(worktreeFolders(of: $1)) }
        // Only a folder in `taken` can be occupied, so one candidate more than those reaches a free one.
        for number in 1...(taken.count + 1) {
            let folder = candidate(number)
            if !taken.contains(folderKey(folder)) { return folder }
        }
        return candidate(1)
    }

    /// Whether a worktree whose folder is missing was really deleted, as opposed to sitting on a
    /// volume that is not mounted right now. git cannot tell the two apart: it calls any missing
    /// folder prunable, and dropping the registration of a worktree that comes back with its disk
    /// leaves it broken beyond what `git worktree repair` can fix (its index and HEAD lived in the
    /// registration).
    ///
    /// Only a folder whose surroundings are there counts as gone: the folder that held it still
    /// exists, and so does the volume for a path under `/Volumes`. Anything else is left alone.
    public static func isProvablyGone(_ folder: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        let folder = folder.standardizedFileURL
        let components = folder.pathComponents
        guard components.count > 1, !fileExists(Project.worktreeKey(folder)) else { return false }
        if components.count >= 3, components[1] == "Volumes" {
            // A worktree at the top of a disk has /Volumes as its parent, which is always there
            // and says nothing about the disk.
            guard components.count > 3, fileExists("/Volumes/" + components[2]) else { return false }
        }
        return fileExists(Project.worktreeKey(folder.deletingLastPathComponent()))
    }

    /// The folders a project's linked worktrees sit in, plus the one it is configured to use.
    private static func worktreeFolders(of project: Project) -> Set<String> {
        var folders = Set(project.worktrees.lazy.filter { !$0.isMain }.map { folderKey($0.path.deletingLastPathComponent()) })
        if let custom = project.worktreesDirectory { folders.insert(folderKey(custom)) }
        return folders
    }

    /// Lowercased because the default file system does not tell `App` from `app`.
    private static func folderKey(_ url: URL) -> String {
        Project.worktreeKey(url).lowercased()
    }
}
