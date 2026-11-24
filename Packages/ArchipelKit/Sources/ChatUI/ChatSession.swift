import ACPKit
import ArchipelCore
import Foundation
import Observation

/// One chat with an agent: the process, the conversation and everything its view shows.
///
/// Views read the properties directly. The owner sets `onEvent`, calls `start()` once, and
/// `shutDown()` (or `terminateNow()` at app quit) when the tab closes. Protocol details such as
/// replay bracketing, sign-in errors at odd places and agents that never finish a rejected tool
/// call are handled here and do not leak out.
@MainActor @Observable
public final class ChatSession {
    // MARK: State for the view

    public internal(set) var phase: Phase
    public internal(set) var transcript: ChatTranscript
    public internal(set) var isTurnRunning = false
    /// Set by `cancel()` until the turn has ended, so the stop button can show it is stopping.
    public internal(set) var isCancelling = false
    /// Set when the agent went on with the turn for a while after `cancel()`. Stop works again
    /// then, and stops the agent itself, since one that ignores a cancel is in no known state.
    public internal(set) var isCancelIgnored = false
    /// Open permission requests, oldest first. The first one is the one to show.
    public internal(set) var permissionRequests: [ChatPermissionRequest] = []
    /// What the user is typing. `send()` takes it and clears it.
    public var draft = ""
    /// Counts requests to put the cursor in the composer. The view focuses its field whenever
    /// this changes, which lets the app ask for focus without knowing the view.
    public internal(set) var composerFocusRequests = 0
    /// Files to send with the next prompt, as file URLs. Images go as image data when the agent
    /// accepts images, everything else as links the agent reads itself.
    public var attachments: [URL] = []
    /// The agent's name and version, once it started.
    public internal(set) var agentInfo: Implementation?
    public internal(set) var promptCapabilities = AgentCapabilities.Prompt()
    /// True when an earlier conversation was resumed or replaced without its messages, so the
    /// view can say "Earlier messages aren't available".
    public internal(set) var isHistoryUnavailable = false
    /// Why the last turn failed, shown under the last message. Cleared by the next send.
    public internal(set) var turnError: String?
    /// A passing problem, such as a setting the agent refused to change. Dismiss with
    /// `dismissNotice()`; the next action clears it too.
    public internal(set) var notice: String?
    /// The agent's id for this conversation, once a session is open.
    public internal(set) var agentSessionID: String?
    /// Whether `agentSessionID` names a conversation worth resuming: restored, or used by a prompt.
    public internal(set) var isAgentSessionIDConfirmed = false
    /// The agent's name as the user knows it, such as "Claude Code".
    public let agentName: String

    /// Receives lifecycle events. Set it before `start()`. Nothing is sent after `shutDown()` or
    /// `terminateNow()`.
    @ObservationIgnored public var onEvent: (@MainActor (Event) -> Void)?

    // MARK: Internal state

    /// Nil for preview sessions, which never start.
    let configuration: Configuration?
    /// The diffs of this chat's edits, worked out once each, off the main actor.
    @ObservationIgnored let diffCache = DiffCache()
    @ObservationIgnored var client: ACPClient?
    @ObservationIgnored var connection: ChatAgentConnection?
    /// The inbox of the current client. Events drained from any other inbox belong to a client
    /// that was replaced by `retry()` and are dropped.
    @ObservationIgnored var inbox: EventInbox?
    @ObservationIgnored var closeReason: ACPCloseReason?
    @ObservationIgnored var authMethods: [AuthMethod] = []
    @ObservationIgnored var agentCapabilities = AgentCapabilities()
    @ObservationIgnored var pendingRetry: PendingRetry?
    /// The prompt of the running turn, kept so a sign-in can resend it.
    @ObservationIgnored var runningPrompt: [ContentBlock]?
    /// Counts turns, so work for one turn can tell when a later one replaced it.
    @ObservationIgnored var turnCount = 0
    /// Waits out `Timing.cancelGrace` after a cancel.
    @ObservationIgnored var cancelGraceTask: Task<Void, Never>?
    /// The running `launch`, which `cancelStart()` cancels.
    @ObservationIgnored var startTask: Task<Void, Never>?
    /// Bumped by every sign-in attempt and by `cancelStart()`, so an abandoned one is ignored.
    @ObservationIgnored var signInAttempt = 0
    /// The conversation a start is restoring, until it is open. A retry after a start that broke
    /// off in the middle restores it again rather than starting a new one.
    @ObservationIgnored var restoringID: String?
    /// Bumped by every launch; work from an older launch stops when it notices.
    @ObservationIgnored var generation = 0
    @ObservationIgnored var hasStarted = false
    @ObservationIgnored var isShuttingDown = false
    @ObservationIgnored var isReplayPending = false
    @ObservationIgnored var replayWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored var lastActivityReport: ContinuousClock.Instant?
    @ObservationIgnored var reportedTitle: String?
    @ObservationIgnored var reportedUsage: UsageUpdate?

    /// What to do once a sign-in succeeds.
    enum PendingRetry {
        case openSession(restoring: String?)
        case prompt([ContentBlock])
    }

    /// At most one `.activity` per this interval; the owner only needs to know the agent is busy.
    static let activityInterval: Duration = .milliseconds(250)

    /// One prompt at a time. The protocol allows no second `session/prompt` while one runs, but a
    /// client could queue it; flip this and teach `submit` to queue to allow typing ahead.
    static let acceptsPromptsWhileRunning = false

    public init(configuration: Configuration) {
        self.configuration = configuration
        agentName = configuration.agentName
        phase = .starting(.preparing)
        transcript = ChatTranscript()
    }

    /// A session with fixed content and no process, for previews. Actions do nothing.
    public init(
        previewAgentName agentName: String,
        phase: Phase,
        transcript: ChatTranscript = ChatTranscript(),
        permissionRequests: [ChatPermissionRequest] = [],
        isTurnRunning: Bool = false,
        draft: String = "",
        agentInfo: Implementation? = nil
    ) {
        configuration = nil
        self.agentName = agentName
        self.phase = phase
        self.transcript = transcript
        self.permissionRequests = permissionRequests
        self.isTurnRunning = isTurnRunning
        self.draft = draft
        self.agentInfo = agentInfo
        agentSessionID = "preview"
        isAgentSessionIDConfirmed = true
    }

    // MARK: Derived state

    /// Whether `send()` would send now.
    public var canSend: Bool {
        canAcceptPrompt && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var canAcceptPrompt: Bool {
        phase.isReady && client != nil && agentSessionID != nil && (Self.acceptsPromptsWhileRunning || !isTurnRunning)
    }

    /// The agent's text from the newest agent message, for notifications and previews.
    public var lastAgentText: String? { transcript.lastAgentText }

    // MARK: Events

    func emit(_ events: [Event]) {
        guard !isShuttingDown, let onEvent else { return }
        for event in events { onEvent(event) }
    }

    func emit(_ event: Event) {
        emit([event])
    }

    func isCurrent(_ launch: Int) -> Bool {
        launch == generation && !isShuttingDown
    }
}
