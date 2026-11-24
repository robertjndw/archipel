import AgentKit
import Foundation

/// Apps launched from Finder or the Dock get launchd's bare environment, so agents
/// installed through Homebrew, npm or mise would not be found, and nothing a shell
/// profile exports would reach them. We ask the user's shell once and reuse the
/// answer for every session and for the app's own lookups.
enum LoginEnvironment {
    /// Everything the login shell exports, or nil when it gave no answer. Sessions are started
    /// with it and the app reads its own copies of `CLAUDE_CONFIG_DIR`, `XDG_CONFIG_HOME` and
    /// `CODEX_HOME` from it, so both sides look in the same places.
    nonisolated static let exported: Task<[String: String]?, Never> = Task.detached {
        let shell = ShellAdapter.loginShellPath
        // Interactive first: zsh reads ~/.zshrc only then, and that is where nvm, mise, fnm, volta and
        // ~/.local/bin usually end up. An rc file written for a terminal can hang or bail out without
        // one, so the plain login shell is still asked when the interactive one gives no answer.
        return exports(from: shell, flags: ["-l", "-i"]) ?? exports(from: shell, flags: ["-l"])
    }

    nonisolated static func resolvePATH() async -> String {
        let resolved = await resolveVariable("PATH")
            ?? ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return addingCommonDirectories(to: resolved)
    }

    /// A variable from the user's login shell, for settings that live in rc files and so never
    /// reach an app started by launchd. Nil when it is unset or empty.
    nonisolated static func resolveVariable(_ name: String) async -> String? {
        guard let answer = await exported.value?[name], !answer.isEmpty else { return nil }
        return answer
    }

    private nonisolated static let startMarker = Data("<<archipel:env>>".utf8)
    private nonisolated static let endMarker = Data("<<archipel:end>>".utf8)

    /// Nil when the shell could not be run, was stopped by the watchdog or printed no PATH. An
    /// environment without one is a shell that did not get through its startup files.
    private nonisolated static func exports(from shell: String, flags: [String]) -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Markers because shell startup files are free to print anything. `env` and not the
        // shell's own listing, so the answer has the same form in zsh, bash and fish, and NUL
        // between the entries because values can span lines.
        process.arguments = flags + ["-c", "printf '<<archipel:env>>'; /usr/bin/env -0; printf '<<archipel:end>>'"]
        // A file, not a pipe: a profile that starts something in the background (`foo &`) hands it
        // our stdout, and reading a pipe to EOF would then wait for that process, not the shell.
        // It holds every secret the profile exports, so it is private and already without a name.
        guard let (output, capture) = LoginShellEnvironment.makeCaptureFile(in: FileManager.default.temporaryDirectory)
        else { return nil }
        defer { try? capture.close() }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? output.close()
            return nil
        }

        // A broken shell profile must not keep the app from starting sessions.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, process.isRunning else { return }
            process.terminate()
            // SIGTERM is not enough for an interactive shell: it ignores it, and one that was stopped
            // for touching a terminal it does not own (Archipel run from a shell) never even sees it.
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        watchdog.cancel()
        try? output.close()
        let data = (try? capture.readToEnd()) ?? Data()

        // The last end marker, in case a value happens to contain one.
        guard let start = data.range(of: startMarker),
              let end = data.range(of: endMarker, options: .backwards, in: start.upperBound..<data.endIndex)
        else { return nil }
        let environment = LoginShellEnvironment.parse(data.subdata(in: start.upperBound..<end.lowerBound))
        guard let path = environment["PATH"], !path.isEmpty else { return nil }
        return environment
    }

    /// Where agents usually get installed. Appended, so they never shadow what the user's own PATH
    /// finds, but a common install is still found when the shell could not be asked.
    nonisolated static func addingCommonDirectories(to path: String) -> String {
        let present = Set(path.split(separator: ":"))
        let common = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        return ([path] + common.filter { !present.contains(Substring($0)) }).joined(separator: ":")
    }

    nonisolated static func locate(_ executable: String, inPATH path: String) -> String? {
        if executable.contains("/") {
            return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
        }
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(executable)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
