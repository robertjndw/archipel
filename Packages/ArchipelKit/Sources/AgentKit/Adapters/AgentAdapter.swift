import ArchipelCore
import Foundation

/// Everything Archipel knows about one kind of agent: how to start and resume it, how its hooks
/// reach the app, and what the app may rely on while it runs. Adding an agent should mean adding an
/// adapter and registering it, not new branches in the app.
public protocol AgentAdapter: Sendable {
    /// Same string as the `AgentKind` raw value persisted with each session.
    var id: String { get }
    var displayName: String { get }
    var symbolName: String { get }
    /// The command name shown to the user and looked up on the PATH.
    var executableName: String { get }
    /// What the app looks for to tell whether the agent is installed. Defaults to `executableName`.
    var executableToLocate: String { get }
    var capabilities: AgentCapabilities { get }
    /// The envelope `source` values this adapter decodes.
    var hookSources: Set<String> { get }
    /// The subset of `hookSources` that only stands in for the agent's real hooks until those have
    /// reported. Messages from them are dropped once the session has been heard from through
    /// another source. Only meaningful with `LifecycleSource.hooksOnceSeen`.
    var fallbackHookSources: Set<String> { get }

    func launchCommand(for context: LaunchContext) -> LaunchCommand
    /// Nil when the agent cannot resume a conversation.
    func resumeCommand(for context: LaunchContext, agentSessionID: String) -> LaunchCommand?
    /// Nil drops the message entirely. A payload that is understood but carries no event should
    /// still come back, so the app learns the agent session id or the lifecycle from it.
    func decodeHook(source: String, payload: [String: Any], receivedAt date: Date) -> DecodedHook?
    /// What a desktop notification the agent printed to its terminal asks of the user. Only used
    /// while the session does not report through hooks, since hooks say the same with more detail.
    func attentionReason(forTerminalNotification body: String) -> AttentionReason?
    /// A fresh conversation id for `SessionIDStrategy.presetByApp`, in whatever shape the agent accepts.
    func makePresetSessionID() -> String
    /// Whether `id` has the shape of this agent's conversation ids. Asked before an id from a hook
    /// is kept and again before one goes on a command line; see `AgentSessionID`.
    func acceptsSessionID(_ id: String) -> Bool
    /// The conversation's name inside the title the agent sets on its terminal, or nil when the
    /// title says nothing about it. The title is shown as is, minus leading status glyphs.
    func conversationTitle(fromTerminalTitle title: String) -> String?
    /// How the agent runs as a chat over the Agent Client Protocol. Nil when it only has a terminal.
    var acp: ACPSupport? { get }
}

extension AgentAdapter {
    public var executableToLocate: String { executableName }
    public var fallbackHookSources: Set<String> { [] }
    public var acp: ACPSupport? { nil }

    /// Nil when the agent cannot resume, no agent session id is known yet or the one that was
    /// saved does not look like an id; start fresh then.
    public func resumeCommand(for context: LaunchContext) -> LaunchCommand? {
        guard let agentSessionID = context.agentSessionID, acceptsSessionID(agentSessionID) else { return nil }
        return resumeCommand(for: context, agentSessionID: agentSessionID)
    }

    public func acceptsSessionID(_ id: String) -> Bool { AgentSessionID.isPlainWord(id) }

    /// The conversation id in a hook payload, or nil when the value is not one this agent could
    /// have produced.
    func sessionID(_ value: Any?) -> String? {
        HookDecoder.nonEmptyString(value).flatMap { acceptsSessionID($0) ? $0 : nil }
    }

    public func decodeHook(source: String, payload: [String: Any], receivedAt date: Date) -> DecodedHook? { nil }

    public func makePresetSessionID() -> String { UUID().uuidString.lowercased() }

    public func conversationTitle(fromTerminalTitle title: String) -> String? {
        // Agents put a status glyph or spinner character in front of the name.
        let name = String(title.drop { !($0.isLetter || $0.isNumber) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

public struct AgentCapabilities: Sendable {
    public var sessionID: SessionIDStrategy
    public var lifecycle: LifecycleSource
    /// The session is an agent prompt the app may type text into. A shell would run it.
    public var acceptsPrompts: Bool
    /// `ApprovalPrompt` can read the agent's approval prompt from its screen.
    public var answersApprovalsInTerminal: Bool
    public var usage: UsageSource?
    /// Hooks report subagents starting and stopping, so a turn is not over while they run.
    public var tracksSubagents: Bool
    /// Example arguments shown in an empty preset field.
    public var presetPlaceholder: String
    /// Extra settings the app shows for this agent, in this order.
    public var settingsSections: [AgentSettingsSection]

    public init(
        sessionID: SessionIDStrategy,
        lifecycle: LifecycleSource,
        acceptsPrompts: Bool,
        answersApprovalsInTerminal: Bool,
        usage: UsageSource?,
        tracksSubagents: Bool,
        presetPlaceholder: String,
        settingsSections: [AgentSettingsSection]
    ) {
        self.sessionID = sessionID
        self.lifecycle = lifecycle
        self.acceptsPrompts = acceptsPrompts
        self.answersApprovalsInTerminal = answersApprovalsInTerminal
        self.usage = usage
        self.tracksSubagents = tracksSubagents
        self.presetPlaceholder = presetPlaceholder
        self.settingsSections = settingsSections
    }

    /// True when hooks report the whole lifecycle (start, attention, finish) from the first moment.
    /// Without that, the app has to infer those moments from the terminal and from the user looking
    /// at the session.
    public var reportsLifecycleThroughHooks: Bool { lifecycle == .hooks }
}

/// Where the agent's own conversation id, needed to resume, comes from.
public enum SessionIDStrategy: Sendable {
    /// The app picks a fresh id before the first launch and passes it in, so the session can be
    /// resumed later without waiting for a hook.
    case presetByApp
    /// The agent picks one and a hook reports it.
    case reportedByHook
    /// Nothing to resume.
    case none
}

/// What tells the app that a turn started, needs the user, or finished.
public enum LifecycleSource: Sendable {
    /// Hooks, always.
    case hooks
    /// The terminal until the session's first hook arrives, hooks from then on. For an agent whose
    /// hooks only run once the user has trusted them.
    case hooksOnceSeen
    /// Only the terminal: its title, notifications and bell.
    case terminal
}

/// Where the subscription limits shown in the status bar come from.
public enum UsageSource: Sendable {
    /// Claude's status line input, sent live while a session runs.
    case claudeStatusLine
    /// The token counts Codex writes to its session logs, which can be read again at any time.
    case codexLogs

    public var provider: UsageProvider {
        switch self {
        case .claudeStatusLine: .claude
        case .codexLogs: .codex
        }
    }

    /// The numbers live on disk, so the user can ask for them to be read again.
    public var canRefreshOnDemand: Bool { self == .codexLogs }
}

/// Agent specific settings. AgentKit has no UI, so the app maps each case to its own view.
public enum AgentSettingsSection: Hashable, Sendable {
    /// Archipel's hooks in the user's own Claude settings, for a Claude started by hand.
    case claudeShellHooks
    /// Whether Codex has been told to trust Archipel's hooks.
    case codexHooksStatus
    /// The plugin Archipel loads into OpenCode.
    case openCodeIntegration
}

extension AgentKind {
    /// The built-in adapter for this kind; anything unknown runs as a plain shell.
    public var adapter: any AgentAdapter {
        AgentRegistry.builtIn.adapter(id: rawValue) ?? ShellAdapter()
    }
}
