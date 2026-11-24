import Foundation

public enum ACPError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    case rpc(JSONRPCError)
    case unsupportedProtocolVersion(Int)
    /// The connection ended before the agent answered.
    case connectionClosed(ACPCloseReason)
    case invalidResponse(String)
    case encodingFailed(String)

    /// The agent wants the user to sign in first (`-32000`).
    public var isAuthenticationRequired: Bool {
        if case let .rpc(error) = self { error.isAuthenticationRequired } else { false }
    }

    /// The JSON-RPC error code, when the agent sent one.
    public var code: Int? {
        if case let .rpc(error) = self { error.code } else { nil }
    }

    public var description: String {
        switch self {
        case let .rpc(error): error.description
        case let .unsupportedProtocolVersion(version): "The agent speaks ACP version \(version), which this app does not support"
        case let .connectionClosed(reason): reason.description
        case let .invalidResponse(message): "Unexpected answer from the agent: \(message)"
        case let .encodingFailed(message): "Could not encode a message: \(message)"
        }
    }

    public var errorDescription: String? { description }
}

/// Everything that arrives from the agent, in the order it arrived.
///
/// One stream on purpose: a turn's result must never overtake the updates sent before it, so
/// replies the consumer has to order against updates come through here too.
public enum ACPEvent: Sendable, Hashable {
    case sessionUpdate(SessionNotification)
    /// The agent asks the user to allow a tool call. Answer through `respond(toPermission:with:)`.
    case permissionRequest(id: JSONRPCID, RequestPermissionRequest)
    /// The agent withdrew a permission request it sent earlier (Codex does after `session/cancel`).
    /// The connection already answered it as cancelled; the UI should drop the prompt.
    case permissionRequestWithdrawn(id: JSONRPCID)
    /// The reply to `session/prompt`: the turn is over, and every update of it came before this.
    /// A JSON-RPC error, such as `-32000` from Claude when signed out, arrives as a failure here.
    case promptFinished(sessionId: String, result: Result<PromptResponse, ACPError>)
    /// `session/load` was sent. Every update until `.sessionLoaded` is history being replayed;
    /// the replay itself carries no marker.
    case replayStarted(sessionId: String)
    /// The reply to `session/load`: the history replay is over.
    case sessionLoaded(sessionId: String, result: Result<SessionSetup, ACPError>)
    /// The agent's sign-in state from its `auth/status_update` notification, such as
    /// "authenticated" or "unauthenticated". Only the state is kept: the rest names the account.
    case authStatus(state: String)
    /// Always the last event. Every outstanding request has failed by then.
    case closed(ACPCloseReason)
}

