import Foundation

/// An agent the user started by hand in a shell tab, such as `claude` typed at the prompt. Exists
/// only while that process runs. The session stays a shell and none of this is saved.
public struct RuntimeAgent: Equatable, Sendable {
    public var kind: AgentKind
    /// Nil while only a hook has announced the agent and no scan has found its process yet.
    public var process: ProcessIdentity?
    /// Set once a hook from the user's own Claude settings arrived from this run. Until then the
    /// app relies on the terminal alone.
    public var reportsThroughHooks: Bool
    /// The conversation whose hooks count. Others arrive too, from a `claude -p` the agent runs
    /// through its Bash tool, which inherits the tab's environment.
    public var agentSessionID: String?

    public init(kind: AgentKind, process: ProcessIdentity? = nil, reportsThroughHooks: Bool = false, agentSessionID: String? = nil) {
        self.kind = kind
        self.process = process
        self.reportsThroughHooks = reportsThroughHooks
        self.agentSessionID = agentSessionID
    }
}

/// What a look at a shell tab's terminal found in its foreground.
public struct ForegroundObservation: Equatable, Sendable {
    /// The agent in the foreground process group, if any.
    public var agent: AgentKind?
    public var process: ProcessIdentity?
    /// The shell itself holds the terminal, so whatever ran before is gone or suspended.
    public var shellInForeground: Bool

    public init(agent: AgentKind? = nil, process: ProcessIdentity? = nil, shellInForeground: Bool) {
        self.agent = agent
        self.process = process
        self.shellInForeground = shellInForeground
    }
}

/// Which agent, if any, is running inside one shell tab. Two sources feed it: scans of the
/// terminal's foreground, which see any agent but only every few seconds, and hooks from the
/// user's Claude settings, which are precise but only there when the user installed them.
///
/// A hook can carry a `sender`, the nearest Claude process above the hook helper. Once the agent's
/// process is known, that separates the agent's own hooks from those of a `claude -p` it runs
/// through its Bash tool, which inherits the tab's environment. Older helpers send no sender, and
/// then only the conversation id tells them apart.
public struct RuntimeAgentState: Equatable, Sendable {
    /// Claude still takes a moment to shut down after SessionEnd, and a scan in that moment must not
    /// bring it back. Longer, and a SessionEnd that did not end the process (a conversation switch,
    /// say) would keep the tab a shell for the rest of the run.
    public static let endedProcessGrace: TimeInterval = 5
    /// A few scans. An agent known only from its hooks that no scan ties to a process by then is
    /// not in the terminal's foreground: it runs under tmux or the like, or died without SessionEnd.
    public static let unattachedLimit: TimeInterval = 15

    private struct Ended: Equatable, Sendable {
        var process: ProcessIdentity
        var at: Date
    }

    private enum Sender {
        case agent, other, unknown
    }

    public private(set) var agent: RuntimeAgent?
    private var ended: Ended?
    /// Set while the agent is known only from its hooks.
    private var unattachedSince: Date?

    public init() {}

    public mutating func observe(_ observation: ForegroundObservation, at now: Date = Date()) {
        guard let kind = observation.agent else {
            // Ctrl-Z lands here too: a suspended agent is not running.
            if observation.shellInForeground || agent?.process != nil {
                clearAgent()
            } else if let since = unattachedSince, now.timeIntervalSince(since) >= Self.unattachedLimit {
                clearAgent()
            }
            return
        }
        if let process = observation.process, isEnded(process, at: now) { return }
        if var current = agent, current.kind == kind,
           current.process == nil || observation.process == nil || current.process == observation.process {
            current.process = observation.process ?? current.process
            agent = current
            if current.process != nil { unattachedSince = nil }
        } else {
            // A different process is a new run. Drop what the old one's hooks reported.
            agent = RuntimeAgent(kind: kind, process: observation.process)
            unattachedSince = nil
        }
    }

    /// Ties an agent known only from its hooks to the process that sent them. A hook from that
    /// process means it is still running, so an end it reported earlier no longer counts.
    public mutating func attach(_ process: ProcessIdentity) {
        guard var current = agent, current.process == nil else { return }
        current.process = process
        agent = current
        unattachedSince = nil
        if ended?.process == process { ended = nil }
    }

