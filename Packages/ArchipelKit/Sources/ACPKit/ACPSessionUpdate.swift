import Foundation

/// Params of the agent's `session/update` notification.
public struct SessionNotification: Sendable, Hashable, Codable {
    public var sessionId: String
    public var update: SessionUpdate

    public init(sessionId: String, update: SessionUpdate) {
        self.sessionId = sessionId
        self.update = update
    }
}

/// Something that happened in a session, streamed by the agent while a turn runs or a session loads.
public enum SessionUpdate: Sendable, Hashable, Codable {
    case userMessageChunk(ContentChunk)
    case agentMessageChunk(ContentChunk)
    case agentThoughtChunk(ContentChunk)
    case toolCall(ToolCall)
    case toolCallUpdate(ToolCallUpdate)
    /// The whole plan; it replaces the previous one.
    case plan([PlanEntry])
    case availableCommands([AvailableCommand])
    case currentMode(modeId: String)
    /// The full list of config options.
    case configOptions([SessionConfigOption])
    case sessionInfo(SessionInfoUpdate)
    case usage(UsageUpdate)
    /// A variant this client does not know, with the whole update as sent.
    case unknown(kind: String, raw: JSONValue)

    private enum CodingKeys: String, CodingKey {
        case sessionUpdate, entries, availableCommands, currentModeId, configOptions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .sessionUpdate)
        switch kind {
        case "user_message_chunk":
            self = .userMessageChunk(try ContentChunk(from: decoder))
        case "agent_message_chunk":
            self = .agentMessageChunk(try ContentChunk(from: decoder))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(try ContentChunk(from: decoder))
        case "tool_call":
            self = .toolCall(try ToolCall(from: decoder))
        case "tool_call_update":
            self = .toolCallUpdate(try ToolCallUpdate(from: decoder))
        case "plan":
            self = .plan(container.lossyArray(PlanEntry.self, forKey: .entries) ?? [])
        case "available_commands_update":
            self = .availableCommands(container.lossyArray(AvailableCommand.self, forKey: .availableCommands) ?? [])
        case "current_mode_update":
            self = .currentMode(modeId: try container.decode(String.self, forKey: .currentModeId))
        case "config_option_update":
            self = .configOptions(container.lossyArray(SessionConfigOption.self, forKey: .configOptions) ?? [])
        case "session_info_update":
            self = .sessionInfo(try SessionInfoUpdate(from: decoder))
        case "usage_update":
            self = .usage(try UsageUpdate(from: decoder))
        default:
            self = .unknown(kind: kind, raw: try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case let .unknown(_, raw) = self {
            return try raw.encode(to: encoder)
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .sessionUpdate)
        switch self {
        case let .userMessageChunk(chunk), let .agentMessageChunk(chunk), let .agentThoughtChunk(chunk):
            try chunk.encode(to: encoder)
        case let .toolCall(call):
            try call.encode(to: encoder)
        case let .toolCallUpdate(update):
            try update.encode(to: encoder)
        case let .plan(entries):
            try container.encode(entries, forKey: .entries)
        case let .availableCommands(commands):
            try container.encode(commands, forKey: .availableCommands)
        case let .currentMode(modeId):
            try container.encode(modeId, forKey: .currentModeId)
        case let .configOptions(options):
            try container.encode(options, forKey: .configOptions)
        case let .sessionInfo(info):
            try info.encode(to: encoder)
        case let .usage(usage):
            try usage.encode(to: encoder)
        case .unknown:
            break
        }
    }

    /// The `sessionUpdate` discriminator.
    public var kind: String {
        switch self {
        case .userMessageChunk: "user_message_chunk"
        case .agentMessageChunk: "agent_message_chunk"
        case .agentThoughtChunk: "agent_thought_chunk"
        case .toolCall: "tool_call"
        case .toolCallUpdate: "tool_call_update"
        case .plan: "plan"
        case .availableCommands: "available_commands_update"
        case .currentMode: "current_mode_update"
        case .configOptions: "config_option_update"
        case .sessionInfo: "session_info_update"
        case .usage: "usage_update"
        case let .unknown(kind, _): kind
        }
    }
}

/// One streamed piece of a user, agent or thought message.
public struct ContentChunk: Sendable, Hashable, Codable {
    public var content: ContentBlock
    /// Groups chunks into messages when the agent sends it; a new id starts a new message.
    public var messageId: String?
    public var meta: JSONValue?

