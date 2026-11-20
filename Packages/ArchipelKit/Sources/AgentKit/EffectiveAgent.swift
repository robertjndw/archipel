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
    public var definition: AgentDefinition { kind.definition }

    public static func resolve(persisted: AgentKind, runtime: RuntimeAgent?) -> EffectiveAgent {
        if persisted == .shell, let runtime {
            return EffectiveAgent(
                kind: runtime.kind,
                acceptsPrompts: runtime.kind.definition.acceptsPrompts,
                // Claude launched by the app always reports through hooks; one started by hand
                // only does once the user's settings carry them.
                reportsLifecycleThroughHooks: runtime.reportsThroughHooks,
                isDetected: true
            )
        }
        let definition = persisted.definition
        return EffectiveAgent(
            kind: persisted,
            acceptsPrompts: definition.acceptsPrompts,
            reportsLifecycleThroughHooks: definition.reportsLifecycleThroughHooks,
            isDetected: false
        )
    }
}
