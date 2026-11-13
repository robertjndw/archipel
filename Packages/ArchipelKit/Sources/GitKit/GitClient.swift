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

    public func addWorktree(repository: URL, path: URL, branch: String, createBranch: Bool) async throws {
        let args = createBranch
            ? ["worktree", "add", "-b", branch, "--", path.path]
            : ["worktree", "add", "--", path.path, branch]
        try await run(args, in: repository, readOnly: false)
    }

    public func removeWorktree(repository: URL, path: URL) async throws {
        try await run(["worktree", "remove", "--", path.path], in: repository, readOnly: false)
    }

    public func status(in folder: URL) async throws -> GitStatus {
        GitParser.status(try await run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: folder))
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

    /// Status paths are relative to the repository root, so pin them there with `top`, and use `literal`
    /// so names containing `*`, `?` or `[` are not treated as globs.
    private func pathspecs(_ paths: [String]) -> [String] {
        paths.map { ":(top,literal)" + $0 }
    }

    @discardableResult
    private func run(_ arguments: [String], in folder: URL, readOnly: Bool = true, acceptedExitCodes: Set<Int32> = [0]) async throws -> String {
        let result = try await GitProcess.run(arguments, in: folder, readOnly: readOnly)
        guard acceptedExitCodes.contains(result.status) else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: stderr.isEmpty ? "git \(arguments.first ?? "") failed with exit code \(result.status)" : stderr)
        }
        return result.stdout
    }
}

enum GitProcess {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs on a GCD thread so the blocking reads never tie up the caller or the cooperative pool.
    static func run(_ arguments: [String], in folder: URL, readOnly: Bool) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runBlocking(arguments, in: folder, readOnly: readOnly) })
            }
        }
    }

    private static func runBlocking(_ arguments: [String], in folder: URL, readOnly: Bool) throws -> Output {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        // Without this, diff headers escape non-ASCII file names as octal.
        process.arguments = ["-c", "core.quotepath=false"] + arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if readOnly {
            // Keeps status from taking index.lock to refresh the index, which would race an agent's own git commands.
            environment["GIT_OPTIONAL_LOCKS"] = "0"
        }
        process.environment = environment

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

        // Drain stderr concurrently: if git fills one pipe while we block reading the other, both sides hang.
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
