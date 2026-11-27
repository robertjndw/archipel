import Foundation

/// Method names this client sends or answers.
public enum ACPMethod {
    public static let initialize = "initialize"
    public static let authenticate = "authenticate"
    public static let sessionNew = "session/new"
    public static let sessionLoad = "session/load"
    public static let sessionResume = "session/resume"
    public static let sessionClose = "session/close"
    public static let sessionPrompt = "session/prompt"
    public static let sessionCancel = "session/cancel"
    public static let sessionSetMode = "session/set_mode"
    public static let sessionSetConfigOption = "session/set_config_option"
    public static let sessionUpdate = "session/update"
    public static let sessionRequestPermission = "session/request_permission"
}

// MARK: - Initialization

/// Name and version of either side.
public struct Implementation: Sendable, Hashable, Codable {
    public var name: String
    public var title: String?
    public var version: String

    public init(name: String, title: String? = nil, version: String) {
        self.name = name
        self.title = title
        self.version = version
    }

    private enum CodingKeys: String, CodingKey { case name, title, version }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.lenient(String.self, forKey: .name) ?? ""
        title = container.lenient(String.self, forKey: .title)
        version = container.lenient(String.self, forKey: .version) ?? ""
    }
}

public struct ClientCapabilities: Sendable, Hashable, Codable {
    public struct FileSystem: Sendable, Hashable, Codable {
        public var readTextFile: Bool
        public var writeTextFile: Bool

        public init(readTextFile: Bool = false, writeTextFile: Bool = false) {
            self.readTextFile = readTextFile
            self.writeTextFile = writeTextFile
        }
    }

    public struct Auth: Sendable, Hashable, Codable {
        /// The client can run terminal-type auth methods.
        public var terminal: Bool

        public init(terminal: Bool = false) {
            self.terminal = terminal
        }
    }

    public var fs: FileSystem
    public var terminal: Bool
    public var auth: Auth
    /// Extensions outside the protocol, which an agent that knows them acts on.
    public var meta: JSONValue?

    public init(fs: FileSystem = FileSystem(), terminal: Bool = false, auth: Auth = Auth(), meta: JSONValue? = nil) {
        self.fs = fs
        self.terminal = terminal
        self.auth = auth
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case fs, terminal, auth
        case meta = "_meta"
    }
}

public struct InitializeRequest: Sendable, Hashable, Codable {
    public var protocolVersion: Int
    public var clientCapabilities: ClientCapabilities
    public var clientInfo: Implementation?

    public init(protocolVersion: Int, clientCapabilities: ClientCapabilities, clientInfo: Implementation?) {
        self.protocolVersion = protocolVersion
        self.clientCapabilities = clientCapabilities
        self.clientInfo = clientInfo
    }
}

public struct AgentCapabilities: Sendable, Hashable, Codable {
    public struct Prompt: Sendable, Hashable, Codable {
        public var image: Bool
        public var audio: Bool
        public var embeddedContext: Bool

        public init(image: Bool = false, audio: Bool = false, embeddedContext: Bool = false) {
            self.image = image
            self.audio = audio
            self.embeddedContext = embeddedContext
        }

