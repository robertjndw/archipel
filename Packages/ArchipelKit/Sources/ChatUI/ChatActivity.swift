import ACPKit
import Foundation

/// What the status line at the end of the transcript says while a turn runs.
///
/// The rows above it are the record ("Read ChatView.swift"); the line is the present tense
/// ("Reading"). It is there for the whole turn, so the end of the transcript does not jump each
/// time the agent moves from one step to the next.
enum WorkingStatus {
    static let working = "Working"
    static let thinking = "Thinking"
    static let stopping = "Stopping"

    /// The phrase for where the turn is right now.
    ///
    /// A call whose row sits directly above the line is named only by its kind of work, since the row
    /// already says which file or command. A call still running further up, behind newer rows, is
    /// named in full, since nothing next to the line says what the agent is waiting for.
    static func phrase(items: [ChatItem], isCancelling: Bool) -> String {
        if isCancelling { return stopping }
        // Calls of earlier turns never finish for an agent that drops them, so only this turn's
        // count as running.
        let turn = items[(items.lastIndex { if case .userMessage = $0 { true } else { false } } ?? items.startIndex)...]
        switch turn.last {
        case let .toolCall(call) where !call.status.isFinished:
            return call.kind.activityVerb
        case .agentThought:
            return thinking
        default:
            break
        }
        for item in turn.reversed() {
            if case let .toolCall(call) = item, !call.status.isFinished { return call.activityPhrase }
        }
        return working
    }

    /// Whether the line shows at all. A permission card asks the user, and until it is answered
    /// nobody is working.
    static func isShown(isTurnRunning: Bool, isAwaitingPermission: Bool) -> Bool {
        isTurnRunning && !isAwaitingPermission
    }
}

extension ToolKind {
    /// The kind of work as something going on: "Reading".
    var activityVerb: String {
        switch self {
        case .read: "Reading"
        case .edit: "Editing"
        case .delete: "Deleting"
        case .move: "Moving"
        case .search: "Searching"
        case .execute: "Running"
        case .think: WorkingStatus.thinking
        case .fetch: "Fetching"
        case .switchMode: "Planning"
        case .other: WorkingStatus.working
        }
    }
}

extension ToolCall {
    /// The call as something going on, with what it is about: "Reading ChatView.swift",
    /// "Running swift build".
    var activityPhrase: String {
        switch kind {
        case .read, .edit, .delete, .move:
            guard let path = locations.first?.path ?? diffs.first?.path, !path.isEmpty else { return kind.activityVerb }
            return "\(kind.activityVerb) \((path as NSString).lastPathComponent)"
        case .execute:
            guard let line = command?.split(whereSeparator: \.isNewline).first else { return kind.activityVerb }
            return "\(kind.activityVerb) \(line.trimmingCharacters(in: .whitespaces))"
        case .search, .think, .fetch, .switchMode:
            return kind.activityVerb
        case .other:
            // Nothing is known about such a tool but the title its agent gave the call.
            let title = displayTitle()
            return title.isEmpty ? kind.activityVerb : title
        }
    }
}

/// How long a turn has been running, as the status line shows it.
enum ElapsedTime {
    /// A turn that is over this quickly never shows a time: most are, and a counter that appears
    /// only to vanish is noise.
    static let quietSeconds = 5

    /// Whole seconds from `anchor` to `date`, as the label that ticks once a second counts them.
    /// A tick lands on a whole second give or take rounding; the margin keeps it from reading
    /// as the second before.
    static func seconds(since anchor: Date, at date: Date) -> Int {
        max(0, Int(date.timeIntervalSince(anchor) + 0.05))
    }

    /// "8s", "1m 12s", "1h 04m". The smaller unit keeps two digits, so the text is as wide at
    /// 1m 09s as at 1m 10s and nothing next to it moves when it ticks.
    static func text(seconds: Int) -> String {
        let seconds = max(seconds, 0)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(twoDigits(seconds % 60))s" }
        return "\(seconds / 3600)h \(twoDigits(seconds % 3600 / 60))m"
    }

    /// The same time in words, for VoiceOver: "1 minute, 12 seconds".
    static func spoken(seconds: Int, locale: Locale = .current) -> String {
        let seconds = max(seconds, 0)
        // Past an hour the seconds are left out, as they are on screen.
        let shown = seconds < 3600 ? seconds : seconds - seconds % 60
        return Duration.seconds(shown).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide).locale(locale))
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

/// When the running turn began, less the time it spent waiting on the user.
///
/// The time on the status line answers "is the agent stuck?", so minutes a permission card sat
/// unanswered must not count against it.
struct TurnClock: Equatable, Sendable {
    /// The turn being timed, by the session's turn count. Nil while none runs.
    private(set) var turn: Int?
    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    init() {}

    /// A clock that has already run for `elapsed`, for previews.
    init(turn: Int, elapsed: TimeInterval, now: Date = .now) {
        self.turn = turn
        startedAt = now.addingTimeInterval(-elapsed)
    }

    /// Brings the clock in step with the session. A turn number it has not seen starts it anew,
    /// which also covers a queued prompt going out the moment the turn before it ends.
    mutating func update(turn: Int?, isWaitingOnUser: Bool, now: Date) {
        guard let turn else {
            self = TurnClock()
            return
        }
        if turn != self.turn {
            self = TurnClock()
            self.turn = turn
            startedAt = now
        }
        if isWaitingOnUser {
            if pausedAt == nil { pausedAt = now }
        } else if let paused = pausedAt {
            pausedTotal += now.timeIntervalSince(paused)
            pausedAt = nil
        }
    }

    /// The moment the turn would have started had it never waited: the time since then is the
    /// time worked. Nil while no turn runs.
    var anchor: Date? {
        startedAt?.addingTimeInterval(pausedTotal)
    }
}
