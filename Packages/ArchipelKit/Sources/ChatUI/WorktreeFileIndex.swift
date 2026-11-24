import Foundation
import GitKit

/// The files of a session's worktree, for @ mentions in the composer.
///
/// Listed on the first @ and kept. The list is brought up to date when the completion opens again
/// a while later, so a file the agent just wrote can be mentioned, without asking git on every
/// keystroke. Listing and ranking both happen off the main actor: a large repository has a
/// hundred thousand files and more.
actor WorktreeFileIndex {
    /// The files of a folder as paths relative to it, without what git ignores. Throws when the
    /// folder is no repository.
    typealias Lister = @Sendable (_ folder: URL) async throws -> [String]

    /// git's own answer: tracked files and untracked ones that are not ignored.
    static let gitFiles: Lister = { folder in try await GitClient().listFiles(in: folder) }

    nonisolated let root: URL
    private let list: Lister?
    private let staleAfter: Duration
    private var candidates: [FileMention]
    private var loadedAt: ContinuousClock.Instant?
    private var loading: Task<[FileMention], Never>?

    init(root: URL, list: @escaping Lister = WorktreeFileIndex.gitFiles, staleAfter: Duration = .seconds(5)) {
        self.root = root
        self.list = list
        self.staleAfter = staleAfter
        candidates = []
    }

    /// An index of fixed content that never looks at the disk, for previews.
    init(root: URL, files: [String]) {
        self.root = root
        list = nil
        staleAfter = .zero
        candidates = FileMentions.candidates(fromFiles: files)
    }

    /// The candidates to show for `query`, best first; see `FileMentions.rank`. Empty when the
    /// surrounding task was cancelled, which a caller that cancels has to tell apart itself.
    ///
    /// Answers from the list it has, however old, and waits only for the very first one. Not
    /// isolated, so a query that is already out of date does not hold up the one that replaced it.
    nonisolated func matches(query: String, recent: [String] = [], limit: Int = FileMentions.shownLimit) async -> [FileMention] {
        let candidates = await current()
        return FileMentions.rank(candidates, query: query, recent: recent, limit: limit) ?? []
    }

    /// Lists the files again when the list is older than a few seconds. True when that changed
    /// what can be mentioned, so matches already on screen are worth asking for again.
    func refreshIfStale() async -> Bool {
        guard list != nil else { return false }
        guard let loadedAt else {
            // Nothing is on screen from a list that never existed; `matches` waits for this one.
            _ = await load()
            return false
        }
        guard ContinuousClock.now - loadedAt >= staleAfter else { return false }
        let before = candidates
        return await load() != before
    }

    private func current() async -> [FileMention] {
        loadedAt == nil && list != nil ? await load() : candidates
    }

    /// One listing at a time; whoever asks while it runs gets its result.
    private func load() async -> [FileMention] {
        guard let list else { return candidates }
        if let loading { return await loading.value }
        let root = root
        let task = Task.detached(priority: .userInitiated) {
            var paths: [String]
            do {
                paths = try await list(root)
                Self.markSubmodules(in: &paths, root: root)
            } catch {
                // Not a repository, or git is not there: walk the folder instead.
                paths = Self.walk(root, limit: Self.maximumWalkedFiles)
            }
            return FileMentions.candidates(fromFiles: paths)
        }
        loading = task
        let listed = await task.value
        loading = nil
        candidates = listed
        loadedAt = .now
        return listed
    }

    /// git lists a submodule as one entry that looks like a file. With the slash a nested
    /// repository's entry has, it becomes the folder it is. Only looked for in a listing that
    /// has a `.gitmodules` at its top, which is read once per listing.
    static func markSubmodules(in paths: inout [String], root: URL) {
        let name = ".gitmodules"
        guard paths.contains(name),
              let text = try? String(contentsOf: root.appending(path: name, directoryHint: .notDirectory), encoding: .utf8)
        else { return }
        let submodules = FileMentions.submodulePaths(inGitmodules: text)
        guard !submodules.isEmpty else { return }
        for index in paths.indices where submodules.contains(paths[index]) {
            paths[index] += "/"
        }
    }

    // MARK: Without git

    /// Without git's ignore rules the walk cannot tell a source folder from a cache, so it stops
    /// here rather than index a home folder.
    static let maximumWalkedFiles = 20_000

    private static let skippedFolders: Set<String> = ["node_modules", ".build", "DerivedData"]

    /// The files under `root` as relative paths, without hidden folders and build output.
    ///
    /// Level by level, so `limit` cuts what lies deepest, and within the level that goes over it
    /// the folders with the fewest files come first: one folder of twenty thousand downloaded
    /// packages then fills what is left, and not the list before the project's own sources.
    static func walk(_ root: URL, limit: Int) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        var files: [String] = []
        // Paths are put together from names, so they do not depend on how the system spells the
        // way to `root` (`/tmp` and `/private/tmp` are the same folder).
        var level = [""]
        while !level.isEmpty, files.count < limit {
            var found: [[String]] = []
            var next: [String] = []
            for folder in level {
                let url = folder.isEmpty ? root : root.appending(path: folder, directoryHint: .isDirectory)
                guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { continue }
                var inFolder: [String] = []
                for entry in entries {
                    let name = entry.lastPathComponent
                    let path = folder.isEmpty ? name : folder + "/" + name
                    // A link to a folder is a file here, so the walk cannot go in circles.
                    if (try? entry.resourceValues(forKeys: Set(keys)).isDirectory) == true {
                        if !name.hasPrefix("."), !skippedFolders.contains(name) { next.append(path) }
                    } else {
                        inFolder.append(path)
                    }
                }
                if !inFolder.isEmpty { found.append(inFolder) }
            }
            if files.count + found.reduce(0, { $0 + $1.count }) > limit {
                // The system lists a folder in no particular order; sorted, the cut is the same
                // every time.
                found = found.map { $0.sorted() }.sorted { ($0.count, $0[0]) < ($1.count, $1[0]) }
            }
            for inFolder in found {
                files += inFolder.prefix(limit - files.count)
                if files.count >= limit { break }
            }
            level = next.sorted()
        }
        return files.sorted()
    }
}