    public init(content: ContentBlock, messageId: String? = nil, meta: JSONValue? = nil) {
        self.content = content
        self.messageId = messageId
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case content, messageId
        case meta = "_meta"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(ContentBlock.self, forKey: .content)
        messageId = container.lenient(String.self, forKey: .messageId)
        meta = container.lenient(JSONValue.self, forKey: .meta)
    }
}

// MARK: - Tool calls

public enum ToolKind: String, Sendable, Hashable, Codable, CaseIterable {
    case read
    case edit
    case delete
    case move
    case search
    case execute
    case think
    case fetch
    case switchMode = "switch_mode"
    case other

    public init(from decoder: any Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(Self.init(rawValue:)) ?? .other
    }
}

public enum ToolCallStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
    /// Not sent by agents: the client marks calls that were still running when the user cancelled.
    case cancelled

    public init(from decoder: any Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        // Something new is most likely a flavour of still running; claiming it finished would be worse.
        self = raw.flatMap(Self.init(rawValue:)) ?? .inProgress
    }

    public var isFinished: Bool {
        switch self {
        case .pending, .inProgress: false
        case .completed, .failed, .cancelled: true
        }
    }
}

/// What a tool call produced or proposes.
public enum ToolCallContent: Sendable, Hashable, Codable {
    case content(ContentBlock)
    case diff(path: String, oldText: String?, newText: String)
    /// Output of a terminal the client created. This client creates none, so it only shows the id.
    case terminal(terminalId: String)
    case unknown(JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type, content, path, oldText, newText, terminalId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch container.lenient(String.self, forKey: .type) {
        case "content":
            self = .content(try container.decode(ContentBlock.self, forKey: .content))
        case "diff":
            self = .diff(
                path: try container.decode(String.self, forKey: .path),
                oldText: container.lenient(String.self, forKey: .oldText),
                newText: container.lenient(String.self, forKey: .newText) ?? ""
            )
        case "terminal":
            self = .terminal(terminalId: try container.decode(String.self, forKey: .terminalId))
        default:
            self = .unknown(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case let .unknown(raw) = self {
            return try raw.encode(to: encoder)
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .content(block):
            try container.encode("content", forKey: .type)
            try container.encode(block, forKey: .content)
        case let .diff(path, oldText, newText):
            try container.encode("diff", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(oldText, forKey: .oldText)
            try container.encode(newText, forKey: .newText)
        case let .terminal(terminalId):
            try container.encode("terminal", forKey: .type)
            try container.encode(terminalId, forKey: .terminalId)
        case .unknown:
            break
        }
    }
}

public struct ToolCallLocation: Sendable, Hashable, Codable {
    public var path: String
    public var line: Int?

    public init(path: String, line: Int? = nil) {
        self.path = path
        self.line = line
    }

    private enum CodingKeys: String, CodingKey { case path, line }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        line = container.lenient(Int.self, forKey: .line)
    }
}

/// A tool call as a whole, as `tool_call` announces it.
public struct ToolCall: Sendable, Hashable, Codable, Identifiable {
    public var toolCallId: String
    public var title: String
    public var kind: ToolKind
    public var status: ToolCallStatus
    public var content: [ToolCallContent]
    public var locations: [ToolCallLocation]
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?
    /// The agent's `_meta`, as last sent.
    public var meta: JSONValue?
    /// Command output collected from `_meta.terminal_output_delta`. Codex streams shell output
    /// there instead of as content; nil when the agent sent none. Not part of the protocol shape.
    public var terminalOutput: String?
    /// The exit code from `_meta.terminal_exit`, when the agent reported one.
    public var terminalExitCode: Int?

    public var id: String { toolCallId }

    public init(
        toolCallId: String,
        title: String,
        kind: ToolKind = .other,
        status: ToolCallStatus = .pending,
        content: [ToolCallContent] = [],
        locations: [ToolCallLocation] = [],
        rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil,
        meta: JSONValue? = nil,
        terminalOutput: String? = nil,
        terminalExitCode: Int? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.meta = meta
        self.terminalOutput = terminalOutput
        self.terminalExitCode = terminalExitCode
    }

    private enum CodingKeys: String, CodingKey {
        case toolCallId, title, kind, status, content, locations, rawInput, rawOutput
        case meta = "_meta"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        title = container.lenient(String.self, forKey: .title) ?? ""
        kind = container.lenient(ToolKind.self, forKey: .kind) ?? .other
        status = container.lenient(ToolCallStatus.self, forKey: .status) ?? .pending
        content = container.lossyArray(ToolCallContent.self, forKey: .content) ?? []
        locations = container.lossyArray(ToolCallLocation.self, forKey: .locations) ?? []
        rawInput = container.lenient(JSONValue.self, forKey: .rawInput)
        rawOutput = container.lenient(JSONValue.self, forKey: .rawOutput)
        meta = container.lenient(JSONValue.self, forKey: .meta)
        absorbTerminalMeta(meta)
    }

    /// Takes over every field the update carries and keeps the rest. Claude streams a call as
    /// several updates that each fill in some fields, often without a status.
    public mutating func merge(_ update: ToolCallUpdate) {
        if let title = update.title { self.title = title }
        if let kind = update.kind { self.kind = kind }
        if let status = update.status { self.status = status }
        if let content = update.content { self.content = content }
        if let locations = update.locations { self.locations = locations }
        if let rawInput = update.rawInput { self.rawInput = rawInput }
        if let rawOutput = update.rawOutput { self.rawOutput = rawOutput }
        if let meta = update.meta { self.meta = meta }
        absorbTerminalMeta(update.meta)
    }

    private mutating func absorbTerminalMeta(_ meta: JSONValue?) {
        guard let meta else { return }
        if let delta = meta["terminal_output_delta"]?["data"]?.stringValue {
            terminalOutput = (terminalOutput ?? "") + delta
        }
        if let exitCode = meta["terminal_exit"]?["exit_code"]?.intValue {
            terminalExitCode = exitCode
        }
    }
}

/// A change to a tool call. Only the id is required; fields that are present replace the old values.
public struct ToolCallUpdate: Sendable, Hashable, Codable, Identifiable {
    public var toolCallId: String
    public var title: String?
    public var kind: ToolKind?
    public var status: ToolCallStatus?
    public var content: [ToolCallContent]?
    public var locations: [ToolCallLocation]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?
    public var meta: JSONValue?

    public var id: String { toolCallId }

    public init(
        toolCallId: String,
        title: String? = nil,
        kind: ToolKind? = nil,
        status: ToolCallStatus? = nil,
        content: [ToolCallContent]? = nil,
        locations: [ToolCallLocation]? = nil,
        rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil,
        meta: JSONValue? = nil
    ) {
        self.meta = meta
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }

    private enum CodingKeys: String, CodingKey {
        case toolCallId, title, kind, status, content, locations, rawInput, rawOutput
        case meta = "_meta"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        meta = container.lenient(JSONValue.self, forKey: .meta)
        title = container.lenient(String.self, forKey: .title)
        kind = container.lenient(ToolKind.self, forKey: .kind)
        status = container.lenient(ToolCallStatus.self, forKey: .status)
        content = container.lossyArray(ToolCallContent.self, forKey: .content)
        locations = container.lossyArray(ToolCallLocation.self, forKey: .locations)
        // Null reads as absent: there is no way to tell "cleared" from "unchanged" that agents agree on.
        rawInput = container.lenient(JSONValue.self, forKey: .rawInput).flatMap { $0.isNull ? nil : $0 }
        rawOutput = container.lenient(JSONValue.self, forKey: .rawOutput).flatMap { $0.isNull ? nil : $0 }
    }

    /// A full tool call built from this update, for an id the client has not seen announced.
    public var asToolCall: ToolCall {
        var call = ToolCall(toolCallId: toolCallId, title: "")
        call.merge(self)
        return call
    }
}

// MARK: - Plan, commands, info, usage

public enum PlanEntryPriority: String, Sendable, Hashable, Codable, CaseIterable {
    case high
    case medium
    case low

    public init(from decoder: any Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(Self.init(rawValue:)) ?? .medium
    }
}

public enum PlanEntryStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed

    public init(from decoder: any Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(Self.init(rawValue:)) ?? .pending
    }
}

public struct PlanEntry: Sendable, Hashable, Codable {
    public var content: String
    public var priority: PlanEntryPriority
    public var status: PlanEntryStatus

