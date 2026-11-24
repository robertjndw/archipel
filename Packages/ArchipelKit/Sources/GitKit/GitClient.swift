import Foundation
import Synchronization

public struct GitClient: Sendable {
    /// Where a discarded file goes that no commit holds. The system Trash unless a caller says
    /// otherwise, which is what lets tests discard without filling the Trash of whoever runs them.
    private let moveToTrash: @Sendable (URL) throws -> Void

    public init() {
        moveToTrash = { try GitProcess.moveToTrash($0) }
    }

    public init(moveToTrash: @escaping @Sendable (URL) throws -> Void) {
        self.moveToTrash = moveToTrash
    }

    /// Makes every client of this process that was not given a trash of its own put discarded
    /// files into `folder`. The system Trash belongs to the user account, whatever HOME says, so
    /// the UI test build, which really discards files, would otherwise leave them in the Trash of
    /// whoever runs the tests.
    public static func discardInto(_ folder: URL) {
        GitProcess.trashFolder.withLock { $0 = folder }
    }

    /// Gives every git this process starts the user's own PATH, once `resolve` has it. An app
    /// started from the Dock has launchd's bare PATH, where the tools git itself runs are missing
    /// when they come from Homebrew: hook managers (husky, lefthook), git-lfs, gpg, credential helpers.
    ///
    /// Asking a login shell takes a while. Commands that only read never wait for the answer and
    /// run with the inherited PATH until it is there, so status polling starts at once. Commands
    /// that write wait, because those are the ones that run hooks and filters.
    public static func resolveSearchPATH(_ resolve: @escaping @Sendable () async -> String) {
        GitProcess.searchPATH.resolve(resolve)
    }

