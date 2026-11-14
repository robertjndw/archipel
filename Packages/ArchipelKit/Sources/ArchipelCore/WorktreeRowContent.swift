import Foundation

/// Repository state of a worktree as the sidebar shows it. ArchipelCore does not know git, so the app
/// fills this in from its own git summary.
public struct WorktreeGitState: Equatable, Sendable {
    public var changedFiles: Int
    public var ahead: Int
    public var behind: Int
    public var insertions: Int
    public var deletions: Int
    public var pullRequest: PullRequestBadge?

    public init(
        changedFiles: Int = 0,
        ahead: Int = 0,
        behind: Int = 0,
        insertions: Int = 0,
        deletions: Int = 0,
        pullRequest: PullRequestBadge? = nil
    ) {
        self.changedFiles = changedFiles
        self.ahead = ahead
        self.behind = behind
        self.insertions = insertions
        self.deletions = deletions
        self.pullRequest = pullRequest
    }
}

public struct PullRequestBadge: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case open, draft, merged, closed
    }

    public var number: Int
    public var state: State

    public init(number: Int, state: State) {
        self.number = number
        self.state = state
    }

    public var title: String { "#\(number)" }

    public var accessibilityLabel: String {
        let state = switch state {
        case .open: "open"
        case .draft: "draft"
        case .merged: "merged"
        case .closed: "closed"
        }
        return "Pull request \(number), \(state)"
    }
}

/// What one worktree row in the sidebar shows, decided in one place so the view only lays it out.
///
/// The row has two lines. The first is the branch with the state of its most pressing session at the
/// trailing edge. The second is either what the agent said, while that matters, or a line of metadata.
public struct WorktreeRowContent: Equatable, Sendable {
    /// Which optional parts the user wants in the sidebar.
    public struct Options: Equatable, Sendable {
        public var showsGitStatus: Bool
        public var showsPullRequests: Bool
        public var showsMessages: Bool

        public init(showsGitStatus: Bool = true, showsPullRequests: Bool = true, showsMessages: Bool = true) {
            self.showsGitStatus = showsGitStatus
            self.showsPullRequests = showsPullRequests
            self.showsMessages = showsMessages
        }

        public static let all = Options()
    }

    public enum Trailing: Equatable, Sendable {
        case status(SessionActivity)
        case none
    }

    public enum Detail: Equatable, Sendable {
        /// Something the agent said. `needsUser` is set while it is waiting on an answer.
        case message(String, needsUser: Bool)
        /// Metadata in display order, as several variants from fullest to sparsest: the view shows the
        /// first that fits the sidebar's width.
        case metadata([[MetadataItem]])
    }

    public enum MetadataItem: Equatable, Sendable, Identifiable {
        case pullRequest(PullRequestBadge)
        case diff(insertions: Int, deletions: Int)
        case changedFiles(Int)
        /// At least one of them is non-zero.
        case aheadBehind(ahead: Int, behind: Int)
        /// The agents running here, each kind once, in the order they were started.
        case agents([AgentKind])
        /// The folder, when it says something the branch name does not.
        case folder(String)

        public var id: String {
            switch self {
            case .pullRequest: "pullRequest"
            case .diff: "diff"
            case .changedFiles: "changedFiles"
            case .aheadBehind: "aheadBehind"
            case .agents: "agents"
            case .folder: "folder"
            }
        }

        public var accessibilityLabel: String {
            switch self {
            case .pullRequest(let badge):
                return badge.accessibilityLabel
            case .diff(let insertions, let deletions):
                return "\(Self.count(insertions, "line")) added, \(Self.count(deletions, "line")) removed"
            case .changedFiles(let count):
                return count == 1 ? "1 changed file" : "\(count) changed files"
            case .aheadBehind(let ahead, let behind):
                var parts: [String] = []
                if ahead > 0 { parts.append("\(Self.count(ahead, "commit")) ahead") }
                if behind > 0 { parts.append("\(Self.count(behind, "commit")) behind") }
                return parts.joined(separator: ", ")
            case .agents(let agents):
                return agents.count == 1 ? "1 agent" : "\(agents.count) agents"
            case .folder(let name):
                return "Folder \(name)"
            }
        }

        private static func count(_ value: Int, _ noun: String) -> String {
            value == 1 ? "1 \(noun)" : "\(value) \(noun)s"
        }

