import ArchipelCore
import Foundation

/// What one hook payload means to the app. The adapter for the envelope's source fills it in.
public struct DecodedHook: Equatable, Sendable {
    public var event: AgentEvent?
    public var agentSessionID: String?
    public var lifecycle: HookLifecycle?
    /// Subscription limits. Never set together with an event.
    public var usage: ProviderUsage?
    /// Context window fill. Never set together with an event.
    public var context: SessionContext?
    /// The file the agent writes the conversation to, when the payload names it.
    public var transcriptPath: String?

    public init(
        event: AgentEvent?,
        agentSessionID: String?,
        lifecycle: HookLifecycle? = nil,
        usage: ProviderUsage? = nil,
        context: SessionContext? = nil,
        transcriptPath: String? = nil
    ) {
        self.event = event
        self.agentSessionID = agentSessionID
        self.lifecycle = lifecycle
        self.usage = usage
        self.context = context
        self.transcriptPath = transcriptPath
    }
}

/// Routes raw hook payloads to the adapter that owns their source. Anything unrecognised maps to
/// nil rather than failing.
public enum HookDecoder {
    public static func decode(
        source: String,
        payload: [String: Any],
        receivedAt date: Date = .now,
        registry: AgentRegistry = .builtIn
    ) -> DecodedHook? {
        registry.adapter(forHookSource: source)?.decodeHook(source: source, payload: payload, receivedAt: date)
    }

    public static func decode(
        source: String,
        payload: Data,
        receivedAt date: Date = .now,
        registry: AgentRegistry = .builtIn
    ) -> DecodedHook? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return decode(source: source, payload: object, receivedAt: date, registry: registry)
    }

    /// Hook payloads use empty strings and missing keys interchangeably.
    public static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
