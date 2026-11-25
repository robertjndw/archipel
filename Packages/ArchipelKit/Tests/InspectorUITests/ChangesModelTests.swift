import Foundation
import GitKit
import Testing
@testable import InspectorUI

@MainActor
final class ChangesModelTests {
    let repo: URL
    /// What the app keeps per worktree. Shared by every model of the test, as it is in the app.
    let state: GitWorktreeState

    init() throws {
        let temp = realpath(FileManager.default.temporaryDirectory.path, nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
        repo = URL(filePath: temp).appending(path: "InspectorUITests-\(UUID().uuidString)")
        state = GitWorktreeState(root: repo)
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
        let model = ChangesModel(state: state)
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

        let model = ChangesModel(state: state)
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
        // Idle can come before the stage's refresh lands, and until then the model may still show
        // a.txt staged from before the commit.
        try await until { model.status.staged.map(\.path) == ["b.txt"] }

        #expect(model.actionError == nil)
        #expect(try git("show", "--name-only", "--format=%s", "HEAD") == "slow\n\na.txt")
    }

    @Test func aModelCreatedDuringACommitDoesNotKeepTheCommittedMessage() async throws {
        let committing = ChangesModel(state: state)
        await committing.refresh()
        committing.message = "done"
        committing.commit()
        // What switching to another worktree and back does while git runs.
        let successor = ChangesModel(state: state)
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
        let model = ChangesModel(state: state)
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

        // Not an error, but b.txt was left out and the user should hear about it.
        #expect(model.actionError == "1 file changed while the question was open and was not discarded.")
        model.actionError = nil
        #expect(try String(contentsOf: repo.appending(path: "a.txt"), encoding: .utf8) == "a\n")
        // Agreed to as a modification, now a deletion: restoring it was never asked for.
        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: "b.txt").path))
        #expect(try String(contentsOf: repo.appending(path: "c.txt"), encoding: .utf8) == "new\n")
        #expect(model.status.unstaged.map(\.path) == ["b.txt", "c.txt"])
    }

    @Test func discardLeavesAFileRewrittenBehindTheDialog() async throws {
        let model = ChangesModel(state: state)
        await model.refresh()
        let confirmed = model.status.unstaged
        #expect(confirmed.map(\.path) == ["a.txt", "b.txt"])
        let seen = model.stamps(of: confirmed)

        // Still a modification of a.txt as far as status goes, but not the one that was asked about.
        try write("a.txt", "written while the dialog was open\n")
        await model.refresh()
        #expect(model.status.unstaged == confirmed)

        model.discard(confirmed[0], staged: false, seen: seen)
        model.discardAll(confirmed, seen: seen)
        try await until { model.status.unstaged.map(\.path) == ["a.txt"] }

        #expect(try String(contentsOf: repo.appending(path: "a.txt"), encoding: .utf8) == "written while the dialog was open\n")
        // b.txt went, a.txt did not, and the user is told instead of left to wonder.
        #expect(model.actionError == "1 file changed while the question was open and was not discarded.")
        model.actionError = nil
    }

    @Test func aDiscardThatIsSkippedSaysSo() async throws {
        let model = ChangesModel(state: state)
        await model.refresh()
        let a = try #require(model.status.unstaged.first { $0.path == "a.txt" })
        let seen = model.stamps(of: [a])
        try write("a.txt", "written while the dialog was open\n")

        model.discard(a, staged: false, seen: seen)
        #expect(model.actionError?.hasPrefix("Nothing was discarded: a.txt changed") == true)
        model.actionError = nil
        model.discardAll([a], seen: seen)
        #expect(model.actionError?.hasPrefix("Nothing was discarded") == true)
        model.actionError = nil

        #expect(try String(contentsOf: repo.appending(path: "a.txt"), encoding: .utf8) == "written while the dialog was open\n")
    }

    @Test func aDiscardOfAnEntryThatWentAwaySaysThatAndNotThatItChanged() async throws {
        let model = ChangesModel(state: state)
        await model.refresh()
        let confirmed = model.status.unstaged
        let a = try #require(confirmed.first { $0.path == "a.txt" })

        // What an agent's commit does behind the dialog.
        try git("commit", "-q", "-m", "by the agent", "a.txt")
        await model.refresh()

        model.discard(a, staged: false)
        #expect(model.actionError == "Nothing was discarded: a.txt has no unstaged changes any more.")
        model.actionError = nil
        model.discardAll([a])
        #expect(model.actionError == "Nothing was discarded: the file has no unstaged changes any more.")
        model.actionError = nil
        #expect(try git("log", "-1", "--format=%s") == "by the agent")
    }

    @Test func aRefusedDiscardKeepsItsNoticeWhenAnEarlierActionFinishes() async throws {
        let model = ChangesModel(state: state)
        await model.refresh()
        let a = try #require(model.status.unstaged.first { $0.path == "a.txt" })
        let b = try #require(model.status.unstaged.first { $0.path == "b.txt" })
        let seen = model.stamps(of: [a])
        try write("a.txt", "written while the dialog was open\n")

        // Still queued when the discard is turned down, and done only after the notice is up.
        model.stage(b)
        model.discard(a, staged: false, seen: seen)
        let notice = try #require(model.actionError)
        #expect(notice.hasPrefix("Nothing was discarded"))
        try await until { model.status.staged.map(\.path) == ["b.txt"] }

        #expect(model.actionError == notice)
        model.actionError = nil
    }

    @Test func aStageThatWorksClearsTheErrorOfTheOneBeforeIt() async throws {
        let model = ChangesModel(state: state)
        await model.refresh()
        let b = try #require(model.status.unstaged.first { $0.path == "b.txt" })

        model.stage(GitFileChange(path: "missing.txt", kind: .modified))
        try await until { model.actionError != nil }
        model.stage(b)
        try await until { model.status.staged.map(\.path) == ["b.txt"] }
        #expect(model.actionError == nil)
    }

    @Test func aStagedFolderIsToldFromAStagedFile() async throws {
        try FileManager.default.createDirectory(at: repo.appending(path: "vendor/lib"), withIntermediateDirectories: true)
        let model = ChangesModel(state: state)
        // How status lists a nested repository once it is staged: no trailing slash.
        #expect(model.isFolder(GitFileChange(path: "vendor/lib", kind: .added)))
        #expect(model.isFolder(GitFileChange(path: "elsewhere/", kind: .untracked)))
        #expect(!model.isFolder(GitFileChange(path: "a.txt", kind: .added)))
        #expect(!model.isFolder(GitFileChange(path: "missing.txt", kind: .added)))
    }

    @Test func aRemovedWorktreeTakesItsKeptModelWithIt() async throws {
        let store = ChangesModelStore.shared
        let model = ChangesModel(state: state)
        model.actionError = "rejected by the remote"
        #expect(store.model(for: state) === model)

        store.forget(repo)
        #expect(store.model(for: state) !== model)
        // Whatever the old model still has to say does not bring it back for the next worktree
        // that is created at this path.
        model.actionError = "and one more thing"
        #expect(store.model(for: state) !== model)
    }

    @Test func aKeptModelIsNotHandedOutOnceItsFolderIsGone() async throws {
        let store = ChangesModelStore.shared
        let model = ChangesModel(state: state)
        model.actionError = "rejected by the remote"
        #expect(store.model(for: state) === model)

        // Removed without the store being told.
        try FileManager.default.removeItem(at: repo)
        #expect(store.model(for: state) !== model)
        // A new worktree at the same path is another folder, and gets a model of its own.
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        #expect(store.model(for: state) !== model)
    }

    @Test func commitDoesNotBecomeCommitAllWhenTheStagedFilesAreGone() async throws {
        try write("new.txt", "never offered\n")
        try git("add", "a.txt")
        let model = ChangesModel(state: state)
        await model.refresh()
        model.message = "only a"
        #expect(model.commitControl.mode == .commit)

        // What an agent's own `git reset` (or commit) does between the last poll and the click.
        try git("reset", "-q")
        model.commit()
        try await idle(model)

        let error = try #require(model.actionError)
        #expect(error.contains("no longer what the list showed"))
        #expect(try git("log", "--format=%s") == "first")
        // Nothing was staged on the way either.
        #expect(model.status.staged.isEmpty)
        #expect(model.status.unstaged.map(\.path) == ["a.txt", "b.txt", "new.txt"])
        #expect(model.message == "only a")
        model.message = ""
        model.actionError = nil
    }

    @Test func stageAllLeavesConflictedFilesUnstaged() async throws {
        try git("commit", "-q", "-am", "ours")
        try git("checkout", "-q", "-b", "other", "HEAD~1")
        try write("a.txt", "theirs\n")
        try git("commit", "-q", "-am", "theirs")
        try git("checkout", "-q", "main")
        try git("merge", "-q", "other")
        try write("b.txt", "b3\n")
        try write("new.txt", "new\n")

        let model = ChangesModel(state: state)
        await model.refresh()
        #expect(model.status.unstaged.contains { $0.path == "a.txt" && $0.kind == .conflicted })

        model.stageAll()
        try await until { model.status.staged.map(\.path).sorted() == ["b.txt", "new.txt"] }

        #expect(model.actionError == nil)
        // Still unmerged: `git add -A` would have marked it resolved with the markers in it.
        #expect(model.status.unstaged == [GitFileChange(path: "a.txt", kind: .conflicted)])
        #expect(try String(contentsOf: repo.appending(path: "a.txt"), encoding: .utf8).contains("<<<<<<<"))
    }

    /// A rename git only sees in the working tree (the new name added with `git add -N`) is one
    /// entry with two paths. Staging just the new name would leave the old one deleted and unstaged.
    @Test func stageAllAroundAConflictStagesBothNamesOfARename() async throws {
        try git("commit", "-q", "-am", "ours")
        try git("checkout", "-q", "-b", "other", "HEAD~1")
        try write("a.txt", "theirs\n")
        try git("commit", "-q", "-am", "theirs")
        try git("checkout", "-q", "main")
        try git("merge", "-q", "other")
        try FileManager.default.moveItem(at: repo.appending(path: "b.txt"), to: repo.appending(path: "moved.txt"))
        try git("add", "-N", "moved.txt")

        let model = ChangesModel(state: state)
        await model.refresh()
        #expect(model.status.unstaged.contains { $0.path == "moved.txt" && $0.originalPath == "b.txt" })

        model.stageAll()
        try await until { model.status.unstaged.count == 1 }

        #expect(model.actionError == nil)
        #expect(model.status.unstaged == [GitFileChange(path: "a.txt", kind: .conflicted)])
    }

    @Test func stageAllStagesEverythingWithoutConflicts() async throws {
        try write("new.txt", "new\n")
        try FileManager.default.removeItem(at: repo.appending(path: "b.txt"))
        let model = ChangesModel(state: state)
        await model.refresh()
        model.stageAll()
        try await until { model.status.staged.count == 3 }
        #expect(model.status.unstaged.isEmpty)
        #expect(model.actionError == nil)
    }

    @Test func aRunningCommitAndItsErrorSurviveLeavingTheWorktree() async throws {
        // Slow, then rejected: first there is progress to come back to, then an error.
        try installHook("#!/bin/sh\nsleep 1\necho 'lint failed' >&2\nexit 1\n")
        let store = ChangesModelStore.shared
        var model: ChangesModel? = ChangesModel(state: state)
        await model?.refresh()
        model?.message = "rejected"
        model?.commit()
        // The inspector turns to another worktree and drops its reference.
        model = nil

        // Coming back while git runs finds the same model: busy, so Commit cannot be sent twice.
        let returned = store.model(for: state)
        #expect(returned.activity == .commit)
        #expect(!returned.commitControl.isEnabled)
        try await idle(returned)
        #expect(returned.actionError?.contains("lint failed") == true)

        // And once more with the commit long over: the error is still waiting to be read.
        #expect(store.model(for: state) === returned)
        returned.actionError = nil
        #expect(store.model(for: state) !== returned)
        returned.message = ""
    }

    @Test func aModelWithNothingPendingIsNotKept() async throws {
        let store = ChangesModelStore.shared
        let model = ChangesModel(state: state)
        await model.refresh()
        model.message = "everything"
        model.commit()
        #expect(store.model(for: state) === model)
        try await idle(model)
        #expect(model.actionError == nil)
        // A clean finish leaves nothing to come back for, so the next visit starts fresh.
        #expect(store.model(for: state) !== model)
    }

    @Test func commitAllStagesEverythingWhenNothingIsStaged() async throws {
        let model = ChangesModel(state: state)
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
        let model = ChangesModel(state: state)
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

        let model = ChangesModel(state: state)
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

    @Test func aPushFromTheMenuHoldsTheTabsControlsAndTheOtherWayRound() async throws {
        let model = ChangesModel(state: state)
        await model.refresh()
        model.message = "while pushing"
        #expect(state.begin(.push))
        #expect(model.activity == .push)
        #expect(!model.commitControl.isEnabled)
        model.commit()
        #expect(state.operation == .push)
        state.end(.push)

        // A commit from the tab keeps the menu's push from starting.
        try installHook("#!/bin/sh\nsleep 1\n")
        model.commit()
        #expect(state.operation == .commit)
        #expect(!state.begin(.push))
        try await idle(model)
        model.message = ""
    }

    @Test func aStageInTheTabMovesTheSharedCountRightAway() async throws {
        let model = ChangesModel(state: state)
        let sidebarsView = state
        await model.refresh()
        #expect(sidebarsView.summary?.changedFiles == 2)
        let a = try #require(model.status.unstaged.first { $0.path == "a.txt" })
        model.discard(a, staged: false)
        try await until { sidebarsView.summary?.changedFiles == 1 }
        #expect(model.actionError == nil)
    }

    @Test func unstagingARenameUnstagesBothNames() async throws {
        try git("checkout", "-q", "--", ".")
        try git("mv", "a.txt", "moved.txt")
        let model = ChangesModel(state: state)
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
