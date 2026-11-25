import AppKit
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
        case file(URL)
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
    /// host, a file that does not exist.
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
            let file = url.standardizedFileURL
            // Judged by what the link ends up at, so a harmless name cannot stand in for an app.
            let target = file.resolvingSymlinksInPath()
            let path = target.path(percentEncoded: false)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
            let runs = isDirectory.boolValue || isPackage(target)
                || runnableExtensions.contains(target.pathExtension.lowercased())
                || runnableExtensions.contains(file.pathExtension.lowercased())
                || FileManager.default.isExecutableFile(atPath: path)
            return runs ? .reveal(file) : .file(file)
        default:
            return nil
        }
    }
}
