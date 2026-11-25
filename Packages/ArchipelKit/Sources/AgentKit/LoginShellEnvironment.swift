import Foundation

/// What the user's login shell exports, as `env -0` prints it, and the part of it a launched
/// session should get. An app started from the Dock has none of what the shell profile sets, so
/// without this an agent in Archipel would miss its `CLAUDE_CONFIG_DIR`, API key or proxy.
public enum LoginShellEnvironment {
    /// Entries are separated by NUL because values may contain newlines.
    public static func parse(_ data: Data) -> [String: String] {
        var environment: [String: String] = [:]
        for entry in data.split(separator: 0) {
            guard let separator = entry.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let name = String(decoding: entry[..<separator], as: UTF8.self)
            guard isVariableName(name) else { continue }
            environment[name] = String(decoding: entry[entry.index(after: separator)...], as: UTF8.self)
        }
        return environment
    }

    /// Describes the terminal or the one shell that was asked, or is set per process by launchd.
    /// The session's own terminal and shell decide these.
    private static let perProcess: Set<String> = [
        "PWD", "OLDPWD", "SHLVL", "_", "TERM", "TERMINFO", "TERMINFO_DIRS", "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "COLORTERM", "COLUMNS", "LINES", "WINDOWID",
        "TMUX", "TMUX_PANE", "STY", "COMMAND_MODE", "SECURITYSESSIONID", "LaunchInstanceID",
        // The shell that was asked has no terminal, so a profile's `export GPG_TTY=$(tty)` comes
        // out as "not a tty", and a session that kept it could not be asked for a passphrase.
        "GPG_TTY", "TTY", "SSH_TTY",
    ]
    /// `ARCHIPEL_` and `GHOSTTY_` are set for each session by the app and the terminal. The shell
    /// only has them when Archipel itself was started from a terminal, with that terminal's values.
    private static let perProcessPrefixes = ["ARCHIPEL_", "GHOSTTY_", "XPC_", "DYLD_", "__"]

    /// The variables to start a session with. What the app sets for the session itself goes on top.
    public static func sessionVariables(from environment: [String: String]) -> [String: String] {
        environment.filter { name, _ in
            isVariableName(name) && !perProcess.contains(name) && !perProcessPrefixes.contains(where: name.hasPrefix)
        }
    }

    /// A file for the shell to print its environment into, as one handle to write it and one
    /// to read it back. Everything the profile exports ends up in it, keys and tokens included,
    /// so it is the user's alone from the moment it exists, and its name is gone again before
    /// anything is written: no way out of the caller, a crash included, leaves it on disk. Nil
    /// when it cannot be created.
    public static func makeCaptureFile(in directory: URL) -> (writing: FileHandle, reading: FileHandle)? {
        let path = directory.appending(path: "archipel-env-\(UUID().uuidString)").path
        // O_EXCL so a file or link someone put at that name is never written through.
        let writer = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard writer >= 0 else { return nil }
        let reader = open(path, O_RDONLY | O_CLOEXEC)
        unlink(path)
        guard reader >= 0 else {
            close(writer)
            return nil
        }
        return (FileHandle(fileDescriptor: writer, closeOnDealloc: true), FileHandle(fileDescriptor: reader, closeOnDealloc: true))
    }

    /// Leaves out what is not a variable, such as the functions bash exports as `BASH_FUNC_name%%`.
    private static func isVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || isLetter(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || isLetter($0) || ("0"..."9").contains($0) }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
}
