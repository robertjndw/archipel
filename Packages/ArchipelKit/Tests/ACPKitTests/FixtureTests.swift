@testable import ACPKit
import Foundation
import Testing

/// Messages captured from the real Claude, Codex and OpenCode adapters, scrubbed of personal data.
enum Fixture {
    static var directory: URL {
        get throws {
            try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil), "Fixtures folder missing from the test bundle")
        }
    }

    static func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    /// The messages in a fixture; files hold one message or an array of them.
    static func messages(_ name: String) throws -> [JSONValue] {
        let data = try Data(contentsOf: directory.appending(path: "\(name).json"))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return value.arrayValue ?? [value]
    }

    static func message(_ name: String) throws -> JSONValue {
        try #require(messages(name).first)
    }

    /// One message as a single wire line.
    static func line(_ message: JSONValue) throws -> Data {
        try ACPCoding.encode(message)
    }

    /// The `result` of a response fixture, decoded as `type`.
    static func result<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        try #require(try message(name)["result"]).decode(as: type)
    }

    static func updates(_ name: String) throws -> [SessionUpdate] {
        try messages(name)
            .filter { $0["method"]?.stringValue == ACPMethod.sessionUpdate }
            .map { try #require($0["params"]).decode(as: SessionNotification.self).update }
    }
}

extension JSONValue {
    /// A copy with the top-level `id` replaced, to answer a request the test actually sent.
    func with(id: JSONRPCID) -> JSONValue {
        guard var object = objectValue else { return self }
        switch id {
        case let .int(value): object["id"] = .number(Double(value))
        case let .string(value): object["id"] = .string(value)
        }
        return .object(object)
    }
}

extension FakeAgent {
    func send(fixture message: JSONValue) throws {
        var line = try Fixture.line(message)
        line.append(0x0A)
        try transport.sendRaw(line)
    }
}

struct FixtureDecodingTests {
    private static let knownUpdateKinds: Set<String> = [
        "user_message_chunk", "agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update", "plan",
        "available_commands_update", "current_mode_update", "config_option_update", "session_info_update", "usage_update",
    ]

    @Test func everyCapturedMessageDecodes() throws {
        let names = try Fixture.names()
        #expect(names.count > 40)
        var updates = 0
        for name in names {
            for message in try Fixture.messages(name) {
                let classified = try JSONRPCMessage.decode(Fixture.line(message))
                switch classified {
                case let .notification(ACPMethod.sessionUpdate, params):
                    let notification = try #require(params).decode(as: SessionNotification.self)
                    #expect(Self.knownUpdateKinds.contains(notification.update.kind), "\(name)")
                    if case .unknown = notification.update { Issue.record("\(name) decoded as unknown") }
                    updates += 1
                case let .request(_, ACPMethod.sessionRequestPermission, params):
                    let request = try #require(params).decode(as: RequestPermissionRequest.self)
                    #expect(request.options.count == 3, "\(name)")
                    #expect(request.options.allSatisfy { if case .unknown = $0.kind { false } else { true } }, "\(name)")
                default:
                    break
                }
            }
        }
        #expect(updates > 50)
    }

    @Test(arguments: ["claude", "codex", "opencode"])
    func initializeResponses(agent: String) throws {
        let response = try Fixture.result("\(agent)-initialize-response", as: InitializeResponse.self)
        #expect(response.protocolVersion == 1)
        let capabilities = response.agentCapabilities
        #expect(capabilities.loadSession)
        #expect(capabilities.promptCapabilities.image)
        #expect(capabilities.promptCapabilities.embeddedContext)
        #expect(capabilities.mcpCapabilities.http)
        #expect(capabilities.sessionCapabilities.resume)
        #expect(capabilities.sessionCapabilities.list)
        #expect(capabilities.sessionCapabilities.close)
        #expect(capabilities.sessionCapabilities.delete)
        #expect(capabilities.sessionCapabilities.fork)
        #expect(capabilities.sessionCapabilities.additionalDirectories)

        switch agent {
        case "claude":
            #expect(capabilities.sessionCapabilities.options)
            #expect(capabilities.sessionCapabilities.status)
            #expect(capabilities.sessionCapabilities.systemPrompt)
            #expect(capabilities.sessionCapabilities.title)
            #expect(capabilities.auth == .init(logout: true, status: true))
            #expect(response.authMethods.map(\.id) == ["claude-ai-login", "console-login"])
            #expect(response.authMethods.allSatisfy { $0.type == .terminal })
            #expect(response.authMethods.first?.args == ["--cli", "auth", "login", "--claudeai"])
        case "codex":
            // No `type` means an agent method, which `authenticate` handles.
            #expect(response.authMethods.map(\.id) == ["api-key", "chat-gpt"])
            #expect(response.authMethods.allSatisfy { $0.type == .agent })
            #expect(response.agentInfo?.title == "Codex")
        default:
            #expect(response.authMethods.map(\.type) == [.terminal])
            #expect(response.authMethods.first?.args == ["--login"])
            #expect(!capabilities.mcpCapabilities.sse)
        }
    }

