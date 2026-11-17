import Foundation
import GitKit
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
        // The default, spelled out so a global core.hooksPath cannot run the user's own hooks here.
        try git("config", "core.hooksPath", ".git/hooks")
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

    @Test func discardAllTouchesOnlyWhatTheDialogListed() async throws {
        let model = ChangesModel(root: repo, searchPATH: { "" })
        await model.refresh()
        // What the dialog was raised with.
        let confirmed = model.status.unstaged
        #expect(confirmed.map(\.path) == ["a.txt", "b.txt"])

        // The poll keeps running behind the dialog: b.txt is deleted outright and a new file shows up.
        try FileManager.default.removeItem(at: repo.appending(path: "b.txt"))
        try write("c.txt", "new\n")
        await model.refresh()

        model.discardAll(confirmed)
        try await until { model.status.unstaged.allSatisfy { $0.path != "a.txt" } }

        #expect(model.actionError == nil)
        #expect(try String(contentsOf: repo.appending(path: "a.txt"), encoding: .utf8) == "a\n")
        // Agreed to as a modification, now a deletion: restoring it was never asked for.
        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: "b.txt").path))
        #expect(try String(contentsOf: repo.appending(path: "c.txt"), encoding: .utf8) == "new\n")
        #expect(model.status.unstaged.map(\.path) == ["b.txt", "c.txt"])
    }

    @Test func commitAllStagesEverythingWhenNothingIsStaged() async throws {
        let model = ChangesModel(root: repo, searchPATH: { "" })
        await model.refresh()
        model.message = "everything"
        #expect(model.commitControl.mode == .commitAll)
        model.commit()
        try await idle(model)

        #expect(model.actionError == nil)
        #expect(try git("show", "--name-only", "--format=%s", "HEAD") == "everything\n\na.txt\nb.txt")
        #expect(model.status.staged.isEmpty && model.status.unstaged.isEmpty)
        #expect(model.commitCompletions == 1)
    }

    @Test func aFailedCommitAllSaysTheFilesWereLeftStaged() async throws {
        try installHook("#!/bin/sh\necho 'lint failed' >&2\nexit 1\n")
        let model = ChangesModel(root: repo, searchPATH: { "" })
        await model.refresh()
        model.message = "rejected"
        model.commit()
        try await idle(model)

        let error = try #require(model.actionError)
        #expect(error.hasPrefix("All changes were staged, but the commit failed. They remain staged."))
        #expect(error.contains("lint failed"))
        #expect(model.status.staged.map(\.path) == ["a.txt", "b.txt"])
        #expect(try git("log", "--format=%s") == "first")
        // The draft stays for the next attempt, and no checkmark is shown.
        #expect(model.message == "rejected")
        #expect(model.commitCompletions == 0)
        model.message = ""
    }

    @Test func aMergeConflictBlocksTheCommit() async throws {
        try git("commit", "-q", "-am", "ours")
        try git("checkout", "-q", "-b", "other", "HEAD~1")
        try write("a.txt", "theirs\n")
        try git("commit", "-q", "-am", "theirs")
        try git("checkout", "-q", "main")
        try git("merge", "-q", "other")

        let model = ChangesModel(root: repo, searchPATH: { "" })
        await model.refresh()
        #expect(model.status.unstaged.contains { $0.path == "a.txt" && $0.kind == .conflicted })
        model.message = "merge with markers"
        #expect(model.commitControl.hasConflicts)
        #expect(!model.commitControl.isEnabled)

        model.commit()
        #expect(model.activity == nil)
        #expect(try git("rev-parse", "-q", "--verify", "MERGE_HEAD").isEmpty == false)
        #expect(try String(contentsOf: repo.appending(path: "a.txt"), encoding: .utf8).contains("<<<<<<<"))
        model.message = ""
    }

    @Test func unstagingARenameUnstagesBothNames() async throws {
        try git("checkout", "-q", "--", ".")
        try git("mv", "a.txt", "moved.txt")
        let model = ChangesModel(root: repo, searchPATH: { "" })
        await model.refresh()
        let rename = try #require(model.status.staged.first)
        #expect(rename.kind == .renamed)
        #expect(rename.originalPath == "a.txt")

        model.unstage(rename)
        try await until { model.status.staged.isEmpty }
        #expect(model.actionError == nil)
        // The old name's deletion was unstaged too: it is now a working tree change, not a staged one.
        #expect(model.status.unstaged.contains { $0.path == "a.txt" && $0.kind == .deleted })
        #expect(model.status.unstaged.contains { $0.path == "moved.txt" && $0.kind == .untracked })
    }

    /// Polls for a state the model reaches on its own, since stage, unstage and discard return
    /// before git has run. The deadline only turns a hang into a failure.
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func installHook(_ script: String) throws {
        let hook = repo.appending(path: ".git/hooks/pre-commit")
        try script.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
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