        private enum CodingKeys: String, CodingKey { case image, audio, embeddedContext }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            image = container.capability(.image)
            audio = container.capability(.audio)
            embeddedContext = container.capability(.embeddedContext)
        }
    }

    public struct MCP: Sendable, Hashable, Codable {
        public var http: Bool
        public var sse: Bool

        public init(http: Bool = false, sse: Bool = false) {
            self.http = http
            self.sse = sse
        }

        private enum CodingKeys: String, CodingKey { case http, sse }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            http = container.capability(.http)
            sse = container.capability(.sse)
        }
    }

    /// Which optional session methods the agent has. Only `list`, `resume`, `close` and `delete`
    /// are stable spec; the rest are seen on the current Claude and Codex adapters.
    public struct Session: Sendable, Hashable, Codable {
        public var list: Bool
        public var resume: Bool
        public var close: Bool
        public var delete: Bool
        public var fork: Bool
        public var title: Bool
        public var additionalDirectories: Bool
        public var systemPrompt: Bool
        public var options: Bool
        public var status: Bool

        public init(
            list: Bool = false,
            resume: Bool = false,
            close: Bool = false,
            delete: Bool = false,
            fork: Bool = false,
            title: Bool = false,
            additionalDirectories: Bool = false,
            systemPrompt: Bool = false,
            options: Bool = false,
            status: Bool = false
        ) {
            self.list = list
            self.resume = resume
            self.close = close
            self.delete = delete
            self.fork = fork
            self.title = title
            self.additionalDirectories = additionalDirectories
            self.systemPrompt = systemPrompt
            self.options = options
            self.status = status
        }

        private enum CodingKeys: String, CodingKey {
            case list, resume, close, delete, fork, title, additionalDirectories, systemPrompt, options, status
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            list = container.capability(.list)
            resume = container.capability(.resume)
            close = container.capability(.close)
            delete = container.capability(.delete)
            fork = container.capability(.fork)
            title = container.capability(.title)
            additionalDirectories = container.capability(.additionalDirectories)
            systemPrompt = container.capability(.systemPrompt)
            options = container.capability(.options)
            status = container.capability(.status)
        }
    }

    public struct Auth: Sendable, Hashable, Codable {
        public var logout: Bool
        public var status: Bool

        public init(logout: Bool = false, status: Bool = false) {
            self.logout = logout
            self.status = status
        }

        private enum CodingKeys: String, CodingKey { case logout, status }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            logout = container.capability(.logout)
            status = container.capability(.status)
        }
    }

    public var loadSession: Bool
    public var promptCapabilities: Prompt
    public var mcpCapabilities: MCP
    public var sessionCapabilities: Session
    public var auth: Auth

    public init(
        loadSession: Bool = false,
        promptCapabilities: Prompt = Prompt(),
        mcpCapabilities: MCP = MCP(),
        sessionCapabilities: Session = Session(),
        auth: Auth = Auth()
    ) {
        self.loadSession = loadSession
        self.promptCapabilities = promptCapabilities
        self.mcpCapabilities = mcpCapabilities
        self.sessionCapabilities = sessionCapabilities
        self.auth = auth
    }

    private enum CodingKeys: String, CodingKey {
        case loadSession, promptCapabilities, mcpCapabilities, sessionCapabilities, auth
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        loadSession = container.capability(.loadSession)
        promptCapabilities = container.lenient(Prompt.self, forKey: .promptCapabilities) ?? Prompt()
        mcpCapabilities = container.lenient(MCP.self, forKey: .mcpCapabilities) ?? MCP()
        sessionCapabilities = container.lenient(Session.self, forKey: .sessionCapabilities) ?? Session()
        auth = container.lenient(Auth.self, forKey: .auth) ?? Auth()
    }
}

public struct InitializeResponse: Sendable, Hashable, Codable {
    public var protocolVersion: Int
    public var agentCapabilities: AgentCapabilities
    public var agentInfo: Implementation?
    public var authMethods: [AuthMethod]

    public init(protocolVersion: Int, agentCapabilities: AgentCapabilities = AgentCapabilities(), agentInfo: Implementation? = nil, authMethods: [AuthMethod] = []) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.agentInfo = agentInfo
        self.authMethods = authMethods
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, agentCapabilities, agentInfo, authMethods
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        agentCapabilities = container.lenient(AgentCapabilities.self, forKey: .agentCapabilities) ?? AgentCapabilities()
        agentInfo = container.lenient(Implementation.self, forKey: .agentInfo)
        authMethods = container.lossyArray(AuthMethod.self, forKey: .authMethods) ?? []
    }
}

// MARK: - Authentication

public enum AuthMethodType: OpenStringEnum {
    /// The client calls `authenticate` and the agent does the rest.
    case agent
    /// The client runs the agent with the method's `args` and `env` in a terminal for the user.
    case terminal
    case unknown(String)

    public init(rawString: String) {
        switch rawString {
        case "agent": self = .agent
        case "terminal": self = .terminal
        default: self = .unknown(rawString)
        }
    }

    public var rawString: String {
        switch self {
        case .agent: "agent"
        case .terminal: "terminal"
        case let .unknown(value): value
        }
    }
}

public struct AuthMethod: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var description: String?
    public var type: AuthMethodType
    public var args: [String]
    public var env: [String: String]

    public init(id: String, name: String, description: String? = nil, type: AuthMethodType = .agent, args: [String] = [], env: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
        self.args = args
        self.env = env
    }

    private enum CodingKeys: String, CodingKey { case id, name, description, type, args, env }

    private struct Variable: Decodable {
        let name: String
        let value: String
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = container.lenient(String.self, forKey: .name) ?? id
        description = container.lenient(String.self, forKey: .description)
        type = container.lenient(AuthMethodType.self, forKey: .type) ?? .agent
        args = container.lenient([String].self, forKey: .args) ?? []
        // Seen both as a plain map and as a list of name/value pairs.
        if let map = container.lenient([String: String].self, forKey: .env) {
            env = map
        } else if let pairs = container.lossyArray(Variable.self, forKey: .env) {
            env = Dictionary(pairs.map { ($0.name, $0.value) }) { _, last in last }
        } else {
            env = [:]
        }
    }
}

