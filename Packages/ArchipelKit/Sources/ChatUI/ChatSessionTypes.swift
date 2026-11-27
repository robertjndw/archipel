import ACPKit
import ArchipelCore
import Foundation

extension ChatSession {
    /// Where the chat is in its life. The transcript stays readable in every phase.
    public enum Phase: Sendable, Equatable {
        /// Getting the agent ready; nothing can be sent yet.
        case starting(StartStep)
        /// Connected, with a session open. Whether a turn runs is `isTurnRunning`.
        case ready
        /// Something needs the user, or a retry, before the chat can go on.
        case failed(ChatFailure)
        /// The agent process is gone.
        case ended(ChatEnding)

        public var isReady: Bool {
            if case .ready = self { true } else { false }
        }
    }

    /// What starting is busy with, for the view to describe.
    public enum StartStep: Sendable, Equatable {
        /// Looking up how to run the agent.
        case preparing
        /// Downloading or installing the agent's chat adapter. `fraction` is nil when the
        /// installer cannot tell (npm installs).
        case installing(agentName: String, fraction: Double?)
        /// Starting the process and opening the session.
        case connecting
        /// Reading back an earlier conversation.
        case restoringHistory
        /// Waiting on `authenticate(methodId:)`. `cancelStart()` goes back to asking.
        case signingIn
    }

    /// Something the owner hears about. Map `.agent` straight onto the session's status; the rest
    /// are facts to store.
    public enum Event: Sendable, Equatable {
        /// `.sessionStarted`, `.promptSubmitted`, `.activity` (throttled), `.attentionRequested`
        /// with `.permission`, `.turnFinished` and `.processExited`. Never sent for history that is
        /// being replayed.
        case agent(AgentEvent)
        /// The agent's own session id, sent once the first prompt got an update or a result: an
        /// agent that merely started has no conversation worth resuming. Not sent for the id the
        /// chat was restored from, which the owner already has.
        case agentSessionIDConfirmed(String)
        case titleChanged(String)
        /// Context window use, in tokens.
        case usageChanged(used: Int, size: Int)
        /// The chat stopped and needs the user (sign-in) or a retry. Also sent when the failure
        /// happened before any process existed, so the owner can leave its "starting" state.
        case failed(ChatFailure)
    }

    /// How long the agent gets for the steps that wait on it. Tests shorten them.
    public struct Timing: Sendable {
        /// For `initialize`, `session/new` and `session/resume`.
        public var request: Duration
        /// For `session/load`, which replays the whole conversation first and can take a while.
        public var loadSession: Duration
        /// How long a turn may go on after `cancel()` before Stop can end it by stopping the agent.
        public var cancelGrace: Duration

        public init(request: Duration = .seconds(30), loadSession: Duration = .seconds(60), cancelGrace: Duration = .seconds(5)) {
            self.request = request
            self.loadSession = loadSession
            self.cancelGrace = cancelGrace
        }
    }

    /// Everything a session needs from its owner. Tests swap `resolveLaunch` and `connect`.
    public struct Configuration: Sendable {
        /// The agent's name as the user knows it, such as "Claude Code".
        public var agentName: String
        /// The absolute directory the agent works in.
        public var workingDirectory: String
        /// The agent's session id to restore, or nil to start a new conversation.
        public var existingAgentSessionID: String?
        public var clientInfo: Implementation
        /// Produces the process to start, reporting install progress on the way. Normally
        /// `ChatLauncher.resolve`; a `ChatLaunchError` becomes a matching `ChatFailure`.
        public var resolveLaunch: @Sendable (_ progress: @escaping @Sendable (ChatLauncher.Progress) -> Void) async throws -> ChatLaunch
        /// Starts the process. Defaults to `ChatAgentConnection.spawn`.
        public var connect: @Sendable (ChatLaunch, _ workingDirectory: String) throws -> ChatAgentConnection
        public var timing: Timing
        /// Lists the working directory's files for @ mentions, as relative paths without what
        /// git ignores. Defaults to asking git. When it throws, as git does outside a repository,
        /// the session walks the folder itself. An owner that knows git is missing should throw
        /// without running it, or every call opens the system's install dialog.
        public var listFiles: @Sendable (_ folder: URL) async throws -> [String] = WorktreeFileIndex.gitFiles
        /// See `ACPClient.initialize(clientInfo:rendersTerminalOutput:)`.
        public var rendersTerminalOutput = false

        public init(
            agentName: String,
            workingDirectory: String,
            existingAgentSessionID: String? = nil,
            clientInfo: Implementation,
            resolveLaunch: @escaping @Sendable (_ progress: @escaping @Sendable (ChatLauncher.Progress) -> Void) async throws -> ChatLaunch,
            connect: @escaping @Sendable (ChatLaunch, _ workingDirectory: String) throws -> ChatAgentConnection = ChatAgentConnection.spawn,
            timing: Timing = Timing()
        ) {
            self.agentName = agentName
            self.workingDirectory = workingDirectory
            self.existingAgentSessionID = existingAgentSessionID
            self.clientInfo = clientInfo
            self.resolveLaunch = resolveLaunch
            self.connect = connect
            self.timing = timing
        }

