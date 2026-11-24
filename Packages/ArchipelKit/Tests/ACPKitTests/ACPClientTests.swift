@testable import ACPKit
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ACPClientTests {
    private static let info = Implementation(name: "archipel", title: "Archipel", version: "1.2.3")

    @Test func initializeHandshake() async throws {
        let (client, agent) = makeClient()
        async let response = client.initialize(clientInfo: Self.info)

        var inbox = agent.inbox.makeAsyncIterator()
        let (id, params) = try await inbox.request("initialize")
        #expect(params == [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false, "auth": ["terminal": true]],
            "clientInfo": ["name": "archipel", "title": "Archipel", "version": "1.2.3"],
        ])
        try agent.respond(to: id, result: [
            "protocolVersion": 1,
            "agentCapabilities": ["loadSession": true, "sessionCapabilities": ["resume": [:]]],
            "agentInfo": ["name": "fake", "version": "0.1"],
            "authMethods": [["id": "login", "name": "Log in"]],
        ])

        let initialized = try await response
        #expect(initialized.agentCapabilities.loadSession)
        #expect(initialized.agentCapabilities.sessionCapabilities.resume)
        #expect(initialized.authMethods.map(\.id) == ["login"])
        #expect(initialized.agentInfo?.name == "fake")
        await client.shutdown()
    }

    @Test func unsupportedVersionThrows() async throws {
        let (client, agent) = makeClient()
        let response = Task { try await client.initialize(clientInfo: Self.info) }
        var inbox = agent.inbox.makeAsyncIterator()
        let (id, _) = try await inbox.request("initialize")
        try agent.respond(to: id, result: ["protocolVersion": 2, "agentCapabilities": [:]])
        await #expect(throws: ACPError.unsupportedProtocolVersion(2)) { try await response.value }
        await client.shutdown()
    }

    @Test func responsesAreMatchedByIdInAnyOrder() async throws {
        let (client, agent) = makeClient()
        async let session = client.newSession(cwd: "/repo")
        async let options = client.setConfigOption(sessionId: "s1", configId: "fast", value: true)
        async let mode: Void = client.setMode(sessionId: "s1", modeId: "plan")

        var inbox = agent.inbox.makeAsyncIterator()
        var requests: [String: (id: JSONRPCID, params: JSONValue)] = [:]
        for _ in 0..<3 {
            guard case let .request(id, method, params) = await inbox.next() else { Issue.record("expected a request"); return }
            requests[method] = (id, params ?? .null)
        }
        let new = try #require(requests[ACPMethod.sessionNew])
        let config = try #require(requests[ACPMethod.sessionSetConfigOption])
        let setMode = try #require(requests[ACPMethod.sessionSetMode])
        #expect(new.params == ["cwd": "/repo", "mcpServers": []])
        #expect(config.params == ["sessionId": "s1", "configId": "fast", "value": true])
        #expect(setMode.params == ["sessionId": "s1", "modeId": "plan"])
        #expect(Set([new.id, config.id, setMode.id]).count == 3)

        try agent.respond(to: setMode.id, result: [:])
        try agent.respond(to: config.id, result: ["configOptions": [["id": "fast", "name": "Fast", "type": "boolean", "currentValue": true]]])
        try agent.respond(to: new.id, result: ["sessionId": "s1"])

        #expect(try await session.sessionId == "s1")
        #expect(try await options.map(\.id) == ["fast"])
        try await mode
        await client.shutdown()
    }

    @Test func permissionRequestIsAnswered() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        var inbox = agent.inbox.makeAsyncIterator()

        try agent.send(#"""
        {"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"Edit a.swift","kind":"edit"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}}
        """#)
        guard case let .permissionRequest(id, request) = await events.next() else { Issue.record("expected a permission request"); return }
        #expect(id == .string("perm-1"))
        #expect(request.toolCall.title == "Edit a.swift")
        #expect(request.options.map(\.optionId) == ["allow", "reject"])
        #expect(await client.connection.openPermissionRequests == [id])

        #expect(await client.respond(toPermission: id, with: .selected(optionId: "allow")))
        let response = try await inbox.response()
        #expect(response.id == .string("perm-1"))
        #expect(response.result == .success(["outcome": ["outcome": "selected", "optionId": "allow"]]))
        // Answering twice sends nothing.
        #expect(await !client.respond(toPermission: id, with: .cancelled))
        #expect(await client.connection.openPermissionRequests.isEmpty)
        await client.shutdown()
    }

    @Test func malformedPermissionRequestGetsInvalidParams() async throws {
        let (client, agent) = makeClient()
        var inbox = agent.inbox.makeAsyncIterator()
        try agent.send(#"{"jsonrpc":"2.0","id":4,"method":"session/request_permission","params":{"options":[]}}"#)
        let response = try await inbox.response()
        #expect(response.id == .int(4))
        #expect((try? response.result.get()) == nil)
        if case let .failure(error) = response.result { #expect(error.code == JSONRPCError.invalidParams) }
        await client.shutdown()
    }

    @Test func unknownRequestsGetMethodNotFoundAndUnknownNotificationsAreIgnored() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        var inbox = agent.inbox.makeAsyncIterator()

        try agent.send(#"{"jsonrpc":"2.0","method":"_vendor/hello","params":{"x":1}}"#)
        try agent.send(#"{"jsonrpc":"2.0","id":7,"method":"fs/read_text_file","params":{"sessionId":"s1","path":"/etc/hosts"}}"#)
        try agent.send(#"{"jsonrpc":"2.0","id":"x","method":"_vendor/ask"}"#)
        try agent.update("s1", UpdateSamples.mode)

        for expected in [JSONRPCID.int(7), .string("x")] {
            let response = try await inbox.response()
            #expect(response.id == expected)
            if case let .failure(error) = response.result {
                #expect(error.code == JSONRPCError.methodNotFound)
            } else {
                Issue.record("expected an error")
            }
        }
        #expect(await events.next() == .sessionUpdate(SessionNotification(sessionId: "s1", update: .currentMode(modeId: "plan"))))
        await client.shutdown()
    }

    @Test func authenticationRequiredError() async throws {
        let (client, agent) = makeClient()
        async let session = client.newSession(cwd: "/repo")
        var inbox = agent.inbox.makeAsyncIterator()
        let (id, _) = try await inbox.request(ACPMethod.sessionNew)
        try agent.respond(to: id, error: -32000, message: "Authentication required")
        do {
            _ = try await session
            Issue.record("expected an error")
        } catch let error as ACPError {
            #expect(error.isAuthenticationRequired)
            #expect(error == .rpc(JSONRPCError(code: -32000, message: "Authentication required")))
        }

        async let auth: Void = client.authenticate(methodId: "login")
        let (authID, params) = try await inbox.request(ACPMethod.authenticate)
        #expect(params == ["methodId": "login"])
        try agent.respond(to: authID, result: [:])
        try await auth
        await client.shutdown()
    }

    @Test func otherErrorsAreNotAuthentication() async throws {
        let (client, agent) = makeClient()
        let mode = Task { try await client.setMode(sessionId: "s", modeId: "m") }
        var inbox = agent.inbox.makeAsyncIterator()
        let (id, _) = try await inbox.request(ACPMethod.sessionSetMode)
        try agent.respond(to: id, error: -32602, message: "bad mode")
        await #expect {
            try await mode.value
        } throws: { error in
            (error as? ACPError)?.isAuthenticationRequired == false && (error as? ACPError)?.code == -32602
        }
        await client.shutdown()
    }

    @Test func closeSessionTreatsNotFoundAsSuccess() async throws {
        let (client, agent) = makeClient()
        async let closed: Void = client.closeSession(id: "s1")
        var inbox = agent.inbox.makeAsyncIterator()
        let (id, params) = try await inbox.request(ACPMethod.sessionClose)
        #expect(params == ["sessionId": "s1"])
        try agent.respond(to: id, error: JSONRPCError.resourceNotFound, message: "No such session")
        try await closed
        await client.shutdown()
    }

    @Test func promptFinishesAfterItsUpdates() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        var inbox = agent.inbox.makeAsyncIterator()

        try await client.prompt(sessionId: "s1", blocks: [.text("Hi"), .resourceLink(ResourceLink(uri: "file:///repo/a.swift", name: "a.swift"))])
        let (id, params) = try await inbox.request(ACPMethod.sessionPrompt)
        #expect(params == ["sessionId": "s1", "prompt": [["type": "text", "text": "Hi"], ["type": "resource_link", "uri": "file:///repo/a.swift", "name": "a.swift"]]])

        try agent.update("s1", UpdateSamples.agentChunk)
        try agent.update("s1", UpdateSamples.toolCall)
        try agent.respond(to: id, result: ["stopReason": "end_turn"])

        let received = await ACPKitTests.events(from: &events) { $0.isPromptFinished }
        #expect(received.count == 3)
        #expect(received.last == .promptFinished(sessionId: "s1", result: .success(PromptResponse(stopReason: .endTurn))))
        await client.shutdown()
    }

    /// The guarantee the chat view depends on: everything sent before the reply is seen before it,
    /// whichever way the bytes are chunked.
    @Test func orderingUnderStress() async throws {
        let (client, agent) = makeClient()
        let consumer = Task {
            var events = client.events.makeAsyncIterator()
            var failures: [String] = []
            var turns = 0
            var updatesThisTurn = 0
            while let event = await events.next() {
                switch event {
                case let .sessionUpdate(notification):
                    guard case let .agentMessageChunk(chunk) = notification.update, let text = chunk.content.text else { continue }
                    if text != "\(turns):\(updatesThisTurn)" { failures.append("turn \(turns) got \(text)") }
                    updatesThisTurn += 1
                case let .promptFinished(_, result):
                    // The extra prompt sent last fails when the agent hangs up; it carries no updates.
                    guard case .success = result else { continue }
                    if updatesThisTurn != 25 { failures.append("turn \(turns) finished after \(updatesThisTurn) updates") }
                    turns += 1
                    updatesThisTurn = 0
                case .closed:
                    return (turns, failures)
                default:
                    break
                }
            }
            return (turns, failures)
        }

        var inbox = agent.inbox.makeAsyncIterator()
        for turn in 0..<200 {
            try await client.prompt(sessionId: "s1", blocks: [.text("go")])
            let (id, _) = try await inbox.request(ACPMethod.sessionPrompt)
            var wire = Data()
            for index in 0..<25 {
                let line = try JSONRPCMessage.notification(method: "session/update", params: [
                    "sessionId": "s1",
                    "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string("\(turn):\(index)")]],
                ]).encoded()
                wire.append(line)
                wire.append(0x0A)
            }
            wire.append(try JSONRPCMessage.response(id: id, result: .success(["stopReason": "end_turn"])).encoded())
            wire.append(0x0A)
            // Odd chunk sizes, so the reply often shares a chunk with the updates before it.
            let size = [1, 7, 97, 4096, wire.count][turn % 5]
            var offset = 0
            while offset < wire.count {
                let end = min(offset + size, wire.count)
                try agent.transport.sendRaw(wire.subdata(in: offset..<end))
                offset = end
            }
        }
        // Let the last turn drain before closing.
        try await client.prompt(sessionId: "s1", blocks: [.text("last")])
        _ = try await inbox.request(ACPMethod.sessionPrompt)
        agent.close()

        let (turns, failures) = await consumer.value
        #expect(turns == 200)
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    @Test func loadSessionReplaysBeforeTheLoadedEvent() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        async let setup = client.loadSession(id: "s1", cwd: "/repo")
        var inbox = agent.inbox.makeAsyncIterator()
        let (id, params) = try await inbox.request(ACPMethod.sessionLoad)
        #expect(params == ["sessionId": "s1", "cwd": "/repo", "mcpServers": []])
        try agent.update("s1", UpdateSamples.userChunk)
        try agent.update("s1", UpdateSamples.agentChunk)
        try agent.respond(to: id, result: ["modes": ["currentModeId": "default", "availableModes": [["id": "default", "name": "Default"]]]])

        let received = await ACPKitTests.events(from: &events) {
            if case .sessionLoaded = $0 { true } else { false }
        }
        #expect(received.count == 4)
        #expect(received.first == .replayStarted(sessionId: "s1"))
        guard case let .sessionLoaded(sessionId, result) = received.last else { Issue.record("no load event"); return }
        #expect(sessionId == "s1")
        #expect((try? result.get())?.modes?.currentModeId == "default")
        #expect(try await setup.modes?.currentModeId == "default")
        await client.shutdown()
    }

    @Test func resumeSession() async throws {
        let (client, agent) = makeClient()
        async let setup = client.resumeSession(id: "s1", cwd: "/repo")
        var inbox = agent.inbox.makeAsyncIterator()
        let (id, params) = try await inbox.request(ACPMethod.sessionResume)
        #expect(params == ["sessionId": "s1", "cwd": "/repo", "mcpServers": []])
        try agent.respond(to: id, result: .null)
        #expect(try await setup == SessionSetup())
        await client.shutdown()
    }

    @Test func cancelAnswersOpenPermissionsOfThatSession() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        var inbox = agent.inbox.makeAsyncIterator()

        try await client.prompt(sessionId: "s1", blocks: [.text("go")])
        let (promptID, _) = try await inbox.request(ACPMethod.sessionPrompt)
        for (id, session) in [(10, "s1"), (11, "s2"), (12, "s1")] {
            try agent.send(#"{"jsonrpc":"2.0","id":\#(id),"method":"session/request_permission","params":{"sessionId":"\#(session)","toolCall":{"toolCallId":"t\#(id)"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}"#)
        }
        for _ in 0..<3 {
            guard case .permissionRequest = await events.next() else { Issue.record("expected a permission request"); return }
        }

        await client.cancel(sessionId: "s1")
        #expect(try await inbox.notification(ACPMethod.sessionCancel) == ["sessionId": "s1"])
        for expected in [10, 12] {
            let response = try await inbox.response()
            #expect(response.id == .int(expected))
            #expect(response.result == .success(["outcome": ["outcome": "cancelled"]]))
        }
        #expect(await client.connection.openPermissionRequests == [.int(11)])
        // The UI may still try to answer a card that cancel already answered.
        #expect(await !client.respond(toPermission: .int(10), with: .selected(optionId: "allow")))

        // Updates after cancel are still delivered, then the turn ends as cancelled.
        try agent.update("s1", UpdateSamples.toolCallUpdate)
        try agent.respond(to: promptID, result: ["stopReason": "cancelled"])
        let received = await ACPKitTests.events(from: &events) { $0.isPromptFinished }
        #expect(received.first?.update?.kind == "tool_call_update")
        #expect(received.last == .promptFinished(sessionId: "s1", result: .success(PromptResponse(stopReason: .cancelled))))
        await client.shutdown()
    }

    @Test func agentCanWithdrawAPermissionRequest() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        var inbox = agent.inbox.makeAsyncIterator()
        try agent.send(#"{"jsonrpc":"2.0","id":3,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t"},"options":[]}}"#)
        guard case .permissionRequest = await events.next() else { Issue.record("expected a permission request"); return }
        try agent.send(#"{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":3}}"#)
        #expect(await events.next() == .permissionRequestWithdrawn(id: .int(3)))
        let response = try await inbox.response()
        #expect(response.id == .int(3))
        #expect(response.result == .success(["outcome": ["outcome": "cancelled"]]))
        #expect(await !client.respond(toPermission: .int(3), with: .cancelled))
        await client.shutdown()
    }

    @Test func badMessagesDoNotEndTheConnection() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        try agent.send("Debugger listening on ws://127.0.0.1:9229")
        try agent.send(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","title":"no id"}}}"#)
        try agent.send(#"{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"plan","entries":[]}}}"#)
        try agent.send(#"{"jsonrpc":"2.0","id":999,"result":{}}"#)
        try agent.update("s1", UpdateSamples.unknown)
        try agent.update("s1", UpdateSamples.usage)

        #expect(await events.next()?.update?.kind == "compaction_update")
        #expect(await events.next()?.update == .usage(UsageUpdate(used: 53000, size: 200_000, cost: .init(amount: 0.42, currency: "USD"))))
        #expect(await client.connection.closeReason == nil)
        await client.shutdown()
    }

    @Test func closingFailsPendingRequestsAndEndsTheStream() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        var inbox = agent.inbox.makeAsyncIterator()

        try await client.prompt(sessionId: "s1", blocks: [.text("go")])
        _ = try await inbox.request(ACPMethod.sessionPrompt)
        let session = Task { try await client.newSession(cwd: "/repo") }
        _ = try await inbox.request(ACPMethod.sessionNew)
        try agent.update("s1", UpdateSamples.agentChunk)
        agent.close()

        await #expect(throws: ACPError.connectionClosed(.endOfStream)) { try await session.value }
        let received = await ACPKitTests.events(from: &events) { $0.isClosed }
        #expect(received.count == 3)
        #expect(received[0].update?.kind == "agent_message_chunk")
        #expect(received[1] == .promptFinished(sessionId: "s1", result: .failure(.connectionClosed(.endOfStream))))
        #expect(received[2] == .closed(.endOfStream))
        #expect(await events.next() == nil)

        await #expect(throws: ACPError.connectionClosed(.endOfStream)) { try await client.newSession(cwd: "/repo") }
        await #expect(throws: ACPError.connectionClosed(.endOfStream)) { try await client.prompt(sessionId: "s1", blocks: []) }
    }

    @Test func shutdownClosesFromTheClientSide() async throws {
        let (client, agent) = makeClient()
        var events = client.events.makeAsyncIterator()
        var inbox = agent.inbox.makeAsyncIterator()
        let session = Task { try await client.newSession(cwd: "/repo") }
        _ = try await inbox.request(ACPMethod.sessionNew)

        await client.shutdown()
        await #expect(throws: ACPError.connectionClosed(.closedByClient)) { try await session.value }
        #expect(await events.next() == .closed(.closedByClient))
        #expect(await events.next() == nil)
        // The agent sees end of input.
        #expect(await inbox.next() == nil)
        await client.shutdown()
    }

    @Test func oversizedLineIsAProtocolError() async throws {
        let (transport, agentTransport) = InMemoryTransport.pair()
        let client = ACPClient(transport: transport, maximumMessageSize: 1024)
        var events = client.events.makeAsyncIterator()
        try agentTransport.sendRaw(Data(#"{"jsonrpc":"2.0","method":"x"}"#.utf8 + [0x0A]))
        for _ in 0..<10 {
            try agentTransport.sendRaw(Data(repeating: UInt8(ascii: "x"), count: 200))
        }
        guard case let .closed(.protocolError(message)) = await events.next() else { Issue.record("expected a protocol error"); return }
        #expect(message.contains("exceeded"))
    }
}