/// A JSON-RPC connection to an agent, with the ACP specifics of which replies need ordering.
///
/// Requests from the agent the client does not handle are answered with `-32601`, unknown
/// notifications and lines that are not JSON are ignored, so one bad message never ends the
/// connection. Reading starts on creation and stops when the transport ends or `close()` is called;
/// until then the connection keeps itself alive, so always close it.
public actor ACPConnection {
    public nonisolated let events: AsyncStream<ACPEvent>

    private let transport: any ACPTransport
    private let eventSink: AsyncStream<ACPEvent>.Continuation
    /// Every outgoing line goes through here, so lines are written in exactly the order the actor
    /// produced them. Awaiting the transport directly would let reentrant calls overtake each other.
    private let outbox: AsyncStream<Data>.Continuation
    private var nextID = 0
    private var pending: [JSONRPCID: Pending] = [:]
    /// Open permission requests and their session, so cancelling a session can answer them.
    private var permissions: [JSONRPCID: (sessionId: String, sequence: Int)] = [:]
    private var permissionSequence = 0
    private var endReason: ACPCloseReason?
    private let maximumMessageSize: Int
    /// Lines queued and lines handed to the transport, so `close()` can let the queue drain.
    private var queuedLines = 0
    private var writtenLines = 0
    private var flushWaiters: [Int: (target: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextFlushWaiter = 0

    private enum OrderedReply {
        case prompt(sessionId: String)
        case loadSession(sessionId: String)
    }

    private struct Pending {
        let sequence: Int
        var continuation: CheckedContinuation<Data, any Error>?
        var ordered: OrderedReply?
    }

    /// `maximumMessageSize` bounds a single incoming line; a longer one ends the connection.
    public init(transport: any ACPTransport, maximumMessageSize: Int = 256 << 20) {
        self.transport = transport
        self.maximumMessageSize = maximumMessageSize
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        let (outgoing, outbox) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        self.outbox = outbox
        Task { await self.readLoop() }
        Task { await self.writeLoop(outgoing) }
    }

    /// Why the connection ended, or nil while it is open.
    public var closeReason: ACPCloseReason? { endReason }

    /// Oldest first.
    public var openPermissionRequests: [JSONRPCID] {
        permissions.sorted { $0.value.sequence < $1.value.sequence }.map(\.key)
    }

    // MARK: Sending

    /// Sends a request and waits for its result.
    public func request<Result: Decodable & Sendable>(
        _ method: String,
        params: some Encodable & Sendable,
        returning: Result.Type = Result.self
    ) async throws -> Result {
        let data = try await sendAndWait(method, params: params, ordered: nil)
        return try Self.decodeResult(Result.self, from: data).get()
    }

    /// Sends `session/prompt` without waiting. The reply arrives as `.promptFinished` in `events`,
    /// after every update the agent sent before it.
    @discardableResult
    public func sendPrompt(_ params: PromptRequest) throws -> JSONRPCID {
        try ensureOpen()
        let (id, line) = try makeRequest(ACPMethod.sessionPrompt, params: params)
        pending[id] = Pending(sequence: nextID, continuation: nil, ordered: .prompt(sessionId: params.sessionId))
        enqueue(line)
        return id
    }

    /// Sends `session/load` and waits for it. `events` brackets the replayed history with
    /// `.replayStarted` and `.sessionLoaded`, which is what a consumer that needs to tell replayed
    /// updates from live ones should go by: this method can return before the consumer has read
    /// the last replayed update.
    public func loadSession(_ params: ExistingSessionRequest) async throws -> SessionSetup {
        let data = try await sendAndWait(ACPMethod.sessionLoad, params: params, ordered: .loadSession(sessionId: params.sessionId))
        return try Self.decodeResult(SessionSetup.self, from: data).get()
    }

    public func notify(_ method: String, params: some Encodable & Sendable) throws {
        try ensureOpen()
        enqueue(try encode { try JSONRPCEncoding.notification(method: method, params: params) })
    }

    /// Answers a request the agent sent.
    public func respond(to id: JSONRPCID, result: some Encodable & Sendable) throws {
        try ensureOpen()
        enqueue(try encode { try JSONRPCEncoding.response(id: id, result: result) })
    }

    /// Answers a request the agent sent with an error.
    public func respond(to id: JSONRPCID, error: JSONRPCError) throws {
        try ensureOpen()
        enqueue(try encode { try JSONRPCEncoding.response(id: id, error: error) })
    }

    /// Answers a permission request. Returns false when it is no longer open, for instance because
    /// `cancel(sessionId:)` already answered it, in which case nothing is sent.
    @discardableResult
    public func respond(toPermission id: JSONRPCID, with outcome: RequestPermissionOutcome) -> Bool {
        guard endReason == nil, permissions.removeValue(forKey: id) != nil else { return false }
        try? respond(to: id, result: RequestPermissionResponse(outcome: outcome))
        return true
    }

    /// Sends `session/cancel` and answers every open permission request of the session with
    /// `cancelled`, as the protocol requires. Updates keep arriving until the prompt finishes.
    public func cancel(sessionId: String) {
        guard endReason == nil else { return }
        try? notify(ACPMethod.sessionCancel, params: SessionIdParams(sessionId: sessionId))
        let open = permissions
            .filter { $0.value.sessionId == sessionId }
            .sorted { $0.value.sequence < $1.value.sequence }
        for (id, _) in open {
            respond(toPermission: id, with: .cancelled)
        }
    }

    /// Ends the connection and closes the transport. Outstanding requests fail and `events`
    /// finishes with `.closed(.closedByClient)`.
    ///
    /// Lines already queued, such as a `session/cancel` sent just before, are written first, for
    /// up to a second: closing a process transport closes the agent's input, and anything
    /// written after that is lost.
    public func close() async {
        await flush(within: .seconds(1))
        await finish(.closedByClient)
    }

    private func enqueue(_ line: Data) {
        queuedLines += 1
        outbox.yield(line)
    }

    /// Returns once every line queued so far was handed to the transport, or after `limit`, so an
    /// agent that stopped reading cannot hold a close up.
    private func flush(within limit: Duration) async {
        let target = queuedLines
        guard endReason == nil, writtenLines < target else { return }
        let id = nextFlushWaiter
        nextFlushWaiter += 1
        let timer = Task {
            try? await Task.sleep(for: limit)
            self.resumeFlushWaiter(id)
        }
        await withCheckedContinuation { flushWaiters[id] = (target, $0) }
        timer.cancel()
    }

    private func resumeFlushWaiter(_ id: Int) {
        flushWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    private func sendAndWait(_ method: String, params: some Encodable & Sendable, ordered: OrderedReply?) async throws -> Data {
        try ensureOpen()
        let (id, line) = try makeRequest(method, params: params)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = Pending(sequence: nextID, continuation: continuation, ordered: ordered)
            // Yielded before the request is even queued, so it precedes every replayed update.
            if case let .loadSession(sessionId) = ordered {
                eventSink.yield(.replayStarted(sessionId: sessionId))
            }
            enqueue(line)
        }
    }

    private func makeRequest(_ method: String, params: some Encodable) throws -> (JSONRPCID, Data) {
        let id = JSONRPCID.int(nextID)
        let line = try encode { try JSONRPCEncoding.request(id: id, method: method, params: params) }
        nextID += 1
        return (id, line)
    }

    private func encode(_ body: () throws -> Data) throws -> Data {
        do {
            return try body()
        } catch {
            throw ACPError.encodingFailed(String(describing: error))
        }
    }

    private func ensureOpen() throws {
        if let endReason { throw ACPError.connectionClosed(endReason) }
    }

    // MARK: Receiving

    private func readLoop() async {
        var framer = JSONRPCLineFramer(maximumLineLength: maximumMessageSize)
        for await chunk in transport.incoming {
            guard endReason == nil else { break }
            do {
                for line in try framer.append(chunk) {
                    receive(line)
                }
            } catch {
                await finish(.protocolError("A message exceeded \(error.limit) bytes"))
                return
            }
        }
        guard endReason == nil else { return }
        await finish(await transport.closeReason())
    }

    private func writeLoop(_ lines: AsyncStream<Data>) async {
        for await line in lines {
            do {
                try await transport.send(line)
                writtenLines += 1
                for (id, waiter) in flushWaiters where waiter.target <= writtenLines {
                    resumeFlushWaiter(id)
                }
            } catch {
                guard endReason == nil else { return }
                // The agent is usually on its way out when its input breaks; its exit status says
                // more than the write error does.
                let reason = await transport.closeReason()
                await finish(reason == .endOfStream ? .transportError(String(describing: error)) : reason)
                return
            }
        }
    }

    private func receive(_ line: Data) {
        // Not JSON-RPC at all: some agents print stray output on stdout. Skipping it beats dying.
        guard let header = try? ACPCoding.decode(JSONRPCHeader.self, from: line) else { return }
        switch header.kind {
        case let .response(id, error):
            guard let id, let entry = pending.removeValue(forKey: id) else { return }
            complete(entry, with: error.map { .failure(.rpc($0)) } ?? .success(line))
        case let .request(id, method):
            receiveRequest(id: id, method: method, line: line)
        case let .notification(method):
            receiveNotification(method: method, line: line)
        }
    }

    private func receiveRequest(id: JSONRPCID, method: String, line: Data) {
        switch method {
        case ACPMethod.sessionRequestPermission:
            guard let params = (try? ACPCoding.decode(ParamsEnvelope<RequestPermissionRequest>.self, from: line))?.params else {
                try? respond(to: id, error: JSONRPCError(code: JSONRPCError.invalidParams, message: "Invalid params for \(method)"))
                return
            }
            permissionSequence += 1
            permissions[id] = (params.sessionId, permissionSequence)
            eventSink.yield(.permissionRequest(id: id, params))
        default:
            try? respond(to: id, error: JSONRPCError(code: JSONRPCError.methodNotFound, message: "Method not found: \(method)"))
        }
    }

    private struct CancelRequestParams: Decodable {
        let requestId: JSONRPCID
    }

    private struct AuthStatusParams: Decodable {
        let state: String
    }

    // Agents send notifications outside the spec without the `_` prefix it asks for, so anything
    // unrecognized is ignored whatever its name. Payloads are never logged: some carry the
    // user's email address.
    private func receiveNotification(method: String, line: Data) {
        switch method {
        case ACPMethod.sessionUpdate:
            // A malformed update is dropped on its own; the rest of the turn is still worth showing.
            guard let params = (try? ACPCoding.decode(ParamsEnvelope<SessionNotification>.self, from: line))?.params else { return }
            eventSink.yield(.sessionUpdate(params))
        case "$/cancel_request":
            // The id is one of the agent's, so it can only name a request the agent sent us.
            // Ours live in `pending` and are never confused with it, even when both are 0.
            guard
                let params = (try? ACPCoding.decode(ParamsEnvelope<CancelRequestParams>.self, from: line))?.params,
                respond(toPermission: params.requestId, with: .cancelled)
            else { return }
            eventSink.yield(.permissionRequestWithdrawn(id: params.requestId))
        case "auth/status_update", "_auth/status_update":
            guard let params = (try? ACPCoding.decode(ParamsEnvelope<AuthStatusParams>.self, from: line))?.params else { return }
            eventSink.yield(.authStatus(state: params.state))
        default:
            break
        }
    }

    private func complete(_ entry: Pending, with outcome: Swift.Result<Data, ACPError>) {
        switch entry.ordered {
        case let .prompt(sessionId):
            eventSink.yield(.promptFinished(sessionId: sessionId, result: outcome.flatMap { Self.decodeResult(PromptResponse.self, from: $0) }))
        case let .loadSession(sessionId):
            eventSink.yield(.sessionLoaded(sessionId: sessionId, result: outcome.flatMap { Self.decodeResult(SessionSetup.self, from: $0) }))
        case nil:
            break
        }
        entry.continuation?.resume(with: outcome.mapError { $0 as any Error })
    }

    private static func decodeResult<T: Decodable>(_ type: T.Type, from line: Data) -> Swift.Result<T, ACPError> {
        do {
            if let result = try ACPCoding.decode(ResultEnvelope<T>.self, from: line).result {
                return .success(result)
            }
            // `null` where `{}` was meant; types whose fields are all optional still make sense of it.
            return .success(try JSONValue.object([:]).decode(as: T.self))
        } catch {
            return .failure(.invalidResponse(String(describing: error)))
        }
    }

    // MARK: Closing

    private func finish(_ reason: ACPCloseReason) async {
        guard endReason == nil else { return }
        endReason = reason
        let error = ACPError.connectionClosed(reason)
        let failed = pending.values.sorted { $0.sequence < $1.sequence }
        pending = [:]
        permissions = [:]
        for entry in failed {
            complete(entry, with: .failure(error))
        }
        eventSink.yield(.closed(reason))
        eventSink.finish()
        outbox.finish()
        for id in flushWaiters.keys { resumeFlushWaiter(id) }
        await transport.close()
    }
}
