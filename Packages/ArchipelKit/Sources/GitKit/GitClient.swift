import Foundation

public struct GitClient: Sendable {
    public init() {}

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

    public func worktrees(of repository: URL) async throws -> [GitWorktreeEntry] {
        GitParser.worktrees(try await run(["worktree", "list", "--porcelain", "-z"], in: repository))
    }

    public func localBranches(in repository: URL) async throws -> [String] {
        try await run(["for-each-ref", "--format=%(refname:short)", "refs/heads/"], in: repository)
            .split(separator: "\n")
            .map(String.init)
    }

    /// `base` is the ref a new branch starts from; nil means HEAD. It is ignored for an existing branch.
    public func addWorktree(repository: URL, path: URL, branch: String, createBranch: Bool, base: String? = nil) async throws {
        let args = createBranch
            ? ["worktree", "add", "-b", branch, "--", path.path] + (base.map { [$0] } ?? [])
            : ["worktree", "add", "--", path.path, branch]
        let result = try await GitProcess.run(args, in: repository, readOnly: false)
        guard result.status != 0 else { return }
        throw GitError(worktreeAddFailure: result)
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

    /// Safe delete with `-d`: a branch not merged into HEAD (or its upstream) is kept, not thrown away.
    public func deleteBranch(_ branch: String, in repository: URL) async throws -> GitBranchDeletion {
        // C locale so the message below is not translated.
        let result = try await GitProcess.run(["branch", "-d", branch], in: repository, readOnly: false, environment: ["LC_ALL": "C"])
        if result.status == 0 { return .deleted }
        // git has no dedicated exit code for this, so the message is the only way to tell it apart
        // from a missing branch or one checked out elsewhere.
        if result.stderr.contains("not fully merged") { return .keptUnmerged }
        throw GitError(command: "git branch", output: result)
    }

    public func status(in folder: URL) async throws -> GitStatus {
        GitParser.status(try await run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: folder))
    }

    /// Skips `--untracked-files=all` so a huge untracked directory counts once and the call stays fast
    /// enough to poll for every worktree.
    public func summary(in folder: URL) async throws -> GitSummary {
        GitParser.summary(try await run(["status", "--porcelain=v2", "-z", "--branch"], in: folder))
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

    /// Plain `git push` when the branch tracks something, otherwise publishes it to `origin` and sets the
    /// upstream. Nothing here can prompt: stdin is /dev/null, `GIT_TERMINAL_PROMPT=0` is set, and the
    /// app has no controlling terminal for ssh or credential helpers to open.
    public func push(in folder: URL) async throws {
        let summary = try await summary(in: folder)
        guard summary.branch != nil else {
            throw GitError(message: "HEAD is detached. Check out a branch before pushing.")
        }
        if summary.upstream != nil {
            try await run(["push"], in: folder, readOnly: false)
            return
        }
        let remotes = try await run(["remote"], in: folder).split(whereSeparator: \.isNewline)
        guard remotes.contains("origin") else {
            throw GitError(message: "This branch has no upstream and the repository has no remote named origin.")
        }
        try await run(["push", "-u", "origin", "HEAD"], in: folder, readOnly: false)
    }

    /// Updates the remote-tracking refs so ahead/behind counts are current. Meant to run unattended:
    /// ssh gets BatchMode so an unknown host key or a locked key fails at once instead of waiting
    /// for a prompt nobody can answer. A GIT_SSH_COMMAND the user set is left alone.
    public func fetch(in folder: URL) async throws {
        var environment: [String: String] = [:]
        if ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] == nil {
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        }
        let result = try await GitProcess.run(["fetch", "--quiet", "--prune"], in: folder, readOnly: false, environment: environment)
        guard result.status == 0 else { throw GitError(command: "git fetch", output: result) }
    }

    /// Fetches, then fast-forwards the branch to its upstream. Never merges or rebases. A diverged
    /// branch is refused with an explanation, since sorting that out needs someone in a terminal.
    public func pull(in folder: URL) async throws {
        let before = try await summary(in: folder)
        guard before.branch != nil else {
            throw GitError(message: "HEAD is detached. Check out a branch before pulling.")
        }
        guard let upstream = before.upstream else {
            throw GitError(message: "This branch has no upstream to pull from.")
        }
        try await fetch(in: folder)
        let after = try await summary(in: folder)
        guard after.behind > 0 else { return }
        guard after.ahead == 0 else {
            throw GitError(message: "This branch and \(upstream) have diverged (\(after.ahead) ahead, \(after.behind) behind), so it cannot be fast-forwarded. Rebase or merge in a terminal.")
        }
        try await run(["merge", "--ff-only", "@{upstream}"], in: folder, readOnly: false)
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
        guard !paths.isEmpty else { return }
        try await run(["add", "-A", "--"] + pathspecs(paths), in: folder, readOnly: false)
    }

