import Foundation

/// Persisted as a bare string so new agents can ship without a format migration.
public struct AgentKind: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let claude = AgentKind(rawValue: "claude")
    public static let codex = AgentKind(rawValue: "codex")
    public static let shell = AgentKind(rawValue: "shell")
}

public enum Tint: String, Codable, CaseIterable, Sendable {
    case blue, purple, pink, red, orange, yellow, green, teal, gray
}

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

public struct Worktree: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: URL
    /// Last known branch; nil for a detached HEAD or a folder that is not a git repository. The app refreshes it.
    public var branch: String?
    public var isMain: Bool
    public var sessions: [Session]

    public init(id: UUID = UUID(), path: URL, branch: String? = nil, isMain: Bool = false, sessions: [Session] = []) {
        self.id = id
        self.path = path
        self.branch = branch
        self.isMain = isMain
        self.sessions = sessions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(URL.self, forKey: .path)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        isMain = try c.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
        sessions = try c.decode([Session].self, forKey: .sessions)
    }

    /// branch if there is one, otherwise the folder name.
    public var displayName: String { branch ?? path.lastPathComponent }
}

public struct Project: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var folderURL: URL
    /// Sidebar disclosure state.
    public var isExpanded: Bool
    public var worktrees: [Worktree]

    public init(id: UUID = UUID(), name: String, folderURL: URL, isExpanded: Bool = true, worktrees: [Worktree] = []) {
        self.id = id
        self.name = name
        self.folderURL = folderURL
        self.isExpanded = isExpanded
        self.worktrees = worktrees
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        folderURL = try c.decode(URL.self, forKey: .folderURL)
        isExpanded = try c.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        worktrees = try c.decode([Worktree].self, forKey: .worktrees)
    }
}

public struct Island: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// SF Symbol name.
    public var symbol: String
    public var tint: Tint
    public var projects: [Project]

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "square.stack.3d.up",
        tint: Tint = .blue,
        projects: [Project] = []
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.projects = projects
    }
}
