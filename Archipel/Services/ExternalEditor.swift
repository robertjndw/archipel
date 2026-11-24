import AppKit
import UniformTypeIdentifiers

/// A code editor Archipel can hand a worktree or file to.
struct ExternalEditor: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let url: URL

    var id: String { bundleID }

    /// False for an application the user picked with Other… in Settings.
    var isKnown: Bool { Self.known.contains { $0.bundleID == bundleID } }

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

    /// The known editors that are installed, then `custom` when it is an application picked from
    /// outside the list. One LaunchServices lookup per editor, so views read
    /// `AppModel.installedEditors`, which is refreshed whenever the app comes forward.
    static func installed(including custom: String? = nil) -> [ExternalEditor] {
        var editors = known.compactMap { entry in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID)
                .map { ExternalEditor(bundleID: entry.bundleID, name: entry.name, url: $0) }
        }
        if let custom, !editors.contains(where: { $0.bundleID == custom }),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: custom) {
            editors.append(ExternalEditor(bundleID: custom, name: displayName(of: url), url: url))
        }
        return editors
    }

    /// What to call a bundle id that is no longer installed.
    static func name(forBundleID bundleID: String) -> String {
        known.first { $0.bundleID == bundleID }?.name ?? bundleID
    }

    private static func displayName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

extension AppModel {
    /// The editor the user picked if it is still installed, otherwise the first known one that is.
    /// An application picked with Other… is never what "automatic" lands on.
    var preferredEditor: ExternalEditor? {
        let installed = installedEditors
        if let id = settings.externalEditorBundleID, let chosen = installed.first(where: { $0.bundleID == id }) {
            return chosen
        }
        return installed.first(where: \.isKnown)
    }

    /// Opens a worktree folder or a single file in the preferred editor.
    func openInEditor(_ url: URL) {
        guard let editor = preferredEditor else { return }
        NSWorkspace.shared.open([url], withApplicationAt: editor.url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.problem = "\(editor.name) could not open \(url.lastPathComponent). \(error.localizedDescription)"
            }
        }
    }

    /// Lets the user pick any application as the editor. `completion` gets nil once one is in use,
    /// or why the pick was refused, for Settings to show next to the picker: the main window's
    /// `problem` alert would come up behind Settings, out of sight. Not called on cancel.
    func chooseOtherEditor(completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the application that opens worktrees and files."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                completion(self.useEditor(at: url))
            }
        }
    }

    /// Nil when the application is now the editor, otherwise why it cannot be.
    func useEditor(at url: URL) -> String? {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            return "\(url.deletingPathExtension().lastPathComponent) is not an application Archipel can open files with."
        }
        settings.externalEditorBundleID = bundleID
        refreshInstalledEditors()
        return nil
    }
}
