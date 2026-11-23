import ArchipelCore

/// The agents the app offers, in menu order. A value rather than a global list, so agents the user
/// defines could be added later without touching the call sites.
public struct AgentRegistry: Sendable {
    public let adapters: [any AgentAdapter]

    public init(adapters: [any AgentAdapter]) {
        self.adapters = adapters
    }

    public static let builtIn = AgentRegistry(adapters: [ClaudeAdapter(), CodexAdapter(), OpenCodeAdapter(), ShellAdapter()])

    public func adapter(id: String) -> (any AgentAdapter)? {
        adapters.first { $0.id == id }
    }

    /// The adapter that decodes envelopes with this `source`. Nil for a source nobody claims, such
    /// as one sent by a newer helper.
    public func adapter(forHookSource source: String) -> (any AgentAdapter)? {
        adapters.first { $0.hookSources.contains(source) }
    }

    /// The agent whose subscription these limits belong to.
    public func adapter(forUsage provider: UsageProvider) -> (any AgentAdapter)? {
        adapters.first { $0.capabilities.usage?.provider == provider }
    }
}