    public func isRepository(_ folder: URL) async -> Bool {
        let output = try? await run(["rev-parse", "--is-inside-work-tree"], in: folder)
        return output?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func currentBranch(in folder: URL) async -> String? {
        // symbolic-ref also answers on an unborn branch, unlike rev-parse --abbrev-ref.
        guard let output = try? await run(["symbolic-ref", "--short", "-q", "HEAD"], in: folder) else { return nil }
        let branch = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    /// The git directory shared by the main checkout and all its linked worktrees, which is where
    /// refs and the list of worktrees live. Nil for a folder outside any repository.
    public func commonDirectory(of folder: URL) async -> URL? {
        guard let output = try? await run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: folder) else { return nil }
        let path = output.trimmingCharacters(in: .newlines)
        return path.isEmpty ? nil : URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Whether both refs exist and point at the same commit. Full ref names (`refs/heads/x`), so a
    /// branch named like an option or a tag of the same name cannot get in the way.
    public func refsMatch(_ first: String, _ second: String, in folder: URL) async -> Bool {
        // The trailing `--` makes a missing ref an error instead of something to look for as a file.
        guard let output = try? await run(["rev-parse", first + "^{commit}", second + "^{commit}", "--"], in: folder) else { return false }
        let lines = output.split(whereSeparator: \.isNewline)
        return lines.count >= 2 && lines[0] == lines[1]
    }

    /// The commits without parents that HEAD's history starts from, sorted. Every clone of a
    /// repository has the same ones, and an unrelated repository has none of them, so they identify
    /// a repository after its folder is gone. Nil outside a repository or before its first commit.
    public func rootCommits(in folder: URL) async -> [String]? {
        guard let output = try? await run(["rev-list", "--max-parents=0", "HEAD", "--"], in: folder) else { return nil }
        let roots = output.split(whereSeparator: \.isNewline).map(String.init).sorted()
        return roots.isEmpty ? nil : roots
    }

    public func worktrees(of repository: URL) async throws -> [GitWorktreeEntry] {
        GitParser.worktrees(try await run(["worktree", "list", "--porcelain", "-z"], in: repository))
    }

    public func localBranches(in repository: URL) async throws -> [String] {
        try await run(["for-each-ref", "--format=%(refname:short)", "refs/heads/"], in: repository)
            .split(separator: "\n")
            .map(String.init)
    }

    /// Remote-tracking branches as `origin/name`. The symbolic `origin/HEAD` is left out: it only
    /// points at one of the others, and switching to it would leave HEAD detached.
    public func remoteBranches(in repository: URL) async throws -> [String] {
        try await run(["for-each-ref", "--format=%(refname:short)%09%(symref)", "refs/remotes/"], in: repository)
            .split(separator: "\n")
            .compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 2, fields[1].isEmpty else { return nil }
                return String(fields[0])
            }
    }

    /// Checks out another branch in place. Uncommitted changes come along if they don't conflict,
    /// otherwise git refuses and nothing changes. `switch` instead of `checkout` because it never
    /// overwrites files or detaches HEAD by accident.
    public func switchBranch(to target: GitSwitchTarget, in folder: URL) async throws {
        let args = switch target {
        // --no-guess so a typo never quietly creates a tracking branch from a remote of that name.
        // The `--` keeps a ref that starts with a dash from being read as an option.
        case .local(let branch): ["switch", "--no-guess", "--", branch]
        case .remote(let remoteBranch): ["switch", "--track", "--", remoteBranch]
        // --no-track for the same reason as in addWorktree: a remote base must not become the upstream.
        case .new(let branch, let base): ["switch", "-c", branch] + (base.map { ["--no-track", "--", $0] } ?? [])
        }
        let result = try await GitProcess.run(args, in: folder, readOnly: false)
        guard result.status != 0 else { return }
        throw GitError(switchFailure: result)
    }

    /// `base` is the ref a new branch starts from; nil means HEAD. It is ignored for an existing branch.
    public func addWorktree(repository: URL, path: URL, branch: String, createBranch: Bool, base: String? = nil) async throws {
        // --no-track because branching off `origin/main` would otherwise make it the upstream: status
        // then reads "ahead of origin/main" and a plain push is refused for the mismatched name.
        let args = createBranch
            ? ["worktree", "add", "-b", branch] + (base == nil ? [] : ["--no-track"]) + ["--", path.path] + (base.map { [$0] } ?? [])
            : ["worktree", "add", "--", path.path, branch]
        let result = try await GitProcess.run(args, in: repository, readOnly: false)
        guard result.status != 0 else { return }
        throw GitError(worktreeAddFailure: result)
    }

    /// A worktree on a new local branch that starts at and tracks `remoteBranch` (`origin/feature`),
    /// for a branch that so far only exists on the remote. Unlike a new branch off a base, the
    /// remote branch is meant to be the upstream here. Fails when `branch` already exists locally.
    public func addWorktree(repository: URL, path: URL, branch: String, tracking remoteBranch: String) async throws {
        let args = ["worktree", "add", "--track", "-b", branch, "--", path.path, remoteBranch]
        let result = try await GitProcess.run(args, in: repository, readOnly: false)
        guard result.status != 0 else { return }
        throw GitError(worktreeAddFailure: result)
    }

    /// The remote's default branch as `origin/main`, read from the local `origin/HEAD`. Clones set
    /// that, but `git remote add` does not, so `origin/main` and `origin/master` are tried after it.
    /// Nil without such a branch, which includes having no origin at all. Never touches the network.
    public func remoteDefaultBranch(in repository: URL) async -> String? {
        if let output = try? await run(["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"], in: repository) {
            let ref = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ref.isEmpty { return ref }
        }
        for name in ["main", "master"] {
            if await refExists("refs/remotes/origin/\(name)", in: repository) { return "origin/\(name)" }
        }
        return nil
    }

    /// Splits a remote-tracking branch such as `origin/feature/x` into remote and branch, or nil when
    /// `ref` is not one. A local branch of the same name wins, as it does when git resolves the name.
    public func remoteTrackingBranch(_ ref: String, in repository: URL) async -> (remote: String, branch: String)? {
        guard await !refExists("refs/heads/\(ref)", in: repository),
              await refExists("refs/remotes/\(ref)", in: repository),
              let output = try? await run(["remote"], in: repository)
        else { return nil }
        // Remote names may contain slashes themselves, so match against the configured names.
        let remote = output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { ref.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
        guard let remote else { return nil }
        return (remote, String(ref.dropFirst(remote.count + 1)))
    }

    /// Updates a single remote-tracking branch, e.g. right before branching off it. The sheet waits
    /// on this, so a dead connection should fail fast.
    ///
    /// The stall limits below only cover a transfer that has started. `timeout` bounds the whole
    /// call, including a connection that never answers and the wait for a slot behind other
    /// fetches that hang on the same dead network.
    public func fetch(branch: String, from remote: String, in repository: URL, timeout: Duration) async throws {
        let (outcomes, outcome) = AsyncStream.makeStream(of: Result<Void, any Error>.self)
        let work = Task {
            do {
                try await fetch(branch: branch, from: remote, in: repository)
                outcome.yield(.success(()))
            } catch {
                outcome.yield(.failure(error))
            }
        }
        let timer = Task {
            try await Task.sleep(for: timeout)
            outcome.yield(.failure(GitError(message: "Fetching \(branch) from \(remote) took too long.")))
        }
        // Cancelling stops the git process, or keeps it from starting once its slot comes up.
        defer {
            work.cancel()
            timer.cancel()
        }
        // Ends without an outcome when the caller is cancelled.
        for await first in outcomes { return try first.get() }
        throw CancellationError()
    }

    public func fetch(branch: String, from remote: String, in repository: URL) async throws {
        let args = [
            "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=15",
            "fetch", "--quiet", "--no-tags", "--", remote, "refs/heads/\(branch)",
        ]
        let environment = await sshEnvironment(batchMode: true, in: repository)
        let result = try await GitProcess.run(args, in: repository, readOnly: false, environment: environment, lane: .network)
        guard result.status == 0 else { throw GitError(command: "git fetch", output: result) }
    }

    private func refExists(_ ref: String, in repository: URL) async -> Bool {
        let result = try? await GitProcess.run(["rev-parse", "--verify", "-q", ref], in: repository, readOnly: true)
        return result?.status == 0
    }

    /// Asks git rather than reimplementing check-ref-format's rules. Uses `--branch`, so it also
    /// rejects names git would refuse for a branch specifically, such as `-x` or `HEAD`.
    public func isValidBranchName(_ name: String, in repository: URL) async -> Bool {
        let result = try? await GitProcess.run(["check-ref-format", "--branch", name], in: repository, readOnly: true)
        return result?.status == 0
    }

    /// Without `force` git refuses a worktree with uncommitted or untracked changes. Locked worktrees
    /// stay protected either way: git wants `--force` twice for those, and we never send that.
    public func removeWorktree(repository: URL, path: URL, force: Bool = false) async throws {
        let args = ["worktree", "remove"] + (force ? ["--force"] : []) + ["--", path.path]
        try await run(args, in: repository, readOnly: false)
    }

    /// Reconnects worktrees that were moved by hand. Run in a moved linked worktree, it updates the
    /// repository's record of where it is; run in a moved main checkout with the linked worktrees'
    /// folders, it points those back at the repository.
    public func repairWorktrees(in folder: URL, paths: [URL] = []) async throws {
        try await run(["worktree", "repair", "--"] + paths.map(\.path), in: folder, readOnly: false)
    }

    /// Safe delete with `-d`: a branch not merged into HEAD (or its upstream) is kept, not thrown away.
    public func deleteBranch(_ branch: String, in repository: URL) async throws -> GitBranchDeletion {
        // C locale so the message below is not translated.
        let result = try await GitProcess.run(["branch", "-d", "--", branch], in: repository, readOnly: false, environment: ["LC_ALL": "C"])
        if result.status == 0 { return .deleted }
        // git has no dedicated exit code for this, so the message is the only way to tell it apart
        // from a missing branch or one checked out elsewhere.
        if result.stderr.contains("not fully merged") { return .keptUnmerged }
        throw GitError(command: "git branch", output: result)
    }

    public func status(in folder: URL) async throws -> GitStatus {
        var status = GitParser.status(try await run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: folder))
        if let missing = status.goneUpstream, await upstreamRemoteHasNoBranches(of: status.branch, in: folder) {
            status.goneUpstream = nil
            status.pendingUpstream = missing
        }
        return status
    }

    /// Skips `--untracked-files=all` so a huge untracked directory counts once and the call stays fast
    /// enough to poll for every worktree.
    public func summary(in folder: URL) async throws -> GitSummary {
        var summary = GitParser.summary(try await run(["status", "--porcelain=v2", "-z", "--branch"], in: folder))
        if let missing = summary.goneUpstream, await upstreamRemoteHasNoBranches(of: summary.branch, in: folder) {
            summary.goneUpstream = nil
            summary.pendingUpstream = missing
        }
        return summary
    }

    /// Status reports a missing upstream the same way whether the branch was deleted on the remote
    /// or was never there. What tells them apart: a remote that had a branch deleted after a merge
    /// still has the one it was merged into, while the clone of an empty repository knows no
    /// branch of its remote at all until the first push.
    ///
    /// Only asked for a branch whose upstream is missing, so the usual poll stays one git call.
    private func upstreamRemoteHasNoBranches(of branch: String?, in folder: URL) async -> Bool {
        guard let branch, let configured = try? await run(["config", "--get", "branch.\(branch).remote"], in: folder) else { return false }
        let remote = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        // "." is a local branch as upstream, which has no remote to be empty.
        guard !remote.isEmpty, remote != "." else { return false }
        guard let known = try? await run(["for-each-ref", "--count=1", "--format=%(refname)", "refs/remotes/\(remote)/"], in: folder) else { return false }
        return known.isEmpty
    }

    /// Commits what is staged. The message travels as its own argv element, so newlines and a leading
    /// dash are safe. stderr is surfaced on failure because a hook may reject the commit.
    public func commit(message: String, in folder: URL) async throws {
        try await run(["commit", "-m", message], in: folder, readOnly: false)
    }

    /// The URL of `origin`, or nil without one.
    public func originURL(in folder: URL) async -> String? {
        guard let output = try? await run(["remote", "get-url", "origin"], in: folder) else { return nil }
        let url = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    /// True when any remote is configured.
    public func hasRemote(in folder: URL) async -> Bool {
        let output = try? await run(["remote"], in: folder)
        return output?.contains(where: { !$0.isWhitespace }) == true
    }

    /// The configured remotes; empty without any, or when git cannot be asked.
    public func remoteNames(in folder: URL) async -> [String] {
        guard let output = try? await run(["remote"], in: folder) else { return [] }
        return output.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// The remote `push` publishes a branch without a usable upstream to, or nil when that would
    /// be a guess. A branch whose upstream is gone goes back to the remote it was on. Otherwise
    /// `origin`, or the only remote there is, whatever it is called.
    public static func publishRemote(among remotes: [String], goneUpstream: String? = nil) -> String? {
        // Remote names may contain slashes themselves, so the longest one that fits wins.
        if let goneUpstream, let remote = remotes.filter({ goneUpstream.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            return remote
        }
        if remotes.contains("origin") { return "origin" }
        return remotes.count == 1 ? remotes[0] : nil
    }

    /// Plain `git push` when the branch tracks something, otherwise publishes it to the remote
    /// `publishRemote` picks and sets the upstream. Nothing here can prompt: stdin is /dev/null, `GIT_TERMINAL_PROMPT=0` is set, and the
    /// app has no controlling terminal for ssh or credential helpers to open.
    ///
    /// No BatchMode, unlike the unattended fetches: a push is something the user asked for, so an askpass
    /// helper they set up for their key may still show its window.
    public func push(in folder: URL) async throws {
        let summary = try await summary(in: folder)
        guard summary.branch != nil else {
            throw GitError(message: "HEAD is detached. Check out a branch before pushing.")
        }
        if summary.upstream != nil {
            try await runPush(["push"], in: folder)
            return
        }
        let remotes = try await run(["remote"], in: folder).split(whereSeparator: \.isNewline).map(String.init)
        guard let remote = Self.publishRemote(among: remotes, goneUpstream: summary.goneUpstream ?? summary.pendingUpstream) else {
            throw GitError(message: remotes.isEmpty
                ? "This branch has no upstream and the repository has no remote."
                : "This branch has no upstream, and none of the repository's remotes is named origin. Push from a terminal to choose one.")
        }
        // Also for a gone upstream: a plain push is refused under `push.default=simple` when the
        // old upstream had another name, and naming the remote and HEAD works either way.
        try await runPush(["push", "-u", remote, "HEAD"], in: folder)
    }

    private func runPush(_ arguments: [String], in folder: URL) async throws {
        let result = try await GitProcess.run(
            Self.stallOptions + arguments, in: folder, readOnly: false,
            environment: await sshEnvironment(batchMode: false, in: folder), lane: .network
        )
        guard result.status == 0 else { throw GitError(command: "git push", output: result) }
    }

    /// Updates the remote-tracking refs so ahead/behind counts are current. Unattended unless
    /// `userInitiated`: ssh gets BatchMode so an unknown host key or a locked key fails at once
    /// instead of waiting for a prompt nobody can answer. A fetch the user asked for is treated like
    /// a push, see there. An ssh command the user chose is left alone, see `sshEnvironment`.
    public func fetch(in folder: URL, userInitiated: Bool = false) async throws {
        let result = try await GitProcess.run(
            Self.stallOptions + ["fetch", "--quiet", "--prune"], in: folder, readOnly: false,
            environment: await sshEnvironment(batchMode: !userInitiated, in: folder), lane: .network
        )
        guard result.status == 0 else { throw GitError(command: "git fetch", output: result) }
    }

    private func sshEnvironment(batchMode: Bool, in folder: URL) async -> [String: String] {
        let configured = try? await run(["config", "--get", "core.sshCommand"], in: folder)
        return Self.sshEnvironment(
            batchMode: batchMode,
            inherited: ProcessInfo.processInfo.environment,
            configuredCommand: configured?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// ConnectTimeout only covers the handshake. The keepalives are what end a connection that died
    /// later: ssh gives up after three unanswered ones, where it would otherwise wait on the dead
    /// socket for as long as TCP lets it.
    ///
    /// Empty when the user chose their own ssh, in the environment or as `core.sshCommand` (in the
    /// repository or any config it includes). git ranks GIT_SSH_COMMAND above both `core.sshCommand`
    /// and GIT_SSH, so setting it would replace their command, and with it the key or account it
    /// selects, by plain `ssh`. Their command then runs without our timeouts.
    static func sshEnvironment(batchMode: Bool, inherited: [String: String], configuredCommand: String?) -> [String: String] {
        guard inherited["GIT_SSH_COMMAND"] == nil, inherited["GIT_SSH"] == nil, configuredCommand?.isEmpty != false else { return [:] }
        let options = (batchMode ? ["-o BatchMode=yes"] : [])
            + ["-o ConnectTimeout=10", "-o ServerAliveInterval=15", "-o ServerAliveCountMax=3"]
        return ["GIT_SSH_COMMAND": (["ssh"] + options).joined(separator: " ")]
    }

    /// The HTTP counterpart: a transfer that moves nothing at all for a minute is aborted.
    ///
    /// Deliberately more patient than `fetch(branch:)`. While a server packs objects or runs its
    /// receive hooks, all that arrives is a few keepalive bytes every five seconds, and a limit of
    /// 1000 bytes per second would cut off a slow but healthy push or a fetch of a large repository.
    private static let stallOptions = ["-c", "http.lowSpeedLimit=1", "-c", "http.lowSpeedTime=60"]

    /// Fetches, then fast-forwards the branch to its upstream. Never merges or rebases. A diverged
    /// branch is refused with an explanation, since sorting that out needs someone in a terminal.
    public func pull(in folder: URL) async throws {
        let before = try await summary(in: folder)
        guard before.branch != nil else {
            throw GitError(message: "HEAD is detached. Check out a branch before pulling.")
        }
        guard let upstream = before.upstream else {
            if let pending = before.pendingUpstream {
                throw GitError(message: "\(pending) does not exist yet, so there is nothing to pull. Publish the branch first.")
            }
            throw GitError(message: before.goneUpstream.map(Self.goneUpstreamMessage) ?? "This branch has no upstream to pull from.")
        }
        // Only ever asked for by the user.
        try await fetch(in: folder, userInitiated: true)
        let after = try await summary(in: folder)
        // The fetch prunes, so it can be the one that finds the branch deleted on the remote.
        // Without this the pull would end as if there had simply been nothing new.
        if let gone = after.goneUpstream { throw GitError(message: Self.goneUpstreamMessage(gone)) }
        guard after.behind > 0 else { return }
        guard after.ahead == 0 else {
            throw GitError(message: "This branch and \(upstream) have diverged (\(after.ahead) ahead, \(after.behind) behind), so it cannot be fast-forwarded. Rebase or merge in a terminal.")
        }
        try await run(["merge", "--ff-only", "@{upstream}"], in: folder, readOnly: false)
    }

    private static func goneUpstreamMessage(_ upstream: String) -> String {
        "\(upstream) no longer exists, so there is nothing to pull. Publish the branch to push it again."
    }

    /// Paths are relative to `folder`, not the repository root, and limited to it. Callers pass the
    /// worktree root, where the two coincide. Tracked files plus untracked ones that are not ignored,
    /// minus tracked files already deleted from the working tree.
    public func listFiles(in folder: URL) async throws -> [String] {
        async let listed = run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: folder)
        async let deletedListed = run(["ls-files", "-z", "--deleted"], in: folder)
        let all = GitParser.paths(try await listed)
        let deleted = Set(GitParser.paths(try await deletedListed))
        // A path can appear twice, e.g. while merge conflicts leave several index stages.
        var seen = Set<String>()
        return all.filter { !deleted.contains($0) && seen.insert($0).inserted }
    }

    public func stage(_ paths: [String], in folder: URL) async throws {
        for batch in Self.batches(paths) {
            try await run(["add", "-A", "--"] + pathspecs(batch), in: folder, readOnly: false)
        }
    }

    /// `git reset` rather than `git restore --staged` because reset also works on an unborn branch.
    public func unstage(_ paths: [String], in folder: URL) async throws {
        for batch in Self.batches(paths) {
            try await run(["reset", "-q", "--"] + pathspecs(batch), in: folder, readOnly: false)
        }
    }

    public func stageAll(in folder: URL) async throws {
        try await run(["add", "-A"], in: folder, readOnly: false)
    }

    public func unstageAll(in folder: URL) async throws {
        try await run(["reset", "-q"], in: folder, readOnly: false)
    }

    /// Throws away the working tree edits of unstaged entries, leaving the index alone. Untracked
    /// files have no copy in git, so they go to the Trash where they can still be recovered.
    /// Conflicted entries are skipped: picking a side is a merge decision, not a discard. So is a
    /// folder, which is a nested repository or linked worktree and not one change to throw away.
    public func discardUnstaged(_ changes: [GitFileChange], in folder: URL) async throws {
        let changes = changes.filter { $0.kind != .conflicted && !$0.isDirectory }
        let top = try await topLevel(of: folder)
        // An unstaged addition is an intent-to-add entry (`git add -N`). Its index entry is empty, so
        // `restore --worktree` would "restore" the file to zero bytes and report success. The only
        // copy is the one on disk, exactly as for an untracked file.
        //
        // An unstaged rename or copy is one too: the working tree only has a name the index lacks
        // after `git add -N`, which status then pairs with a file that went missing or changed.
        let unversionedKinds: [GitChangeKind] = [.untracked, .added, .renamed, .copied]
        let unversioned = changes.filter { unversionedKinds.contains($0.kind) }
        // Index first: if the entry outlived a trashed file it would read as a deletion, and
        // discarding that restores the empty file after all. Failing here leaves everything in place.
        var intended = unversioned.filter { $0.kind != .untracked }.map(\.path)
        // An intent-to-add file that was then deleted reads as a plain deletion. Restoring it would
        // bring back a file that never had content in git, empty. Dropping the entry is all there is to undo.
        let abandoned = try await intentToAddEntries(among: changes.filter { $0.kind == .deleted }.map(\.path), top: top)
        intended += abandoned
        if !intended.isEmpty {
            try await unstage(intended, in: folder)
        }
        let leftovers = trash(unversioned.map(\.path), top: top)
        // A rename also took the old name away, which is tracked and comes back like any deletion.
        let tracked: [String] = changes.compactMap { change in
            switch change.kind {
            case .untracked, .added, .copied: return nil
            case .renamed: return change.originalPath
            default: return abandoned.contains(change.path) ? nil : change.path
            }
        }
        for batch in Self.batches(tracked) {
            try await run(["restore", "--worktree", "--"] + pathspecs(batch), in: folder, readOnly: false)
        }
        if let error = leftovers.error(unstaged: false) { throw error }
    }

    /// Which of these paths the index holds only as an intent to add (`git add -N`). Status does
    /// not say: it reports such an entry with the mode and the empty blob of a real one. What gives
    /// it away is that HEAD has no such file and the index has no addition staged for it.
    private func intentToAddEntries(among paths: [String], top: URL) async throws -> Set<String> {
        var known = Set<String>()
        for batch in Self.batches(paths) {
            // Fails on a branch without commits, where nothing is in HEAD.
            let committed = (try? await run(["ls-tree", "-r", "-z", "--name-only", "HEAD", "--"] + batch, in: top)) ?? ""
            let staged = try await run(["diff", "--cached", "--name-only", "-z", "--diff-filter=A", "--"] + pathspecs(batch), in: top)
            known.formUnion((committed + staged).split(separator: "\0").map(String.init))
        }
        return Set(paths).subtracting(known)
    }

    /// Resets staged entries to HEAD in both index and working tree. Files HEAD has never seen
    /// (added, or the new name of a rename or copy) have nothing to be reset to. They leave the
    /// index and go to the Trash, as in `discardUnstaged`: no commit holds them, so deleting them
    /// would be final. That also covers an unborn branch, where every staged entry is an addition.
    public func discardStaged(_ changes: [GitFileChange], in folder: URL) async throws {
        let changes = changes.filter { $0.kind != .conflicted }
        var removed: [String] = []
        var restored: [String] = []
        for change in changes {
            switch change.kind {
            case .added:
                removed.append(change.path)
            case .renamed, .copied:
                removed.append(change.path)
                // A copy leaves its source in place, so only a rename has an old name to bring back.
                if change.kind == .renamed, let original = change.originalPath { restored.append(original) }
            default:
                restored.append(change.path)
            }
        }
        var leftovers = Leftovers()
        if !removed.isEmpty {
            let top = try await topLevel(of: folder)
            // Index first, so a failure leaves the files where they are.
            for batch in Self.batches(removed) {
                try await run(["rm", "--cached", "-f", "-q", "--"] + pathspecs(batch), in: folder, readOnly: false)
            }
            leftovers = trash(removed, top: top)
        }
        for batch in Self.batches(restored) {
            try await run(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + pathspecs(batch), in: folder, readOnly: false)
        }
        if let error = leftovers.error(unstaged: true) { throw error }
    }

    /// Splits paths over as many commands as it takes to keep each one well under the kernel's
    /// limit on arguments plus environment (1 MB). A few thousand changed files in deep folders
    /// reach it, and the command then fails before git even starts.
    ///
    /// The count is limited too: Process refuses more than 4096 arguments however short they are,
    /// and very short paths would get close to that within the byte limit.
    static func batches(_ paths: [String], byteLimit: Int = 128 * 1024, countLimit: Int = 2000) -> [[String]] {
        var batches: [[String]] = []
        var size = 0
        for path in paths {
            // The pathspec magic in front, the terminator and the pointer to it.
            let cost = path.utf8.count + 32
            if batches.isEmpty || size + cost > byteLimit || batches[batches.count - 1].count >= countLimit {
                batches.append([])
                size = 0
            }
            batches[batches.count - 1].append(path)
            size += cost
        }
        return batches
    }

    private func topLevel(of folder: URL) async throws -> URL {
        let top = try await run(["rev-parse", "--show-toplevel"], in: folder).trimmingCharacters(in: .newlines)
        return URL(filePath: top, directoryHint: .isDirectory)
    }

    /// Files and links only. A folder that gets here is a repository of its own (a staged
    /// gitlink, say), possibly with agents at work in it, and stays where it is.
    ///
    /// A file that cannot be trashed does not stop the rest. By now its index entry is gone and
    /// nothing is lost, so the discard carries on and the caller reports what stayed behind.
    private func trash(_ paths: [String], top: URL) -> Leftovers {
        var leftovers = Leftovers()
        for path in paths {
            let url = top.appending(path: path)
            // Asked about the item itself, so a link is trashed whether or not it leads anywhere.
            guard let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
                  type != .typeDirectory else { continue }
            do {
                try moveToTrash(url)
            } catch {
                leftovers.paths.append(path)
                // Network shares and some external volumes have no Trash at all.
                let cocoa = error as NSError
                let hasNoTrash = cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFeatureUnsupportedError
                if !hasNoTrash, leftovers.otherReason == nil { leftovers.otherReason = error.localizedDescription }
            }
        }
        return leftovers
    }

    /// The files a discard meant for the Trash that are still in their folder.
    private struct Leftovers {
        var paths: [String] = []
        /// Why, in the system's words, unless the volume simply has no Trash.
        var otherReason: String?

        /// `unstaged` when the files also left the index on the way, which the user should know:
        /// they now show up as untracked.
        func error(unstaged: Bool) -> GitError? {
            guard let first = paths.first else { return nil }
            let single = paths.count == 1
            let subject = single ? (first as NSString).lastPathComponent : "\(paths.count) files"
            let outcome = (single ? "was " : "were ") + (unstaged ? "unstaged and left in place" : "left in place")
            guard let otherReason else {
                return GitError(message: "\(subject) \(outcome) because this volume has no Trash.")
            }
            return GitError(message: "\(subject) \(outcome) because \(single ? "it" : "they") could not be moved to the Trash: \(otherReason)")
        }
    }

    public func diff(path: String, staged: Bool, in folder: URL) async throws -> String {
        let base = ["diff", "--no-color", "--no-ext-diff"]
        if staged {
            return try await run(base + ["--cached", "--"] + pathspecs([path]), in: folder)
        }
        let tracked = try await run(["ls-files", "--"] + pathspecs([path]), in: folder)
        if !tracked.isEmpty {
            return try await run(base + ["--"] + pathspecs([path]), in: folder)
        }
        // --no-index takes real file paths, not pathspecs, and exits 1 whenever the files differ.
        let top = try await topLevel(of: folder)
        if let link = untrackedLinkDiff(path, in: top) { return link }
        try refuseFolder(path, in: top)
        return try await run(base + ["--no-index", "--", "/dev/null", path], in: top, acceptedExitCodes: [0, 1])
    }

    /// The diff of an untracked symlink, written the way git shows a tracked one: a new file whose
    /// only line is where the link points. `diff --no-index` cannot be asked, because it follows
    /// the link. For one that leads to a folder it then fails with exit code 1, the code it also
    /// uses for "the files differ", and the link reads as having no changes.
    private func untrackedLinkDiff(_ path: String, in top: URL) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: top.appending(path: path).path) else { return nil }
        return """
            diff --git \(Self.quotedForDiffHeader("a/" + path)) \(Self.quotedForDiffHeader("b/" + path))
            new file mode 120000
            --- /dev/null
            +++ \(Self.quotedForDiffHeader("b/" + path))
            @@ -0,0 +1 @@
            +\(target)
            \\ No newline at end of file

            """
    }

    /// git puts a path in quotes when it holds something a diff header cannot carry as it is.
    private static func quotedForDiffHeader(_ path: String) -> String {
        guard path.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == "\"" || $0 == "\\" || $0.value == 0x7F }) else { return path }
        var quoted = "\""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\t": quoted += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                quoted += "\\" + String(scalar.value, radix: 8).leftPadded(to: 3)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }

    /// Status lists every untracked file on its own, so the one folder it can report is a repository
    /// nested in this one, which git will not look into. `diff --no-index` against a folder fails
    /// with exit code 1, the same code it uses for "the files differ", so this has to be caught
    /// before it runs or the folder reads as having no changes.
    private func refuseFolder(_ path: String, in top: URL) throws {
        let folder = top.appending(path: path)
        // lstat, so a symlink to a folder still diffs as the link it is.
        let type = try? FileManager.default.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType
        guard type == .typeDirectory else { return }
        let name = path.hasSuffix("/") ? String(path.dropLast()) : path
        let isRepository = FileManager.default.fileExists(atPath: folder.appending(path: ".git").path)
        throw GitError(message: isRepository
            ? "\(name) is a nested Git repository. Open it as its own project to see its changes."
            : "\(name) is a folder, not a file.")
    }

    /// The whole file as one hunk, for showing a full comparison, unless `contextLines` asks for less. Staged compares HEAD with the index,
    /// unstaged compares the index with the working tree, and an untracked file comes back as added.
    /// Returns nil when there is no difference.
    ///
    /// One git call yields both sides, so they always come from the same moment even while an agent
    /// keeps writing.
    ///
    /// `originalPath` is the old name of a staged rename, as status reports it. Passing it saves the
    /// rename detection over the whole index that is otherwise needed to find it.
    public func fileDiff(
        path: String,
        staged: Bool,
        contextLines: Int? = nil,
        originalPath: String? = nil,
        in folder: URL
    ) async throws -> GitFileDiff? {
        try await fileDiff(path: path, staged: staged, contextLines: contextLines, origin: originalPath.map { .known($0) } ?? .detect, in: folder)
    }

    /// For a change that came from `status(in:)`, which has already settled whether it is a rename,
    /// so no staged diff needs to detect that again. A copy has an origin too, but its source is
    /// a file of its own that must stay out of the pathspec.
    public func fileDiff(for change: GitFileChange, staged: Bool, contextLines: Int? = nil, in folder: URL) async throws -> GitFileDiff? {
        try await fileDiff(path: change.path, staged: staged, contextLines: contextLines, origin: .known(change.kind == .renamed ? change.originalPath : nil), in: folder)
    }

    private enum RenameOrigin {
        case detect
        case known(String?)
    }

    private func fileDiff(path: String, staged: Bool, contextLines: Int?, origin: RenameOrigin, in folder: URL) async throws -> GitFileDiff? {
        // Explicit prefixes and no textconv keep the output parseable whatever the user's diff config says.
        let base = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
                    "--unified=\(contextLines ?? Self.wholeFileContext)"]
        let output: String
        if staged {
            // A pathspec of just the new name would hide the rename, so its source has to be named too.
            let source: String?
            switch origin {
            case .known(let original):
                source = original
            case .detect:
                let renames = try await run(["diff", "--cached", "--name-status", "-z", "-M", "--diff-filter=R"], in: folder)
                source = GitParser.renameOrigin(of: path, in: renames)
            }
            output = try await run(base + ["--cached", "-M", "--"] + pathspecs([path] + [source].compactMap(\.self)), in: folder)
        } else if try await !run(["ls-files", "--"] + pathspecs([path]), in: folder).isEmpty {
            output = try await run(base + ["--"] + pathspecs([path]), in: folder)
        } else {
            let topURL = try await topLevel(of: folder)
            if let link = untrackedLinkDiff(path, in: topURL) {
                output = link
            } else {
                guard FileManager.default.fileExists(atPath: topURL.appending(path: path).path) else { return nil }
                try refuseFolder(path, in: topURL)
                output = try await run(base + ["--no-index", "--", "/dev/null", path], in: topURL, acceptedExitCodes: [0, 1])
            }
        }
        let diffs = GitParser.fileDiffs(output)
        // A staged rename is one diff. Asking by name guards against a second pathspec bringing its own along.
        return diffs.first { $0.newPath == path } ?? diffs.first
    }

    /// Large enough that any text file fits in a single hunk.
    private static let wholeFileContext = 100_000_000

    /// The size in bytes of the larger of the two versions `fileDiff` would compare, found without
    /// reading either. A whole-file diff holds both in full, so a viewer asks this first and turns
    /// down a file it could not show anyway, such as a log an agent keeps writing to.
    public func fileDiffSize(path: String, staged: Bool, in folder: URL) async throws -> Int64 {
        let top = try await topLevel(of: folder)
        // `:0:path` and `HEAD:path` name paths from the top of the repository. The stage is spelled
        // out because a bare `:2:notes.txt` is not a file of that name but stage 2 of `notes.txt`.
        func blobSize(_ object: String) async throws -> Int64 {
            // A path missing from the index or from HEAD is a new file there, not an error.
            let size = try await run(["cat-file", "-s", object], in: top, acceptedExitCodes: [0, 128])
            return Int64(size.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        let index = try await blobSize(":0:" + path)
        if staged { return max(index, try await blobSize("HEAD:" + path)) }
        // The working tree file itself, not what a symlink points to: a link diffs as its target path.
        let attributes = try? FileManager.default.attributesOfItem(atPath: top.appending(path: path).path)
        let working = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return max(index, working)
    }

    /// Status paths are relative to the repository root, so pin them there with `top`, and use `literal`
    /// so names containing `*`, `?` or `[` are not treated as globs.
    private func pathspecs(_ paths: [String]) -> [String] {
        paths.map { ":(top,literal)" + $0 }
    }

    @discardableResult
    func run(
        _ arguments: [String],
        in folder: URL,
        readOnly: Bool = true,
        acceptedExitCodes: Set<Int32> = [0],
        lane: GitProcess.Lane = .local
    ) async throws -> String {
        let result = try await GitProcess.run(arguments, in: folder, readOnly: readOnly, lane: lane)
        guard acceptedExitCodes.contains(result.status) else {
            throw GitError(command: "git \(arguments.first ?? "")", output: result)
        }
        return result.stdout
    }
}

extension GitError {
    /// git and gh explain themselves on stderr; the exit code is all that is left when they don't.
    init(command: String, output: GitProcess.Output) {
        let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(message: stderr.isEmpty ? "\(command) failed with exit code \(output.status)" : stderr)
    }

    /// `git worktree add` wraps its one useful line in progress output ("Preparing worktree…")
    /// and advice ("hint: …"), which is a lot of noise in a sheet. Keeps only the fatal/error lines,
    /// without their prefix.
    init(worktreeAddFailure output: GitProcess.Output) {
        let reasons = output.stderr.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            for prefix in ["fatal: ", "error: "] where line.hasPrefix(prefix) {
                let reason = line.dropFirst(prefix.count)
                return reason.prefix(1).uppercased() + reason.dropFirst()
            }
            return nil
        }
        if reasons.isEmpty {
            self.init(command: "git worktree", output: output)
        } else {
            self.init(message: reasons.joined(separator: "\n"))
        }
    }

    /// A refused switch lists the conflicting files on the lines after "error:", so unlike
    /// `worktree add` we keep plain lines and only drop the hints and the trailing "Aborting".
    init(switchFailure output: GitProcess.Output) {
        let lines = output.stderr.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            if line.hasPrefix("hint: ") || line == "hint:" || line == "Aborting" { return nil }
            for prefix in ["fatal: ", "error: "] where line.hasPrefix(prefix) {
                let reason = line.dropFirst(prefix.count)
                return reason.prefix(1).uppercased() + reason.dropFirst()
            }
            // git indents the file list with a tab, which a sheet draws far too wide.
            return line.hasPrefix("\t") ? "    " + line.drop { $0 == "\t" } : String(line)
        }
        if lines.isEmpty {
            self.init(command: "git switch", output: output)
        } else {
            self.init(message: lines.joined(separator: "\n"))
        }
    }
}

enum GitProcess {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static let gitExecutable = URL(filePath: "/usr/bin/git")

