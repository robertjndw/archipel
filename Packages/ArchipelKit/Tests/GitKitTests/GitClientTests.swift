import Foundation
import Testing
@testable import GitKit

/// Each test gets a fresh repository in its own temp directory, removed in deinit.
final class GitClientTests {
    let base: URL
    let repo: URL
    let git = GitClient()

    init() throws {
        // git reports /private/var paths; resolvingSymlinksInPath would map them back to /var, realpath does not.
        let temp = realpath(FileManager.default.temporaryDirectory.path, nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
        base = URL(filePath: temp).appending(path: "GitKitTests-\(UUID().uuidString)")
        repo = base.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try sh("init", "-q", "-b", "main")
        try sh("config", "user.name", "GitKit Tests")
        try sh("config", "user.email", "tests@example.invalid")
        try sh("config", "commit.gpgsign", "false")
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    @Test func reportsStagedUnstagedUntrackedRenamedAndDeleted() async throws {
        try write("keep.txt", "one\n")
        try write("old name.txt", "rename me\n")
        try write("doomed.txt", "bye\n")
        try write("staged del.txt", "bye\n")
        try commitAll()

        try write("keep.txt", "two\n")
        try sh("mv", "old name.txt", "new name.txt")
        try FileManager.default.removeItem(at: repo.appending(path: "doomed.txt"))
        try sh("rm", "-q", "staged del.txt")
        try write("dir with space/fresh file.txt", "hi\n")
        try write("added.txt", "a\n")
        try sh("add", "added.txt")

        let status = try await git.status(in: repo)

        #expect(status.branch == "main")
        #expect(status.staged.contains(GitFileChange(path: "new name.txt", originalPath: "old name.txt", kind: .renamed)))
        #expect(status.staged.contains(GitFileChange(path: "staged del.txt", kind: .deleted)))
        #expect(status.staged.contains(GitFileChange(path: "added.txt", kind: .added)))
        #expect(status.unstaged.contains(GitFileChange(path: "keep.txt", kind: .modified)))
        #expect(status.unstaged.contains(GitFileChange(path: "doomed.txt", kind: .deleted)))
        #expect(status.unstaged.contains(GitFileChange(path: "dir with space/fresh file.txt", kind: .untracked)))
    }

    @Test func stageAndUnstageRoundTrip() async throws {
        try write("a.txt", "a\n")
        try commitAll()
        try write("a.txt", "changed\n")
        try write("b [1].txt", "glob characters\n")
        try write("c.txt", "c\n")

        try await git.stage(["a.txt", "b [1].txt"], in: repo)
        var status = try await git.status(in: repo)
        #expect(status.staged.map(\.path).sorted() == ["a.txt", "b [1].txt"])
        #expect(status.unstaged.map(\.path) == ["c.txt"])

        try await git.unstage(["a.txt"], in: repo)
        status = try await git.status(in: repo)
        #expect(status.staged.map(\.path) == ["b [1].txt"])
        #expect(status.unstaged.contains(GitFileChange(path: "a.txt", kind: .modified)))

        try await git.stageAll(in: repo)
        status = try await git.status(in: repo)
        #expect(status.unstaged.isEmpty)
        #expect(status.staged.count == 3)

        try await git.unstageAll(in: repo)
        status = try await git.status(in: repo)
        #expect(status.staged.isEmpty)
        #expect(status.unstaged.count == 3)
    }

    @Test func unstageWorksWithoutCommits() async throws {
        try write("first.txt", "1\n")
        try write("second.txt", "2\n")
        try await git.stageAll(in: repo)

        try await git.unstage(["first.txt"], in: repo)
        var status = try await git.status(in: repo)
        #expect(status.staged == [GitFileChange(path: "second.txt", kind: .added)])
        #expect(status.unstaged == [GitFileChange(path: "first.txt", kind: .untracked)])

        try await git.unstageAll(in: repo)
        status = try await git.status(in: repo)
        #expect(status.staged.isEmpty)
        #expect(status.unstaged.count == 2)
    }

    @Test func worktreeLifecycle() async throws {
        try write("a.txt", "a\n")
        try commitAll()
        try sh("branch", "existing")

        let fresh = base.appending(path: "wt fresh")
        let existing = base.appending(path: "wt-existing")
        try await git.addWorktree(repository: repo, path: fresh, branch: "feature/new", createBranch: true)
        try await git.addWorktree(repository: repo, path: existing, branch: "existing", createBranch: false)

        let entries = try await git.worktrees(of: repo)
        #expect(entries.map(\.path.path) == [repo.path, fresh.path, existing.path])
        #expect(entries.map(\.branch) == ["main", "feature/new", "existing"])
        #expect(entries.map(\.isMain) == [true, false, false])
        #expect(try await git.localBranches(in: repo) == ["existing", "feature/new", "main"])
        #expect(await git.currentBranch(in: fresh) == "feature/new")

        try "dirty\n".write(to: fresh.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: GitError.self) {
            try await self.git.removeWorktree(repository: self.repo, path: fresh)
        }
        #expect(FileManager.default.fileExists(atPath: fresh.path))

        try await git.removeWorktree(repository: repo, path: existing)
        #expect(try await git.worktrees(of: repo).count == 2)
        #expect(!FileManager.default.fileExists(atPath: existing.path))

        await #expect(throws: GitError.self) {
            try await self.git.addWorktree(repository: self.repo, path: self.base.appending(path: "dup"), branch: "main", createBranch: false)
        }
    }

    @Test func currentBranchAndRepositoryDetection() async throws {
        let plain = base.appending(path: "plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        #expect(await git.isRepository(repo))
        #expect(await !git.isRepository(plain))
        #expect(await git.currentBranch(in: repo) == "main")
        #expect(await git.currentBranch(in: plain) == nil)

        try write("a.txt", "a\n")
        try commitAll()
        try sh("checkout", "-q", "--detach")
        #expect(await git.currentBranch(in: repo) == nil)
        await #expect(throws: GitError.self) { try await self.git.status(in: plain) }
    }

    @Test func diffsTrackedStagedAndUntrackedFiles() async throws {
        try write("tracked.txt", "old\n")
        try commitAll()
        try write("tracked.txt", "new\n")
        try write("caf\u{e9} notes.txt", "fresh\n")

        let unstaged = try await git.diff(path: "tracked.txt", staged: false, in: repo)
        #expect(unstaged.contains("-old"))
        #expect(unstaged.contains("+new"))
        #expect(try await git.diff(path: "tracked.txt", staged: true, in: repo).isEmpty)

        try await git.stage(["tracked.txt"], in: repo)
        #expect(try await git.diff(path: "tracked.txt", staged: true, in: repo).contains("+new"))

        let untracked = try await git.diff(path: "caf\u{e9} notes.txt", staged: false, in: repo)
        #expect(untracked.contains("new file mode"))
        #expect(untracked.contains("+fresh"))
        #expect(untracked.contains("caf\u{e9} notes.txt"))
    }

    @Test func readsLargeOutputWithoutDeadlocking() async throws {
        try write("big.txt", "")
        try commitAll()
        let line = String(repeating: "x", count: 99) + "\n"
        try write("big.txt", String(repeating: line, count: 20_000))

        let diff = try await git.diff(path: "big.txt", staged: false, in: repo)
        #expect(diff.utf8.count > 2_000_000)
    }

    // MARK: Helpers

    private func write(_ path: String, _ contents: String) throws {
        let url = repo.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commitAll() throws {
        try sh("add", "-A")
        try sh("commit", "-q", "-m", "commit")
    }

    private func sh(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError(message: "git \(arguments.joined(separator: " ")) failed")
        }
    }
}
