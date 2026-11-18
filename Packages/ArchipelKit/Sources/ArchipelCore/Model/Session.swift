import Foundation

public struct Session: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Default name ("Claude Code") or the name the user typed.
    public var title: String
    /// True once the user renamed the session; then the agent's title no longer overrides it.
    public var hasCustomTitle: Bool
    /// The title the agent set for its conversation through the terminal title, if any.
    public var agentTitle: String?
    public var agent: AgentKind
    /// The agent's own conversation id, used to resume after a relaunch.
    public var agentSessionID: String?
    /// Set on the tab a project script runs in, so Run finds that tab again after a relaunch. Only
    /// the kind is kept: the command is read from the project each time, and nothing runs by itself.
    public var script: ScriptKind?
    /// Set when the session was started on a non-default model. Stored so a resume after a
    /// relaunch stays on that model.
    public var model: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        hasCustomTitle: Bool = false,
        agentTitle: String? = nil,
        agent: AgentKind,
        agentSessionID: String? = nil,
        script: ScriptKind? = nil,
        model: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
        self.agentTitle = agentTitle
        self.agent = agent
        self.agentSessionID = agentSessionID
        self.script = script
        self.model = model
        self.createdAt = createdAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        hasCustomTitle = try c.decodeIfPresent(Bool.self, forKey: .hasCustomTitle) ?? false
        agentTitle = try c.decodeIfPresent(String.self, forKey: .agentTitle)
        agent = try c.decode(AgentKind.self, forKey: .agent)
        agentSessionID = try c.decodeIfPresent(String.self, forKey: .agentSessionID)
        // Read as a string so a kind added by a later version makes this a plain session instead of
        // failing the whole workspace file.
        script = try c.decodeIfPresent(String.self, forKey: .script).flatMap(ScriptKind.init(rawValue:))
        model = try c.decodeIfPresent(String.self, forKey: .model)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public var displayTitle: String {
        if hasCustomTitle { return title }
        if let agentTitle, !agentTitle.isEmpty { return agentTitle }
        return title
    }
}
