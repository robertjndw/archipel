import Foundation

public struct Worktree: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: URL
    /// Last known branch; nil for a detached HEAD or a folder that is not a git repository. The app refreshes it.
    public var branch: String?
    public var isMain: Bool
    /// The branch name the app generated for a worktree started without choosing a branch. The
    /// worktree counts as still unnamed only while `branch` equals it, so a rename by hand ends that.
    public var placeholderBranch: String?
    /// The session records. Each one is shown by exactly one `.session` tab in `panes`.
    public var sessions: [Session]
    /// Never empty. Mutate through `Workspace` so the pane invariants hold.
    public var panes: [Pane]
    public var focusedPaneID: Pane.ID?

    public init(id: UUID = UUID(), path: URL, branch: String? = nil, isMain: Bool = false, sessions: [Session] = [], placeholderBranch: String? = nil) {
        self.id = id
        self.path = path
        self.branch = branch
        self.isMain = isMain
        self.placeholderBranch = placeholderBranch
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
        placeholderBranch = try c.decodeIfPresent(String.self, forKey: .placeholderBranch)
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

    public var isOnPlaceholderBranch: Bool { placeholderBranch != nil && branch == placeholderBranch }

    public var displayName: String { branch ?? path.lastPathComponent }
}
