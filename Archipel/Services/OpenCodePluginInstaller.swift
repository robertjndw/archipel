import Foundation

/// Puts the OpenCode plugin where OpenCode can load it from.
///
/// OpenCode only loads a TUI plugin from a directory holding `tui.js`, and the bundled copy lives
/// inside the app, whose path changes with every update. A copy in the support directory also
/// keeps the path stable for the sessions that are still running.
nonisolated enum OpenCodePluginInstaller {
    static func directory(in supportDirectory: URL) -> URL {
        supportDirectory.appending(path: "opencode-plugin", directoryHint: .isDirectory)
    }

    /// The plugin directory, or nil when the plugin could not be put in place; OpenCode then runs
    /// without it.
    static func install(in supportDirectory: URL, bundle: Bundle = .main) -> URL? {
        guard let source = bundle.url(forResource: "archipel-opencode-tui", withExtension: "js"),
              let contents = try? Data(contentsOf: source)
        else { return nil }
        let directory = directory(in: supportDirectory)
        let destination = directory.appending(path: "tui.js")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // A running OpenCode may be reading the file, so only touch it when something changed.
            if (try? Data(contentsOf: destination)) != contents {
                try contents.write(to: destination, options: .atomic)
            }
            return directory
        } catch {
            return nil
        }
    }
}
