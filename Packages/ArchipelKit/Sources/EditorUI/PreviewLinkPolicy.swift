import AppKit
import UniformTypeIdentifiers

/// What to do with a link clicked in a Markdown preview. The Markdown can come from a repository
/// nobody has read, and a URL scheme can do far more than show a page: run a shortcut, mount a
/// share, start a connection. The decisions live here, free of windows and alerts, so they can
/// be tested; the app only carries them out.
public enum PreviewLinkPolicy {
    /// True for the schemes that only show something the user then acts on: a web page, or a mail
    /// draft that still has to be sent. Anything else should be confirmed with its destination
    /// in view before it goes to the system.
    public static func opensWithoutAsking(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }

    // MARK: Where a link goes

    public enum Action: Equatable, Sendable {
        /// A file or folder inside the worktree, as the link named it.
        case file(URL)
        /// A file or folder somewhere else, with symlinks followed. Ask before showing it.
        case fileOutsideRoot(URL)
        case web(URL)
        /// Goes to the system without a question: a mail draft.
        case system(URL)
        /// Any other scheme. Ask, naming the app that would get it.
        case confirm(URL)
        case ignore
    }

    /// `root` is the worktree the previewed document belongs to. Without one every file counts
    /// as outside.
    public static func action(for link: URL, root: URL?) -> Action {
        guard let scheme = link.scheme?.lowercased() else { return .ignore }
        switch scheme {
        case "file":
            // A file URL with a host names a file on another machine. Opening its path here
            // would show a local file the link did not point at.
            guard [nil, "", "localhost"].contains(link.host()?.lowercased()) else { return .ignore }
            if let root, PreviewScheme.isInside(link, root: root) { return .file(link) }
            return .fileOutsideRoot(URL(filePath: PreviewScheme.resolvedPath(link)))
        case "http", "https":
            return link.host()?.isEmpty == false ? .web(link) : .ignore
        case "mailto":
            return .system(link)
        case PreviewScheme.name:
            return .ignore
        default:
            return HTMLSanitizer.scriptSchemes.contains(scheme) ? .ignore : .confirm(link)
        }
    }

    // MARK: What a caller without its own handling gets

    public enum DefaultAction: Equatable, Sendable {
        case open(URL)
        /// Shown in Finder, never opened: `setup.command` or an app bundle in a clone would run.
        case reveal(URL)
        case ignore
    }

    public static func defaultAction(for link: URL) -> DefaultAction {
        if link.isFileURL { return .reveal(link) }
        return opensWithoutAsking(link) ? .open(link) : .ignore
    }

    @MainActor
    public static func openByDefault(_ link: URL) {
        switch defaultAction(for: link) {
        case .open(let url): NSWorkspace.shared.open(url)
        case .reveal(let file): NSWorkspace.shared.activateFileViewerSelecting([file])
        case .ignore: break
        }
    }

    // MARK: Asking

    /// The text of a question about a link, or of the explanation why it stays unopened.
    public struct Prompt: Equatable, Sendable {
        public var title: String
        public var detail: String
        /// False when there is nothing to agree to and the alert only informs.
        public var canOpen: Bool
    }

    public enum HandlerLocation: Equatable, Sendable {
        /// Where apps are installed: `/Applications`, `/System`, the user's Applications folder.
        case standard
        /// Anywhere else, with the resolved path to show.
        case elsewhere(String)
        /// Inside the worktree the link came from.
        case insideRoot(String)
    }

    /// Launch Services registers any app bundle it comes across, including one inside a clone,
    /// and such a bundle can claim a scheme and call itself "Safari". Its name says nothing;
    /// where it lives does.
    public static func location(
        ofHandler handler: URL,
        root: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> HandlerLocation {
        let path = PreviewScheme.resolvedPath(handler)
        if let root, PreviewScheme.isInside(handler, root: root) { return .insideRoot(path) }
        let installed = ["/Applications/", "/System/", PreviewScheme.resolvedPath(home.appending(path: "Applications")) + "/"]
        return installed.contains(where: path.hasPrefix) ? .standard : .elsewhere(path)
    }

    /// `handler` is the app the system would hand `url` to and `handlerName` what it calls itself.
    public static func prompt(
        forOpening url: URL,
        handler: URL?,
        handlerName: String?,
        root: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Prompt {
        let destination = shortened(url.absoluteString)
        guard let handler else {
            return Prompt(title: "No app can open this link", detail: destination, canOpen: false)
        }
        let name = shortened(handlerName ?? handler.lastPathComponent, limit: 80)
        let trust = "The link comes from the file you are previewing. Open it only if you trust it."
        switch location(ofHandler: handler, root: root, home: home) {
        case .standard:
            return Prompt(title: "Open this link in \(name)?", detail: "\(destination)\n\n\(trust)", canOpen: true)
        case .elsewhere(let path):
            return Prompt(
                title: "Open this link in \(name)?",
                detail: "\(destination)\n\n\(name) is not in an Applications folder. It is at \(shortened(path)).\n\n\(trust)",
                canOpen: true
            )
        case .insideRoot(let path):
            return Prompt(
                title: "This link was not opened",
                detail: "\(destination)\n\nThe app registered for it, \(name), is part of the worktree the link comes from: \(shortened(path)). "
                    + "A repository that brings its own app for its own links is not to be trusted with them.",
                canOpen: false
            )
        }
    }

    /// `file` is where the link leads with symlinks followed, as `action(for:root:)` hands it out.
    public static func prompt(forFileOutsideRoot file: URL) -> Prompt {
        Prompt(
            title: "Open a file outside this worktree?",
            detail: "\(shortened(file.path(percentEncoded: false)))\n\n"
                + "The link comes from the file you are previewing and leads out of the worktree it belongs to. Open it only if you trust it.",
            canOpen: true
        )
    }

    /// Past the limit an alert would outgrow the screen. What decides is at the front anyway:
    /// the scheme and where it leads.
    public static func shortened(_ text: String, limit: Int = 600) -> String {
        text.count > limit ? "\(text.prefix(limit))... (\(text.count - limit) more characters)" : text
    }
}

/// Handing a file to its default app. For most files that shows them; for some it runs them.
enum ExternalFileOpen {
    /// The rule the terminal applies to links in its output: no packages and no executables.
    /// Added to it are the types whose default app runs them or acts on what they say, such as
    /// scripts, installers and location files.
    static func runsCodeWhenOpened(_ file: URL) -> Bool {
        let path = file.resolvingSymlinksInPath().path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        // Nothing to open either way; erring on this side keeps a file that appears later closed.
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return true }
        if NSWorkspace.shared.isFilePackage(atPath: path) { return true }
        if !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: path) { return true }
        let name = (path as NSString).pathExtension.lowercased()
        if launchingExtensions.contains(name) { return true }
        guard let type = UTType(filenameExtension: name) else { return false }
        return launchingTypes.contains { type.conforms(to: $0) }
    }

    private static let launchingTypes: [UTType] = [
        .executable, .application, .script, .bundle, .package, .diskImage, .internetLocation, .aliasFile,
    ]

    /// Types the system may not declare, or declares without one of the parents above.
    private static let launchingExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "workflow", "action", "wflow", "shortcut", "scpt", "scptd",
        "applescript", "jar", "jnlp", "pkg", "mpkg", "dmg", "inetloc", "webloc", "fileloc", "url",
        "prefpane", "saver", "service", "kext", "osax", "plugin", "xpc", "appex",
    ]

    @MainActor
    static func openOrReveal(_ file: URL) {
        if runsCodeWhenOpened(file) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(file)
        }
    }
}
