import ACPKit
import Foundation

/// A started agent: the pipe to it, plus what a chat needs from the process behind it.
public struct ChatAgentConnection: Sendable {
    public var transport: any ACPTransport
    /// The end of the agent's stderr, for failure messages.
    public var stderrText: @Sendable () -> String
    /// Stops the process without waiting, for app quit.
    public var terminateNow: @Sendable () -> Void
    /// Waits up to the given time for the process to exit; false when it is still running then.
    public var waitForExit: @Sendable (Duration) async -> Bool

    public init(
        transport: any ACPTransport,
        stderrText: @escaping @Sendable () -> String = { "" },
        terminateNow: @escaping @Sendable () -> Void = {},
        waitForExit: @escaping @Sendable (Duration) async -> Bool = { _ in true }
    ) {
        self.transport = transport
        self.stderrText = stderrText
        self.terminateNow = terminateNow
        self.waitForExit = waitForExit
    }

    /// Starts `launch` as a child process in `workingDirectory`, with the app's environment plus
    /// the launch's variables.
    public static func spawn(_ launch: ChatLaunch, workingDirectory: String) throws -> ChatAgentConnection {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(launch.environment) { _, launch in launch }
        let transport = try StdioTransport(
            executable: launch.executable.path,
            arguments: launch.arguments,
            environment: environment,
            currentDirectory: workingDirectory
        )
        let process = transport.process
        return ChatAgentConnection(
            transport: transport,
            stderrText: { process.stderrText },
            terminateNow: { process.terminateNow() },
            waitForExit: { await process.waitForExit(timeout: $0) != nil }
        )
    }
}
