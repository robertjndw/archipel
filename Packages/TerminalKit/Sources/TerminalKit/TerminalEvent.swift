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
    /// An existing file or folder, as a standardized file URL.
    case file(URL)

    public var url: URL {
        switch self {
        case .web(let url), .mail(let url), .file(let url): url
        }
    }

    /// Opens the link with the system. Apps, packages and executables are
    /// refused here, because `open` would launch them; viewing one inside the
    /// host is harmless.
    @MainActor
    public func openExternally() {
        if case .file(let url) = self {
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
    /// URLs and files that don't exist.
    init?(_ string: String) {
        let url: URL
        if let candidate = URL(string: string), candidate.scheme != nil {
            url = candidate
        } else {
            url = URL(filePath: NSString(string: string).standardizingPath)
        }

        switch url.scheme?.lowercased() {
        case "http", "https":
            guard url.host() != nil else { return nil }
            self = .web(url)
        case "mailto":
            self = .mail(url)
        case "file":
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
            self = .file(url.standardizedFileURL)
        default:
            return nil
        }
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

    public init(background: RGB, unfocusedSplitFill: RGB, unfocusedSplitOpacity: Double) {
        self.background = background
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
