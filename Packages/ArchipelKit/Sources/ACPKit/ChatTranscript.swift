import Foundation

/// A message as shown in the chat: its text, plus any non-text content that came with it.
public struct ChatMessage: Sendable, Hashable, Identifiable {
    public var id: String
    /// All text blocks of the message, joined in order.
    public var text: String
    /// Images, resource links and other non-text blocks, in order.
    public var attachments: [ContentBlock]
    /// The agent's id for the message, when it sends one.
    public var messageId: String?

    public init(id: String, text: String = "", attachments: [ContentBlock] = [], messageId: String? = nil) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.messageId = messageId
    }

    mutating func append(_ block: ContentBlock) {
        if case let .text(text) = block {
            self.text += text
        } else {
            attachments.append(block)
        }
    }
}

/// One row of the chat.
public enum ChatItem: Sendable, Hashable, Identifiable {
    case userMessage(ChatMessage)
    case agentMessage(ChatMessage)
    case agentThought(ChatMessage)
    case toolCall(ToolCall)

    /// Stable for the life of the transcript. Tool calls use their call id, which the agent keeps unique.
    public var id: String {
        switch self {
        case let .userMessage(message), let .agentMessage(message), let .agentThought(message): message.id
        case let .toolCall(call): "tool:\(call.toolCallId)"
        }
    }

    public var message: ChatMessage? {
        switch self {
        case let .userMessage(message), let .agentMessage(message), let .agentThought(message): message
        case .toolCall: nil
        }
    }

    fileprivate var role: ChatTranscript.Role? {
        switch self {
        case .userMessage: .user
        case .agentMessage: .agent
        case .agentThought: .thought
        case .toolCall: nil
        }
    }

    /// Put in place of an item while its payload is edited, so the payload is uniquely referenced
    /// and appending to a long message does not copy it.
    private static let vacant = ChatItem.agentThought(ChatMessage(id: ""))

    fileprivate mutating func modifyMessage(_ body: (inout ChatMessage) -> Void) {
        switch self {
        case var .userMessage(message):
            self = Self.vacant
            body(&message)
            self = .userMessage(message)
        case var .agentMessage(message):
            self = Self.vacant
            body(&message)
            self = .agentMessage(message)
        case var .agentThought(message):
            self = Self.vacant
            body(&message)
            self = .agentThought(message)
        case .toolCall:
            break
        }
    }

    fileprivate mutating func modifyToolCall(_ body: (inout ToolCall) -> Void) {
        guard case var .toolCall(call) = self else { return }
        self = Self.vacant
        body(&call)
        self = .toolCall(call)
    }
}

/// The state of a chat, built by folding session updates and local events into display items.
///
/// A pure value: the owner feeds it updates in the order they arrived and renders `items`.
///
/// A `session/load` replay is folded between `beginReplay()` and `endReplay()`. Replays are
/// coarser than live turns (a message arrives as one chunk, a tool call as its final state), but
/// they end in the same content.
public struct ChatTranscript: Sendable, Equatable {
    enum Role {
        case user, agent, thought
    }

    public private(set) var items: [ChatItem] = []
    /// The agent's latest plan. Each plan update replaces the previous one.
    public private(set) var plan: [PlanEntry] = []
    public private(set) var availableCommands: [AvailableCommand] = []
    public private(set) var availableModes: [SessionMode] = []
    public private(set) var currentModeId: String?
    public private(set) var configOptions: [SessionConfigOption] = []
    public private(set) var usage: UsageUpdate?
    public private(set) var title: String?
    /// How the most recent turn ended, once it has. Nil after a turn that failed.
    public private(set) var lastStopReason: StopReason?

    /// Drops `user_message_chunk` updates outside a replay while set, which is the default. Live
    /// prompts are shown by `appendUserPrompt`; none of the Claude, Codex and OpenCode adapters
    /// echo them, but one that did would otherwise show every prompt twice.
    public var ignoresUserMessageChunks = true