        /// Launches through `launcher`.
        public init(
            launcher: ChatLauncher,
            workingDirectory: String,
            existingAgentSessionID: String? = nil,
            clientInfo: Implementation
        ) {
            self.init(
                agentName: launcher.agentName,
                workingDirectory: workingDirectory,
                existingAgentSessionID: existingAgentSessionID,
                clientInfo: clientInfo,
                resolveLaunch: { progress in try await launcher.resolve(progress: progress) }
            )
            rendersTerminalOutput = launcher.support.rendersTerminalOutput
        }
    }
}

/// Why a chat cannot go on, phrased for the user.
public struct ChatFailure: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// The agent wants a sign-in. Agent-type methods go through `authenticate(methodId:)`;
        /// terminal-type ones are run by the app in a terminal, followed by `retry()`.
        case signInRequired(agentMethods: [AuthMethod], terminalMethods: [AuthMethod])
        case nodeMissing
        case installFailed
        case couldNotStart
        /// The agent speaks a protocol version this app does not.
        case unsupportedProtocolVersion(Int)
    }

    public var reason: Reason
    /// A short headline, such as "Sign In to Claude Code".
    public var title: String
    /// One or two sentences on what happened and what to do.
    public var message: String
    /// The end of the agent's error output, when it has something to say. Monospaced material.
    public var details: String?

    public init(reason: Reason, title: String, message: String, details: String? = nil) {
        self.reason = reason
        self.title = title
        self.message = message
        self.details = details
    }
}

/// How the agent process ended, phrased for the user.
public struct ChatEnding: Sendable, Equatable {
    /// The exit status when the process exited normally; nil when it was killed by a signal or
    /// the connection closed without an exit being seen.
    public var exitCode: Int32?
    /// True when the chat was shut down on purpose or the agent exited with status 0.
    public var isClean: Bool
    public var message: String
    /// The end of the agent's error output after an unclean exit.
    public var details: String?

    public init(exitCode: Int32?, isClean: Bool, message: String, details: String? = nil) {
        self.exitCode = exitCode
        self.isClean = isClean
        self.message = message
        self.details = details
    }
}

/// A tool call the agent wants the user to allow. Answer with `ChatSession.respond(to:optionId:)`.
public struct ChatPermissionRequest: Sendable, Equatable, Identifiable {
    /// The JSON-RPC id of the agent's request.
    public let id: JSONRPCID
    /// Build the buttons from each option's `kind` and `name`; option ids differ per agent.
    public var options: [PermissionOption]
    /// The best picture of the call: what the transcript knows, with the request's own fields on
    /// top. Codex's request carries little more than the id, so the diff comes from the transcript.
    public var toolCall: ToolCall
    /// The tool call exactly as the request sent it.
    public var requestedToolCall: ToolCallUpdate

    public init(id: JSONRPCID, options: [PermissionOption], toolCall: ToolCall, requestedToolCall: ToolCallUpdate) {
        self.id = id
        self.options = options
        self.toolCall = toolCall
        self.requestedToolCall = requestedToolCall
    }
}

/// One setting the composer shows as a menu or a toggle: a config option, or the agent's legacy
/// modes when it sends no config options.
public struct ChatControl: Sendable, Equatable, Identifiable {
    public enum Value: Sendable, Equatable {
        /// `current` is the chosen value, nil when the agent reported one that is not a choice.
        case select(current: String?, groups: [ChoiceGroup])
        case toggle(Bool)
    }

    /// A run of choices; `name` is nil for an ungrouped list.
    public struct ChoiceGroup: Sendable, Equatable {
        public var name: String?
        public var choices: [ConfigOptionValue]

        public init(name: String?, choices: [ConfigOptionValue]) {
            self.name = name
            self.choices = choices
        }
    }

    /// The id of the control made from legacy modes. Pass it to `setControl` like any other.
    public static let modeFallbackID = "archipel.mode"

    public var id: String
    public var name: String
    public var description: String?
    /// The agent's category; nil or `.unknown` is common, so do not rely on it for layout.
    public var category: ConfigOptionCategory?
    public var value: Value

    public init(id: String, name: String, description: String? = nil, category: ConfigOptionCategory?, value: Value) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.value = value
    }

    /// The chosen value of a select; nil for a toggle and for a value that is not a choice.
    var currentValue: String? {
        guard case let .select(current, _) = value else { return nil }
        return current
    }

    /// The display name of the current choice, for a menu's label.
    public var currentChoiceName: String? {
        guard case let .select(current?, groups) = value else { return nil }
        return groups.lazy.flatMap(\.choices).first { $0.value == current }?.name
    }
}

/// A prompt waiting for the running turn to end.
public struct QueuedPrompt: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var text: String
    public var attachments: [URL]

    public init(id: UUID = UUID(), text: String, attachments: [URL] = []) {
        self.id = id
        self.text = text
        self.attachments = attachments
    }
}
