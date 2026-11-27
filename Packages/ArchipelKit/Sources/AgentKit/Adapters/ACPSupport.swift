/// How an agent runs as a chat over the Agent Client Protocol instead of in a terminal.
public struct ACPSupport: Sendable, Equatable {
    /// The agent's id in the ACP registry, which is where its adapter program and version come from.
    public var registryID: String
    public var launch: Launch
    /// The CLI and the ACP agent store one conversation under one id, so a session can move between
    /// the terminal and the chat without losing it.
    public var sharesConversationIDs: Bool
    /// Set on top of the inherited environment when the chat's agent process starts. Never holds
    /// `ARCHIPEL_SESSION_ID` or `ARCHIPEL_SOCKET`: terminal sessions report through hooks that need
    /// them, and a chat reports through the protocol, so a hook reaching the app would count twice.
    public var environment: [String: String]
    /// Ask the agent to report command output and exits in a tool call's `_meta`. Claude's agent
    /// then says when a command left in the background exits, which is the only way to know.
    public var rendersTerminalOutput: Bool

    public enum Launch: Sendable, Equatable {
        /// The agent's own CLI speaks ACP when started with these arguments.
        case cli(arguments: [String])
        /// A separate adapter program from the registry. `cliExecutableVariable` names the
        /// environment variable through which the adapter is told where the user's own CLI is, when
        /// it has one.
        case registry(cliExecutableVariable: String?)
    }

    public init(
        registryID: String,
        launch: Launch,
        sharesConversationIDs: Bool,
        environment: [String: String] = [:],
        rendersTerminalOutput: Bool = false
    ) {
        self.registryID = registryID
        self.launch = launch
        self.sharesConversationIDs = sharesConversationIDs
        self.environment = environment
        self.rendersTerminalOutput = rendersTerminalOutput
    }
}
