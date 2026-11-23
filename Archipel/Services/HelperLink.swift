import Foundation

/// A stable path to the bundled `archipel-hook`, in the support directory.
///
/// Anything that stores the helper's path, or a hash of it, needs one that survives moving or
/// updating the app: the hook entries in the user's Claude settings, and the trust Codex records
/// for a hook by its command line.
nonisolated struct HelperLink {
    let url: URL
    let bundledHelper: URL

    init(supportDirectory: URL, bundledHelper: URL) {
        url = supportDirectory.appending(path: "bin", directoryHint: .isDirectory).appending(path: "archipel-hook")
        self.bundledHelper = bundledHelper
    }

    /// Creates or repoints the link. Renaming a temporary link over it is atomic, so an agent that
    /// is running a hook never finds the helper missing.
    func refresh() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? manager.destinationOfSymbolicLink(atPath: url.path)) == bundledHelper.path { return }

        let temporary = url.deletingLastPathComponent().appending(path: ".archipel-hook-\(UUID().uuidString)")
        try manager.createSymbolicLink(atPath: temporary.path, withDestinationPath: bundledHelper.path)
        if rename(temporary.path, url.path) != 0 {
            let code = errno
            try? manager.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