    /// Which queue a process waits in. Fetches and pushes can sit on a dead connection for many
    /// seconds; in a lane of their own they cannot use up the slots that status polls and the
    /// user's stage or commit need. Pull request lookups run one per worktree in the background,
    /// so they get their own lane too and a push never queues behind them.
    enum Lane: Sendable {
        case local, network, lookup

        fileprivate var limiter: ProcessLimiter {
            switch self {
            case .local: GitProcess.localLimiter
            case .network: GitProcess.networkLimiter
            case .lookup: GitProcess.lookupLimiter
            }
        }
    }

    private static let localLimiter = ProcessLimiter(limit: 8)
    private static let networkLimiter = ProcessLimiter(limit: 4)
    private static let lookupLimiter = ProcessLimiter(limit: 4)

    /// See `GitClient.resolveSearchPATH`.
    static let searchPATH = SearchPATH()

    /// See `GitClient.discardInto`. Nil means the system Trash.
    static let trashFolder = Mutex<URL?>(nil)

    static func moveToTrash(_ url: URL) throws {
        guard let folder = trashFolder.withLock({ $0 }) else {
            return try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        try move(url, into: folder)
    }

    static func move(_ url: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appending(path: url.lastPathComponent)
        // The Trash keeps both when a name is taken, and so must this: a second discard of a
        // file with the same name is not a reason to fail.
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appending(path: "\(UUID().uuidString) \(url.lastPathComponent)")
        }
        try FileManager.default.moveItem(at: url, to: destination)
    }

