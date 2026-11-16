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

public enum TerminalError: Error, Sendable {
    case alreadyInitialized
    case initializationFailed
    case configurationFailed
    case appCreationFailed
    case surfaceCreationFailed
}
