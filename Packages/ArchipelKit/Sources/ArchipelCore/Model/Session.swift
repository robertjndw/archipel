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
    /// Copied from the preset the session was started from, so editing or deleting the preset
    /// later doesn't affect it. Nil means it follows the agent's default preset, also on resume.
    public var arguments: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        hasCustomTitle: Bool = false,
        agentTitle: String? = nil,
        agent: AgentKind,
        agentSessionID: String? = nil,
        script: ScriptKind? = nil,
        arguments: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
        self.agentTitle = agentTitle
        self.agent = agent
        self.agentSessionID = agentSessionID
        self.script = script
        self.arguments = arguments
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
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public var displayTitle: String {
        if hasCustomTitle { return title }
        if let agentTitle, !agentTitle.isEmpty { return agentTitle }
        return title
    }

    /// The title of a new session of an agent, numbered among `siblings`, that agent's sessions in
    /// the same worktree: the first gets `base` alone, later ones the lowest number none of them
    /// holds, so closing a tab frees its number instead of a later one being handed out twice.
    /// A session the user renamed holds no number.
    public static func numberedTitle(_ base: String, among siblings: [Session]) -> String {
        let taken = Set(siblings.lazy.filter { !$0.hasCustomTitle }.map { session -> Int in
            guard let space = session.title.lastIndex(of: " "),
                  let number = Int(session.title[session.title.index(after: space)...]), number > 1
            else { return 1 }
            return number
        })
        let number = (1...).first { !taken.contains($0) } ?? 1
        return number == 1 ? base : "\(base) \(number)"
    }
}
