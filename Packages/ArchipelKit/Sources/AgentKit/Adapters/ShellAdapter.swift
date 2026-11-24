import ArchipelCore
import Foundation

public struct ShellAdapter: AgentAdapter {
    /// The user's login shell, falling back to the macOS default when `SHELL` is unset or empty.
    public static let loginShellPath = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"

    public init() {}

    public let id = "shell"
    public let displayName = "Shell"
    public let symbolName = "terminal"
    public var executableName: String { (Self.loginShellPath as NSString).lastPathComponent }
    // The shell is launched by its full path, which need not be in a folder on the PATH.
    public var executableToLocate: String { Self.loginShellPath }
    public let hookSources: Set<String> = []

    public var capabilities: AgentCapabilities {
        AgentCapabilities(
            sessionID: .none,
            lifecycle: .terminal,
            acceptsPrompts: false,
            answersApprovalsInTerminal: false,
            usage: nil,
            tracksSubagents: false,
            presetPlaceholder: "",
            settingsSections: []
        )
    }

    public func launchCommand(for context: LaunchContext) -> LaunchCommand {
        LaunchCommand(executable: Self.loginShellPath, arguments: ["-l"], environment: hookEnvironment(context))
    }

    public func resumeCommand(for context: LaunchContext, agentSessionID: String) -> LaunchCommand? { nil }

    /// Whatever runs in the shell and posts a notification is most likely asking something.
    public func attentionReason(forTerminalNotification body: String) -> AttentionReason? {
        .question
    }
}
