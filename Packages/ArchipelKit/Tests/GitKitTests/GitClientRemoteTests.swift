import Foundation
import Testing
@testable import GitKit

final class GitClientRemoteTests {
    let base: URL
    let repo: URL
    let git = GitClient()

    init() throws {
        let temp = realpath(FileManager.default.temporaryDirectory.path, nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
        base = URL(filePath: temp).appending(path: "GitKitRemoteTests-\(UUID().uuidString)")
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

    @Test func commitsOnAnUnbornBranch() async throws {
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)
        #expect(try shOutput("log", "-1", "--format=%s") == "first")
        #expect(try await git.status(in: repo).staged.isEmpty)
    }

    @Test func preservesMultiLineAndDashLeadingMessages() async throws {
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "feat: subject\n\nbody line one\nbody line two", in: repo)
        #expect(try shOutput("log", "-1", "--format=%B") == "feat: subject\n\nbody line one\nbody line two")

        try write("b.txt", "b\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "--amend -m nope", in: repo)
        #expect(try shOutput("log", "-1", "--format=%s") == "--amend -m nope")
        #expect(try shOutput("rev-list", "--count", "HEAD") == "2")
    }

    @Test func commitFailureCarriesGitsMessage() async throws {
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)

        let hook = repo.appending(path: ".git/hooks/pre-commit")
        try "#!/bin/sh\necho 'rejected by hook' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try write("b.txt", "b\n")
        try await git.stageAll(in: repo)

        do {
            try await git.commit(message: "second", in: repo)
            Issue.record("expected the hook to reject the commit")
        } catch let error as GitError {
            #expect(error.message.contains("rejected by hook"))
        }
    }

    @Test func pushSetsUpstreamThenPushesAgain() async throws {
        let remote = try makeBareRemote()
        try sh("remote", "add", "origin", remote.path)
        #expect(await git.hasRemote(in: repo))

        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "one", in: repo)
        var summary = try await git.summary(in: repo)
        #expect(summary.upstream == nil)

        try await git.push(in: repo)
        summary = try await git.summary(in: repo)
        #expect(summary.upstream == "origin/main")
        #expect(summary.ahead == 0)

        try write("b.txt", "b\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "two", in: repo)
        #expect(try await git.summary(in: repo).ahead == 1)

        try await git.push(in: repo)
        #expect(try await git.summary(in: repo).ahead == 0)
        let remoteHead = try shOutput("--git-dir", remote.path, "rev-list", "--count", "main", dir: false)
        #expect(remoteHead == "2")
    }

    @Test func pushRefusesDetachedHeadAndMissingOrigin() async throws {
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "one", in: repo)
        #expect(await !git.hasRemote(in: repo))

        await #expect(throws: GitError.self) { try await self.git.push(in: self.repo) }
        do {
            try await git.push(in: repo)
        } catch let error as GitError {
            #expect(error.message.contains("origin"))
        }

        try sh("checkout", "-q", "--detach")
        do {
            try await git.push(in: repo)
            Issue.record("expected detached HEAD to be refused")
        } catch let error as GitError {
            #expect(error.message.contains("detached"))
        }
    }

    @Test func listFilesCoversTrackedUntrackedAndSkipsIgnoredAndDeleted() async throws {
        try write(".gitignore", "*.log\nbuild/\n")
        try write("src/main.swift", "x\n")
        try write("doomed.txt", "x\n")
        try write("dir with space/é.txt", "x\n")
        try sh("add", "-A")
        try sh("commit", "-q", "-m", "init")

        try write("untracked.txt", "u\n")
        try write("debug.log", "ignored\n")
        try write("build/out.o", "ignored\n")
        try FileManager.default.removeItem(at: repo.appending(path: "doomed.txt"))
        try write("src/main.swift", "changed\n")

        let files = try await git.listFiles(in: repo)
        #expect(files.sorted() == [".gitignore", "dir with space/é.txt", "src/main.swift", "untracked.txt"])
    }

    @Test func listFilesIsRelativeToTheFolderItIsRunIn() async throws {
        try write("top.txt", "x\n")
        try write("sub/inner.txt", "x\n")
        try await git.stageAll(in: repo)
        #expect(try await git.listFiles(in: repo.appending(path: "sub")) == ["inner.txt"])
    }

    @Test func summaryCountsChangedFilesOncePerPath() async throws {
        try write("a.txt", "a\n")
        try write("b.txt", "b\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "init", in: repo)

        try write("a.txt", "staged\n")
        try await git.stage(["a.txt"], in: repo)
        try write("a.txt", "staged and modified again\n")
        try write("b.txt", "changed\n")
        try write("new/one.txt", "1\n")
        try write("new/two.txt", "2\n")

        let summary = try await git.summary(in: repo)
        #expect(summary.branch == "main")
        // a.txt once, b.txt once, and the untracked directory once.
        #expect(summary.changedFiles == 3)
    }

    // MARK: Helpers

    private func makeBareRemote() throws -> URL {
        let remote = base.appending(path: "remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try run(["init", "-q", "--bare", "-b", "main", remote.path])
        return remote
    }

    private func write(_ path: String, _ contents: String) throws {
        let url = repo.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func sh(_ arguments: String...) throws {
        try run(["-C", repo.path] + arguments)
    }

    private func shOutput(_ arguments: String..., dir: Bool = true) throws -> String {
        try run((dir ? ["-C", repo.path] : []) + arguments)
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError(message: "git \(arguments.joined(separator: " ")) failed")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