        /// Lower survives longer when the row is narrow. The pull request is what the user acts on
        /// next and the line counts say how big the change is; the file count mostly restates the line
        /// counts, and the agents are visible in the trailing glyph or the session rows anyway.
        var keepPriority: Int {
            switch self {
            case .pullRequest: 0
            case .diff: 1
            case .aheadBehind: 2
            case .changedFiles: 3
            case .agents: 4
            case .folder: 5
            }
        }
    }

    public var title: String
    public var detail: Detail?
    public var isUnread: Bool
    public var trailing: Trailing

    public init(worktree: Worktree, activity: SessionActivity?, git: WorktreeGitState?, options: Options = .all) {
        title = worktree.displayName
        isUnread = activity?.unread == true
        trailing = activity.map(Trailing.status) ?? .none

        if options.showsMessages, let activity, let message = Self.messageWorthShowing(activity) {
            detail = .message(message, needsUser: activity.needsUser)
            return
        }
        let items = Self.metadataItems(worktree: worktree, git: git, options: options)
        detail = items.isEmpty ? nil : .metadata(Self.variants(of: items))
    }

    /// The fullest variant, or nothing when the second line is a message.
    public var metadata: [MetadataItem] {
        if case .metadata(let variants) = detail { return variants.first ?? [] }
        return []
    }

    /// One sentence for VoiceOver covering the compact symbols and numbers.
    public var metadataAccessibilityLabel: String {
        metadata.map(\.accessibilityLabel).joined(separator: ", ")
    }

    /// A message is shown while the agent waits for the user, and after a finished turn until the user
    /// has looked at it. Once read, the row falls back to the quieter metadata line.
    static func messageWorthShowing(_ activity: SessionActivity) -> String? {
        guard activity.needsUser || (activity.status == .finished && activity.unread),
              let message = activity.lastMessage
        else { return nil }
        // Agents send multi-line messages; the row has one line, and a leading blank line would show nothing.
        let flattened = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flattened.isEmpty ? nil : flattened
    }

    static func metadataItems(worktree: Worktree, git: WorktreeGitState?, options: Options) -> [MetadataItem] {
        var items: [MetadataItem] = []
        if options.showsPullRequests, let pullRequest = git?.pullRequest {
            items.append(.pullRequest(pullRequest))
        }
        if options.showsGitStatus, let git {
            if git.insertions > 0 || git.deletions > 0 {
                items.append(.diff(insertions: git.insertions, deletions: git.deletions))
            }
            if git.changedFiles > 0 { items.append(.changedFiles(git.changedFiles)) }
            if git.ahead > 0 || git.behind > 0 { items.append(.aheadBehind(ahead: git.ahead, behind: git.behind)) }
        }
        // With two or more sessions the sidebar lists them under the row, which says more than icons.
        if worktree.sessions.count == 1 {
            items.append(.agents([worktree.sessions[0].agent]))
        }
        // The folder only adds something when the first line shows the branch instead of it, and the
        // main checkout's folder is the project, which the section header already names.
        if items.isEmpty, !worktree.isMain, worktree.branch != nil, worktree.path.lastPathComponent != worktree.branch {
            items.append(.folder(worktree.path.lastPathComponent))
        }
        return items
    }

    /// Drops the least important item one at a time, keeping display order, down to a single item.
    static func variants(of items: [MetadataItem]) -> [[MetadataItem]] {
        var current = items
        var result = [current]
        while current.count > 1, let weakest = current.max(by: { $0.keepPriority < $1.keepPriority }) {
            current.removeAll { $0 == weakest }
            result.append(current)
        }
        return result
    }
}

/// A session listed under its worktree row.
public struct SessionRowContent: Equatable, Sendable, Identifiable {
    public var id: Session.ID
    public var title: String
    public var agent: AgentKind
    public var activity: SessionActivity
    /// The session in the worktree's focused pane, which is what the content area shows.
    public var isFocused: Bool

    /// Only worktrees with several sessions get session rows: with one, the worktree row already is the
    /// session, and an extra row would just repeat it.
    public static func rows(
        for worktree: Worktree,
        activities: [Session.ID: SessionActivity],
        focusedSessionID: Session.ID?
    ) -> [SessionRowContent] {
        guard worktree.sessions.count > 1 else { return [] }
        return worktree.sessions.map { session in
            SessionRowContent(
                id: session.id,
                title: session.displayTitle,
                agent: session.agent,
                activity: activities[session.id] ?? SessionActivity(),
                isFocused: session.id == focusedSessionID
            )
        }
    }
}
