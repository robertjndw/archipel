import AgentKit
import Foundation

/// Apps launched from Finder or the Dock get launchd's bare PATH, so agents
/// installed through Homebrew, npm or mise would not be found. We ask the
/// user's shell once and reuse the answer for every session.
enum LoginEnvironment {
    nonisolated static func resolvePATH() async -> String {
        let shell = ShellAdapter.loginShellPath
        // Interactive first: zsh reads ~/.zshrc only then, and that is where nvm, mise, fnm, volta and
        // ~/.local/bin usually end up. An rc file written for a terminal can hang or bail out without
        // one, so the plain login shell is still asked when the interactive one gives no answer.
        let resolved = path(from: shell, flags: ["-l", "-i"])
            ?? path(from: shell, flags: ["-l"])
            ?? ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return addingCommonDirectories(to: resolved)
    }

    /// A variable from the user's login shell, for settings that live in rc files and so never
    /// reach an app started by launchd. Nil when it is unset or empty.
    nonisolated static func resolveVariable(_ name: String) async -> String? {
        let shell = ShellAdapter.loginShellPath
        // Retry without -i only when the shell gave no answer. An unset variable is a real answer.
        let answer = value(of: name, from: shell, flags: ["-l", "-i"]) ?? value(of: name, from: shell, flags: ["-l"])
        guard let answer, !answer.isEmpty else { return nil }
        return answer
    }

    /// Nil when the shell could not be run, was stopped by the watchdog or printed no PATH.
    private nonisolated static func path(from shell: String, flags: [String]) -> String? {
        guard let path = value(of: "PATH", from: shell, flags: flags), !path.isEmpty else { return nil }
        return path
    }

    /// Nil when the shell gave no answer at all; an empty string means it answered with an empty value.
    private nonisolated static func value(of name: String, from shell: String, flags: [String]) -> String? {
        precondition(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }, "not a variable name")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Markers because shell startup files are free to print anything.
        // Quoted "$PATH" also works in fish, which joins path variables with colons.
        process.arguments = flags + ["-c", #"printf '<<archipel:%s>>' "$\#(name)""#]
        // A file, not a pipe: a profile that starts something in the background (`foo &`) hands it
        // our stdout, and reading a pipe to EOF would then wait for that process, not the shell.
        let outputFile = FileManager.default.temporaryDirectory.appending(path: "archipel-path-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputFile.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputFile)
        else { return nil }
        defer { try? FileManager.default.removeItem(at: outputFile) }
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
        let data = (try? Data(contentsOf: outputFile)) ?? Data()

        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<<archipel:"),
              let end = text.range(of: ">>", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
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