    @Test(arguments: ["claude", "codex", "opencode"])
    func newSessionResponses(agent: String) throws {
        // Codex adds a legacy `models` object; it must not get in the way.
        let response = try Fixture.result("\(agent)-session-new-response", as: NewSessionResponse.self)
        #expect(!response.sessionId.isEmpty)
        let options = try #require(response.configOptions)
        #expect(options.first?.id == "model")
        #expect(options.allSatisfy { $0.type == .select && !$0.options.allValues.isEmpty })
        #expect(options.contains { $0.category == .thoughtLevel })
        if agent == "claude" {
            #expect(options.first { $0.id == "fast" }?.category == .unknown("speed"))
            #expect(options.first { $0.id == "agent" }?.category == nil)
        }
        if agent == "codex" {
            #expect(options.first { $0.id == "collaboration_mode" }?.category == .unknown("collaboration_mode"))
            #expect(response.modes?.availableModes.isEmpty == false)
        }
        // `session/load` answers in the same shape, sessionId and models included.
        let setup = try Fixture.result("\(agent)-session-new-response", as: SessionSetup.self)
        #expect(setup.configOptions == response.configOptions)
    }

    @Test(arguments: ["claude", "codex", "opencode"])
    func configOptionUpdates(agent: String) throws {
        let updates = try Fixture.updates("\(agent)-update-config_option_update")
        guard case let .configOptions(options) = updates.first else { Issue.record("not a config option update"); return }
        #expect(options.count >= 3)
        #expect(options.contains { $0.category == .mode })
    }

    @Test(arguments: ["claude", "codex", "opencode"])
    func promptResponsesWithUsageAndMeta(agent: String) throws {
        let ended = try Fixture.result("\(agent)-prompt-response-end-turn", as: PromptResponse.self)
        #expect(ended.stopReason == .endTurn)
        let cancelled = try Fixture.result("\(agent)-prompt-response-cancelled", as: PromptResponse.self)
        #expect(cancelled.stopReason == .cancelled)
        if agent == "claude" {
            #expect(ended.usage?["totalTokens"]?.intValue == 31268)
            #expect(ended.meta?["quota"] != nil)
        }
        if agent == "codex" {
            // `"usage": null` reads as no usage.
            #expect(cancelled.usage == nil)
        }
    }

    @Test func usageUpdatesKeepTheirMeta() throws {
        #expect(try Fixture.updates("claude-update-usage_update") == [.usage(UsageUpdate(used: 31268, size: 1_000_000, meta: ["_claude/model": "claude-opus-5-5"]))])
        #expect(try Fixture.updates("codex-update-usage_update") == [.usage(UsageUpdate(used: 16806, size: 258_400))])
        guard case let .usage(usage) = try Fixture.updates("opencode-update-usage_update").first else { Issue.record("not usage"); return }
        #expect(usage.size > 0)
    }

    @Test func permissionOptionsDifferByAgentButKindsAgree() throws {
        for name in ["claude-request-permission-edit", "codex-request-permission-edit", "opencode-request-permission-edit"] {
            let request = try #require(try Fixture.message(name)["params"]).decode(as: RequestPermissionRequest.self)
            #expect(request.options.map(\.kind) == [.allowOnce, .allowAlways, .rejectOnce], "\(name)")
            #expect(request.toolCall.kind == .edit)
        }
        let plan = try #require(try Fixture.message("claude-request-permission-exit-plan-mode")["params"]).decode(as: RequestPermissionRequest.self)
        #expect(plan.toolCall.kind == .switchMode)
        #expect(plan.toolCall.title == "Approve Plan")
    }
}

