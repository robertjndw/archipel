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

        do {
            try await git.push(in: repo)
            Issue.record("expected a push without a remote to be refused")
        } catch let error as GitError {
            #expect(error.message.contains("no remote"))
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
        // a.txt once, b.txt once, and each file of the untracked directory, as the Changes tab lists them.
        #expect(summary.changedFiles == 4)
        let status = try await git.status(in: repo)
        #expect(status.changedFiles == summary.changedFiles)
        #expect(status.unstaged.count { $0.kind == .untracked } == 2)
    }

    // MARK: Switching branches

    @Test func switchesToLocalAndNewBranches() async throws {
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)
        try sh("branch", "other")

        try await git.switchBranch(to: .local("other"), in: repo)
        #expect(await git.currentBranch(in: repo) == "other")

        try await git.switchBranch(to: .new("feat/fresh", base: "main"), in: repo)
        #expect(await git.currentBranch(in: repo) == "feat/fresh")

        await #expect(throws: GitError.self) {
            try await git.switchBranch(to: .local("does-not-exist"), in: repo)
        }
        #expect(await git.currentBranch(in: repo) == "feat/fresh")
    }

    @Test func switchCarriesChangesAlongButRefusesToOverwriteThem() async throws {
        try write("a.txt", "a\n")
        try write("b.txt", "b\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)
        try sh("switch", "-q", "-c", "other")
        try write("a.txt", "theirs\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "change a", in: repo)
        try sh("switch", "-q", "main")

        try write("b.txt", "carried\n")
        try await git.switchBranch(to: .local("other"), in: repo)
        #expect(await git.currentBranch(in: repo) == "other")
        #expect(try String(contentsOf: repo.appending(path: "b.txt"), encoding: .utf8) == "carried\n")
        try sh("switch", "-q", "main")

        try write("a.txt", "mine\n")
        do {
            try await git.switchBranch(to: .local("other"), in: repo)
            Issue.record("expected a conflicting switch to be refused")
        } catch let error as GitError {
            #expect(error.message.contains("a.txt"))
            #expect(!error.message.contains("Aborting"))
            #expect(!error.message.hasPrefix("error:"))
        }
        #expect(await git.currentBranch(in: repo) == "main")
        #expect(try String(contentsOf: repo.appending(path: "a.txt"), encoding: .utf8) == "mine\n")
    }

    @Test func listsRemoteBranchesAndTracksOne() async throws {
        let remote = try makeBareRemote()
        try sh("remote", "add", "origin", remote.path)
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)
        try await git.push(in: repo)

        let other = try makeOtherClone(of: remote)
        try run(["-C", other.path, "switch", "-q", "-c", "feature"])
        try "x\n".write(to: other.appending(path: "feature.txt"), atomically: true, encoding: .utf8)
        try run(["-C", other.path, "add", "-A"])
        try run(["-C", other.path, "commit", "-q", "-m", "feature"])
        try run(["-C", other.path, "push", "-q", "-u", "origin", "feature"])
        try await git.fetch(in: repo)
        try sh("remote", "set-head", "origin", "main")

        #expect(try await git.remoteBranches(in: repo).sorted() == ["origin/feature", "origin/main"])

        try await git.switchBranch(to: .remote("origin/feature"), in: repo)
        let summary = try await git.summary(in: repo)
        #expect(summary.branch == "feature")
        #expect(summary.upstream == "origin/feature")
    }

    @Test func remoteDefaultBranchFallsBackWithoutOriginHead() async throws {
        #expect(await git.remoteDefaultBranch(in: repo) == nil)

        let remote = try makeBareRemote()
        try sh("remote", "add", "origin", remote.path)
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)
        try await git.push(in: repo)
        // `remote add` leaves origin/HEAD unset, so this is the main/master guess.
        #expect(await git.remoteDefaultBranch(in: repo) == "origin/main")

        try sh("branch", "trunk")
        try sh("push", "-q", "origin", "trunk")
        try sh("remote", "set-head", "origin", "trunk")
        #expect(await git.remoteDefaultBranch(in: repo) == "origin/trunk")
    }

    @Test func remoteTrackingBranchSplitsOnlyRemoteRefs() async throws {
        let remote = try makeBareRemote()
        try sh("remote", "add", "origin", remote.path)
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)
        try sh("branch", "feature/x")
        try sh("push", "-q", "origin", "main", "feature/x")
        try await git.fetch(in: repo)

        let tracking = await git.remoteTrackingBranch("origin/feature/x", in: repo)
        #expect(tracking?.remote == "origin")
        #expect(tracking?.branch == "feature/x")
        #expect(await git.remoteTrackingBranch("main", in: repo) == nil)
        #expect(await git.remoteTrackingBranch("origin/missing", in: repo) == nil)
    }

    @Test func worktreeFromFetchedRemoteBaseHasNoUpstream() async throws {
        let remote = try makeBareRemote()
        try sh("remote", "add", "origin", remote.path)
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)
        try await git.push(in: repo)
        try commitInOther(try makeOtherClone(of: remote), "theirs.txt")

        try await git.fetch(branch: "main", from: "origin", in: repo)
        let wt = base.appending(path: "wt")
        try await git.addWorktree(repository: repo, path: wt, branch: "task", createBranch: true, base: "origin/main")

        #expect(FileManager.default.fileExists(atPath: wt.appending(path: "theirs.txt").path))
        let summary = try await git.summary(in: wt)
        #expect(summary.branch == "task")
        #expect(summary.upstream == nil)
    }

    @Test func fetchingAnUnreachableRemoteThrows() async throws {
        try sh("remote", "add", "origin", base.appending(path: "nowhere.git").path)
        await #expect(throws: GitError.self) {
            try await self.git.fetch(branch: "main", from: "origin", in: self.repo)
        }
    }

    @Test func ownSSHOptionsGiveWayToTheUsersCommand() {
        let ours = GitClient.sshEnvironment(batchMode: true, inherited: [:], configuredCommand: nil)
        #expect(ours["GIT_SSH_COMMAND"]?.hasPrefix("ssh -o BatchMode=yes -o ConnectTimeout=") == true)
        #expect(GitClient.sshEnvironment(batchMode: false, inherited: ["PATH": "/usr/bin"], configuredCommand: "")["GIT_SSH_COMMAND"]?.contains("BatchMode") == false)

        // git would run ours instead of any of these, and with it another key or account.
        #expect(GitClient.sshEnvironment(batchMode: true, inherited: ["GIT_SSH_COMMAND": "ssh -i key"], configuredCommand: nil).isEmpty)
        #expect(GitClient.sshEnvironment(batchMode: true, inherited: ["GIT_SSH": "/usr/local/bin/ssh"], configuredCommand: nil).isEmpty)
        #expect(GitClient.sshEnvironment(batchMode: false, inherited: [:], configuredCommand: "ssh -i ~/.ssh/work_key").isEmpty)
    }

    @Test func pushAndFetchRunTheConfiguredSSHCommand() async throws {
        // Stands in for `ssh -i ~/.ssh/work_key`: notes that it was the one git ran, then fails.
        let marker = base.appending(path: "ssh-ran")
        let script = base.appending(path: "work-ssh")
        try "#!/bin/sh\necho \"$@\" >> '\(marker.path)'\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try sh("config", "core.sshCommand", script.path)
        try sh("remote", "add", "origin", "ssh://git@example.invalid/repo.git")
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)

        await #expect(throws: GitError.self) { try await self.git.push(in: self.repo) }
        #expect(try String(contentsOf: marker, encoding: .utf8).contains("git-receive-pack"))

        try FileManager.default.removeItem(at: marker)
        await #expect(throws: GitError.self) { try await self.git.fetch(in: self.repo) }
        #expect(try String(contentsOf: marker, encoding: .utf8).contains("git-upload-pack"))

        try FileManager.default.removeItem(at: marker)
        await #expect(throws: GitError.self) { try await self.git.fetch(branch: "main", from: "origin", in: self.repo) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: Helpers

    /// A second clone of the remote, standing in for a teammate who pushes.
    private func makeOtherClone(of remote: URL) throws -> URL {
        let other = base.appending(path: "other")
        try run(["clone", "-q", remote.path, other.path])
        try run(["-C", other.path, "config", "user.name", "Other"])
        try run(["-C", other.path, "config", "user.email", "other@example.invalid"])
        try run(["-C", other.path, "config", "commit.gpgsign", "false"])
        return other
    }

    private func commitInOther(_ other: URL, _ file: String) throws {
        try "x\n".write(to: other.appending(path: file), atomically: true, encoding: .utf8)
        try run(["-C", other.path, "add", "-A"])
        try run(["-C", other.path, "commit", "-q", "-m", file])
        try run(["-C", other.path, "push", "-q"])
    }

    @Test func fetchThenPullFastForwards() async throws {
        let remote = try makeBareRemote()
        try sh("remote", "add", "origin", remote.path)
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)
        try await git.push(in: repo)

        let other = try makeOtherClone(of: remote)
        try commitInOther(other, "b.txt")

        #expect(try await git.summary(in: repo).behind == 0)
        try await git.fetch(in: repo)
        #expect(try await git.summary(in: repo).behind == 1)

        try await git.pull(in: repo)
        let after = try await git.summary(in: repo)
        #expect(after.behind == 0 && after.ahead == 0)
        #expect(FileManager.default.fileExists(atPath: repo.appending(path: "b.txt").path))
    }

    @Test func pullRefusesDivergedBranch() async throws {
        let remote = try makeBareRemote()
        try sh("remote", "add", "origin", remote.path)
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)
        try await git.push(in: repo)

        try commitInOther(try makeOtherClone(of: remote), "theirs.txt")
        try write("mine.txt", "m\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "mine", in: repo)

        do {
            try await git.pull(in: repo)
            Issue.record("expected a diverged branch to be refused")
        } catch let error as GitError {
            #expect(error.message.contains("diverged"))
        }
        #expect(try shOutput("log", "-1", "--format=%s") == "mine")
    }

    @Test func pullWithoutUpstreamExplains() async throws {
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)
        do {
            try await git.pull(in: repo)
            Issue.record("expected a branch without upstream to be refused")
        } catch let error as GitError {
            #expect(error.message.contains("no upstream"))
        }
    }

    /// A branch pushed to `origin`, whose remote branch is then deleted the way merging its pull
    /// request does. The local tracking ref is still there until a fetch prunes it.
    private func makeBranchDeletedOnTheRemote() async throws -> URL {
        let remote = try makeBareRemote()
        try sh("remote", "add", "origin", remote.path)
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "one", in: repo)
        try await git.push(in: repo)
        try sh("switch", "-q", "-c", "feature")
        try write("b.txt", "b\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "two", in: repo)
        try await git.push(in: repo)
        #expect(try await git.summary(in: repo).upstream == "origin/feature")
        try run(["--git-dir", remote.path, "branch", "-D", "feature"])
        return remote
    }

    @Test func aPrunedUpstreamIsGoneAndPushPublishesTheBranchAgain() async throws {
        let remote = try await makeBranchDeletedOnTheRemote()
        // What the app's own background fetch does.
        try await git.fetch(in: repo)

        let summary = try await git.summary(in: repo)
        #expect(summary.upstream == nil)
        #expect(summary.goneUpstream == "origin/feature")
        #expect(summary.ahead == 0 && summary.behind == 0)
        #expect(try await git.status(in: repo).goneUpstream == "origin/feature")

        do {
            try await git.pull(in: repo)
            Issue.record("expected a pull from a deleted upstream to be refused")
        } catch let error as GitError {
            #expect(error.message.contains("origin/feature no longer exists"))
        }

        try await git.push(in: repo)
        let after = try await git.summary(in: repo)
        #expect(after.upstream == "origin/feature")
        #expect(after.goneUpstream == nil)
        #expect(try shOutput("--git-dir", remote.path, "rev-list", "--count", "feature", dir: false) == "2")
    }

    @Test func pullSaysSoWhenItsOwnFetchFindsTheUpstreamDeleted() async throws {
        _ = try await makeBranchDeletedOnTheRemote()
        // Nothing has pruned yet, so the branch still looks published and up to date.
        #expect(try await git.summary(in: repo).upstream == "origin/feature")
        do {
            try await git.pull(in: repo)
            Issue.record("expected the pull to report the deleted upstream")
        } catch let error as GitError {
            #expect(error.message.contains("origin/feature no longer exists"))
        }
    }

    @Test func aGoneUpstreamOnAnotherRemoteIsPublishedBackThere() async throws {
        let remote = try makeBareRemote()
        let other = base.appending(path: "fork.git")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try run(["init", "-q", "--bare", "-b", "main", other.path])
        try sh("remote", "add", "origin", remote.path)
        try sh("remote", "add", "fork", other.path)
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "one", in: repo)
        // The fork keeps another branch, as a remote does whose branch was merged and deleted.
        try sh("push", "-q", "fork", "main:elsewhere")
        try sh("push", "-q", "-u", "fork", "main")
        try run(["--git-dir", other.path, "symbolic-ref", "HEAD", "refs/heads/elsewhere"])
        try run(["--git-dir", other.path, "branch", "-D", "main"])
        try await git.fetch(in: repo)
        #expect(try await git.summary(in: repo).goneUpstream == "fork/main")

        try await git.push(in: repo)
        #expect(try await git.summary(in: repo).upstream == "fork/main")
    }

    @Test func anUpstreamThatWasNeverThereIsPendingNotGone() async throws {
        // What cloning a repository without commits leaves: an upstream in the config and
        // nothing on the remote for it to name.
        let remote = try makeBareRemote()
        try FileManager.default.removeItem(at: repo)
        try run(["clone", "-q", remote.path, repo.path])
        try sh("config", "user.name", "GitKit Tests")
        try sh("config", "user.email", "tests@example.invalid")
        try sh("config", "commit.gpgsign", "false")

        let unborn = try await git.status(in: repo)
        #expect(unborn.upstream == nil)
        #expect(unborn.goneUpstream == nil)
        #expect(unborn.pendingUpstream == "origin/main")

        // With a commit status prints the same lines as for a deleted upstream. The remote
        // having no branch at all is what tells them apart.
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)
        let summary = try await git.summary(in: repo)
        #expect(summary.upstream == nil)
        #expect(summary.goneUpstream == nil)
        #expect(summary.pendingUpstream == "origin/main")
        #expect(try await git.status(in: repo).pendingUpstream == "origin/main")
        do {
            try await git.pull(in: repo)
            Issue.record("expected a pull without an upstream to be refused")
        } catch let error as GitError {
            #expect(error.message.contains("origin/main does not exist yet"))
        }

        try await git.push(in: repo)
        let published = try await git.summary(in: repo)
        #expect(published.upstream == "origin/main")
        #expect(published.pendingUpstream == nil)
    }

    @Test func aRemoteBranchIsSplitAtTheRemotesOwnName() async throws {
        let remote = try makeBareRemote()
        try sh("remote", "add", "team/mirror", remote.path)
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)
        try sh("push", "-q", "team/mirror", "main:feature/x")
        try sh("fetch", "-q", "team/mirror")

        // Cut at the first slash this would be a remote "team", which does not exist.
        let tracking = await git.remoteTrackingBranch("team/mirror/feature/x", in: repo)
        #expect(tracking?.remote == "team/mirror")
        #expect(tracking?.branch == "feature/x")
    }

    @Test func aFetchWithATimeoutGivesUpOnARemoteThatNeverAnswers() async throws {
        // Stands in for a connection that hangs: an ssh that accepts the call and says nothing.
        let script = base.appending(path: "silent-ssh")
        try "#!/bin/sh\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try sh("config", "core.sshCommand", script.path)
        try sh("remote", "add", "origin", "ssh://git@example.invalid/repo.git")

        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await git.fetch(branch: "main", from: "origin", in: repo, timeout: .milliseconds(300))
            Issue.record("expected the fetch to be given up")
        } catch let error as GitError {
            #expect(error.message.contains("took too long"))
        }
        // Well short of the 30 seconds the remote stays silent, with room for a busy runner.
        #expect(clock.now - start < .seconds(15))

        // A remote that answers in time is fetched as without a timeout.
        let remote = try makeBareRemote()
        try sh("config", "--unset", "core.sshCommand")
        try sh("remote", "set-url", "origin", remote.path)
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "first", in: repo)
        try await git.push(in: repo)
        try await git.fetch(branch: "main", from: "origin", in: repo, timeout: .seconds(60))
    }

    @Test func publishGoesToOriginOrTheOnlyRemote() async throws {
        #expect(GitClient.publishRemote(among: []) == nil)
        #expect(GitClient.publishRemote(among: ["origin"]) == "origin")
        #expect(GitClient.publishRemote(among: ["upstream", "origin"]) == "origin")
        #expect(GitClient.publishRemote(among: ["github"]) == "github")
        // Two remotes and no origin: picking one would be a guess.
        #expect(GitClient.publishRemote(among: ["github", "gitlab"]) == nil)
        // Unless the branch was on one of them before.
        #expect(GitClient.publishRemote(among: ["github", "gitlab"], goneUpstream: "gitlab/feature") == "gitlab")
        #expect(GitClient.publishRemote(among: ["team", "team/mirror"], goneUpstream: "team/mirror/feature") == "team/mirror")
        #expect(GitClient.publishRemote(among: ["origin", "fork"], goneUpstream: "removed/feature") == "origin")

        let remote = try makeBareRemote()
        try sh("remote", "add", "github", remote.path)
        #expect(await git.remoteNames(in: repo) == ["github"])
        try write("a.txt", "a\n")
        try await git.stageAll(in: repo)
        try await git.commit(message: "one", in: repo)
        try await git.push(in: repo)
        #expect(try await git.summary(in: repo).upstream == "github/main")

        try sh("remote", "add", "gitlab", remote.path)
        try sh("switch", "-q", "-c", "second")
        do {
            try await git.push(in: repo)
            Issue.record("expected a publish with two remotes and no origin to be refused")
        } catch let error as GitError {
            #expect(error.message.contains("named origin"))
        }
    }

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