public struct AuthenticateRequest: Sendable, Hashable, Codable {
    public var methodId: String

    public init(methodId: String) {
        self.methodId = methodId
    }
}

// MARK: - Sessions

/// MCP servers the agent should connect to. This client never passes any, but the field is required.
public typealias MCPServer = JSONValue

public struct NewSessionRequest: Sendable, Hashable, Codable {
    public var cwd: String
    public var mcpServers: [MCPServer]

    public init(cwd: String, mcpServers: [MCPServer] = []) {
        self.cwd = cwd
        self.mcpServers = mcpServers
    }
}

/// The modes and config options a session reports when it starts, loads or resumes.
public struct SessionSetup: Sendable, Hashable, Codable {
    public var modes: SessionModeState?
    public var configOptions: [SessionConfigOption]?

    public init(modes: SessionModeState? = nil, configOptions: [SessionConfigOption]? = nil) {
        self.modes = modes
        self.configOptions = configOptions
    }

    private enum CodingKeys: String, CodingKey { case modes, configOptions }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modes = container.lenient(SessionModeState.self, forKey: .modes)
        configOptions = container.lossyArray(SessionConfigOption.self, forKey: .configOptions)
    }
}

public struct NewSessionResponse: Sendable, Hashable, Codable {
    public var sessionId: String
    public var modes: SessionModeState?
    public var configOptions: [SessionConfigOption]?

    public init(sessionId: String, modes: SessionModeState? = nil, configOptions: [SessionConfigOption]? = nil) {
        self.sessionId = sessionId
        self.modes = modes
        self.configOptions = configOptions
    }

    private enum CodingKeys: String, CodingKey { case sessionId, modes, configOptions }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        modes = container.lenient(SessionModeState.self, forKey: .modes)
        configOptions = container.lossyArray(SessionConfigOption.self, forKey: .configOptions)
    }

    public var setup: SessionSetup { SessionSetup(modes: modes, configOptions: configOptions) }
}

/// Parameters of `session/load` and `session/resume`, which take the same shape.
public struct ExistingSessionRequest: Sendable, Hashable, Codable {
    public var sessionId: String
    public var cwd: String
    public var mcpServers: [MCPServer]

    public init(sessionId: String, cwd: String, mcpServers: [MCPServer] = []) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.mcpServers = mcpServers
    }
}

public struct SessionIdParams: Sendable, Hashable, Codable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// MARK: - Prompt turn

public struct PromptRequest: Sendable, Hashable, Codable {
    public var sessionId: String
    public var prompt: [ContentBlock]

    public init(sessionId: String, prompt: [ContentBlock]) {
        self.sessionId = sessionId
        self.prompt = prompt
    }
}

/// Why the agent ended a turn.
public enum StopReason: OpenStringEnum {
    case endTurn
    case maxTokens
    case maxTurnRequests
    case refusal
    case cancelled
    case unknown(String)

    public init(rawString: String) {
        switch rawString {
        case "end_turn": self = .endTurn
        case "max_tokens": self = .maxTokens
        case "max_turn_requests": self = .maxTurnRequests
        case "refusal": self = .refusal
        case "cancelled": self = .cancelled
        default: self = .unknown(rawString)
        }
    }

    public var rawString: String {
        switch self {
        case .endTurn: "end_turn"
        case .maxTokens: "max_tokens"
        case .maxTurnRequests: "max_turn_requests"
        case .refusal: "refusal"
        case .cancelled: "cancelled"
        case let .unknown(value): value
        }
    }
}

public struct PromptResponse: Sendable, Hashable, Codable {
    public var stopReason: StopReason
    /// Token counts for the turn. Not in the spec yet and shaped differently per agent, so kept raw.
    public var usage: JSONValue?
    public var meta: JSONValue?

    public init(stopReason: StopReason, usage: JSONValue? = nil, meta: JSONValue? = nil) {
        self.stopReason = stopReason
        self.usage = usage
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case stopReason, usage
        case meta = "_meta"
    }

    public init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        // A turn that ended is what matters; an agent that leaves out the reason still ended it.
        stopReason = container?.lenient(StopReason.self, forKey: .stopReason) ?? .endTurn
        usage = container?.lenient(JSONValue.self, forKey: .usage).flatMap { $0.isNull ? nil : $0 }
        meta = container?.lenient(JSONValue.self, forKey: .meta)
    }
}

