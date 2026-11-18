import Foundation

/// Remotes for the sync tests. A bare repository in the sandbox stands in for the server, reached
/// by its path, so pushing and fetching never leave the machine.
extension Sandbox {
    /// Makes a bare repository, adds it to `repository` as origin and publishes `main` to it, so
    /// the main checkout starts out tracking `origin/main` and up to date with it.
    @discardableResult
    func makeRemote(for repository: FixtureRepository) throws -> FixtureRepository {
        let url = root.appending(path: "\(repository.url.lastPathComponent)-remote.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let remote = FixtureRepository(url: url, home: home)
        try remote.git("init", "--bare", "--initial-branch=main")
        try repository.git("remote", "add", "origin", url.path)
        try repository.git("push", "--quiet", "--set-upstream", "origin", "main")
        return remote
    }

    /// Another checkout of `remote`, for commits that reach the remote without the app knowing:
    /// a teammate's push, as far as the repository under test can tell.
    func clone(_ remote: FixtureRepository, named name: String) throws -> FixtureRepository {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        let clone = FixtureRepository(url: url, home: home)
        // Run from the sandbox, since the clone's own folder does not exist yet.
        try clone.git(["clone", "--quiet", remote.url.path, url.path], in: root)
        // The global configuration is /dev/null here as well, so without these git refuses to commit.
        try clone.git("config", "user.name", "Someone Else")
        try clone.git("config", "user.email", "someone@archipel.invalid")
        try clone.git("config", "commit.gpgsign", "false")
        return clone
    }
}

extension FixtureRepository {
    /// Writes a file and commits it, and returns the new commit's hash.
    @discardableResult
    func commit(_ path: String, _ contents: String, message: String) throws -> String {
        try write(path, contents)
        try git("add", "--", path)
        try git("commit", "--quiet", "-m", message)
        return try sha(of: "HEAD")
    }

    func sha(of ref: String) throws -> String {
        try git("rev-parse", "--verify", "--quiet", ref)
    }

    /// The upstream `branch` tracks, as `origin/name`. Throws when it tracks nothing.
    func upstream(of branch: String) throws -> String {
        try git("rev-parse", "--abbrev-ref", "\(branch)@{upstream}")
    }

    func contents(of path: String) throws -> String {
        try String(contentsOf: url.appending(path: path), encoding: .utf8)
    }
}
