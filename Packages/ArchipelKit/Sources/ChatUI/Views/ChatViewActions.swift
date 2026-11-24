import Foundation

/// What the chat asks of the app around it. The chat itself only knows its conversation: opening
/// tabs, settings and the terminal belong to whoever hosts it.
public struct ChatViewActions {
    /// Open a file the agent mentioned, at a 1-based line when it named one.
    public var openFile: @MainActor (URL, Int?) -> Void
    /// Open a link from a reply, following the app's own rules for where links go.
    public var openLink: @MainActor (URL) -> Void
    /// Show the session as a terminal so the user can sign in with the agent's own CLI. Nil when
    /// the host has no terminal to offer, which hides the button.
    public var signInInTerminal: (@MainActor () -> Void)?
    public var openAgentSettings: @MainActor () -> Void
    /// Start the agent again after it ended.
    public var restart: @MainActor () -> Void
    public var close: @MainActor () -> Void
    /// The user typed or clicked in the chat, which counts as having seen what it shows.
    public var userInteracted: @MainActor () -> Void

    public init(
        openFile: @escaping @MainActor (URL, Int?) -> Void = { _, _ in },
        openLink: @escaping @MainActor (URL) -> Void = { _ in },
        signInInTerminal: (@MainActor () -> Void)? = nil,
        openAgentSettings: @escaping @MainActor () -> Void = {},
        restart: @escaping @MainActor () -> Void = {},
        close: @escaping @MainActor () -> Void = {},
        userInteracted: @escaping @MainActor () -> Void = {}
    ) {
        self.openFile = openFile
        self.openLink = openLink
        self.signInInTerminal = signInInTerminal
        self.openAgentSettings = openAgentSettings
        self.restart = restart
        self.close = close
        self.userInteracted = userInteracted
    }
}