// MARK: - Modes and config options

public struct SessionMode: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }

    private enum CodingKeys: String, CodingKey { case id, name, description }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = container.lenient(String.self, forKey: .name) ?? id
        description = container.lenient(String.self, forKey: .description)
    }
}

public struct SessionModeState: Sendable, Hashable, Codable {
    public var currentModeId: String
    public var availableModes: [SessionMode]

    public init(currentModeId: String, availableModes: [SessionMode]) {
        self.currentModeId = currentModeId
        self.availableModes = availableModes
    }

    private enum CodingKeys: String, CodingKey { case currentModeId, availableModes }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentModeId = try container.decode(String.self, forKey: .currentModeId)
        availableModes = container.lossyArray(SessionMode.self, forKey: .availableModes) ?? []
    }
}

public struct SetModeRequest: Sendable, Hashable, Codable {
    public var sessionId: String
    public var modeId: String

    public init(sessionId: String, modeId: String) {
        self.sessionId = sessionId
        self.modeId = modeId
    }
}

public enum ConfigOptionCategory: OpenStringEnum {
    case mode
    case model
    case modelConfig
    case thoughtLevel
    case custom
    case unknown(String)

    public init(rawString: String) {
        switch rawString {
        case "mode": self = .mode
        case "model": self = .model
        case "model_config": self = .modelConfig
        case "thought_level": self = .thoughtLevel
        case "custom": self = .custom
        default: self = .unknown(rawString)
        }
    }

    public var rawString: String {
        switch self {
        case .mode: "mode"
        case .model: "model"
        case .modelConfig: "model_config"
        case .thoughtLevel: "thought_level"
        case .custom: "custom"
        case let .unknown(value): value
        }
    }
}

/// One choice of a select config option.
public struct ConfigOptionValue: Sendable, Hashable, Codable {
    public var value: String
    public var name: String
    public var description: String?

    public init(value: String, name: String, description: String? = nil) {
        self.value = value
        self.name = name
        self.description = description
    }

    private enum CodingKeys: String, CodingKey { case value, name, description }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(String.self, forKey: .value)
        name = container.lenient(String.self, forKey: .name) ?? value
        description = container.lenient(String.self, forKey: .description)
    }
}

public struct ConfigOptionGroup: Sendable, Hashable, Codable {
    public var group: String
    public var name: String
    public var options: [ConfigOptionValue]

    public init(group: String, name: String, options: [ConfigOptionValue]) {
        self.group = group
        self.name = name
        self.options = options
    }

    private enum CodingKeys: String, CodingKey { case group, name, options }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        group = try container.decode(String.self, forKey: .group)
        name = container.lenient(String.self, forKey: .name) ?? group
        options = container.lossyArray(ConfigOptionValue.self, forKey: .options) ?? []
    }
}

/// The choices of a select option, either as one list or in named groups.
public enum ConfigOptionChoices: Sendable, Hashable, Codable {
    case flat([ConfigOptionValue])
    case grouped([ConfigOptionGroup])

    /// Every choice, groups flattened in order.
    public var allValues: [ConfigOptionValue] {
        switch self {
        case let .flat(values): values
        case let .grouped(groups): groups.flatMap(\.options)
        }
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [ConfigOptionValue] = []
        var groups: [ConfigOptionGroup] = []
        while !container.isAtEnd {
            let element = try container.decode(JSONValue.self)
            if element["group"] != nil, let group = try? element.decode(as: ConfigOptionGroup.self) {
                groups.append(group)
            } else if let value = try? element.decode(as: ConfigOptionValue.self) {
                values.append(value)
            }
        }
        self = groups.isEmpty ? .flat(values) : .grouped(groups)
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .flat(values): try values.encode(to: encoder)
        case let .grouped(groups): try groups.encode(to: encoder)
        }
    }
}

public enum ConfigOptionKind: String, Sendable, Hashable, Codable {
    case select
    case boolean
}

/// A session setting the agent exposes, such as its model or mode. Options of a type this client
/// does not know are dropped while decoding, as the protocol asks.
public struct SessionConfigOption: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var category: ConfigOptionCategory?
    public var type: ConfigOptionKind
    /// A choice's `value` for select options, a bool for boolean ones.
    public var currentValue: JSONValue
    /// Empty for boolean options.
    public var options: ConfigOptionChoices

    public init(
        id: String,
        name: String,
        description: String? = nil,
        category: ConfigOptionCategory? = nil,
        type: ConfigOptionKind,
        currentValue: JSONValue,
        options: ConfigOptionChoices = .flat([])
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.type = type
        self.currentValue = currentValue
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, category, type, currentValue, options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(ConfigOptionKind.self, forKey: .type)
        name = container.lenient(String.self, forKey: .name) ?? id
        description = container.lenient(String.self, forKey: .description)
        category = container.lenient(ConfigOptionCategory.self, forKey: .category)
        currentValue = container.lenient(JSONValue.self, forKey: .currentValue) ?? .null
        options = container.lenient(ConfigOptionChoices.self, forKey: .options) ?? .flat([])
    }
}

