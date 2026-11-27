import Foundation

/// The typed ACP client the app talks to: one agent process, any number of sessions.
///
/// Everything the agent sends arrives through `events`, in wire order. Read it from one task for
/// the client's whole life; prompt results come through it too.
public final class ACPClient: Sendable {
    public static let protocolVersion = 1

    public let connection: ACPConnection

    public var events: AsyncStream<ACPEvent> { connection.events }

    public init(transport: any ACPTransport, maximumMessageSize: Int = 256 << 20) {
        connection = ACPConnection(transport: transport, maximumMessageSize: maximumMessageSize)
    }

    /// Negotiates the protocol. Throws `ACPError.unsupportedProtocolVersion` when the agent
    /// answers with a version other than 1; the caller should then shut the agent down.
    ///
    /// `rendersTerminalOutput` asks the agent to report a command's output and exit in a tool
    /// call's `_meta` (`terminal_output`, `terminal_exit`), as Zed's clients do. Claude's agent
    /// then also reports when a command it left running in the background exits, which it
    /// otherwise never says.
    public func initialize(clientInfo: Implementation, rendersTerminalOutput: Bool = false) async throws -> InitializeResponse {
        let params = InitializeRequest(
            protocolVersion: Self.protocolVersion,
            // Files and terminals stay with the agent. Terminal sign-in is something the app can run.
            clientCapabilities: ClientCapabilities(
                fs: .init(), terminal: false, auth: .init(terminal: true),
                meta: rendersTerminalOutput ? ["terminal_output": true] : nil
            ),
            clientInfo: clientInfo
        )
        let response = try await connection.request(ACPMethod.initialize, params: params, returning: InitializeResponse.self)
        guard response.protocolVersion == Self.protocolVersion else {
            throw ACPError.unsupportedProtocolVersion(response.protocolVersion)
        }
        return response
    }

    /// Runs an agent-type auth method.
    public func authenticate(methodId: String) async throws {
        _ = try await connection.request(ACPMethod.authenticate, params: AuthenticateRequest(methodId: methodId), returning: EmptyResult.self)
    }

    /// Starts a session in `cwd`, an absolute path. May fail with `isAuthenticationRequired`.
    public func newSession(cwd: String) async throws -> NewSessionResponse {
        try await connection.request(ACPMethod.sessionNew, params: NewSessionRequest(cwd: cwd), returning: NewSessionResponse.self)
    }

    /// Reopens a session with its history, which the agent replays as updates before answering.
    /// Only when the agent advertises `loadSession`. `events` brackets the replay with
    /// `.replayStarted` and `.sessionLoaded`; go by those, since this method can return before
    /// the last replayed update is read.
    public func loadSession(id: String, cwd: String) async throws -> SessionSetup {
        try await connection.loadSession(ExistingSessionRequest(sessionId: id, cwd: cwd))
    }

    /// Reopens a session without replaying its history. Only when the agent advertises
    /// `sessionCapabilities.resume`.
    public func resumeSession(id: String, cwd: String) async throws -> SessionSetup {
        try await connection.request(ACPMethod.sessionResume, params: ExistingSessionRequest(sessionId: id, cwd: cwd), returning: SessionSetup.self)
    }

    /// Ends a session on the agent's side. Only when the agent advertises `sessionCapabilities.close`.
    public func closeSession(id: String) async throws {
        do {
            _ = try await connection.request(ACPMethod.sessionClose, params: SessionIdParams(sessionId: id), returning: EmptyResult.self)
        } catch let error as ACPError where error.code == JSONRPCError.resourceNotFound {
            // Already gone, which is what closing wanted.
        }
    }

    /// Starts a turn. The turn ends with `.promptFinished` in `events`, after all its updates.
    @discardableResult
    public func prompt(sessionId: String, blocks: [ContentBlock]) async throws -> JSONRPCID {
        try await connection.sendPrompt(PromptRequest(sessionId: sessionId, prompt: blocks))
    }

    /// Asks the agent to stop the running turn and answers its open permission requests with
    /// `cancelled`. The turn still ends through `.promptFinished`, normally with `.cancelled`.
    public func cancel(sessionId: String) async {
        await connection.cancel(sessionId: sessionId)
    }

    /// Switches the session's mode. Agents send no `current_mode_update` for it, so update local
    /// state once this returns.
    public func setMode(sessionId: String, modeId: String) async throws {
        _ = try await connection.request(ACPMethod.sessionSetMode, params: SetModeRequest(sessionId: sessionId, modeId: modeId), returning: EmptyResult.self)
    }

    /// Changes a config option and returns the full updated list.
    public func setConfigOption(sessionId: String, configId: String, value: JSONValue) async throws -> [SessionConfigOption] {
        let params = SetConfigOptionRequest(sessionId: sessionId, configId: configId, value: value)
        return try await connection.request(ACPMethod.sessionSetConfigOption, params: params, returning: SetConfigOptionResponse.self).configOptions
    }

    /// Answers a permission request from `events`. Returns false when it was already answered,
    /// withdrawn or the connection is gone.
    @discardableResult
    public func respond(toPermission id: JSONRPCID, with outcome: RequestPermissionOutcome) async -> Bool {
        await connection.respond(toPermission: id, with: outcome)
    }

    /// Closes the connection and stops the agent. With a `StdioTransport` this closes the agent's
    /// input and escalates to signals if it does not exit on its own.
    public func shutdown() async {
        await connection.close()
    }
}