    /// Claude's SessionStart. `source` is `startup`, `resume`, `clear` or `compact`.
    public mutating func hookStarted(agentSessionID: String?, source: String?, sender: ProcessIdentity? = nil, at now: Date = Date()) {
        guard var current = agent else {
            agent = RuntimeAgent(kind: .claude, reportsThroughHooks: true, agentSessionID: agentSessionID)
            unattachedSince = now
            return
        }
        switch origin(of: sender) {
        case .other:
            return
        case .agent:
            current.agentSessionID = agentSessionID ?? current.agentSessionID
        case .unknown:
            if current.agentSessionID == nil {
                // A scan found this Claude but none of its hooks arrived. Its own SessionStart would
                // have arrived right away, so a startup now is more likely a `claude -p` it runs.
                if source == "startup", current.process != nil, !current.reportsThroughHooks { return }
                current.agentSessionID = agentSessionID
            } else if current.agentSessionID == agentSessionID {
                break
            } else if source == "startup" {
                // A second Claude starting up inside the first one.
                return
            } else {
                // /clear and /resume carry on in the same process under another conversation id.
                current.agentSessionID = agentSessionID
            }
        }
        current.reportsThroughHooks = true
        agent = current
    }

    /// Claude's SessionEnd.
    public mutating func hookEnded(agentSessionID: String?, reason: String?, sender: ProcessIdentity? = nil, at now: Date = Date()) {
        // /clear ends the conversation, not the process; SessionStart with the new id follows.
        guard reason != "clear", let current = agent else { return }
        switch origin(of: sender) {
        case .other:
            return
        case .agent:
            break
        case .unknown:
            guard current.agentSessionID == nil || current.agentSessionID == agentSessionID else { return }
        }
        ended = current.process.map { Ended(process: $0, at: now) }
        clearAgent()
    }

    /// Any other hook. False when it comes from some other Claude and must be ignored.
    public mutating func hookEvent(agentSessionID: String?, sender: ProcessIdentity? = nil) -> Bool {
        // Without an agent this is a straggler from one that already ended, or from a Claude
        // started before the hooks were installed that no scan has found yet. Either way the
        // next scan decides.
        guard var current = agent else { return false }
        switch origin(of: sender) {
        case .other:
            return false
        case .agent:
            // From the agent's own process, so accept it whatever the conversation id.
            current.agentSessionID = agentSessionID ?? current.agentSessionID
        case .unknown:
            if let pinned = current.agentSessionID {
                guard pinned == agentSessionID else { return false }
            } else {
                current.agentSessionID = agentSessionID
            }
        }
        current.reportsThroughHooks = true
        agent = current
        return true
    }

    private func origin(of sender: ProcessIdentity?) -> Sender {
        guard let process = agent?.process, let sender else { return .unknown }
        return sender == process ? .agent : .other
    }

    private func isEnded(_ process: ProcessIdentity, at now: Date) -> Bool {
        guard let ended, ended.process == process else { return false }
        return now.timeIntervalSince(ended.at) < Self.endedProcessGrace
    }

    private mutating func clearAgent() {
        agent = nil
        unattachedSince = nil
    }
}

/// Recognises agents and shells by their process label (see `ProcessLabel`).
public enum AgentProcessMatcher {
    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "nu", "dash", "ksh", "tcsh", "csh", "elvish"]

    /// The native install runs as `claude` (its kernel name is the version number, so only argv
    /// says what it is). The npm package runs as `node .../@anthropic-ai/claude-code/cli.js`,
    /// which `ProcessLabel` names after the package.
    public static func agent(forLabel label: String) -> AgentKind? {
        switch label {
        case "claude", "claude-code": .claude
        default: nil
        }
    }

    /// Login shells are started with a leading dash in argv[0].
    public static func isShell(label: String) -> Bool {
        shells.contains(label.hasPrefix("-") ? String(label.dropFirst()) : label)
    }

    /// Whether a process with these arguments is a shell waiting for the user to type, as opposed
    /// to one running a script or a `-c` command. `name` is the kernel's name for the process,
    /// used when its arguments could not be read.
    ///
    /// An argument that is not an option counts as a script, which also takes the value of an
    /// option for one (`bash --rcfile x`). That errs towards "something is running", the side
    /// that asks before a tab is closed.
    public static func isInteractiveShell(name: String, arguments: [String]) -> Bool {
        let executable = arguments.first.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? name
        guard isShell(label: executable) else { return false }
        return arguments.dropFirst().allSatisfy { argument in
            guard argument.hasPrefix("-") else { return false }
            // `-c` also hides in a group of short options, as in `zsh -lc`.
            return argument.hasPrefix("--") || !argument.contains("c")
        }
    }
}

/// Claude's own OSC 9 desktop notifications, the only requests a Claude without hooks reports.
public enum ClaudeTerminalNotification {
    /// Nil for the idle reminder Claude posts a minute after a turn ends. It asks for nothing.
    public static func reason(forBody body: String) -> AttentionReason? {
        let text = body.lowercased()
        if text.contains("waiting for your input") { return nil }
        if text.contains("permission") { return .permission }
        return .question
    }
}