    /// `environment` is layered over the defaults below.
    static func run(
        _ arguments: [String],
        in folder: URL,
        readOnly: Bool,
        environment extra: [String: String] = [:],
        lane: Lane = .local,
        searchPATH: SearchPATH = GitProcess.searchPATH
    ) async throws -> Output {
        var environment = ["GIT_TERMINAL_PROMPT": "0"].merging(extra) { _, new in new }
        if readOnly {
            // Keeps status from taking index.lock to refresh the index, which would race an agent's own git commands.
            environment["GIT_OPTIONAL_LOCKS"] = "0"
        }
        if environment["PATH"] == nil {
            // A command that writes can run hooks and filters, which is what the PATH is for, so
            // it waits for a resolution that is under way. A read takes what is known and goes.
            let path: String?
            if readOnly { path = searchPATH.known } else { path = await searchPATH.value() }
            if let path { environment["PATH"] = path }
        }
        // Without core.quotepath=false, diff headers escape non-ASCII file names as octal.
        return try await run(gitExecutable, ["-c", "core.quotepath=false"] + arguments, in: folder, environment: environment, lane: lane)
    }

    /// Runs on a GCD thread so the blocking reads never tie up the caller or the cooperative pool.
    /// `environment` is layered over the app's own environment.
    ///
    /// Callers wait for a slot in their lane before a thread is taken. Every worktree polls on its
    /// own, so a burst of a few hundred calls is normal, and letting each one block a thread
    /// exhausts the GCD pool (64 threads), along with the process's file descriptors.
    ///
    /// Cancelling the calling task stops a process that talks to the network, and the call throws
    /// `CancellationError`. Local commands run to the end regardless: they are quick, half of them
    /// write to the repository, and the views that poll them are cancelled every time the app
    /// leaves the foreground, where a killed status or diff would only surface as an error.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        in folder: URL,
        environment: [String: String],
        lane: Lane = .local
    ) async throws -> Output {
        let limiter = lane.limiter
        await limiter.acquire()
        let child = Child()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try runBlocking(executable, arguments, in: folder, environment: environment, child: child) }
                    // Before resuming, so the slot is never held by a call whose caller is already running again.
                    limiter.release()
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            if lane != .local { child.cancel() }
        }
    }

    private static func runBlocking(
        _ executable: URL,
        _ arguments: [String],
        in folder: URL,
        environment overrides: [String: String],
        child: Child
    ) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        // Cancelled while it waited for its slot: no point in starting at all.
        guard !child.isCancelled else { throw CancellationError() }
        do {
            try process.run()
        } catch {
            throw GitError(message: error.localizedDescription)
        }
        child.started(process)

        let (outputData, errorData) = collect(stdout.fileHandleForReading, stderr.fileHandleForReading, of: process)
        process.waitUntilExit()
        if child.finished() { throw CancellationError() }

        return Output(
            status: process.terminationStatus,
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorData, as: UTF8.self)
        )
    }

    /// Reads both pipes until they close, or until the process is gone and they have fallen silent.
    ///
    /// Both in one `poll` loop: if the child fills one pipe while we block reading the other, both
    /// sides hang. And not simply to end of file, because that only comes once every process
    /// holding the pipe has exited. An ssh ControlPersist master or a credential helper daemon
    /// started by git inherits it and lives on for minutes after git itself is done.
    private static func collect(_ stdout: FileHandle, _ stderr: FileHandle, of process: Process) -> (stdout: Data, stderr: Data) {
        var descriptors = [stdout, stderr].map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        var collected = [Data(), Data()]
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        // Set once the process is seen to have exited. Whatever it wrote is in the pipes by then,
        // so the deadline only bounds how long a straggler that keeps writing can hold us up.
        //
        // Not a continuous clock: that one keeps counting while the Mac sleeps, and waking up
        // would look like a second of silence.
        var deadline: SuspendingClock.Instant?
        let clock = SuspendingClock()

        while descriptors.contains(where: { $0.fd >= 0 }) {
            if deadline == nil, !process.isRunning { deadline = clock.now + .seconds(1) }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 50)
            if ready < 0, errno != EINTR { break }
            if deadline != nil, ready == 0 { break }
            guard ready > 0 else { continue }
            // Decided before reading but acted on after it. A deadline that passed while we were
            // stalled says nothing about the pipes, which can still hold the end of git's own
            // output; one read takes all of it, a pipe never buffering more than `scratch` holds.
            let isOverdue = deadline.map { clock.now >= $0 } ?? false

            for index in descriptors.indices where descriptors[index].revents != 0 {
                let count = scratch.withUnsafeMutableBytes { read(descriptors[index].fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    collected[index].append(contentsOf: scratch[..<count])
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    // poll skips negative descriptors, which is how a closed pipe leaves the set.
                    descriptors[index].fd = -1
                }
            }
            if isOverdue { break }
        }
        return (collected[0], collected[1])
    }

    /// Lets the cancellation handler, which runs on whatever thread cancels the task, reach the
    /// process that a GCD thread is running.
    private final class Child: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var terminated = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func started(_ process: Process) {
            lock.withLock {
                self.process = process
                // The cancellation came between the check and the launch.
                if cancelled { terminate(process) }
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if let process { terminate(process) }
            }
        }

        private func terminate(_ process: Process) {
            guard process.isRunning else { return }
            process.terminate()
            terminated = true
        }

        /// True when the process was told to stop while it ran. Its output is then cut short and
        /// not worth returning. A cancellation that only arrives once git has exited changes
        /// nothing about what git did, and reporting it would turn a finished push into an error.
        func finished() -> Bool {
            lock.withLock {
                process = nil
                return terminated
            }
        }
    }
}