    public init(content: String, priority: PlanEntryPriority = .medium, status: PlanEntryStatus = .pending) {
        self.content = content
        self.priority = priority
        self.status = status
    }

    private enum CodingKeys: String, CodingKey { case content, priority, status }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(String.self, forKey: .content)
        priority = container.lenient(PlanEntryPriority.self, forKey: .priority) ?? .medium
        status = container.lenient(PlanEntryStatus.self, forKey: .status) ?? .pending
    }
}

/// A slash command the agent accepts. Commands are sent as ordinary prompt text, like `/compact`.
public struct AvailableCommand: Sendable, Hashable, Codable, Identifiable {
    public var name: String
    public var description: String
    /// Placeholder text for the command's argument, when it takes one.
    public var inputHint: String?

    public var id: String { name }

    public init(name: String, description: String, inputHint: String? = nil) {
        self.name = name
        self.description = description
        self.inputHint = inputHint
    }

    private enum CodingKeys: String, CodingKey { case name, description, input }
    private enum InputKeys: String, CodingKey { case hint }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = container.lenient(String.self, forKey: .description) ?? ""
        inputHint = (try? container.nestedContainer(keyedBy: InputKeys.self, forKey: .input))?.lenient(String.self, forKey: .hint)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        if let inputHint {
            var input = container.nestedContainer(keyedBy: InputKeys.self, forKey: .input)
            try input.encode(inputHint, forKey: .hint)
        }
    }
}

