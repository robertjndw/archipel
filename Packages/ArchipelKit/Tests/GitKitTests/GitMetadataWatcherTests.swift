import Foundation
import Testing
@testable import GitKit

@MainActor
final class GitMetadataWatcherTests {
    let base: URL
    let repo: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "GitMetadataWatcherTests-\(UUID().uuidString)")
        repo = base.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-q", "--allow-empty", "-m", "first")
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    @Test func commonDirectoryIsSharedByLinkedWorktrees() async throws {
        let linked = base.appending(path: "linked")
        try git("worktree", "add", "-q", "-b", "feature", linked.path)
        let client = GitClient()

        let fromMain = try #require(await client.commonDirectory(of: repo))
        let fromLinked = try #require(await client.commonDirectory(of: linked))

        #expect(fromMain.resolvingSymlinksInPath() == fromLinked.resolvingSymlinksInPath())
        #expect(fromMain.lastPathComponent == ".git")
        #expect(await client.commonDirectory(of: base) == nil)
    }

    /// What tells a push (remote branch where the local one is) from a fetch of someone else's commits.
    @Test func refsMatchComparesCommits() async throws {
        let client = GitClient()
        try git("update-ref", "refs/remotes/origin/main", "HEAD")
        #expect(await client.refsMatch("refs/remotes/origin/main", "refs/heads/main", in: repo))

        try git("-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-q", "--allow-empty", "-m", "second")
        #expect(await !client.refsMatch("refs/remotes/origin/main", "refs/heads/main", in: repo))
        #expect(await !client.refsMatch("refs/remotes/origin/missing", "refs/heads/main", in: repo))
    }

    @Test func reportsBranchSwitchButNotStatus() async throws {
        var changes: Set<GitMetadataChange> = []
        let watcher = GitMetadataWatcher(directory: repo.appending(path: ".git"), latency: 0.05) { batch in
            changes.formUnion(batch.paths.compactMap(GitMetadataChange.init(relativePath:)))
        }
        defer { watcher.stop() }
        #expect(watcher.isRunning)
        // FSEvents can report writes from just before the stream started.
        try await Task.sleep(for: .milliseconds(300))
        changes.removeAll()

        try git("status")
        try await Task.sleep(for: .milliseconds(500))
        #expect(changes.isEmpty)

        try git("switch", "-q", "-c", "feature")
        try await waitUntil { changes.contains(.head(worktree: nil)) }
        #expect(changes.contains(.localBranch("feature")))
    }

    @Test func missingFolderDoesNotCrash() async throws {
        let watcher = GitMetadataWatcher(directory: base.appending(path: "nowhere/.git")) { _ in }
        watcher.stop()
        watcher.stop()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(condition())
    }

    private func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }
}
