import ACPKit
import ArchipelCore
@testable import ChatUI
import Foundation
import Synchronization
import Testing

/// The agent's side of an in-memory connection. Session setup calls are answered from a script;
/// prompts are left open for the test to drive.
final class ScriptedAgent: Sendable {
    enum Reply: Sendable {
        case result(JSONValue)
        case error(Int, String)
        /// Never answered.
        case silent
    }

    struct Script: Sendable {
        var initialize: Reply = .result(ScriptedAgent.initializeResult())
        /// One reply per `session/new`, in order; the last one repeats.
        var newSession: [Reply] = [.result(["sessionId": "s-new"])]
        /// `update` objects sent as history before `session/load` is answered.
        var replay: [String] = []
        var load: Reply = .result([:])
        var resume: Reply = .result([:])
        var authenticate: Reply = .result([:])
        var setMode: Reply = .result([:])
        var setConfigOption: Reply = .result(["configOptions": []])
    }

    let transport: InMemoryTransport
    private let state: Mutex<State>

    private struct State {
        var script: Script
        var received: [JSONRPCMessage] = []
        var newSessionCount = 0
    }

    init(_ transport: InMemoryTransport, script: Script) {
        self.transport = transport
        state = Mutex(State(script: script))
        Task.detached { [self] in
            var framer = JSONRPCLineFramer()
            for await chunk in transport.incoming {
                for line in (try? framer.append(chunk)) ?? [] {
                    guard let message = try? JSONRPCMessage.decode(line) else { continue }
                    state.withLock { $0.received.append(message) }
                    if case let .request(id, method, params) = message {
                        handle(id: id, method: method, params: params ?? .null)
                    }
                }
            }
        }
    }

    static func initializeResult(
        loadSession: Bool = false,
        resume: Bool = false,
        image: Bool = false,
        protocolVersion: Int = 1,
        authMethods: [JSONValue] = []
    ) -> JSONValue {
        [
            "protocolVersion": .number(Double(protocolVersion)),
            "agentCapabilities": [
                "loadSession": .bool(loadSession),
                "promptCapabilities": ["image": .bool(image)],
                "sessionCapabilities": resume ? ["resume": [:]] : [:],
            ],
            "agentInfo": ["name": "fake-agent", "title": "Fake Agent", "version": "1.0.0"],
            "authMethods": .array(authMethods),
        ]
    }

    func editScript(_ body: (inout Script) -> Void) {
        state.withLock { body(&$0.script) }
    }

    private func handle(id: JSONRPCID, method: String, params: JSONValue) {
        let script = state.withLock { $0.script }
        switch method {
        case ACPMethod.initialize: reply(id, script.initialize)
        case ACPMethod.authenticate: reply(id, script.authenticate)
        case ACPMethod.sessionNew:
            let index = state.withLock { state in
                defer { state.newSessionCount += 1 }
                return state.newSessionCount
            }
            if let last = script.newSession.last {
                reply(id, index < script.newSession.count ? script.newSession[index] : last)
            }
        case ACPMethod.sessionLoad:
            let sessionId = params["sessionId"]?.stringValue ?? ""
            for update in script.replay {
                try? self.update(sessionId, update)
            }
            reply(id, script.load)
        case ACPMethod.sessionResume: reply(id, script.resume)
        case ACPMethod.sessionSetMode: reply(id, script.setMode)
        case ACPMethod.sessionSetConfigOption: reply(id, script.setConfigOption)
        default:
            // Prompts stay open: the test finishes them.
            break
        }
    }

    private func reply(_ id: JSONRPCID, _ reply: Reply) {
        switch reply {
        case let .result(value): try? send(.response(id: id, result: .success(value)))
        case let .error(code, message): try? send(.response(id: id, result: .failure(JSONRPCError(code: code, message: message))))
        case .silent: break
        }
    }

    // MARK: What the client sent

    var received: [JSONRPCMessage] { state.withLock { $0.received } }

