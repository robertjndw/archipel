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
    /// The session records. Each one is shown by exactly one `.session` tab in `panes`.
    public var sessions: [Session]
    /// Never empty. Mutate through `Workspace` so the pane invariants hold.
    public var panes: [Pane]
    public var focusedPaneID: Pane.ID?

    public init(id: UUID = UUID(), path: URL, branch: String? = nil, isMain: Bool = false, sessions: [Session] = []) {
        self.id = id
        self.path = path
        self.branch = branch
        self.isMain = isMain
        self.sessions = sessions
        self.panes = []
        self.focusedPaneID = nil
        normalize()
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(URL.self, forKey: .path)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        isMain = try c.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
        sessions = try c.decode([Session].self, forKey: .sessions)
        // Files from before split view have no panes; normalize builds the single pane they imply.
        panes = try c.decodeIfPresent([Pane].self, forKey: .panes) ?? []
        focusedPaneID = try c.decodeIfPresent(Pane.ID.self, forKey: .focusedPaneID)
        normalize()
    }

    /// The stored focused pane if it exists, otherwise the first one.
    public var focusedPane: Pane? {
        panes.first { $0.id == focusedPaneID } ?? panes.first
    }

    /// branch if there is one, otherwise the folder name.
    public var displayName: String { branch ?? path.lastPathComponent }
}

/// Shell snippets a project runs for its worktrees. Empty means "not configured".
public struct ProjectScripts: Codable, Equatable, Sendable {
    /// Run once in a freshly created worktree, e.g. installing dependencies or copying `.env`.
    public var setup: String
    /// Started on demand, e.g. a dev server.
    public var run: String

    public init(setup: String = "", run: String = "") {
        self.setup = setup
        self.run = run
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setup = try c.decodeIfPresent(String.self, forKey: .setup) ?? ""
        run = try c.decodeIfPresent(String.self, forKey: .run) ?? ""
    }

    public var setupCommand: String? { Self.command(from: setup) }
    public var runCommand: String? { Self.command(from: run) }

    /// True when neither script would execute anything.
    public var isEmpty: Bool { setupCommand == nil && runCommand == nil }

    /// Only blank lines are trimmed: indentation on the first line and spaces inside lines can be significant to a shell.
    private static func command(from script: String) -> String? {
        var lines = script.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)[...]
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}

public struct Project: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var folderURL: URL
    /// Sidebar disclosure state.
    public var isExpanded: Bool
    public var worktrees: [Worktree]
    public var scripts: ProjectScripts

    public init(
        id: UUID = UUID(),
        name: String,
        folderURL: URL,
        isExpanded: Bool = true,
        worktrees: [Worktree] = [],
        scripts: ProjectScripts = ProjectScripts()
    ) {
        self.id = id
        self.name = name
        self.folderURL = folderURL
        self.isExpanded = isExpanded
        self.worktrees = worktrees
        self.scripts = scripts
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        folderURL = try c.decode(URL.self, forKey: .folderURL)
        isExpanded = try c.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        worktrees = try c.decode([Worktree].self, forKey: .worktrees)
        scripts = try c.decodeIfPresent(ProjectScripts.self, forKey: .scripts) ?? ProjectScripts()
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
