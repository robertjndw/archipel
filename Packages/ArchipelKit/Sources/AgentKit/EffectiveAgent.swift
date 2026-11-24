import ArchipelCore

/// The agent a session behaves as right now. Usually the one it was created with, but a shell tab
/// in which the user started Claude by hand acts as a Claude session until Claude exits.
public struct EffectiveAgent: Equatable, Sendable {
    public var kind: AgentKind
    /// Whether the app may type text into the terminal. Callers that do must still check that the
    /// agent holds the terminal at that moment, since a detected agent can exit at any time.
    public var acceptsPrompts: Bool
    public var reportsLifecycleThroughHooks: Bool
    /// Found running in a shell tab rather than launched by the app.
    public var isDetected: Bool

    public init(kind: AgentKind, acceptsPrompts: Bool, reportsLifecycleThroughHooks: Bool, isDetected: Bool) {
        self.kind = kind
        self.acceptsPrompts = acceptsPrompts
        self.reportsLifecycleThroughHooks = reportsLifecycleThroughHooks
        self.isDetected = isDetected
    }

    /// Use it for the symbol and the name only. Its launch commands and flags don't apply to a
    /// detected agent, since the app didn't start it.
    public var adapter: any AgentAdapter { kind.adapter }

    /// `hooksSeen`: the session's hooks have reported, which turns an agent with
    /// `LifecycleSource.hooksOnceSeen` into one that reports through hooks.
    /// `interface`: what the session runs as. A chat learns every request and turn end from the
    /// protocol from the start, so it reports precisely whatever the agent's terminal lifecycle is,
    /// and there is no shell in which another agent could be found.
    public static func resolve(
        persisted: AgentKind,
        runtime: RuntimeAgent?,
        hooksSeen: Bool = false,
        interface: SessionInterface = .terminal
    ) -> EffectiveAgent {
        if interface == .acp {
            return EffectiveAgent(
                kind: persisted,
                acceptsPrompts: persisted.adapter.capabilities.acceptsPrompts,
                reportsLifecycleThroughHooks: true,
                isDetected: false
            )
        }
        if persisted == .shell, let runtime {
            return EffectiveAgent(
                kind: runtime.kind,
                acceptsPrompts: runtime.kind.adapter.capabilities.acceptsPrompts,
                // Claude launched by the app always reports through hooks; one started by hand
                // only does once the user's settings carry them.
                reportsLifecycleThroughHooks: runtime.reportsThroughHooks,
                isDetected: true
            )
        }
        let capabilities = persisted.adapter.capabilities
        return EffectiveAgent(
            kind: persisted,
            acceptsPrompts: capabilities.acceptsPrompts,
            reportsLifecycleThroughHooks: capabilities.reportsLifecycleThroughHooks
                || (capabilities.lifecycle == .hooksOnceSeen && hooksSeen),
            isDetected: false
        )
    }
}