    func requests(_ method: String) -> [(id: JSONRPCID, params: JSONValue)] {
        received.compactMap { message in
            guard case let .request(id, actual, params) = message, actual == method else { return nil }
            return (id, params ?? .null)
        }
    }

    func notifications(_ method: String) -> [JSONValue] {
        received.compactMap { message in
            guard case let .notification(actual, params) = message, actual == method else { return nil }
            return params ?? .null
        }
    }

    /// Answers the client sent to the agent's own requests, such as permission requests.
    var responses: [(id: JSONRPCID?, result: Result<JSONValue, JSONRPCError>)] {
        received.compactMap { message in
            guard case let .response(id, result) = message else { return nil }
            return (id, result)
        }
    }

    // MARK: Driving the client

    func send(_ message: JSONRPCMessage) throws {
        var line = try message.encoded()
        line.append(0x0A)
        try transport.sendRaw(line)
    }

    /// Sends a `session/update` whose `update` object is given as JSON.
    func update(_ sessionId: String, _ update: String) throws {
        let compact = update.replacingOccurrences(of: "\n", with: "")
        try transport.sendRaw(Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"\#(sessionId)","update":\#(compact)}}"#.utf8 + [0x0A]))
    }

    func agentText(_ sessionId: String, _ text: String, messageId: String? = nil) throws {
        let content = try JSONValue(encoding: ContentBlock.text(text))
        var update: JSONValue = ["sessionUpdate": "agent_message_chunk", "content": content]
        if let messageId, case var .object(fields) = update {
            fields["messageId"] = .string(messageId)
            update = .object(fields)
        }
        try send(.notification(method: ACPMethod.sessionUpdate, params: ["sessionId": .string(sessionId), "update": update]))
    }

    func finishPrompt(_ id: JSONRPCID, stopReason: String = "end_turn") throws {
        try send(.response(id: id, result: .success(["stopReason": .string(stopReason)])))
    }

    func failPrompt(_ id: JSONRPCID, code: Int, message: String) throws {
        try send(.response(id: id, result: .failure(JSONRPCError(code: code, message: message))))
    }

    func requestPermission(
        id: JSONRPCID,
        sessionId: String,
        toolCall: JSONValue,
        options: JSONValue = ScriptedAgent.standardOptions
    ) throws {
        try send(.request(
            id: id, method: ACPMethod.sessionRequestPermission,
            params: ["sessionId": .string(sessionId), "toolCall": toolCall, "options": options]
        ))
    }

    func withdraw(_ id: JSONRPCID) throws {
        try send(.notification(method: "$/cancel_request", params: ["requestId": try JSONValue(encoding: id)]))
    }

    static let standardOptions: JSONValue = [
        ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
        ["optionId": "always", "name": "Always Allow", "kind": "allow_always"],
        ["optionId": "reject", "name": "Reject", "kind": "reject_once"],
    ]

    func close() {
        transport.closeNow()
    }
}

/// A mutex that closures can share.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}

struct TimedOut: Error, CustomStringConvertible {
    let description: String
}

/// Polls `condition` until it holds. Polling is only for waiting; nothing depends on its timing.
@MainActor
func waitUntil(
    _ what: String,
    timeout: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting until \(what)", sourceLocation: sourceLocation)
            throw TimedOut(description: what)
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// A chat session wired to scripted agents, one per launch, with its events recorded.
@MainActor
final class ChatHarness {
    let session: ChatSession
    private(set) var events: [ChatSession.Event] = []
    private let launched: Locked<[ScriptedAgent]>
    private let template: Locked<ScriptedAgent.Script>
    let stderr: Locked<String>
    /// How often a connection's `terminateNow` was called.
    let terminations = Locked(0)

    /// `exits` is whether the fake process counts as exited when asked to wait for it.
    init(
        script: ScriptedAgent.Script = ScriptedAgent.Script(),
        existingSessionID: String? = nil,
        stderr: String = "",
        timing: ChatSession.Timing = ChatSession.Timing(request: .seconds(5), loadSession: .seconds(5), cancelGrace: .seconds(5)),
        exits: Bool = true,
        resolveLaunch: (@Sendable (@escaping @Sendable (ChatLauncher.Progress) -> Void) async throws -> ChatLaunch)? = nil
    ) {
        let launched = Locked<[ScriptedAgent]>([])
        let template = Locked(script)
        let stderrText = Locked(stderr)
        let terminations = terminations
        self.launched = launched
        self.template = template
        self.stderr = stderrText
        let configuration = ChatSession.Configuration(
            agentName: "Fake Agent",
            workingDirectory: "/repo",
            existingAgentSessionID: existingSessionID,
            clientInfo: Implementation(name: "archipel-tests", version: "1.0"),
            resolveLaunch: resolveLaunch ?? { _ in ChatLaunch(executable: URL(fileURLWithPath: "/usr/bin/true")) },
            connect: { _, _ in
                let (client, agentEnd) = InMemoryTransport.pair()
                let agent = ScriptedAgent(agentEnd, script: template.withLock { $0 })
                launched.withLock { $0.append(agent) }
                return ChatAgentConnection(
                    transport: client,
                    stderrText: { stderrText.withLock { $0 } },
                    terminateNow: {
                        terminations.withLock { $0 += 1 }
                        agentEnd.closeNow()
                    },
                    waitForExit: { _ in exits }
                )
            },
            timing: timing
        )
        session = ChatSession(configuration: configuration)
        session.onEvent = { [weak self] event in self?.events.append(event) }
    }

    /// The agent of the latest launch.
    func agent(sourceLocation: SourceLocation = #_sourceLocation) throws -> ScriptedAgent {
        try #require(launched.withLock { $0.last }, sourceLocation: sourceLocation)
    }

    var launchCount: Int { launched.withLock { $0.count } }

    /// Changes the script future launches get.
    func editTemplate(_ body: (inout ScriptedAgent.Script) -> Void) {
        template.withLock { body(&$0) }
    }

    func clearEvents() {
        events = []
    }

    /// The `AgentEvent`s sent, with runs of `.activity` collapsed: how many there are depends on
    /// timing, by design.
    var agentEvents: [AgentEvent] {
        var result: [AgentEvent] = []
        for case let .agent(event) in events where !(event == .activity && result.last == .activity) {
            result.append(event)
        }
        return result
    }

    /// Starts and expects the chat to become ready.
    func start(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await session.start()
        #expect(session.phase == .ready, sourceLocation: sourceLocation)
    }

    /// Sends `text` and returns the id of the prompt request the agent received.
    @discardableResult
    func send(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> JSONRPCID {
        let agent = try agent(sourceLocation: sourceLocation)
        let before = agent.requests(ACPMethod.sessionPrompt).count
        session.draft = text
        #expect(session.send(), sourceLocation: sourceLocation)
        try await waitUntil("the prompt arrives", sourceLocation: sourceLocation) {
            agent.requests(ACPMethod.sessionPrompt).count > before
        }
        return try #require(agent.requests(ACPMethod.sessionPrompt).last?.id, sourceLocation: sourceLocation)
    }
}

extension ChatTranscript {
    /// Items reduced to what a reader sees, so live and replayed transcripts can be compared.
    var readableItems: [String] {
        items.map { item in
            switch item {
            case let .userMessage(message): "user: \(message.text)"
            case let .agentMessage(message): "agent: \(message.text)"
            case let .agentThought(message): "thought: \(message.text)"
            case let .toolCall(call): "tool \(call.toolCallId) \(call.kind.rawValue) \(call.status.rawValue): \(call.title)"
            }
        }
    }
}

extension ChatSession.Phase {
    var failure: ChatFailure? {
        if case let .failed(failure) = self { failure } else { nil }
    }

    var ending: ChatEnding? {
        if case let .ended(ending) = self { ending } else { nil }
    }
}
