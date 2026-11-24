import ArchipelCore
import Foundation

/// Which sessions of a `LifecycleSource.hooksOnceSeen` agent have been heard from through their
/// hooks, and what that does to the fallback messages for them.
public struct HookedSessions: Equatable, Sendable {
    public enum Admission: Equatable, Sendable {
        /// The message is a fallback for a session that has hooks now.
        case dropped
        case accepted
        /// The session's first message from real hooks.
        case firstHook
    }

    private var hooked: Set<UUID> = []

    public init() {}

    public func contains(_ id: UUID) -> Bool { hooked.contains(id) }

    /// Forget a session, as when its agent starts again: trust can have changed since.
    public mutating func reset(_ id: UUID) { hooked.remove(id) }

    public mutating func admit(_ message: HookMessage, agent: AgentKind, registry: AgentRegistry = .builtIn) -> Admission {
        guard let adapter = registry.adapter(id: agent.rawValue),
              adapter.capabilities.lifecycle == .hooksOnceSeen,
              let source = message.source, adapter.hookSources.contains(source)
        else { return .accepted }
        if adapter.fallbackHookSources.contains(source) {
            return hooked.contains(message.sessionID) ? .dropped : .accepted
        }
        return hooked.insert(message.sessionID).inserted ? .firstHook : .accepted
    }
}
