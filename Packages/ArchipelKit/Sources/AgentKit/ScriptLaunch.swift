import Foundation

/// Where a session runs, exported to every process the app launches in a worktree so agents and
/// project scripts can find the main checkout (for example to copy an untracked `.env` from it).
public struct WorktreeEnvironment: Equatable, Sendable {
    public var worktreePath: URL
    /// The project's main checkout.
    public var rootPath: URL
    /// nil for a detached HEAD or a folder that is not a repository; the variable is then left unset.
    public var branch: String?

    public init(worktreePath: URL, rootPath: URL, branch: String?) {
        self.worktreePath = worktreePath
        self.rootPath = rootPath
        self.branch = branch
    }

    public var variables: [String: String] {
        var variables = [
            "ARCHIPEL_WORKTREE_PATH": Self.plainPath(worktreePath),
            "ARCHIPEL_ROOT_PATH": Self.plainPath(rootPath),
        ]
        if let branch, !branch.isEmpty { variables["ARCHIPEL_BRANCH"] = branch }
        return variables
    }

    /// Scripts join these with relative paths ("$ARCHIPEL_ROOT_PATH/.env"), so a trailing slash from a
    /// directory URL would turn into a double slash, and percent escapes would name a different folder.
    private static func plainPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

extension LaunchCommand {
    /// The command with the worktree variables added. Variables the command sets itself win.
    public func adding(_ worktree: WorktreeEnvironment) -> LaunchCommand {
        var command = self
        command.environment.merge(worktree.variables) { own, _ in own }
        return command
    }
}

public enum ScriptLaunch {
    /// Scripts are written in POSIX/zsh syntax, so they never run through `$SHELL`, which may be fish.
    public static let shell = "/bin/zsh"

    /// The script is the process itself, not text typed into an interactive shell: input sent before a
    /// shell is ready is unreliable, and the exit status of the script becomes the session's.
    ///
    /// No `-l`: the app already passes the login shell's PATH, and a zsh login shell would run
    /// path_helper and ~/.zprofile, which reorder or replace that PATH (and are stale or missing for
    /// someone whose login shell is fish).
    public static func command(script: String, context: LaunchContext, worktree: WorktreeEnvironment) -> LaunchCommand {
        LaunchCommand(executable: shell, arguments: ["-c", script], environment: hookEnvironment(context))
            .adding(worktree)
    }
}
