import Foundation
import Testing
@testable import GitKit

/// Repositories in awkward states: odd file names, conflicts, intent-to-add entries, missing
/// folders. Each test gets its own repository, removed in deinit. Settings that change what status
/// reports are pinned in the repository's own config, which outranks whatever the global config says.
final class GitClientEdgeCaseTests {
    let base: URL
    let repo: URL
    let trash: TestTrash
    let git: GitClient

    init() throws {
        // git reports /private/var paths; realpath keeps the expectations in the same form.
        let temp = realpath(FileManager.default.temporaryDirectory.path, nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
        base = URL(filePath: temp).appending(path: "GitKitEdgeTests-\(UUID().uuidString)")
        repo = base.appending(path: "repo")
        trash = TestTrash(in: base)
        git = trash.client()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try sh("init", "-q", "-b", "main")
        try sh("config", "user.name", "GitKit Tests")
        try sh("config", "user.email", "tests@example.invalid")
        try sh("config", "commit.gpgsign", "false")
        try sh("config", "status.renames", "true")
        try sh("config", "core.autocrlf", "false")
        try sh("config", "core.hooksPath", "/dev/null")
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: File names

    @Test func fileDiffKeepsNamesWithQuotesNewlinesAndUnicode() async throws {
        let names = ["say \"hi\".txt", "line\nbreak.txt", "back\\slash.txt", "-dash.txt", "caf\u{e9} [1] *.txt"]
        for name in names { try write(name, "one\n") }
        try commitAll()
        for name in names { try write(name, "two\n") }
        try write("new\ttab \u{1F600}.txt", "fresh\n")

        let status = try await git.status(in: repo)
        #expect(Set(status.unstaged.map(\.path)) == Set(names + ["new\ttab \u{1F600}.txt"]))

        for name in names {
            let diff = try #require(try await git.fileDiff(path: name, staged: false, in: repo), "no diff for \(name)")
            #expect(diff.oldPath == name)
            #expect(diff.newPath == name)
            #expect(diff.hunks.first?.lines == [GitDiffLine(.removed, "one"), GitDiffLine(.added, "two")])
        }
        let untracked = try #require(try await git.fileDiff(path: "new\ttab \u{1F600}.txt", staged: false, in: repo))
        #expect(untracked.status == .added)
        #expect(untracked.newPath == "new\ttab \u{1F600}.txt")
    }

    @Test func stagedRenameBetweenAwkwardNames() async throws {
        try write("old \"name\".txt", "a\nb\nc\n")
        try commitAll()
        try sh("mv", "old \"name\".txt", "new\nname.txt")

        let status = try await git.status(in: repo)
        let rename = try #require(status.staged.first)
        #expect(rename == GitFileChange(path: "new\nname.txt", originalPath: "old \"name\".txt", kind: .renamed))

        for diff in [try await git.fileDiff(for: rename, staged: true, in: repo), try await git.fileDiff(path: "new\nname.txt", staged: true, in: repo)] {
            #expect(diff?.status == .renamed)
            #expect(diff?.oldPath == "old \"name\".txt")
            #expect(diff?.newPath == "new\nname.txt")
        }
    }

    @Test func conflictedFileWithSpacesQuotesAndUnicodeKeepsItsName() async throws {
        let name = "sp ace \"q\" \u{e9}.txt"
        try write(name, "one\ntwo\n")
        try commitAll()
        try sh("switch", "-q", "-c", "other")
        try write(name, "one\ntheirs\n")
        try commitAll()
        try sh("switch", "-q", "main")
        try write(name, "one\nours\n")
        try commitAll()
        #expect(throws: GitError.self) { try self.sh("merge", "-q", "other") }

        // Unstaged is a combined diff with quoted headers, staged only a raw "* Unmerged path" line.
        for staged in [false, true] {
            let diff = try #require(try await git.fileDiff(path: name, staged: staged, in: repo))
            #expect(diff.isConflicted)
            #expect(diff.hunks.isEmpty)
            #expect(diff.newPath == name)
        }
    }

    @Test func fileDiffFromASubfolderUsesRootRelativePaths() async throws {
        try write("sub/tracked.txt", "one\n")
        try commitAll()
        try write("sub/tracked.txt", "two\n")
        try write("sub/untracked.txt", "fresh\n")
        let sub = repo.appending(path: "sub")

        // Status reports paths from the root, whichever folder it runs in, and so must the diffs.
        #expect(try await git.fileDiff(path: "sub/tracked.txt", staged: false, in: sub)?.newPath == "sub/tracked.txt")
        #expect(try await git.fileDiff(path: "sub/untracked.txt", staged: false, in: sub)?.status == .added)
        #expect(try await git.diff(path: "sub/untracked.txt", staged: false, in: sub).contains("+fresh"))
    }

    // MARK: Folders and links

    @Test func plainFolderIsRefusedAsAFolder() async throws {
        try write("a.txt", "a\n")
        try commitAll()
        try write("loose/one.txt", "1\n")

        do {
            _ = try await git.fileDiff(path: "loose", staged: false, in: repo)
            Issue.record("expected a folder to be refused")
        } catch let error as GitError {
            #expect(error.message == "loose is a folder, not a file.")
        }
        do {
            _ = try await git.diff(path: "loose/", staged: false, in: repo)
            Issue.record("expected a folder to be refused")
        } catch let error as GitError {
            #expect(error.message == "loose is a folder, not a file.")
        }
    }

    @Test func untrackedSymlinkToAFolderDiffsAsTheLink() async throws {
        try write("a.txt", "a\n")
        try commitAll()
        try FileManager.default.createDirectory(at: base.appending(path: "elsewhere"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: repo.appending(path: "link").path, withDestinationPath: "../elsewhere")

        #expect(try await git.status(in: repo).unstaged == [GitFileChange(path: "link", kind: .untracked)])

        // `diff --no-index` would follow the link, find a folder, fail with the exit code it also
        // uses for "files differ" and leave the link looking unchanged.
        let diff = try await git.fileDiff(path: "link", staged: false, in: repo)
        #expect(diff?.status == .added)
        #expect(diff?.hunks.first?.lines == [GitDiffLine(.added, "../elsewhere", hasNewline: false)])
        #expect(try await git.diff(path: "link", staged: false, in: repo).contains("+../elsewhere"))
    }

    @Test func untrackedDanglingSymlinkHasADiff() async throws {
        try write("a.txt", "a\n")
        try commitAll()
        try FileManager.default.createSymbolicLink(atPath: repo.appending(path: "dangling").path, withDestinationPath: "nowhere")

        let status = try await git.status(in: repo)
        #expect(status.unstaged == [GitFileChange(path: "dangling", kind: .untracked)])
        // The raw diff has no existence check and shows the link fine.
        #expect(try await git.diff(path: "dangling", staged: false, in: repo).contains("+nowhere"))

        // A check that follows the link would call a dangling one missing, and the viewer would
        // show no changes for a file status lists.
        let diff = try await git.fileDiff(path: "dangling", staged: false, in: repo)
        #expect(diff?.status == .added)
        #expect(diff?.hunks.first?.lines == [GitDiffLine(.added, "nowhere", hasNewline: false)])
    }

    // MARK: Copies and intent-to-add

    @Test func stagedCopyShowsTheCopyNotItsSource() async throws {
        // Copies only show up in status with this setting (or diff.renames=copies), and only from a
        // source that changed too.
        try sh("config", "status.renames", "copies")
        try write("b.txt", "l1\nl2\nl3\nl4\n")
        try commitAll()
        try write("c.txt", "l1\nl2\nl3\nl4\n")
        try write("b.txt", "l1\nl2\nl3\nl4\nextra\n")
        try sh("add", "-A")

        let status = try await git.status(in: repo)
        let copy = try #require(status.staged.first { $0.kind == .copied })
        #expect(copy == GitFileChange(path: "c.txt", originalPath: "b.txt", kind: .copied))

        // Without a known origin, only renames are looked up, so the pathspec is just the copy.
        let detected = try #require(try await git.fileDiff(path: "c.txt", staged: true, in: repo))
        #expect(detected.newPath == "c.txt")
        #expect(detected.status == .added)

        // The copy's source is a modified file of its own. Named in the pathspec like a rename's
        // old name, its diff would come first and be shown for c.txt.
        let diff = try await git.fileDiff(for: copy, staged: true, in: repo)
        #expect(diff?.newPath == "c.txt")
        #expect(diff?.status == .added)
    }

    @Test func discardingADeletedIntentToAddFileDropsItInsteadOfRecreatingIt() async throws {
        try write("tracked.txt", "kept\n")
        try write("empty.txt", "")
        try commitAll()
        // Three deletions that status reports alike: a file git only meant to add, one whose
        // addition is really staged, and committed ones, of which one is empty like the first.
        try write("intended.txt", "never staged\n")
        try sh("add", "-N", "intended.txt")
        try write("staged.txt", "staged\n")
        try sh("add", "staged.txt")
        for name in ["intended.txt", "staged.txt", "tracked.txt", "empty.txt"] {
            try FileManager.default.removeItem(at: repo.appending(path: name))
        }

        let status = try await git.status(in: repo)
        #expect(Set(status.unstaged.map(\.path)) == ["intended.txt", "staged.txt", "tracked.txt", "empty.txt"])
        #expect(status.unstaged.allSatisfy { $0.kind == .deleted })
        try await git.discardUnstaged(status.unstaged, in: repo)

        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: repo.appending(path: name).path) }
        #expect(!exists("intended.txt"))
        // Every file was already gone from disk, so there was nothing to trash.
        #expect(trash.paths.isEmpty)
        #expect((try? String(contentsOf: repo.appending(path: "staged.txt"), encoding: .utf8)) == "staged\n")
        #expect((try? String(contentsOf: repo.appending(path: "tracked.txt"), encoding: .utf8)) == "kept\n")
        #expect(exists("empty.txt"))
        let after = try await git.status(in: repo)
        #expect(after.unstaged.isEmpty)
        #expect(after.staged == [GitFileChange(path: "staged.txt", kind: .added)])
    }

    @Test func discardingADeletedIntentToAddFileWorksWithoutCommits() async throws {
        try write("intended.txt", "never staged\n")
        try sh("add", "-N", "intended.txt")
        try write("staged.txt", "staged\n")
        try sh("add", "staged.txt")
        try FileManager.default.removeItem(at: repo.appending(path: "intended.txt"))
        try FileManager.default.removeItem(at: repo.appending(path: "staged.txt"))

        try await git.discardUnstaged(try await git.status(in: repo).unstaged, in: repo)

        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: "intended.txt").path))
        #expect((try? String(contentsOf: repo.appending(path: "staged.txt"), encoding: .utf8)) == "staged\n")
        #expect(try await git.status(in: repo).unstaged.isEmpty)
    }

    @Test func discardingAnUnstagedRenameOfAnIntentToAddFileKeepsItsContent() async throws {
        try write("a.txt", "l1\nl2\nl3\n")
        try commitAll()
        try FileManager.default.moveItem(at: repo.appending(path: "a.txt"), to: repo.appending(path: "b.txt"))
        try write("b.txt", "l1\nl2\nl3\nextra\n")
        try sh("add", "-N", "b.txt")

        let status = try await git.status(in: repo)
        // With intent-to-add, status pairs the new file with the deleted one as a worktree rename.
        #expect(status.unstaged == [GitFileChange(path: "b.txt", originalPath: "a.txt", kind: .renamed)])

        try await git.discardUnstaged(status.unstaged, in: repo)

        // b.txt's index entry is empty, so restoring it from the index would wipe the only copy.
        // It goes to the Trash like an added file, and the old name comes back.
        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: "b.txt").path))
        #expect(trash.contents(of: repo.appending(path: "b.txt")) == "l1\nl2\nl3\nextra\n")
        #expect((try? String(contentsOf: repo.appending(path: "a.txt"), encoding: .utf8)) == "l1\nl2\nl3\n")
        #expect(try await git.status(in: repo).unstaged.isEmpty)
    }

    // MARK: Missing worktrees and detached HEAD

    @Test func gitCallsInADeletedWorktreeFailCleanly() async throws {
        try write("a.txt", "a\n")
        try commitAll()
        let worktree = base.appending(path: "wt gone")
        try await git.addWorktree(repository: repo, path: worktree, branch: "gone", createBranch: true)
        try FileManager.default.removeItem(at: worktree)

        await #expect(throws: GitError.self) { _ = try await self.git.status(in: worktree) }
        await #expect(throws: GitError.self) { _ = try await self.git.summary(in: worktree) }
        #expect(await git.currentBranch(in: worktree) == nil)
        #expect(await !git.isRepository(worktree))
        #expect(try await git.worktrees(of: repo).map(\.isPrunable) == [false, true])
    }

    @Test func worktreePathsWithNewlinesAndQuotesParse() async throws {
        try write("a.txt", "a\n")
        try commitAll()
        let odd = base.appending(path: "wt \"q\"\nline \u{e9}")
        try await git.addWorktree(repository: repo, path: odd, branch: "odd", createBranch: true)

        let entries = try await git.worktrees(of: repo)
        #expect(entries.map(\.path.path) == [repo.path, odd.path])
        #expect(entries.map(\.branch) == ["main", "odd"])
        #expect(await git.currentBranch(in: odd) == "odd")
    }

    @Test func pullRefusesDetachedHead() async throws {
        try write("a.txt", "a\n")
        try commitAll()
        try sh("checkout", "-q", "--detach")

        #expect(try await git.status(in: repo).branch == nil)
        do {
            try await git.pull(in: repo)
            Issue.record("expected a detached HEAD to be refused")
        } catch let error as GitError {
            #expect(error.message.contains("detached"))
        }
    }

    // MARK: Processes

    @Test func cancelledNetworkProcessIsReapedNotOrphaned() async throws {
        let pidFile = base.appending(path: "pid")
        let ready = base.appending(path: "ready")
        let task = Task { [repo] in
            try await GitProcess.run(
                URL(filePath: "/bin/sh"),
                ["-c", "echo $$ > '\(pidFile.path)'; mv '\(pidFile.path)' '\(ready.path)'; exec sleep 30"],
                in: repo, environment: [:], lane: .network
            )
        }
        // Waits for the child to say it is running, so the cancellation hits a live process.
        let clock = ContinuousClock()
        let giveUp = clock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: ready.path) {
            guard clock.now < giveUp else {
                task.cancel()
                Issue.record("the child never started")
                return
            }
            await Task.yield()
        }
        let pid = try #require(pid_t(try String(contentsOf: ready, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        // waitUntilExit has run by the time the call throws, so the pid is gone, not a zombie.
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func failureWithoutStderrNamesTheExitCode() async throws {
        let result = try await GitProcess.run(URL(filePath: "/bin/sh"), ["-c", "exit 7"], in: repo, environment: [:])
        #expect(GitError(command: "git x", output: result).message == "git x failed with exit code 7")
        let noisy = try await GitProcess.run(URL(filePath: "/bin/sh"), ["-c", "echo '  fatal: nope  ' >&2; exit 1"], in: repo, environment: [:])
        #expect(GitError(command: "git x", output: noisy).message == "fatal: nope")
    }

    @Test func pushKeepsAskpassButFetchesStayInBatchMode() {
        let push = GitClient.sshEnvironment(batchMode: false, inherited: [:], configuredCommand: nil)["GIT_SSH_COMMAND"]
        let fetch = GitClient.sshEnvironment(batchMode: true, inherited: [:], configuredCommand: nil)["GIT_SSH_COMMAND"]
        for command in [push, fetch] {
            // The keepalives are what end a connection that died after the handshake.
            #expect(command?.contains("-o ServerAliveInterval=15 -o ServerAliveCountMax=3") == true)
            #expect(command?.contains("-o ConnectTimeout=10") == true)
        }
        #expect(push?.contains("BatchMode") == false)
        #expect(fetch?.contains("-o BatchMode=yes") == true)
        // A blank core.sshCommand is no choice of the user's.
        #expect(GitClient.sshEnvironment(batchMode: true, inherited: [:], configuredCommand: "").isEmpty == false)
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
        // The setup commands should not depend on the developer's own git config.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError(message: "git \(arguments.joined(separator: " ")) failed")
        }
    }
}
