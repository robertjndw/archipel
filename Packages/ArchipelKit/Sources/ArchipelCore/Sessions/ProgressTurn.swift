import Foundation

/// Tracks turns from the OSC 9;4 progress reports of a Claude that has no hooks. Claude sets
/// progress while it works and clears it when it stops, but it also clears it for a moment in
/// the middle of a turn, and the terminal passes on every report, repeats included. So a set is
/// only a start when nothing was set before, and a clear only ends the turn once it has held for
/// `quietPeriod` and the screen and the process table agree.
public struct ProgressTurn: Equatable, Sendable {
    public static let quietPeriod: TimeInterval = 3
    /// Process start times and the clock are read separately, so a tool started right as the
    /// progress cleared can carry a start time a little before it.
    static let startTimeTolerance: TimeInterval = 1

    public enum Change: Equatable, Sendable {
        case none
        case started
        /// Ask `decide` at `checkAt`.
        case mayHaveEnded(checkAt: Date)
    }

    public enum Outcome: Equatable, Sendable {
        /// A tool is still running; ask again at `recheckAt`.
        case keepWorking(recheckAt: Date)
        case finished
        case needsAttention(AttentionReason)
        /// The turn did not end after all, or something else already settled it.
        case ignore
    }

    public private(set) var isActive = false
    /// When the progress was last cleared, while it stays clear.
    public private(set) var clearedAt: Date?

    public init() {}

    /// `active` is false when the report is an error or a removal.
    public mutating func receive(active: Bool, at now: Date) -> Change {
        defer { isActive = active }
        if active {
            clearedAt = nil
            return isActive ? .none : .started
        }
        guard isActive else { return .none }
        clearedAt = now
        return .mayHaveEnded(checkAt: now.addingTimeInterval(Self.quietPeriod))
    }

    /// Whether a process started at `startTime` (seconds since 1970) started after the progress
    /// cleared. True for a Bash tool call, false for an MCP server started with the agent.
    public func startedSinceClear(_ startTime: TimeInterval) -> Bool {
        guard let clearedAt else { return false }
        return startTime >= clearedAt.timeIntervalSince1970 - Self.startTimeTolerance
    }

    public func decide(
        at now: Date,
        toolProcessStartedSinceClear: Bool,
        screenShowsPrompt: Bool,
        screenShowsMenu: Bool,
        status: SessionStatus
    ) -> Outcome {
        guard !isActive, let clearedAt, status == .working else { return .ignore }
        let due = clearedAt.addingTimeInterval(Self.quietPeriod)
        if now < due { return .keepWorking(recheckAt: due) }
        // A prompt on screen wins over a running tool, since a parallel call may be waiting on it.
        if screenShowsPrompt { return .needsAttention(.permission) }
        if screenShowsMenu { return .needsAttention(.question) }
        // The progress can be clear while a tool call runs, and a long build must not end the turn.
        if toolProcessStartedSinceClear { return .keepWorking(recheckAt: now.addingTimeInterval(Self.quietPeriod)) }
        return .finished
    }
}
