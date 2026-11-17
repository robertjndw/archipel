import Foundation
import Testing
@testable import InspectorUI

@MainActor
final class ChangesModelTests {
    let repo: URL

    init() throws {
        let temp = realpath(FileManager.default.temporaryDirectory.path, nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
        repo = URL(filePath: temp).appending(path: "InspectorUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.name", "InspectorUI Tests")
        try git("config", "user.email", "tests@example.invalid")
        try git("config", "commit.gpgsign", "false")
        try write("a.txt", "a\n")
        try write("b.txt", "b\n")
        try git("add", "-A")
        try git("commit", "-q", "-m", "first")
        try write("a.txt", "a2\n")
        try write("b.txt", "b2\n")
    }

    deinit {
        try? FileManager.default.removeItem(at: repo)
    }

    @Test func commitRightAfterStagingCommitsOnlyWhatWasStaged() async throws {
        let model = ChangesModel(root: repo, searchPATH: { "" })
        await model.refresh()
        let change = try #require(model.status.unstaged.first { $0.path == "a.txt" })
        model.message = "only a"
        // No refresh in between: the status the model holds still has nothing staged, which reads
        // as "Commit All".
        model.stage(change)
        #expect(model.commitControl.mode == .commitAll)
        model.commit()
        try await idle(model)

        #expect(model.actionError == nil)
        #expect(try git("show", "--name-only", "--format=%s", "HEAD") == "only a\n\na.txt")
        #expect(model.status.unstaged.map(\.path) == ["b.txt"])
        #expect(model.message.isEmpty)
    }

    @Test func stageDuringACommitWaitsForIt() async throws {
        // A slow pre-commit hook holds index.lock for as long as it runs.
        let hook = repo.appending(path: ".git/hooks/pre-commit")
        try "#!/bin/sh\nsleep 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let model = ChangesModel(root: repo, searchPATH: { "" })
        await model.refresh()
        let a = try #require(model.status.unstaged.first { $0.path == "a.txt" })
        let b = try #require(model.status.unstaged.first { $0.path == "b.txt" })
        model.stage(a)
        model.message = "slow"
        model.commit()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.activity == .commit)
        model.stage(b)
        try await idle(model)
        for _ in 0..<300 where model.status.staged.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        #expect(model.actionError == nil)
        #expect(model.status.staged.map(\.path) == ["b.txt"])
        #expect(try git("show", "--name-only", "--format=%s", "HEAD") == "slow\n\na.txt")
    }

    @Test func aModelCreatedDuringACommitDoesNotKeepTheCommittedMessage() async throws {
        let committing = ChangesModel(root: repo, searchPATH: { "" })
        await committing.refresh()
        committing.message = "done"
        committing.commit()
        // What switching to another worktree and back does while git runs.
        let successor = ChangesModel(root: repo, searchPATH: { "" })
        #expect(successor.message == "done")
        try await idle(committing)
        #expect(committing.actionError == nil)
        #expect(successor.message.isEmpty)

        // Text typed in the meantime is a new draft and stays.
        try write("a.txt", "a3\n")
        await committing.refresh()
        committing.message = "next"
        committing.commit()
        successor.message = "next, and more"
        try await idle(committing)
        #expect(successor.message == "next, and more")
        successor.message = ""
    }

    private func idle(_ model: ChangesModel) async throws {
        for _ in 0..<1000 where model.activity != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.activity == nil)
    }

    private func write(_ path: String, _ contents: String) throws {
        try contents.write(to: repo.appending(path: path), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
