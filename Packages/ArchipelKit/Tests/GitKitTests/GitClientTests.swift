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

    @Test func worktreeAddFailureKeepsOnlyTheReason() async throws {
        try write("a.txt", "a\n")
        try commitAll()
        try sh("branch", "taken")

        do {
            try await git.addWorktree(repository: repo, path: base.appending(path: "wt"), branch: "taken", createBranch: true)
            Issue.record("expected an existing branch name to be refused")
        } catch let error as GitError {
            #expect(!error.message.contains("hint:"))
            #expect(!error.message.contains("Preparing worktree"))
            #expect(!error.message.hasPrefix("fatal:"))
            #expect(error.message.contains("taken"))
        }
    }

    @Test func branchNameValidation() async throws {
        #expect(await git.isValidBranchName("feature/dark-mode", in: repo))
        #expect(await !git.isValidBranchName("bad name~", in: repo))
        #expect(await !git.isValidBranchName("-leading-dash", in: repo))
        #expect(await !git.isValidBranchName("ends.lock", in: repo))
    }

    @Test func forceRemovesDirtyWorktree() async throws {
        try write("a.txt", "a\n")
        try commitAll()
        let wt = base.appending(path: "wt-dirty")
        try await git.addWorktree(repository: repo, path: wt, branch: "dirty", createBranch: true)
        try "dirty\n".write(to: wt.appending(path: "a.txt"), atomically: true, encoding: .utf8)

        try await git.removeWorktree(repository: repo, path: wt, force: true)

        #expect(!FileManager.default.fileExists(atPath: wt.path))
        #expect(try await git.worktrees(of: repo).count == 1)
    }

    @Test func deleteBranchReportsMergedAndUnmerged() async throws {
        try write("a.txt", "a\n")
        try commitAll()
        try sh("branch", "merged")

        let wt = base.appending(path: "wt-ahead")
        try await git.addWorktree(repository: repo, path: wt, branch: "ahead", createBranch: true)
        try "extra\n".write(to: wt.appending(path: "extra.txt"), atomically: true, encoding: .utf8)
        try shIn(wt, "add", "-A")
        try shIn(wt, "commit", "-q", "-m", "extra")
        try await git.removeWorktree(repository: repo, path: wt)

        #expect(try await git.deleteBranch("merged", in: repo) == .deleted)
        #expect(try await git.deleteBranch("ahead", in: repo) == .keptUnmerged)
        #expect(try await git.localBranches(in: repo) == ["ahead", "main"])
    }

    @Test func deleteBranchThrowsForUnknownBranch() async throws {
        try write("a.txt", "a\n")
        try commitAll()
        await #expect(throws: GitError.self) {
            _ = try await self.git.deleteBranch("nope", in: self.repo)
        }
    }

    @Test func worktreeWithMissingFolderIsPrunable() async throws {
        try write("a.txt", "a\n")
        try commitAll()
        let wt = base.appending(path: "wt-gone")
        try await git.addWorktree(repository: repo, path: wt, branch: "gone", createBranch: true)
        try FileManager.default.removeItem(at: wt)

        let entries = try await git.worktrees(of: repo)

        #expect(entries.map(\.isPrunable) == [false, true])
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

    @Test func fileDiffCoversTheWholeFile() async throws {
        let lines = (1...200).map { "line \($0)" }
        try write("long.txt", lines.joined(separator: "\n") + "\n")
        try commitAll()
        var changed = lines
        changed[99] = "line 100 changed"
        try write("long.txt", changed.joined(separator: "\n") + "\n")

        let diff = try #require(try await git.fileDiff(path: "long.txt", staged: false, in: repo))
        #expect(diff.status == .modified)
        #expect(diff.hunks.count == 1)
        let hunk = try #require(diff.hunks.first)
        #expect(hunk.lines.count == 201)
        #expect(hunk.lines.filter { $0.kind == .context }.count == 199)
        #expect(try await git.fileDiff(path: "long.txt", staged: true, in: repo) == nil)

        try await git.stage(["long.txt"], in: repo)
        #expect(try await git.fileDiff(path: "long.txt", staged: false, in: repo) == nil)
        #expect(try await git.fileDiff(path: "long.txt", staged: true, in: repo)?.hunks.first?.lines.count == 201)
    }

    @Test func fileDiffForUntrackedDeletedAndStagedRename() async throws {
        try write("keep.txt", "a\nb\n")
        try write("doomed.txt", "bye\n")
        try commitAll()

        try write("dir/new [1].txt", "fresh\r\nline")
        let untracked = try #require(try await git.fileDiff(path: "dir/new [1].txt", staged: false, in: repo))
        #expect(untracked.status == .added)
        #expect(untracked.newPath == "dir/new [1].txt")
        #expect(untracked.hunks.first?.lines == [GitDiffLine(.added, "fresh\r"), GitDiffLine(.added, "line", hasNewline: false)])

        try FileManager.default.removeItem(at: repo.appending(path: "doomed.txt"))
        let deleted = try #require(try await git.fileDiff(path: "doomed.txt", staged: false, in: repo))
        #expect(deleted.status == .deleted)
        #expect(deleted.hunks.first?.lines == [GitDiffLine(.removed, "bye")])

        try sh("mv", "keep.txt", "kept.txt")
        let renamed = try #require(try await git.fileDiff(path: "kept.txt", staged: true, in: repo))
        #expect(renamed.status == .renamed)
        #expect(renamed.oldPath == "keep.txt")
        #expect(renamed.newPath == "kept.txt")

        #expect(try await git.fileDiff(path: "missing.txt", staged: false, in: repo) == nil)
    }

    @Test func fileDiffReportsBinaryAndWorksWithoutCommits() async throws {
        try write("first.txt", "1\n")
        try await git.stageAll(in: repo)
        let unborn = try #require(try await git.fileDiff(path: "first.txt", staged: true, in: repo))
        #expect(unborn.status == .added)

        let url = repo.appending(path: "blob.bin")
        try Data([0, 1, 2, 0, 255]).write(to: url)
        let binary = try #require(try await git.fileDiff(path: "blob.bin", staged: false, in: repo))
        #expect(binary.isBinary)
    }

    @Test func diffStatCountsStagedAndUnstagedLinesButNotUntrackedFiles() async throws {
        await #expect(throws: GitError.self) { try await self.git.diffStat(in: self.repo) }

        try write("a.txt", "1\n2\n3\n")
        try write("b.txt", "x\n")
        try commitAll()
        #expect(try await git.diffStat(in: repo) == .zero)

        try write("a.txt", "1\nchanged\n3\nnew\n")
        try sh("add", "a.txt")
        try write("b.txt", "")
        try write("untracked.txt", "ignored by the stat\n")
        #expect(try await git.diffStat(in: repo) == GitDiffStat(insertions: 2, deletions: 2))
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
        try shIn(repo, arguments)
    }

    private func shIn(_ directory: URL, _ arguments: String...) throws {
        try shIn(directory, arguments)
    }

    private func shIn(_ directory: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError(message: "git \(arguments.joined(separator: " ")) failed")
        }
    }
}
