import Foundation

/// What stands for a project in the sidebar.
public enum ProjectIcon: Codable, Equatable, Sendable {
    /// An icon found in the repository (app icon, favicon, logo), or the project's initial when there is none.
    case automatic
    /// SF Symbol name.
    case symbol(String)
    /// An image file the user picked.
    case image(URL)
}

public struct Project: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var folderURL: URL
    /// Sidebar disclosure state.
    public var isExpanded: Bool
    public var worktrees: [Worktree]
    public var scripts: ProjectScripts
    /// nil follows the island's tint.
    public var tint: Tint?
    public var icon: ProjectIcon
    /// Folder that new worktrees are created in, one subfolder per branch. nil uses the app-wide default.
    public var worktreesDirectory: URL?
    /// Branch or ref that new branches start from. nil starts from the main checkout's HEAD.
    public var baseBranch: String?
    /// Standardized paths of worktrees the user took out of the sidebar or declined, so detection
    /// stops suggesting them. They can still be added by hand from the Add Worktree sheet.
    public var dismissedWorktreePaths: Set<String>

    public init(
        id: UUID = UUID(),
        name: String,
        folderURL: URL,
        isExpanded: Bool = true,
        worktrees: [Worktree] = [],
        scripts: ProjectScripts = ProjectScripts(),
        tint: Tint? = nil,
        icon: ProjectIcon = .automatic,
        worktreesDirectory: URL? = nil,
        baseBranch: String? = nil,
        dismissedWorktreePaths: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.folderURL = folderURL
        self.isExpanded = isExpanded
        self.worktrees = worktrees
        self.scripts = scripts
        self.tint = tint
        self.icon = icon
        self.worktreesDirectory = worktreesDirectory
        self.baseBranch = baseBranch
        self.dismissedWorktreePaths = dismissedWorktreePaths
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        folderURL = try c.decode(URL.self, forKey: .folderURL)
        isExpanded = try c.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        worktrees = try c.decode([Worktree].self, forKey: .worktrees)
        scripts = try c.decodeIfPresent(ProjectScripts.self, forKey: .scripts) ?? ProjectScripts()
        tint = try c.decodeIfPresent(Tint.self, forKey: .tint)
        icon = try c.decodeIfPresent(ProjectIcon.self, forKey: .icon) ?? .automatic
        worktreesDirectory = try c.decodeIfPresent(URL.self, forKey: .worktreesDirectory)
        baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch)
        dismissedWorktreePaths = try c.decodeIfPresent(Set<String>.self, forKey: .dismissedWorktreePaths) ?? []
    }

    /// The key detection and dismissal compare by, so `/a/b` and `/a/b/` are the same worktree.
    public static func worktreeKey(_ path: URL) -> String {
        path.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        count > 1 && hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