/// The PATH for git and what it starts, which arrives some time after launch.
final class SearchPATH: Sendable {
    private enum State {
        case inherited
        case resolving(Task<String, Never>)
        case known(String)
    }

    private let state = Mutex(State.inherited)

    func resolve(_ resolve: @escaping @Sendable () async -> String) {
        let task = Task.detached { await resolve() }
        state.withLock { $0 = .resolving(task) }
        Task.detached { [self] in
            let path = await task.value
            state.withLock { state in
                // Unless a later call has replaced this resolution in the meantime.
                if case .resolving(let current) = state, current == task { state = .known(path) }
            }
        }
    }

    /// Nil until the resolution has finished, and when it came back empty.
    var known: String? {
        guard case .known(let path) = state.withLock({ $0 }), !path.isEmpty else { return nil }
        return path
    }

    /// Like `known`, but waits for a resolution that is still running.
    func value() async -> String? {
        let path: String
        switch state.withLock({ $0 }) {
        case .inherited: return nil
        case .known(let known): path = known
        case .resolving(let task): path = await task.value
        }
        return path.isEmpty ? nil : path
    }
}

/// A counting semaphore whose waiters suspend instead of blocking a thread. First come, first served.
final class ProcessLimiter: Sendable {
    private struct State {
        var available: Int
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    init(limit: Int) {
        state = Mutex(State(available: limit))
    }

    func acquire() async {
        await withCheckedContinuation { continuation in
            let acquired = state.withLock { state in
                guard state.available > 0 else {
                    state.waiters.append(continuation)
                    return false
                }
                state.available -= 1
                return true
            }
            if acquired { continuation.resume() }
        }
    }

    /// Hands the slot straight to the longest waiter, so it never shows as free in between.
    func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.available += 1
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}