    /// `git reset` rather than `git restore --staged` because reset also works on an unborn branch.
    public func unstage(_ paths: [String], in folder: URL) async throws {
        guard !paths.isEmpty else { return }
        try await run(["reset", "-q", "--"] + pathspecs(paths), in: folder, readOnly: false)
    }

    public func stageAll(in folder: URL) async throws {
        try await run(["add", "-A"], in: folder, readOnly: false)
    }

    public func unstageAll(in folder: URL) async throws {
        try await run(["reset", "-q"], in: folder, readOnly: false)
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
        let top = try await run(["rev-parse", "--show-toplevel"], in: folder)
            .trimmingCharacters(in: .newlines)
        return try await run(base + ["--no-index", "--", "/dev/null", path], in: URL(filePath: top), acceptedExitCodes: [0, 1])
    }

    /// The whole file as one hunk, for showing a full comparison, unless `contextLines` asks for less. Staged compares HEAD with the index,
    /// unstaged compares the index with the working tree, and an untracked file comes back as added.
    /// Returns nil when there is no difference.
    ///
    /// One git call yields both sides, so they always come from the same moment even while an agent
    /// keeps writing.
    public func fileDiff(path: String, staged: Bool, contextLines: Int? = nil, in folder: URL) async throws -> GitFileDiff? {
        // Explicit prefixes and no textconv keep the output parseable whatever the user's diff config says.
        let base = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
                    "--unified=\(contextLines ?? Self.wholeFileContext)"]
        let output: String
        if staged {
            // A pathspec of just the new name would hide the rename, so look for its source first.
            let renames = try await run(["diff", "--cached", "--name-status", "-z", "-M", "--diff-filter=R"], in: folder)
            let origin = GitParser.renameOrigin(of: path, in: renames)
            output = try await run(base + ["--cached", "-M", "--"] + pathspecs([path] + [origin].compactMap(\.self)), in: folder)
        } else if try await !run(["ls-files", "--"] + pathspecs([path]), in: folder).isEmpty {
            output = try await run(base + ["--"] + pathspecs([path]), in: folder)
        } else {
            let top = try await run(["rev-parse", "--show-toplevel"], in: folder).trimmingCharacters(in: .newlines)
            let topURL = URL(filePath: top, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: topURL.appending(path: path).path) else { return nil }
            output = try await run(base + ["--no-index", "--", "/dev/null", path], in: topURL, acceptedExitCodes: [0, 1])
        }
        return GitParser.fileDiffs(output).first
    }

    /// Large enough that any text file fits in a single hunk.
    private static let wholeFileContext = 100_000_000

    /// Status paths are relative to the repository root, so pin them there with `top`, and use `literal`
    /// so names containing `*`, `?` or `[` are not treated as globs.
    private func pathspecs(_ paths: [String]) -> [String] {
        paths.map { ":(top,literal)" + $0 }
    }

    @discardableResult
    func run(_ arguments: [String], in folder: URL, readOnly: Bool = true, acceptedExitCodes: Set<Int32> = [0]) async throws -> String {
        let result = try await GitProcess.run(arguments, in: folder, readOnly: readOnly)
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
}

enum GitProcess {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static let gitExecutable = URL(filePath: "/usr/bin/git")

    /// `environment` is layered over the defaults below.
    static func run(_ arguments: [String], in folder: URL, readOnly: Bool, environment extra: [String: String] = [:]) async throws -> Output {
        var environment = ["GIT_TERMINAL_PROMPT": "0"].merging(extra) { _, new in new }
        if readOnly {
            // Keeps status from taking index.lock to refresh the index, which would race an agent's own git commands.
            environment["GIT_OPTIONAL_LOCKS"] = "0"
        }
        // Without core.quotepath=false, diff headers escape non-ASCII file names as octal.
        return try await run(gitExecutable, ["-c", "core.quotepath=false"] + arguments, in: folder, environment: environment)
    }

    /// Runs on a GCD thread so the blocking reads never tie up the caller or the cooperative pool.
    /// `environment` is layered over the app's own environment.
    static func run(_ executable: URL, _ arguments: [String], in folder: URL, environment: [String: String]) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(executable, arguments, in: folder, environment: environment) })
            }
        }
    }

    private static func runBlocking(_ executable: URL, _ arguments: [String], in folder: URL, environment overrides: [String: String]) throws -> Output {
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

        do {
            try process.run()
        } catch {
            throw GitError(message: error.localizedDescription)
        }

        // Drain stderr concurrently: if the child fills one pipe while we block reading the other, both sides hang.
        let errorData = DataBox()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            errorData.value = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return Output(
            status: process.terminationStatus,
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorData.value, as: UTF8.self)
        )
    }

    private final class DataBox: @unchecked Sendable {
        var value = Data()
    }
}
