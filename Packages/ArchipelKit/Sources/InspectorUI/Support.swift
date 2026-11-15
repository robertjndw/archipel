import AppKit
import SwiftUI

/// SF Symbol names for files, shared with the app so editor tabs match the sidebar.
public enum FileIcon {
    public static let folder = "folder"

    public static func symbol(for filename: String) -> String {
        switch filename.lowercased() {
        case "makefile", "dockerfile", "justfile", "rakefile", "gemfile", "brewfile": return "hammer"
        case ".gitignore", ".gitattributes", ".gitmodules": return "arrow.triangle.branch"
        case "license", "licence", "readme": return "doc.text"
        default: break
        }
        switch (filename as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "txt", "rtf", "log", "csv", "tsv": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tif", "tiff", "bmp", "ico", "icns", "svg": return "photo"
        case "json", "jsonc", "json5": return "curlybraces"
        case "yml", "yaml", "toml", "ini", "cfg", "conf", "plist", "xcconfig", "env", "entitlements", "editorconfig": return "gearshape"
        case "sh", "bash", "zsh", "fish", "command", "ps1": return "terminal"
        case "c", "h", "m", "mm", "cc", "cpp", "hpp", "rs", "go", "py", "rb", "js", "mjs", "cjs", "ts", "mts", "cts", "tsx", "jsx",
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
    /// The sidebar list style sizes its rows from the system "Sidebar icon size"
    /// setting, whose default is too roomy for a file tree. Pin it to the small
    /// size, which is what Xcode's navigators use.
    func compactRows() -> some View {
        environment(\.sidebarRowSize, .small)
    }
}

extension View {
    /// Fades the top or bottom edge while content is cut off there. Replaces the system scroll edge
    /// effect, which needs a bar, and bars show a hairline on hover.
    func scrollEdgeFade(height: CGFloat = 28) -> some View {
        modifier(ScrollEdgeFade(height: height))
    }
}

private struct ScrollEdgeFade: ViewModifier {
    let height: CGFloat
    @State private var clipped = ClippedEdges()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct ClippedEdges: Equatable {
        var top = false
        var bottom = false
    }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ClippedEdges.self) { geometry in
                // Half a point of slack so rubber-banding and rounding do not flicker the fade.
                let top = geometry.contentOffset.y + geometry.contentInsets.top > 0.5
                let bottom = geometry.visibleRect.maxY < geometry.contentSize.height - 0.5
                return ClippedEdges(top: top, bottom: bottom)
            } action: { _, edges in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { clipped = edges }
            }
            // An overlay rather than a mask: masking the sidebar-style list makes its icons vanish.
            .overlay(alignment: .top) { fade(from: .top).opacity(clipped.top ? 1 : 0) }
            .overlay(alignment: .bottom) { fade(from: .bottom).opacity(clipped.bottom ? 1 : 0) }
    }

    private func fade(from edge: VerticalEdge) -> some View {
        let background = Color.inspectorBackground
        // Solid for the first 30% so rows don't show half transparent right below the header.
        return LinearGradient(
            stops: [
                .init(color: background, location: 0),
                .init(color: background, location: 0.3),
                .init(color: background.opacity(0), location: 1),
            ],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

extension Color {
    /// Painted by the inspector so the scroll fades can use the exact same color. No system color or
    /// material matched the inspector background in both light and dark mode on macOS 26, so these
    /// values are measured. A fade in any other color shows up as a band.
    static let inspectorBackground = Color(nsColor: NSColor(name: "InspectorBackground") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let level: CGFloat = (isDark ? 47 : 239) / 255
        return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
    })
}
