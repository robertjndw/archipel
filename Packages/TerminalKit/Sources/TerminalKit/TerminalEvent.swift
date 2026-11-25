import AppKit

public enum TerminalEvent: Sendable, Equatable {
    case titleChanged(String)
    case workingDirectoryChanged(String)
    /// OSC 9 / OSC 777 desktop notification requested by the program.
    case notification(title: String, body: String)
    case bell
    /// OSC 9;4 progress report; nil when the program removed it.
    case progress(TerminalProgress?)
    /// The child process exited. With `waitAfterCommand` the surface stays
    /// open showing its final output until the host closes the session.
    case childExited(exitCode: UInt32)
    /// Ghostty wants the surface gone (a close keybinding, or the child exited
    /// without `waitAfterCommand`). Nothing is closed until the host calls
    /// `TerminalSession.close()`.
    case closeRequested
    /// The user ⌘-clicked a link that passed TerminalKit's checks. The host
    /// decides where it opens; `TerminalLink.openExternally()` is the fallback.
    /// `alternate` is true for ⌘⌥-click, which flips the host's usual choice.
    case openLink(TerminalLink, alternate: Bool)
}

/// A link from terminal output. Terminal output is untrusted, so only these
/// kinds ever reach the host.
public enum TerminalLink: Sendable, Equatable {
    /// http or https with a host.
    case web(URL)
    case mail(URL)
    /// An existing file or folder, as a standardized file URL. `position` is
    /// set when the text ended in `:line` or `:line:column`.
    case file(URL, position: Position?)

    /// A 1-based line, and optionally column, to jump to inside a file.
    public struct Position: Sendable, Equatable {
        public var line: Int
        public var column: Int?

        public init(line: Int, column: Int? = nil) {
            self.line = line
            self.column = column
        }
    }

    public var url: URL {
        switch self {
        case .web(let url), .mail(let url), .file(let url, _): url
        }
    }

    /// Opens the link with the system, ignoring any position. Apps, packages
    /// and executables are refused here, because `open` would launch them;
    /// viewing one inside the host is harmless.
    @MainActor
    public func openExternally() {
        if case .file(let url, _) = self {
            let path = url.path(percentEncoded: false)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !NSWorkspace.shared.isFilePackage(atPath: path),
                  isDirectory.boolValue || !FileManager.default.isExecutableFile(atPath: path)
            else {
                logger.info("refusing to open untrusted file target")
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    /// nil for anything that must not be opened: custom schemes, hostless web
    /// URLs and files that don't exist. Relative paths resolve against `base`,
    /// the session's directory, because Ghostty only does that itself when the
    /// program reported its pwd.
    init?(_ string: String, relativeTo base: URL?) {
        self.init(string, relativeTo: base) { FileManager.default.fileExists(atPath: $0) }
    }

    init?(_ string: String, relativeTo base: URL?, fileExists: (String) -> Bool) {
        // `foo.swift:12` parses as a URL with scheme "foo.swift", so only
        // `scheme://`, mailto and file count as URLs. Anything else is a path,
        // which the existence check below refuses if it isn't a real file.
        if let candidate = URL(string: string), let scheme = candidate.scheme,
           string.hasPrefix("\(scheme)://") || ["mailto", "file"].contains(scheme.lowercased()) {
            switch candidate.scheme?.lowercased() {
            case "http", "https":
                guard candidate.host() != nil else { return nil }
                self = .web(candidate)
            case "mailto":
                self = .mail(candidate)
            case "file":
                guard fileExists(candidate.path(percentEncoded: false)) else { return nil }
                self = .file(candidate.standardizedFileURL, position: nil)
            default:
                return nil
            }
            return
        }

        // Tried as written first so a file really named `foo.swift:12` wins.
        if let url = Self.resolve(string, relativeTo: base), fileExists(url.path(percentEncoded: false)) {
            self = .file(url, position: nil)
            return
        }
        guard let (path, position) = Self.splitPosition(string),
              let url = Self.resolve(path, relativeTo: base),
              fileExists(url.path(percentEncoded: false))
        else { return nil }
        self = .file(url, position: position)
    }

    private static func resolve(_ path: String, relativeTo base: URL?) -> URL? {
        guard !path.isEmpty else { return nil }
        let expanded = NSString(string: path).standardizingPath
        if expanded.hasPrefix("/") || base == nil {
            return URL(filePath: expanded)
        }
        return URL(filePath: expanded, relativeTo: base).standardizedFileURL
    }

    private static func splitPosition(_ string: String) -> (String, Position)? {
        guard let match = string.wholeMatch(of: /(.+?):(\d+)(?::(\d+))?/),
              let line = Int(match.2), line >= 1
        else { return nil }
        return (String(match.1), Position(line: line, column: match.3.flatMap { Int($0) }))
    }
}

public struct TerminalProgress: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case normal
        case error
        case indeterminate
        case paused
    }

    public var state: State
    /// 0...100, or nil when the program reported no percentage.
    public var percent: Int?

    public init(state: State, percent: Int?) {
        self.state = state
        self.percent = percent
    }
}

/// The colors from the user's Ghostty config that the host needs to draw around a terminal.
public struct TerminalColors: Sendable, Equatable {
    /// An sRGB color with components from 0 to 1.
    public struct RGB: Sendable, Equatable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// WCAG relative luminance, to tell whether text on this color should be light or dark.
        public var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    /// Ghostty's `background`.
    public var background: RGB
    /// Ghostty's `unfocused-split-fill`, which defaults to the background. A split without focus is
    /// covered with it at `1 - unfocusedSplitOpacity`.
    public var unfocusedSplitFill: RGB
    /// Ghostty's `unfocused-split-opacity`: how much of the split stays visible, from 0.15 to 1.
    public var unfocusedSplitOpacity: Double
    /// Ghostty's `foreground`, for text the host draws on the terminal's background.
    public var foreground: RGB

    public init(
        background: RGB,
        unfocusedSplitFill: RGB,
        unfocusedSplitOpacity: Double,
        foreground: RGB = RGB(red: 1, green: 1, blue: 1)
    ) {
        self.background = background
        self.foreground = foreground
        self.unfocusedSplitFill = unfocusedSplitFill
        self.unfocusedSplitOpacity = unfocusedSplitOpacity
    }
}

public enum TerminalError: Error, Sendable {
    case alreadyInitialized
    case initializationFailed
    case configurationFailed
    case appCreationFailed
    case surfaceCreationFailed
}
