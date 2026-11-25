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

    /// Where a linked worktree went when its folder was renamed or moved within the folder that
    /// held it, which is what a rename in Finder does. `isProvablyGone` cannot tell that from a
    /// deletion, and git cannot either, yet dropping the registration ruins the moved worktree just
    /// as it would one on a disk that is not mounted.
    ///
    /// A worktree's `.git` file names its registration, and the registration's `gitdir` file names
    /// the `.git` file it was made for. A neighbour whose registration still points at `folder` is
    /// the worktree under its new name. One moved somewhere else is not found.
    public static func movedWorktree(from folder: URL) -> URL? {
        let folder = folder.standardizedFileURL
        let wanted = pathKey(folder.appending(path: ".git"))
        let parent = folder.deletingLastPathComponent()
        guard let neighbours = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { return nil }
        // A worktrees folder holds a handful of entries. Something far larger is not one, and is not worth reading through.
        for neighbour in neighbours.prefix(500) where pathKey(neighbour.appending(path: ".git")) != wanted {
            guard let registration = pointer(in: neighbour.appending(path: ".git"), prefix: "gitdir: "),
                  let recorded = pointer(in: registration.appending(path: "gitdir"), prefix: ""),
                  pathKey(recorded) == wanted
            else { continue }
            return neighbour.standardizedFileURL
        }
        return nil
    }

    /// The folder git has on record for the linked worktree at `folder`, which after a move by hand
    /// is still where it used to be. Nil for a main checkout or anything that is not a worktree.
    public static func recordedFolder(ofWorktreeAt folder: URL) -> URL? {
        guard let registration = pointer(in: folder.appending(path: ".git"), prefix: "gitdir: "),
              let recorded = pointer(in: registration.appending(path: "gitdir"), prefix: "")
        else { return nil }
        return recorded.deletingLastPathComponent().standardizedFileURL
    }

    /// The folders of the linked worktrees the main checkout at `folder` has registered. They do not
    /// move with the main checkout, which makes them the thing that tells a moved repository apart
    /// from another clone of it.
    public static func registeredWorktreeFolders(ofRepositoryAt folder: URL) -> [URL] {
        let registrations = folder.appending(path: ".git/worktrees", directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(at: registrations, includingPropertiesForKeys: nil)) ?? []
        return entries.prefix(500).compactMap { entry in
            pointer(in: entry.appending(path: "gitdir"), prefix: "")?.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// How far a folder picked to replace a project's missing primary checkout checks out as the
    /// same repository.
    public enum PrimaryCheckoutMatch: Equatable, Sendable {
        case same
        /// The project's linked worktrees are not registered in the chosen repository.
        case worktreesNotRegistered
        /// Both histories are known and share no root commit.
        case differentHistory
        /// The chosen repository lacks the branch the checkout was on.
        case missingBranch(String)
        /// Nothing known about the old repository tells either way, so the user has to say.
        case unverified
    }

    /// Weighs what is still known about a primary checkout whose folder is gone against a
    /// repository picked in its place. Linked worktrees decide when there are any: they stay put
    /// and are registered in exactly one repository. Root commits come next, since another clone
    /// with a `main` branch is the usual wrong pick. A shared root is enough, because merging in an
    /// unrelated history adds roots without the repository becoming another one.
    ///
    /// - Parameters:
    ///   - linkedWorktreesRegistered: nil when the project has no linked worktrees.
    ///   - recordedRoots: what the project noted while the folder existed, nil if never seen.
    ///   - candidateRoots: the chosen repository's, nil if git could not say.
    ///   - branch: the branch the checkout was on, nil for a detached HEAD.
    ///   - candidateBranches: the chosen repository's local branches, nil if git could not say.
    public static func primaryCheckoutMatch(
        linkedWorktreesRegistered: Bool?,
        recordedRoots: [String]?,
        candidateRoots: [String]?,
        branch: String?,
        candidateBranches: [String]?
    ) -> PrimaryCheckoutMatch {
        if let linkedWorktreesRegistered {
            return linkedWorktreesRegistered ? .same : .worktreesNotRegistered
        }
        if let recorded = recordedRoots, !recorded.isEmpty, let candidate = candidateRoots, !candidate.isEmpty {
            return Set(recorded).isDisjoint(with: candidate) ? .differentHistory : .same
        }
        // A branch only rules out: plenty of unrelated repositories have a `main`.
        if let branch, let candidateBranches, !candidateBranches.contains(branch) {
            return .missingBranch(branch)
        }
        return .unverified
    }

    /// Whether two paths name the same folder, symlinks resolved as far as they exist.
    public static func isSameFolder(_ first: URL, _ second: URL) -> Bool {
        pathKey(first) == pathKey(second)
    }

    /// The path a one-line git pointer file holds. git writes it absolute, or relative to the
    /// folder the file is in when `worktree.useRelativePaths` is set.
    private static func pointer(in file: URL, prefix: String) -> URL? {
        // A main checkout has a `.git` folder here, which fails to read as a file and is skipped.
        guard let line = (try? String(contentsOf: file, encoding: .utf8))?.split(whereSeparator: \.isNewline).first,
              line.hasPrefix(prefix)
        else { return nil }
        let path = String(line.dropFirst(prefix.count))
        guard !path.isEmpty else { return nil }
        return URL(filePath: path, relativeTo: file.deletingLastPathComponent()).standardizedFileURL
    }

    private static func pathKey(_ url: URL) -> String {
        Project.worktreeKey(resolvingExistingPart(of: url))
    }

    /// `url` with the symlinks resolved in as much of it as exists. The paths compared here are
    /// often of folders that are not there (yet, or any more), and Foundation leaves such a path
    /// untouched instead of resolving the part it can.
    private static func resolvingExistingPart(of url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while existing.pathComponents.count > 1 {
            if let resolved = realpath(existing.path(percentEncoded: false), nil) {
                defer { free(resolved) }
                return missing.reversed().reduce(URL(filePath: String(cString: resolved), directoryHint: .isDirectory)) {
                    $0.appending(path: $1, directoryHint: .isDirectory)
                }
            }
            missing.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
        return url.standardizedFileURL
    }

    /// The folders a project's linked worktrees sit in, plus the one it is configured to use.
    private static func worktreeFolders(of project: Project) -> Set<String> {
        var folders = Set(project.worktrees.lazy.filter { !$0.isMain }.map { folderKey($0.path.deletingLastPathComponent()) })
        if let custom = project.worktreesDirectory { folders.insert(folderKey(custom)) }
        return folders
    }

    /// Lowercased because the default file system does not tell `App` from `app`. Symlinks are
    /// resolved because git reports a worktree by its real path (`/private/tmp/x`) while one made
    /// here keeps the path as configured (`/tmp/x`), and both have to claim the same folder.
    private static func folderKey(_ url: URL) -> String {
        pathKey(url).lowercased()
    }
}
