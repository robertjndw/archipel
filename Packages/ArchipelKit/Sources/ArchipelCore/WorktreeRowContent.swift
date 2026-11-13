import Foundation

/// Repository state of a worktree as the sidebar shows it. ArchipelCore does not know git, so the app
/// fills this in from its own git summary.
public struct WorktreeGitState: Equatable, Sendable {
    public var changedFiles: Int
    public var ahead: Int
    public var behind: Int
    public var pullRequest: PullRequestBadge?

    public init(changedFiles: Int = 0, ahead: Int = 0, behind: Int = 0, pullRequest: PullRequestBadge? = nil) {
        self.changedFiles = changedFiles
        self.ahead = ahead
        self.behind = behind
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
public struct WorktreeRowContent: Equatable, Sendable {
    public enum Trailing: Equatable, Sendable {
        case status(SessionActivity)
        case sessionCount(Int)
        case none
    }

    public var title: String
    /// Second line, if any.
    public var detail: String?
    /// True when `detail` is something the agent said rather than the folder name.
    public var detailIsMessage: Bool
    public var isUnread: Bool
    /// Zero values are dropped to nil so the view can show exactly what is non-nil.
    public var changedFiles: Int?
    public var ahead: Int?
    public var behind: Int?
    public var pullRequest: PullRequestBadge?
    public var trailing: Trailing

    public init(worktree: Worktree, activity: SessionActivity?, git: WorktreeGitState?) {
        title = worktree.displayName
        isUnread = activity?.unread == true
        changedFiles = Self.positive(git?.changedFiles)
        ahead = Self.positive(git?.ahead)
        behind = Self.positive(git?.behind)
        pullRequest = git?.pullRequest

        if let message = activity.flatMap(Self.messageWorthShowing) {
            detail = message
            detailIsMessage = true
        } else {
            // The folder only adds something when the first line shows the branch instead of it, and
            // the main checkout's folder is the project, which the section header already names.
            detail = worktree.isMain || worktree.branch == nil ? nil : worktree.path.lastPathComponent
            detailIsMessage = false
        }

        if let activity {
            trailing = .status(activity)
        } else if !worktree.sessions.isEmpty {
            trailing = .sessionCount(worktree.sessions.count)
        } else {
            trailing = .none
        }
    }

    public var hasMetadata: Bool {
        changedFiles != nil || ahead != nil || behind != nil || pullRequest != nil
    }

    /// One sentence for VoiceOver covering the compact symbols and numbers.
    public var metadataAccessibilityLabel: String {
        var parts: [String] = []
        if let changedFiles { parts.append(changedFiles == 1 ? "1 changed file" : "\(changedFiles) changed files") }
        if let ahead { parts.append(ahead == 1 ? "1 commit ahead" : "\(ahead) commits ahead") }
        if let behind { parts.append(behind == 1 ? "1 commit behind" : "\(behind) commits behind") }
        if let pullRequest { parts.append(pullRequest.accessibilityLabel) }
        return parts.joined(separator: ", ")
    }

    /// A message is shown while the agent waits for the user, and after a finished turn until the user
    /// has looked at it. Once read, the row falls back to the quieter folder line.
    static func messageWorthShowing(_ activity: SessionActivity) -> String? {
        guard activity.needsUser || (activity.status == .finished && activity.unread),
              let message = activity.lastMessage
        else { return nil }
        // Agents send multi-line messages; the row has one line, and a leading blank line would show nothing.
        let flattened = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flattened.isEmpty ? nil : flattened
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
