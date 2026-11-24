import Foundation

/// ACP over an agent process's stdin and stdout. stderr is kept for failure messages.
public final class StdioTransport: ACPTransport {
    public let process: ChildProcess
    /// How long `close()` lets the agent exit on its own after its input closed, before SIGTERM.
    public let shutdownGracePeriod: Duration

    /// How long to wait for the process to exit once its output ended, to report its status.
    static let exitWait: Duration = .seconds(2)

    public init(process: ChildProcess, shutdownGracePeriod: Duration = .seconds(5)) {
        self.process = process
        self.shutdownGracePeriod = shutdownGracePeriod
    }

    /// Starts the agent. A bare executable name is looked up in `environment["PATH"]`.
    public convenience init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String? = nil,
        shutdownGracePeriod: Duration = .seconds(5)
    ) throws {
        let process = try ChildProcess(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory
        )
        self.init(process: process, shutdownGracePeriod: shutdownGracePeriod)
    }

    public var incoming: AsyncStream<Data> { process.output }

    /// The end of the agent's stderr, for telling the user why it failed.
    public var stderrText: String { process.stderrText }

    public func send(_ line: Data) async throws {
        var framed = line
        framed.append(0x0A)
        try await process.write(framed)
    }

    public func closeReason() async -> ACPCloseReason {
        switch await process.waitForExit(timeout: Self.exitWait) {
        case let .exited(code): .exited(code: code)
        case let .signaled(signal): .signaled(signal)
        case nil: .endOfStream
        }
    }

    /// Stops the agent and its process group; see `ChildProcess.shutdown`.
    public func close() async {
        await process.shutdown(gracePeriod: shutdownGracePeriod)
    }
}
