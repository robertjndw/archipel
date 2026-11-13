import Foundation

/// Apps launched from Finder or the Dock get launchd's bare PATH, so agents
/// installed through Homebrew, npm or mise would not be found. We ask the
/// user's login shell once and reuse the answer for every session.
enum LoginEnvironment {
    nonisolated static func resolvePATH() async -> String {
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Markers because shell startup files are free to print anything.
        // Quoted "$PATH" also works in fish, which joins path variables with colons.
        process.arguments = ["-l", "-c", #"printf '<<archipel:%s>>' "$PATH""#]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return fallback
        }

        // A broken shell profile must not keep the app from starting sessions.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            if process.isRunning { process.terminate() }
        }
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        watchdog.cancel()

        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<<archipel:"),
              let end = text.range(of: ">>", range: start.upperBound..<text.endIndex)
        else { return fallback }
        let path = String(text[start.upperBound..<end.lowerBound])
        return path.isEmpty ? fallback : path
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