    /// True between `beginReplay()` and `endReplay()`. The owner can use it to hold back side
    /// effects, such as notifications, for history.
    public private(set) var isReplaying = false

    private var toolCallIndices: [String: Int] = [:]
    private var lastAgentMessageIndex: Int?
    private var nextMessageNumber = 0
    /// Set at a turn's end, so the next turn's first chunk never continues the last message.
    private var startsNewMessage = false

    public init() {}

    /// The text of the latest agent message, for notifications and previews.
    public var lastAgentText: String? {
        lastAgentMessageIndex.flatMap { items[$0].message?.text }
    }

    // MARK: Updates from the agent

    public mutating func apply(_ update: SessionUpdate) {
        switch update {
        case let .userMessageChunk(chunk):
            guard isReplaying || !ignoresUserMessageChunks else { return }
            append(chunk, as: .user)
        case let .agentMessageChunk(chunk):
            append(chunk, as: .agent)
        case let .agentThoughtChunk(chunk):
            append(chunk, as: .thought)
        case let .toolCall(call):
            if let index = toolCallIndices[call.toolCallId] {
                items[index].modifyToolCall { existing in
                    // A re-announcement replaces the call but not output collected so far.
                    var replacement = call
                    if replacement.terminalOutput == nil { replacement.terminalOutput = existing.terminalOutput }
                    if replacement.terminalExitCode == nil { replacement.terminalExitCode = existing.terminalExitCode }
                    replacement.keepBackgroundState(of: existing)
                    existing = replacement
                }
            } else {
                appendItem(.toolCall(call))
                toolCallIndices[call.toolCallId] = items.count - 1
            }
            noteSubagentHandback(by: call.toolCallId)
        case let .toolCallUpdate(update):
            if let index = toolCallIndices[update.toolCallId] {
                items[index].modifyToolCall { $0.merge(update) }
            } else {
                // The announcement got lost or never came; the update is all there is to show.
                appendItem(.toolCall(update.asToolCall))
                toolCallIndices[update.toolCallId] = items.count - 1
            }
            noteSubagentHandback(by: update.toolCallId)
        case let .plan(entries):
            plan = entries
        case let .availableCommands(commands):
            availableCommands = commands
        case let .currentMode(modeId):
            currentModeId = modeId
        case let .configOptions(options):
            configOptions = options
        case let .sessionInfo(info):
            if let title = info.title { self.title = title }
        case let .usage(usage):
            self.usage = usage
        case .unknown:
            break
        }
    }

    /// Takes over the modes and config options a session reported when it started.
    public mutating func apply(_ setup: SessionSetup) {
        if let modes = setup.modes {
            availableModes = modes.availableModes
            currentModeId = modes.currentModeId
        }
        if let options = setup.configOptions {
            configOptions = options
        }
    }

    /// Takes over the config options `session/set_config_option` returned.
    public mutating func setConfigOptions(_ options: [SessionConfigOption]) {
        configOptions = options
    }

    /// Records a mode change once `session/set_mode` succeeded. Agents do not confirm it with a
    /// `current_mode_update`.
    public mutating func setCurrentMode(_ modeId: String) {
        currentModeId = modeId
    }

    /// The tool call with this id, for instance to fill in a permission request whose own tool
    /// call is nearly empty (Codex sends little more than the id).
    public func toolCall(id: String) -> ToolCall? {
        guard let index = toolCallIndices[id], case let .toolCall(call) = items[index] else { return nil }
        return call
    }

    // MARK: Local events

    /// Shows the user's prompt right away, as its own message.
    public mutating func appendUserPrompt(_ blocks: [ContentBlock]) {
        var message = makeMessage(messageId: nil)
        blocks.forEach { message.append($0) }
        appendItem(.userMessage(message))
    }

    /// Marks the end of a turn, with its stop reason or nil when the prompt failed.
    ///
    /// Tool calls still pending or running are marked cancelled whatever the reason: an agent
    /// sends no final update for a call that was rejected or cut short (Codex never does), and
    /// nothing can change them once the turn is over.
    public mutating func endTurn(_ reason: StopReason?) {
        lastStopReason = reason
        startsNewMessage = true
        markUnfinishedToolCallsCancelled()
    }

