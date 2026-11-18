import AppKit

/// A code editor Archipel can hand a worktree or file to.
struct ExternalEditor: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let url: URL

    var id: String { bundleID }

    /// In the order "automatic" tries them: editors people open a whole repository in come first,
    /// Xcode last because it is the usual fallback that is installed anyway.
    static let known: [(bundleID: String, name: String)] = [
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.microsoft.VSCode", "Visual Studio Code"),
        ("com.microsoft.VSCodeInsiders", "Visual Studio Code Insiders"),
        ("com.exafunction.windsurf", "Windsurf"),
        ("dev.zed.Zed", "Zed"),
        ("dev.zed.Zed-Preview", "Zed Preview"),
        ("com.sublimetext.4", "Sublime Text"),
        ("com.panic.Nova", "Nova"),
        ("com.jetbrains.intellij", "IntelliJ IDEA"),
        ("com.jetbrains.intellij.ce", "IntelliJ IDEA CE"),
        ("com.jetbrains.WebStorm", "WebStorm"),
        ("com.jetbrains.pycharm", "PyCharm"),
        ("com.jetbrains.goland", "GoLand"),
        ("com.barebones.bbedit", "BBEdit"),
        ("com.apple.dt.Xcode", "Xcode"),
    ]

    /// The known editors that are installed. One LaunchServices lookup per known editor, so views
    /// read `AppModel.installedEditors`, which is refreshed whenever the app comes forward.
    static func installed() -> [ExternalEditor] {
        known.compactMap { entry in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID)
                .map { ExternalEditor(bundleID: entry.bundleID, name: entry.name, url: $0) }
        }
    }
}

extension AppModel {
    /// The editor the user picked if it is still installed, otherwise the first installed one.
    var preferredEditor: ExternalEditor? {
        let installed = installedEditors
        if let id = settings.externalEditorBundleID, let chosen = installed.first(where: { $0.bundleID == id }) {
            return chosen
        }
        return installed.first
    }

    /// Opens a worktree folder or a single file in the preferred editor.
    func openInEditor(_ url: URL) {
        guard let editor = preferredEditor else { return }
        NSWorkspace.shared.open([url], withApplicationAt: editor.url, configuration: NSWorkspace.OpenConfiguration())
    }
}
