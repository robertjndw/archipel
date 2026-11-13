import AppKit
import SwiftUI

enum FileIcon {
    static let folder = "folder"

    static func symbol(for fileName: String) -> String {
        switch fileName.lowercased() {
        case "makefile", "dockerfile", "justfile", "rakefile", "gemfile", "brewfile": return "hammer"
        case ".gitignore", ".gitattributes", ".gitmodules": return "arrow.triangle.branch"
        case "license", "licence", "readme": return "doc.text"
        default: break
        }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "txt", "rtf", "log", "csv", "tsv": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "bmp", "ico", "icns", "svg": return "photo"
        case "json", "jsonc", "json5": return "curlybraces"
        case "yml", "yaml", "toml", "ini", "cfg", "conf", "plist", "xcconfig", "env", "entitlements", "editorconfig": return "gearshape"
        case "sh", "bash", "zsh", "fish", "command", "ps1": return "terminal"
        case "c", "h", "m", "mm", "cc", "cpp", "hpp", "rs", "go", "py", "rb", "js", "mjs", "cjs", "ts", "tsx", "jsx",
             "java", "kt", "cs", "php", "lua", "zig", "dart", "ex", "exs", "scala", "sql", "vue", "svelte":
            return "chevron.left.forwardslash.chevron.right"
        case "html", "htm", "xml", "css", "scss", "less": return "chevron.left.slash.chevron.right"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar": return "doc.zipper"
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": return "film"
        case "mp3", "m4a", "wav", "aiff", "aif", "flac", "ogg": return "waveform"
        case "lock", "resolved": return "lock.doc"
        case "ttf", "otf", "woff", "woff2": return "textformat"
        default: return "doc"
        }
    }
}

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

extension View {
    /// Agents edit files while the user is elsewhere, so coming back to the app is the moment to catch up.
    func onAppActivation(perform action: @escaping @MainActor () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            action()
        }
    }
}
