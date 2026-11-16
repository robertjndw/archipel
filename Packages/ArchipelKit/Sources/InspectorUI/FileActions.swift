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
}
