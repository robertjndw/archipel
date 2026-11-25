@testable import ACPKit
import Foundation
import Testing

/// The agent end of an in-memory connection, driven by the test.
final class FakeAgent: Sendable {
    let transport: InMemoryTransport
    /// Every message the client sent, decoded.
    let inbox: AsyncStream<JSONRPCMessage>

    init(_ transport: InMemoryTransport) {
        self.transport = transport
        let (inbox, continuation) = AsyncStream.makeStream(of: JSONRPCMessage.self, bufferingPolicy: .unbounded)
        self.inbox = inbox
        Task {
            var framer = JSONRPCLineFramer()
            for await chunk in transport.incoming {
                for line in (try? framer.append(chunk)) ?? [] {
                    if let message = try? JSONRPCMessage.decode(line) {
                        continuation.yield(message)
                    }
                }
            }
            continuation.finish()
        }
    }

    func send(_ json: String) throws {
        try transport.sendRaw(Data((json + "\n").utf8))
    }

    func send(_ message: JSONRPCMessage) throws {
        var line = try message.encoded()
        line.append(0x0A)
        try transport.sendRaw(line)
    }

    func respond(to id: JSONRPCID, result: JSONValue) throws {
        try send(.response(id: id, result: .success(result)))
    }

    func respond(to id: JSONRPCID, error code: Int, message: String = "failed") throws {
        try send(.response(id: id, result: .failure(JSONRPCError(code: code, message: message))))
    }

    /// Sends a `session/update` whose `update` object is given as JSON, which may span lines.
    func update(_ sessionId: String, _ update: String) throws {
        let compact = update.replacingOccurrences(of: "\n", with: "")
        try send(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"\#(sessionId)","update":\#(compact)}}"#)
    }

    func close() {
        transport.closeNow()
    }
}

/// A client wired to a fake agent.
func makeClient() -> (ACPClient, FakeAgent) {
    let (client, agent) = InMemoryTransport.pair()
    return (ACPClient(transport: client), FakeAgent(agent))
}

struct UnexpectedMessage: Error, CustomStringConvertible {
    let description: String
}

extension AsyncStream<JSONRPCMessage>.Iterator {
    /// The next message, which must be a request for `method`.
    mutating func request(_ method: String) async throws -> (id: JSONRPCID, params: JSONValue) {
        guard case let .request(id, actual, params) = await next() else {
            throw UnexpectedMessage(description: "Expected a \(method) request")
        }
        guard actual == method else { throw UnexpectedMessage(description: "Expected \(method), got \(actual)") }
        return (id, params ?? .null)
    }

    mutating func notification(_ method: String) async throws -> JSONValue {
        guard case let .notification(actual, params) = await next(), actual == method else {
            throw UnexpectedMessage(description: "Expected a \(method) notification")
        }
        return params ?? .null
    }

    mutating func response() async throws -> (id: JSONRPCID?, result: Result<JSONValue, JSONRPCError>) {
        guard case let .response(id, result) = await next() else {
            throw UnexpectedMessage(description: "Expected a response")
        }
        return (id, result)
    }
}

/// Runs `body` with a time limit, so a hang fails the test instead of the whole run.
func withTimeout<T: Sendable>(
    _ timeout: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let value = first else {
            Issue.record("Timed out after \(timeout)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        return value
    }
}

/// Reads events until `predicate` matches one, and returns everything read, that one included.
func events(
    from iterator: inout AsyncStream<ACPEvent>.Iterator,
    until predicate: (ACPEvent) -> Bool
) async -> [ACPEvent] {
    var collected: [ACPEvent] = []
    while let event = await iterator.next() {
        collected.append(event)
        if predicate(event) { break }
    }
    return collected
}

extension ACPEvent {
    var isPromptFinished: Bool {
        if case .promptFinished = self { true } else { false }
    }

    var isClosed: Bool {
        if case .closed = self { true } else { false }
    }

    var update: SessionUpdate? {
        if case let .sessionUpdate(notification) = self { notification.update } else { nil }
    }
}

func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

func jsonString(_ value: some Encodable) throws -> String {
    String(decoding: try ACPCoding.encode(value), as: UTF8.self)
}

/// Realistic `update` objects, one per variant.
enum UpdateSamples {
    static let userChunk = #"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Fix the bug"}}"#
    static let agentChunk = #"{"sessionUpdate":"agent_message_chunk","messageId":"msg_1","content":{"type":"text","text":"Looking at "},"_meta":{"x":1}}"#
    static let thoughtChunk = #"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"The user wants"}}"#
    static let toolCall = #"""
    {"sessionUpdate":"tool_call","toolCallId":"toolu_01","title":"Read src/main.swift","kind":"read","status":"pending",
     "locations":[{"path":"/repo/src/main.swift","line":12}],"rawInput":{"file_path":"/repo/src/main.swift","limit":40},
     "content":[{"type":"content","content":{"type":"text","text":"reading"}}]}
    """#
    static let toolCallUpdate = #"""
    {"sessionUpdate":"tool_call_update","toolCallId":"toolu_01","status":"completed",
     "content":[{"type":"diff","path":"/repo/a.swift","oldText":"let a = 1","newText":"let a = 2"},{"type":"terminal","terminalId":"term-1"}],
     "rawOutput":{"ok":true}}
    """#
    static let plan = #"""
    {"sessionUpdate":"plan","entries":[{"content":"Read the code","priority":"high","status":"completed"},
     {"content":"Write the fix","priority":"medium","status":"in_progress"},{"content":"Run tests","priority":"low","status":"pending"}]}
    """#
    static let commands = #"""
    {"sessionUpdate":"available_commands_update","availableCommands":[{"name":"compact","description":"Compact the conversation"},
     {"name":"review","description":"Review changes","input":{"hint":"branch or path"}}]}
    """#
    static let mode = #"{"sessionUpdate":"current_mode_update","currentModeId":"plan"}"#
    static let configOptions = #"""
    {"sessionUpdate":"config_option_update","configOptions":[{"id":"model","name":"Model","category":"model","type":"select",
     "currentValue":"sonnet","options":[{"value":"sonnet","name":"Sonnet"},{"value":"opus","name":"Opus","description":"Smartest"}]}]}
    """#
    static let sessionInfo = #"{"sessionUpdate":"session_info_update","title":"Fix login bug","updatedAt":"2026-11-24T10:00:00Z"}"#
    static let usage = #"{"sessionUpdate":"usage_update","used":53000,"size":200000,"cost":{"amount":0.42,"currency":"USD"}}"#
    static let unknown = #"{"sessionUpdate":"compaction_update","phase":"started","detail":{"tokens":120000}}"#
}
