import AppKit

@MainActor
enum FileActions {
    static func open(_ urls: [URL]) {
        urls.forEach { NSWorkspace.shared.open($0) }
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copy(_ strings: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(strings.joined(separator: "\n"), forType: .string)
    }

    /// Uses the Trash instead of deleting so it can be undone, same as Finder.
    static func trash(_ urls: [URL]) -> (trashed: [URL], failures: [String]) {
        var trashed: [URL] = []
        var failures: [String] = []
        for url in outermost(urls) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashed.append(url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (trashed, failures)
    }

    /// Trashing a folder takes its contents with it, so trashing those afterwards would fail.
    nonisolated static func outermost(_ urls: [URL]) -> [URL] {
        let keys = urls.map(\.pathKey)
        return urls.filter { url in
            let key = url.pathKey
            return !keys.contains { $0 != key && key.isAtOrBelow($0) }
        }
    }
}
