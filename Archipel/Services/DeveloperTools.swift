import Foundation

/// Whether the tools behind `/usr/bin/git` are there.
enum DeveloperTools {
    /// `/usr/bin/git` exists on every Mac, but without Xcode or the Command Line Tools it is a shim
    /// that puts up the system's "install developer tools" dialog each time it runs. Status polling
    /// would bring that dialog back every few seconds, so this is asked before git is ever started.
    /// `xcode-select -p` answers from the same setting the shim reads and never shows the dialog.
    nonisolated static func isGitInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // Not being able to ask is no reason to switch git off.
            return true
        }
        // A path and nothing else, far below what a pipe buffers, so reading after the exit cannot block.
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let path = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The selected folder can be gone, for example after Xcode was moved to the Trash.
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }
}
