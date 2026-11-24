import ArchipelCore
import Foundation

public struct OpenCodeAdapter: AgentAdapter {
    public init() {}

    public let id = "opencode"
    public let displayName = "OpenCode"
    public let symbolName = "chevron.left.forwardslash.chevron.right"
    public let executableName = "opencode"
    public let hookSources: Set<String> = ["opencode"]

    public var acp: ACPSupport? {
        ACPSupport(registryID: "opencode", launch: .cli(arguments: ["acp"]), sharesConversationIDs: true)
    }

    /// OpenCode rejects ids that do not start with this.
    static let sessionIDPrefix = "ses_"

    public var capabilities: AgentCapabilities {
        AgentCapabilities(
            sessionID: .presetByApp,
            // The plugin is left out when the user's cli.json cannot be read safely, and that
            // session then has to be followed through its terminal.
            lifecycle: .hooksOnceSeen,
            acceptsPrompts: true,
            // The permission prompt is a row of buttons without a numbered menu to type into.
            answersApprovalsInTerminal: false,
            usage: nil,
            tracksSubagents: false,
            presetPlaceholder: "--standalone",
            settingsSections: [.openCodeIntegration]
        )
    }

    /// `opencode -s` creates the session when the id is new and resumes it when it exists.
    public func launchCommand(for context: LaunchContext) -> LaunchCommand {
        LaunchCommand(
            executable: executableName,
            arguments: context.agentSessionID.map { ["-s", $0] } ?? [],
            environment: Self.environment(context)
        )
    }

    public func resumeCommand(for context: LaunchContext, agentSessionID: String) -> LaunchCommand? {
        LaunchCommand(
            executable: executableName,
            arguments: ["-s", agentSessionID],
            environment: Self.environment(context)
        )
    }

    /// OpenCode wants ids of at most 32 characters starting with `ses`; a bare UUID is refused.
    public func makePresetSessionID() -> String {
        Self.sessionIDPrefix + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(28)
    }

    /// The terminal title is "OpenCode" until the conversation has a name, then "OC | <name>".
    public func conversationTitle(fromTerminalTitle title: String) -> String? {
        let prefix = "OC | "
        guard title.hasPrefix(prefix) else { return nil }
        let name = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public func attentionReason(forTerminalNotification body: String) -> AttentionReason? { nil }

    public func decodeHook(source: String, payload: [String: Any], receivedAt date: Date) -> DecodedHook? {
        DecodedHook(
            event: Self.event(payload),
            agentSessionID: HookDecoder.nonEmptyString(payload["opencodeSessionID"])
        )
    }

    static func event(_ payload: [String: Any]) -> AgentEvent? {
        switch payload["event"] as? String {
        case "started":
            return .sessionStarted
        case "switched":
            // The tab now shows another conversation, which may be mid-turn.
            return (payload["running"] as? Bool) == true ? .activity : .sessionStarted
        case "prompt":
            return .promptSubmitted
        case "busy", "permission-replied":
            return .activity
        case "idle":
            return .turnFinished(message: nil)
        case "error":
            return .turnFinished(message: HookDecoder.nonEmptyString(payload["message"]))
        case "permission":
            let resources = (payload["resources"] as? [String])?.joined(separator: ", ")
            let message = HookDecoder.nonEmptyString(resources) ?? HookDecoder.nonEmptyString(payload["action"])
            return .attentionRequested(.permission, message: message)
        case "question":
            return .attentionRequested(.question, message: nil)
        default:
            return nil
        }
    }

    static func environment(_ context: LaunchContext) -> [String: String] {
        var environment = hookEnvironment(context)
        environment["ARCHIPEL_HOOK_BIN"] = context.hookExecutableURL.path
        if let directory = context.opencodePluginDirectory, let userPlugins = context.opencodeUserPlugins {
            environment["OPENCODE_CLI_CONFIG_CONTENT"] = OpenCodeCLIConfig.injectedConfig(
                userPlugins: userPlugins,
                pluginDirectory: directory
            )
        }
        return environment
    }
}
