import Foundation

/// SF Symbol names for files. Lives here so the editor's diff header can share it with the inspector;
/// the app reaches it through InspectorUI's `FileIcon`, since it cannot import UISupport.
public enum FileSymbol {
    public static func name(for filename: String) -> String {
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