public struct SessionInfoUpdate: Sendable, Hashable, Codable {
    /// Absent in most updates; Codex sends many carrying only `_meta`. Absent never means cleared.
    public var title: String?
    public var updatedAt: String?
    public var meta: JSONValue?

    public init(title: String? = nil, updatedAt: String? = nil, meta: JSONValue? = nil) {
        self.title = title
        self.updatedAt = updatedAt
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case title, updatedAt
        case meta = "_meta"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.lenient(String.self, forKey: .title)
        updatedAt = container.lenient(String.self, forKey: .updatedAt)
        meta = container.lenient(JSONValue.self, forKey: .meta)
    }
}

/// Context window use, in tokens.
public struct UsageUpdate: Sendable, Hashable, Codable {
    public struct Cost: Sendable, Hashable, Codable {
        public var amount: Double
        public var currency: String

        public init(amount: Double, currency: String) {
            self.amount = amount
            self.currency = currency
        }
    }

    public var used: Int
    public var size: Int
    public var cost: Cost?
    public var meta: JSONValue?

    public init(used: Int, size: Int, cost: Cost? = nil, meta: JSONValue? = nil) {
        self.used = used
        self.size = size
        self.cost = cost
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case used, size, cost
        case meta = "_meta"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        used = try container.decode(Int.self, forKey: .used)
        size = try container.decode(Int.self, forKey: .size)
        cost = container.lenient(Cost.self, forKey: .cost)
        meta = container.lenient(JSONValue.self, forKey: .meta)
    }
}
