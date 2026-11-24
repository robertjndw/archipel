import Foundation

/// Sessions whose notifications were held back while the user was busy (sharing their screen),
/// to be reported as one summary once they are free again.
public struct HeldNotifications: Equatable, Sendable {
    /// Oldest first, each session once at the position of its latest notification.
    public private(set) var sessionIDs: [Session.ID] = []

    public init() {}

    public var isEmpty: Bool { sessionIDs.isEmpty }

    public mutating func hold(_ id: Session.ID) {
        sessionIDs.removeAll { $0 == id }
        sessionIDs.append(id)
    }

    public mutating func removeAll() {
        sessionIDs.removeAll()
    }

    /// Counts what the held sessions are doing now rather than what they were doing when held: a
    /// request the user already answered in the app is no longer news. Nil when nothing is left.
    public func summary(activities: [Session.ID: SessionActivity]) -> Summary? {
        var summary = Summary()
        // Newest first, so the session to open is the most recent one of the strongest kind.
        for id in sessionIDs.reversed() {
            // Read means the user opened the session in the app while still sharing.
            guard let activity = activities[id], activity.unread else { continue }
            let counted = summary.total
            switch activity.status {
            case .needsAttention:
                summary.needYou += 1
                if summary.needYouTarget == nil { summary.needYouTarget = id }
            case .finished:
                summary.finished += 1
                if summary.otherTarget == nil { summary.otherTarget = id }
            case .exited:
                summary.ended += 1
                if summary.otherTarget == nil { summary.otherTarget = id }
            default:
                break
            }
            if summary.total > counted { summary.covered.insert(id) }
        }
        return summary.sessionID == nil ? nil : summary
    }

    public struct Summary: Equatable, Sendable {
        public var finished = 0
        public var needYou = 0
        public var ended = 0
        /// Every session the counts stand for.
        public fileprivate(set) var covered: Set<Session.ID> = []
        fileprivate var needYouTarget: Session.ID?
        fileprivate var otherTarget: Session.ID?
        fileprivate var total: Int { finished + needYou + ended }

        /// The session the notification opens: one that waits for the user wins over one that is done.
        public var sessionID: Session.ID? { needYouTarget ?? otherTarget }

        /// E.g. "2 agents finished, 1 needs you".
        public var text: String {
            var parts: [String] = []
            if finished > 0 { parts.append(finished == 1 ? "1 agent finished" : "\(finished) agents finished") }
            if needYou > 0 { parts.append(needYou == 1 ? "1 needs you" : "\(needYou) need you") }
            if ended > 0 { parts.append(ended == 1 ? "1 session ended" : "\(ended) sessions ended") }
            return parts.joined(separator: ", ")
        }
    }
}

/// The sessions a posted summary still speaks for. "2 agents finished, 1 needs you" stays worth
/// showing until the user has been to all three, not just the one the notification opens.
public struct SummaryCoverage: Equatable, Sendable {
    private var remaining: Set<Session.ID>

    public init(_ sessions: Set<Session.ID> = []) {
        remaining = sessions
    }

    /// True when `id` was the last session the summary had left, which is when to withdraw it.
    public mutating func clear(_ id: Session.ID) -> Bool {
        remaining.remove(id) != nil && remaining.isEmpty
    }
}