    /// Starts folding replayed history: user message chunks are taken from here on.
    public mutating func beginReplay() {
        isReplaying = true
        startsNewMessage = true
    }

    /// Ends the replay. Calls left unfinished in the history belong to turns long over.
    public mutating func endReplay() {
        isReplaying = false
        startsNewMessage = true
        markUnfinishedToolCallsCancelled()
        endBackgroundWork()
    }

    // MARK: Background work

    /// The calls whose command or subagent is still running: shells left in the background, and
    /// subagents, whether the turn waits for them or not. In the order they started.
    public var backgroundWork: [ToolCall] {
        items.compactMap { item in
            guard case let .toolCall(call) = item else { return nil }
            return call.isRunningInBackground || (call.startsSubagent && !call.status.isFinished) ? call : nil
        }
    }

    /// Takes everything left in the background as over. Nothing outlives the agent's process,
    /// and a replayed history only tells of work that was started, never of how it ended.
    public mutating func endBackgroundWork() {
        for index in toolCallIndices.values {
            items[index].modifyToolCall { call in
                if call.isRunningInBackground { call.backgroundWorkEnded = true }
            }
        }
    }

    /// A background subagent's last act is to hand its report back, which is the one sign of
    /// its end the agent gives. A subagent that is stopped or fails says nothing, and counts as
    /// running until the agent's process ends.
    private mutating func noteSubagentHandback(by id: String) {
        guard let index = toolCallIndices[id], case let .toolCall(call) = items[index],
              call.toolName == "SubagentHandback", call.status.isFinished,
              let parent = call.parentToolCallId, let parentIndex = toolCallIndices[parent]
        else { return }
        items[parentIndex].modifyToolCall { $0.backgroundWorkEnded = true }
    }

    /// After a cancel, calls that never finished will not finish; show them as cancelled.
    public mutating func markUnfinishedToolCallsCancelled() {
        for index in toolCallIndices.values {
            items[index].modifyToolCall { call in
                if !call.status.isFinished { call.status = .cancelled }
            }
        }
    }

    /// Shows one call as cancelled, unless it has finished already: the user refused it, and
    /// not every agent reports what became of it. A later update from the agent still counts.
    public mutating func markToolCallCancelled(id: String) {
        guard let index = toolCallIndices[id] else { return }
        items[index].modifyToolCall { call in
            if !call.status.isFinished { call.status = .cancelled }
        }
    }

    // MARK: Folding

    private mutating func append(_ chunk: ContentChunk, as role: Role) {
        if !startsNewMessage, let last = items.indices.last, items[last].role == role,
           Self.continues(items[last].message?.messageId, with: chunk.messageId)
        {
            items[last].modifyMessage { message in
                message.append(chunk.content)
                if message.messageId == nil { message.messageId = chunk.messageId }
            }
            return
        }
        var message = makeMessage(messageId: chunk.messageId)
        message.append(chunk.content)
        switch role {
        case .user: appendItem(.userMessage(message))
        case .agent: appendItem(.agentMessage(message))
        case .thought: appendItem(.agentThought(message))
        }
    }

    /// Chunks belong together unless both carry a message id and the ids differ. Agents that send
    /// no ids rely on the role change alone.
    private static func continues(_ current: String?, with next: String?) -> Bool {
        guard let current, let next else { return true }
        return current == next
    }

    private mutating func appendItem(_ item: ChatItem) {
        items.append(item)
        startsNewMessage = false
        if case .agentMessage = item { lastAgentMessageIndex = items.count - 1 }
    }

    private mutating func makeMessage(messageId: String?) -> ChatMessage {
        defer { nextMessageNumber += 1 }
        return ChatMessage(id: "message-\(nextMessageNumber)", messageId: messageId)
    }
}
