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
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        hasCustomTitle: Bool = false,
        agentTitle: String? = nil,
        agent: AgentKind,
        agentSessionID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
        self.agentTitle = agentTitle
        self.agent = agent
        self.agentSessionID = agentSessionID
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
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public var displayTitle: String {
        if hasCustomTitle { return title }
        if let agentTitle, !agentTitle.isEmpty { return agentTitle }
        return title
    }
}