public struct SetConfigOptionRequest: Sendable, Hashable, Codable {
    public var sessionId: String
    public var configId: String
    public var value: JSONValue

    public init(sessionId: String, configId: String, value: JSONValue) {
        self.sessionId = sessionId
        self.configId = configId
        self.value = value
    }
}

public struct SetConfigOptionResponse: Sendable, Hashable, Codable {
    public var configOptions: [SessionConfigOption]

    public init(configOptions: [SessionConfigOption]) {
        self.configOptions = configOptions
    }

    private enum CodingKeys: String, CodingKey { case configOptions }

    public init(from decoder: any Decoder) throws {
        configOptions = (try? decoder.container(keyedBy: CodingKeys.self).lossyArray(SessionConfigOption.self, forKey: .configOptions)) ?? []
    }
}

// MARK: - Permission

public enum PermissionOptionKind: OpenStringEnum {
    case allowOnce
    case allowAlways
    case rejectOnce
    case rejectAlways
    case unknown(String)

    public init(rawString: String) {
        switch rawString {
        case "allow_once": self = .allowOnce
        case "allow_always": self = .allowAlways
        case "reject_once": self = .rejectOnce
        case "reject_always": self = .rejectAlways
        default: self = .unknown(rawString)
        }
    }

    public var rawString: String {
        switch self {
        case .allowOnce: "allow_once"
        case .allowAlways: "allow_always"
        case .rejectOnce: "reject_once"
        case .rejectAlways: "reject_always"
        case let .unknown(value): value
        }
    }

    public var isAllow: Bool {
        switch self {
        case .allowOnce, .allowAlways: true
        default: false
        }
    }
}

public struct PermissionOption: Sendable, Hashable, Codable, Identifiable {
    public var optionId: String
    public var name: String
    public var kind: PermissionOptionKind

    public var id: String { optionId }

    public init(optionId: String, name: String, kind: PermissionOptionKind) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case optionId, name, kind }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        optionId = try container.decode(String.self, forKey: .optionId)
        name = container.lenient(String.self, forKey: .name) ?? optionId
        kind = container.lenient(PermissionOptionKind.self, forKey: .kind) ?? .unknown("")
    }
}

/// Params of the agent's `session/request_permission` request.
public struct RequestPermissionRequest: Sendable, Hashable, Codable {
    public var sessionId: String
    public var toolCall: ToolCallUpdate
    public var options: [PermissionOption]

    public init(sessionId: String, toolCall: ToolCallUpdate, options: [PermissionOption]) {
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.options = options
    }

    private enum CodingKeys: String, CodingKey { case sessionId, toolCall, options }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        toolCall = try container.decode(ToolCallUpdate.self, forKey: .toolCall)
        options = container.lossyArray(PermissionOption.self, forKey: .options) ?? []
    }
}

/// The user's answer to a permission request.
public enum RequestPermissionOutcome: Sendable, Hashable, Codable {
    /// The turn was cancelled before the user chose. Required for every open request after `session/cancel`.
    case cancelled
    case selected(optionId: String)

    private enum CodingKeys: String, CodingKey { case outcome, optionId }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .outcome) {
        case "selected":
            self = .selected(optionId: try container.decode(String.self, forKey: .optionId))
        default:
            self = .cancelled
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cancelled:
            try container.encode("cancelled", forKey: .outcome)
        case let .selected(optionId):
            try container.encode("selected", forKey: .outcome)
            try container.encode(optionId, forKey: .optionId)
        }
    }
}

public struct RequestPermissionResponse: Sendable, Hashable, Codable {
    public var outcome: RequestPermissionOutcome

    public init(outcome: RequestPermissionOutcome) {
        self.outcome = outcome
    }
}

/// An empty result, for methods that answer `{}`. Decodes from anything, null included.
public struct EmptyResult: Sendable, Hashable, Codable {
    public init() {}

    public init(from decoder: any Decoder) throws {}

    public func encode(to encoder: any Encoder) throws {
        _ = encoder.container(keyedBy: JSONValueKey.self)
    }
}

struct JSONValueKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}