struct FixtureTranscriptTests {
    private func folded(_ updates: [SessionUpdate]) -> ChatTranscript {
        var transcript = ChatTranscript()
        updates.forEach { transcript.apply($0) }
        return transcript
    }

    private func toolCalls(_ transcript: ChatTranscript) -> [ToolCall] {
        transcript.items.compactMap { if case let .toolCall(call) = $0 { call } else { nil } }
    }

    @Test func claudeFillsAToolCallInOverSeveralUpdates() throws {
        let transcript = folded(try Fixture.updates("claude-sequence-read-tool"))
        let call = try #require(toolCalls(transcript).only)
        #expect(call.title == "Read README.md")
        #expect(call.kind == .read)
        #expect(call.status == .completed)
        #expect(call.rawInput?["file_path"]?.stringValue == "/Users/someone/project/README.md")
        #expect(call.locations == [ToolCallLocation(path: "/Users/someone/project/README.md", line: 1)])
        #expect(call.rawOutput?.stringValue?.contains("mango") == true)
        #expect(call.meta?["claudeCode"]?["toolName"] == "Read")
        guard case let .content(.text(text)) = call.content.first else { Issue.record("no text content"); return }
        #expect(text.contains("mango"))
    }

    @Test func statuslessUpdatesKeepTheStatus() throws {
        let updates = try Fixture.updates("claude-sequence-read-tool")
        var transcript = ChatTranscript()
        transcript.apply(updates[0])
        transcript.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: "toolu_01KXgKcyVftv1HPLF3jqqV5V", status: .inProgress)))
        transcript.apply(updates[1])
        transcript.apply(updates[2])
        let call = try #require(transcript.toolCall(id: "toolu_01KXgKcyVftv1HPLF3jqqV5V"))
        #expect(call.status == .inProgress)
        #expect(call.title == "Read README.md")
        // The third update only carried `_meta`; the locations from the second stay.
        #expect(call.locations.count == 1)
    }

    @Test func codexShellOutputArrivesInMeta() throws {
        let transcript = folded(try Fixture.updates("codex-sequence-execute-tool-terminal-meta"))
        let call = try #require(toolCalls(transcript).only)
        #expect(call.kind == .execute)
        #expect(call.status == .completed)
        #expect(call.content == [.terminal(terminalId: "exec-e83a86a3-0ca8-4122-a76a-5acb5d6cba0d")])
        #expect(call.terminalOutput == "3:The secret fruit is mango.\n# Sample repo\n\nThe secret fruit is mango.\n")
        #expect(call.terminalExitCode == 0)
    }

    @Test func terminalOutputAccumulatesAcrossDeltas() {
        var transcript = ChatTranscript()
        transcript.apply(.toolCall(ToolCall(toolCallId: "x", title: "ls", kind: .execute, status: .inProgress)))
        for chunk in ["a\n", "b\n"] {
            transcript.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: "x", meta: ["terminal_output_delta": ["data": .string(chunk), "terminal_id": "x"]])))
        }
        transcript.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: "x", status: .failed, meta: ["terminal_exit": ["exit_code": 2, "signal": nil]])))
        // A re-announcement of the call keeps what was collected.
        transcript.apply(.toolCall(ToolCall(toolCallId: "x", title: "ls -la", kind: .execute, status: .failed)))
        let call = transcript.toolCall(id: "x")
        #expect(call?.terminalOutput == "a\nb\n")
        #expect(call?.terminalExitCode == 2)
        #expect(call?.title == "ls -la")
    }

    @Test(arguments: ["claude", "opencode"])
    func rejectedCallsEndFailed(agent: String) throws {
        // An update for a call never announced creates it.
        let transcript = folded(try Fixture.updates("\(agent)-update-tool_call_update-failed-after-reject"))
        #expect(toolCalls(transcript).only?.status == .failed)
    }

    @Test(arguments: ["claude", "codex", "opencode"])
    func editWithPermissionSequences(agent: String) throws {
        let messages = try Fixture.messages("\(agent)-sequence-edit-with-permission-allowed")
        var transcript = ChatTranscript()
        for message in messages {
            if message["method"]?.stringValue == ACPMethod.sessionUpdate {
                transcript.apply(try #require(message["params"]).decode(as: SessionNotification.self).update)
            } else if message["method"]?.stringValue == ACPMethod.sessionRequestPermission {
                // Codex's request carries a bare tool call; the transcript has the full one.
                let request = try #require(message["params"]).decode(as: RequestPermissionRequest.self)
                let known = try #require(transcript.toolCall(id: request.toolCall.toolCallId))
                #expect(known.kind == .edit)
            }
        }
        transcript.endTurn(.endTurn)
        let calls = toolCalls(transcript)
        #expect(!calls.isEmpty)
        #expect(calls.allSatisfy { $0.status == .completed }, "\(calls.map(\.status))")
    }

    @Test func titleSurvivesMetaOnlyInfoUpdates() throws {
        var transcript = ChatTranscript()
        try Fixture.updates("codex-update-session_info_update-title").forEach { transcript.apply($0) }
        let title = try #require(transcript.title)
        #expect(title.hasPrefix("Create a file"))
        try Fixture.updates("codex-update-session_info_update-thread-status-meta").forEach { transcript.apply($0) }
        #expect(transcript.title == title)
        guard case let .sessionInfo(info) = try Fixture.updates("codex-update-session_info_update-thread-status-meta").first else {
            Issue.record("not session info"); return
        }
        #expect(info.meta?["codex"]?["threadStatus"]?["type"] == "active")
    }

    @Test func anyStopReasonCancelsUnfinishedCalls() {
        for reason: StopReason? in [.endTurn, .cancelled, .refusal, nil] {
            var transcript = ChatTranscript()
            transcript.apply(.toolCall(ToolCall(toolCallId: "rejected", title: "Edit", kind: .edit, status: .inProgress)))
            transcript.apply(.toolCall(ToolCall(toolCallId: "done", title: "Read", status: .completed)))
            transcript.endTurn(reason)
            #expect(transcript.toolCall(id: "rejected")?.status == .cancelled)
            #expect(transcript.toolCall(id: "done")?.status == .completed)
            #expect(transcript.lastStopReason == reason)
        }
    }

    @Test(arguments: ["claude", "codex", "opencode"])
    func userChunksOnlyCountInReplay(agent: String) throws {
        let chunk = try Fixture.updates("\(agent)-update-user_message_chunk-replayed")
        var transcript = ChatTranscript()
        chunk.forEach { transcript.apply($0) }
        #expect(transcript.items.isEmpty)
        transcript.beginReplay()
        #expect(transcript.isReplaying)
        chunk.forEach { transcript.apply($0) }
        transcript.endReplay()
        #expect(!transcript.isReplaying)
        #expect(transcript.items.count == 1)
        guard case let .userMessage(message) = transcript.items.first else { Issue.record("not a user message"); return }
        #expect(message.text.hasPrefix("Read README.md") || message.text.hasPrefix("Create"))
        // The flag still lets an owner take live user chunks if an agent ever needs it.
        transcript.ignoresUserMessageChunks = false
        chunk.forEach { transcript.apply($0) }
        #expect(transcript.items.count == 2)
    }

    /// What the chat shows, without ids or intermediate states.
    private struct Shown: Equatable, CustomStringConvertible {
        var kind: String
        var text: String

        var description: String { "\(kind): \(text.prefix(40))" }
    }

    private func shown(_ transcript: ChatTranscript) -> [Shown] {
        transcript.items.map { item in
            switch item {
            case let .userMessage(message): Shown(kind: "user", text: message.text)
            case let .agentMessage(message): Shown(kind: "agent", text: message.text)
            case let .agentThought(message): Shown(kind: "thought", text: message.text)
            case let .toolCall(call): Shown(kind: "tool \(call.status.rawValue)", text: call.title + (call.terminalOutput ?? ""))
            }
        }
    }

    /// A replay ends in the same chat as the turns did live: the user's prompts shown locally
    /// in place of the replayed user chunks, everything else as it came.
    @Test(arguments: ["claude", "codex", "opencode"])
    func replayEndsInTheSameStateAsLive(agent: String) throws {
        let updates = try Fixture.updates("\(agent)-sequence-session-load-replay")
        #expect(updates.contains { if case .userMessageChunk = $0 { true } else { false } })

        var replay = ChatTranscript()
        replay.beginReplay()
        updates.forEach { replay.apply($0) }
        replay.endReplay()

        var live = ChatTranscript()
        var inTurn = false
        for update in updates {
            if case let .userMessageChunk(chunk) = update {
                if inTurn { live.endTurn(.endTurn) }
                live.appendUserPrompt([chunk.content])
                inTurn = true
            }
            live.apply(update)
        }
        live.endTurn(.endTurn)

        #expect(shown(replay) == shown(live))
        #expect(shown(replay).filter { $0.kind == "user" }.count == 2)
        #expect(toolCalls(replay).allSatisfy { $0.status == .completed })
        #expect(replay.lastAgentText?.isEmpty == false)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct FixtureConnectionTests {
    @Test func agentAndClientIdsZeroDoNotCollide() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        var inbox = agent.inbox.makeAsyncIterator()

        let session = Task { try await client.newSession(cwd: "/Users/someone/project") }
        let (ourID, _) = try await inbox.request(ACPMethod.sessionNew)
        #expect(ourID == .int(0))

        // The agent's first request to us also uses id 0, before it answers ours.
        try agent.send(fixture: try Fixture.message("claude-request-permission-edit"))
        guard case let .permissionRequest(theirID, request) = await events.next() else { Issue.record("expected a permission request"); return }
        #expect(theirID == .int(0))
        #expect(request.toolCall.title == "Edit hello.txt")

        let newSession = try Fixture.message("claude-session-new-response")
        try agent.send(fixture: newSession.with(id: ourID))
        #expect(try await session.value.sessionId == newSession["result"]?["sessionId"]?.stringValue)
        // Answering the agent's request 0 is unaffected by our request 0 having completed.
        #expect(await client.respond(toPermission: theirID, with: .selected(optionId: "allow-once")))
        let response = try await inbox.response()
        #expect(response.id == .int(0))
        #expect(response.result == .success(["outcome": ["outcome": "selected", "optionId": "allow-once"]]))
        await client.shutdown()
    }

    @Test func claudePromptAuthErrorArrivesInOrder() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        var inbox = agent.inbox.makeAsyncIterator()
        let id = try await client.prompt(sessionId: "s1", blocks: [.text("hi")])
        _ = try await inbox.request(ACPMethod.sessionPrompt)
        try agent.update("s1", UpdateSamples.usage)
        try agent.send(fixture: try Fixture.message("claude-error-prompt-auth-required").with(id: id))

        #expect(await events.next()?.update?.kind == "usage_update")
        guard case let .promptFinished(sessionId, .failure(error)) = await events.next() else { Issue.record("expected a failed prompt"); return }
        #expect(sessionId == "s1")
        #expect(error.isAuthenticationRequired)
        await client.shutdown()
    }

    @Test func codexSessionNewAuthError() async throws {
        let (client, agent) = makeClient()
        let session = Task { try await client.newSession(cwd: "/repo") }
        var inbox = agent.inbox.makeAsyncIterator()
        let (id, _) = try await inbox.request(ACPMethod.sessionNew)
        try agent.send(fixture: try Fixture.message("codex-error-session-new-auth-required").with(id: id))
        await #expect {
            try await session.value
        } throws: { error in
            (error as? ACPError)?.isAuthenticationRequired == true
        }
        await client.shutdown()
    }

    @Test func authStatusSurfacesOnlyTheState() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        let status = try Fixture.message("claude-notification-auth-status-update")
        try agent.send(fixture: status)
        var prefixed = try #require(status.objectValue)
        prefixed["method"] = "_auth/status_update"
        prefixed["params"] = ["state": "unauthenticated"]
        try agent.send(fixture: .object(prefixed))
        // Unknown notifications are ignored whatever their name, underscore or not.
        try agent.send(#"{"jsonrpc":"2.0","method":"auth/something_else","params":{"email":"someone@example.com"}}"#)
        try agent.send(#"{"jsonrpc":"2.0","method":"_codex/telemetry","params":{}}"#)
        try agent.update("s1", UpdateSamples.mode)

        #expect(await events.next() == .authStatus(state: "authenticated"))
        #expect(await events.next() == .authStatus(state: "unauthenticated"))
        #expect(await events.next()?.update == .currentMode(modeId: "plan"))
        await client.shutdown()
    }

    @Test func elicitationRequestGetsMethodNotFound() async throws {
        let (client, agent) = makeClient()
        var inbox = agent.inbox.makeAsyncIterator()
        try agent.send(fixture: try Fixture.message("claude-request-elicitation-create-ask-user-question"))
        let response = try await inbox.response()
        #expect(response.id == .int(0))
        if case let .failure(error) = response.result { #expect(error.code == JSONRPCError.methodNotFound) } else { Issue.record("expected an error") }
        await client.shutdown()
    }

    @Test func codexCancelRequestAfterCancelIsIgnored() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        var inbox = agent.inbox.makeAsyncIterator()
        let permission = try Fixture.message("codex-request-permission-edit")
        let sessionId = try #require(permission["params"]?["sessionId"]?.stringValue)

        try await client.prompt(sessionId: sessionId, blocks: [.text("go")])
        let (promptID, _) = try await inbox.request(ACPMethod.sessionPrompt)
        try agent.send(fixture: permission)
        guard case .permissionRequest(.int(0), _) = await events.next() else { Issue.record("expected permission 0"); return }

        await client.cancel(sessionId: sessionId)
        _ = try await inbox.notification(ACPMethod.sessionCancel)
        #expect(try await inbox.response().result == .success(["outcome": ["outcome": "cancelled"]]))

        // Codex then withdraws the request it already got an answer for: nothing more happens.
        try agent.send(fixture: try Fixture.message("codex-notification-cancel-request"))
        try agent.send(fixture: try Fixture.message("codex-prompt-response-cancelled").with(id: promptID))
        guard case let .promptFinished(_, .success(response)) = await events.next() else { Issue.record("expected the prompt to finish"); return }
        #expect(response.stopReason == .cancelled)
        await client.shutdown()
        #expect(await inbox.next() == nil)
    }

    @Test func codexCancelRequestForAnOpenPermissionAnswersIt() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        var inbox = agent.inbox.makeAsyncIterator()
        try agent.send(fixture: try Fixture.message("codex-request-permission-edit"))
        guard case .permissionRequest(.int(0), _) = await events.next() else { Issue.record("expected permission 0"); return }

        try agent.send(fixture: try Fixture.message("codex-notification-cancel-request"))
        #expect(await events.next() == .permissionRequestWithdrawn(id: .int(0)))
        let response = try await inbox.response()
        #expect(response.id == .int(0))
        #expect(response.result == .success(["outcome": ["outcome": "cancelled"]]))
        #expect(await !client.respond(toPermission: .int(0), with: .selected(optionId: "allow_once")))
        await client.shutdown()
    }

    @Test func replayIsBracketedInTheEventStream() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        var inbox = agent.inbox.makeAsyncIterator()
        let messages = try Fixture.messages("codex-sequence-session-load-replay")
        let load = Task { try await client.loadSession(id: "s1", cwd: "/Users/someone/project") }
        let (id, _) = try await inbox.request(ACPMethod.sessionLoad)
        for message in messages where message["method"]?.stringValue == ACPMethod.sessionUpdate {
            try agent.send(fixture: message)
        }
        // A load response with extras, as Codex sends: sessionId and models next to modes.
        let extras = try #require(try Fixture.message("codex-session-new-response")["result"])
        let response: JSONValue = ["jsonrpc": "2.0", "id": 0, "result": extras]
        try agent.send(fixture: response.with(id: id))

        var transcript = ChatTranscript()
        var replayUpdates = 0
        loop: while let event = await events.next() {
            switch event {
            case .replayStarted:
                transcript.beginReplay()
            case let .sessionUpdate(notification):
                #expect(transcript.isReplaying)
                transcript.apply(notification.update)
                replayUpdates += 1
            case let .sessionLoaded(_, result):
                transcript.endReplay()
                #expect((try? result.get())?.configOptions?.isEmpty == false)
                break loop
            default:
                Issue.record("unexpected \(event)")
            }
        }
        #expect(replayUpdates == messages.filter { $0["method"]?.stringValue == ACPMethod.sessionUpdate }.count)
        #expect(transcript.items.contains { if case .userMessage = $0 { true } else { false } })
        #expect(try await load.value.modes != nil)
        await client.shutdown()
    }
}

extension Collection {
    /// The single element, or nil when there are none or several.
    var only: Element? {
        count == 1 ? first : nil
    }
}
