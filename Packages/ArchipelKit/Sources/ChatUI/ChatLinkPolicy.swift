import AppKit
import EditorUI
import Foundation

/// Where a link clicked in a chat reply may go.
///
/// Agent output is untrusted: a prompt injection can make an agent write any link, and Markdown
/// hides the real target behind its text. Opening a folder, an app or a script with the system's
/// default handler would run it, so those are only ever shown in Finder.
public enum ChatLinkPolicy {
    public enum Destination: Equatable, Sendable {
        case web(URL)
        case mail(URL)
        /// A file that is safe to open: as a tab, or in its default app, as the app decides.
        /// `position` comes from a `#L12` or `#L12C3` fragment, which the URL no longer has.
        case file(URL, position: MarkdownFilePosition?)
        /// A folder, a bundle or something that runs. Selecting it in Finder is safe and still
        /// takes the user to it.
        case reveal(URL)
    }

    /// Extensions of files that run or install something when opened, executable bit or not.
    static let runnableExtensions: Set<String> = [
        "app", "command", "tool", "sh", "zsh", "bash", "fish", "csh", "ksh", "tcsh", "py", "rb", "pl", "js",
        "scpt", "scptd", "applescript", "workflow", "action", "pkg", "mpkg", "dmg", "terminal", "jar",
        "fileloc", "inetloc",
    ]

    /// Where `url` goes, or nil when it goes nowhere: an unknown scheme, a web link without a
    /// host, a file that does not exist, or one that is neither a regular file nor a folder.
    @MainActor
    public static func destination(for url: URL) -> Destination? {
        destination(for: url) { NSWorkspace.shared.isFilePackage(atPath: $0.path(percentEncoded: false)) }
    }

    static func destination(for url: URL, isPackage: (URL) -> Bool) -> Destination? {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return url.host() == nil ? nil : .web(url)
        case "mailto":
            return .mail(url)
        case "file":
            let position = url.fragment(percentEncoded: false).flatMap(MarkdownFilePosition.init(fragment:))
            var bare = url
            if url.fragment() != nil || url.query() != nil, var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                components.fragment = nil
                components.query = nil
                bare = components.url ?? url
            }
            let file = bare.standardizedFileURL
            // Judged by what the link ends up at, so a harmless name cannot stand in for an app.
            // Followed by hand rather than with `resolvingSymlinksInPath`, which would happily
            // walk a planted link into an automount. Devices and FIFOs come back as nil: they
            // would hang whatever reads them.
            guard let found = SafeFileLookup.lookUp(file.path(percentEncoded: false), refusing: SafeFileLookup.automountPrefixes) else {
                return nil
            }
            let path = found.path
            let target = URL(filePath: path, directoryHint: found.kind == .folder ? .isDirectory : .notDirectory)
            let runs = found.kind == .folder || isPackage(target)
                || runnableExtensions.contains(target.pathExtension.lowercased())
                || runnableExtensions.contains(file.pathExtension.lowercased())
                || FileManager.default.isExecutableFile(atPath: path)
            return runs ? .reveal(file) : .file(file, position: position)
        default:
            return nil
        }
    }
}
