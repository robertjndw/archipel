import Foundation
import Testing
@testable import GitKit

@MainActor
final class GitWorktreeStateTests {
    let repo: URL

    init() throws {
        let temp = realpath(FileManager.default.temporaryDirectory.path, nil).map { String(cString: $0) } ?? NSTemporaryDirectory()
        repo = URL(filePath: temp).appending(path: "GitWorktreeStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.name", "GitKit Tests")
        try git("config", "user.email", "tests@example.invalid")
        try git("config", "commit.gpgsign", "false")
        try "a\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try git("add", "-A")
        try git("commit", "-q", "-m", "first")
    }

    deinit {
        try? FileManager.default.removeItem(at: repo)
    }

    @Test func onlyOneOperationRunsAtATime() {
        let state = GitWorktreeState(root: repo)
        #expect(state.begin(.push))
        // Whether the second one comes from the tab or a menu, it does not start.
        #expect(!state.begin(.push))
        #expect(!state.begin(.commit))
        #expect(!state.syncState.canPush(from: .command))
        // Only the operation that is running can end it.
        state.end(.fetch)
        #expect(state.operation == .push)
        state.end(.push)
        #expect(state.operation == nil)
        #expect(state.begin(.pull))
    }

    @Test func theSummaryIsTheStatusCounted() async throws {
        try FileManager.default.createDirectory(at: repo.appending(path: "new"), withIntermediateDirectories: true)
        for name in ["one", "two", "three"] {
            try name.write(to: repo.appending(path: "new/\(name).txt"), atomically: true, encoding: .utf8)
        }
        try "a2\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let state = GitWorktreeState(root: repo)
        await state.refresh()
        #expect(state.status?.unstaged.count == 4)
        #expect(state.summary?.changedFiles == 4)
        #expect(state.summary?.branch == "main")
    }

    @Test func aReadThatStartedBeforeABranchSwitchIsDropped() async throws {
        // Holds `git status` up for a moment, long enough to switch branches under it. A failing
        // monitor only makes git look at every file itself.
        // The marker says git is inside the status call, which a fixed wait cannot promise while
        // other tests keep the main actor and git busy.
        let monitor = repo.appending(path: ".git/slow-monitor")
        let marker = repo.appending(path: ".git/monitor-ran")
        try "#!/bin/sh\ntouch '\(marker.path)'\nsleep 1\nexit 1\n".write(to: monitor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: monitor.path)
        try git("config", "core.fsmonitor", monitor.path)

        let state = GitWorktreeState(root: repo)
        let early = Task { await state.refresh() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try git("switch", "-q", "-c", "other")
        state.invalidatePendingReads()
        await early.value
        #expect(state.status == nil)

        await state.refresh()
        #expect(state.status?.branch == "other")
    }

    @Test func heldReadsKeepWhatIsShownUntilReleased() async throws {
        let state = GitWorktreeState(root: repo)
        await state.refresh()
        #expect(state.summary?.changedFiles == 0)

        // Like a folder that git is partway through deleting.
        state.holdReads()
        try FileManager.default.removeItem(at: repo.appending(path: "a.txt"))
        await state.refresh()
        #expect(state.summary?.changedFiles == 0)

        state.releaseReads()
        await state.refresh()
        #expect(state.summary?.changedFiles == 1)
    }

    @Test func readsAskedForWhileOneRunsAreServedByTheNextOne() async throws {
        let state = GitWorktreeState(root: repo)
        async let first: Void = state.refresh()
        async let second: Void = state.refresh(GitRefreshRequest(readsRemotes: true))
        _ = await (first, second)
        #expect(state.status?.branch == "main")
        #expect(state.remotes == [])
    }

    @Test func aFolderThatIsNotARepositorySaysSo() async throws {
        let outside = URL(filePath: NSTemporaryDirectory()).appending(path: "GitWorktreeStateTests-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let state = GitWorktreeState(root: outside)
        await state.refresh()
        #expect(state.status == nil)
        #expect(state.isRepository == false)
        #expect(state.refreshError == nil)
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
        guard process.terminationStatus == 0 else { throw GitError(message: "git \(arguments.joined(separator: " ")) failed") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
