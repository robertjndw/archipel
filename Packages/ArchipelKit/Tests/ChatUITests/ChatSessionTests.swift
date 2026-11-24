import ACPKit
import ArchipelCore
@testable import ChatUI
import Foundation
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChatSessionTests {
    private static let editCall = #"""
    {"sessionUpdate":"tool_call","toolCallId":"edit-1","title":"Edit a.swift","kind":"edit","status":"pending",
     "content":[{"type":"diff","path":"/repo/a.swift","oldText":"let a = 1","newText":"let a = 2"}]}
    """#

    // MARK: Starting

    @Test func startOpensANewSession() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let agent = try harness.agent()
        let new = try #require(agent.requests(ACPMethod.sessionNew).first)
        #expect(new.params["cwd"] == "/repo")
        #expect(harness.session.agentSessionID == "s-new")
        #expect(!harness.session.isAgentSessionIDConfirmed)
        #expect(!harness.session.isHistoryUnavailable)
        #expect(harness.session.agentInfo?.title == "Fake Agent")
        #expect(harness.events == [.agent(.sessionStarted)])
        await harness.session.shutDown()
    }

    @Test func installProgressShowsWhileStarting() async throws {
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let harness = ChatHarness(resolveLaunch: { progress in
            progress(.checkingRegistry)
            progress(.downloading(fraction: 0.5))
            for await _ in gate { break }
            progress(.done)
            return ChatLaunch(executable: URL(fileURLWithPath: "/usr/bin/true"))
        })
        let start = Task { await harness.session.start() }
        try await waitUntil("installing shows") {
            harness.session.phase == .starting(.installing(agentName: "Fake Agent", fraction: 0.5))
        }
        open.yield()
        await start.value
        #expect(harness.session.phase == .ready)
        await harness.session.shutDown()
    }

    @Test func launchErrorsBecomeTypedFailures() async throws {
        let harness = ChatHarness(resolveLaunch: { _ in throw ChatLaunchError.nodeMissing(agentName: "Codex") })
        await harness.session.start()
        let failure = try #require(harness.session.phase.failure)
        #expect(failure.reason == .nodeMissing)
        #expect(failure.title == "Node.js Is Required")
        #expect(harness.events == [.failed(failure)])
        #expect(harness.launchCount == 0)
    }

    @Test func unsupportedProtocolVersionFails() async throws {
        var script = ScriptedAgent.Script()
        script.initialize = .result(ScriptedAgent.initializeResult(protocolVersion: 2))
        let harness = ChatHarness(script: script)
        await harness.session.start()
        #expect(harness.session.phase.failure?.reason == .unsupportedProtocolVersion(2))
    }

    @Test func agentQuittingWhileStartingFailsWithItsStderr() async throws {
        var script = ScriptedAgent.Script()
        // Never answered: the agent dies first.
        script.newSession = []
        let harness = ChatHarness(script: script, stderr: "line 1\nError: cannot find module 'x'\n")
        let start = Task { await harness.session.start() }
        let agent = try await {
            try await waitUntil("the agent is asked for a session") { harness.launchCount == 1 }
            return try harness.agent()
        }()
        try await waitUntil("session/new arrives") { !agent.requests(ACPMethod.sessionNew).isEmpty }
        agent.close()
        await start.value
        let failure = try #require(harness.session.phase.failure)
        #expect(failure.reason == .couldNotStart)
        #expect(failure.message == "Fake Agent quit while starting.")
        #expect(failure.details == "line 1\nError: cannot find module 'x'")
    }

    // MARK: A full turn

    @Test func fullTurnReportsEventsInOrder() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let agent = try harness.agent()
        let promptID = try await harness.send("Fix it")
        #expect(harness.session.isTurnRunning)
        #expect(harness.session.draft.isEmpty)
        #expect(harness.session.transcript.readableItems == ["user: Fix it"])

        try agent.update("s-new", #"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Looking"}}"#)
        try agent.update("s-new", Self.editCall)
        try agent.requestPermission(id: .int(0), sessionId: "s-new", toolCall: ["toolCallId": "edit-1"])
        try await waitUntil("the permission request shows") { harness.session.permissionRequests.count == 1 }
        let request = try #require(harness.session.permissionRequests.first)
        await harness.session.respond(to: request, optionId: "allow")
        try agent.update("s-new", #"{"sessionUpdate":"tool_call_update","toolCallId":"edit-1","status":"completed"}"#)
        try agent.agentText("s-new", "Done.")
        try agent.finishPrompt(promptID)
        try await waitUntil("the turn ends") { !harness.session.isTurnRunning }

        #expect(harness.agentEvents == [
            .sessionStarted,
            .promptSubmitted,
            .activity,
            .attentionRequested(.permission, message: "Edit a.swift"),
            .activity,
            .turnFinished(message: "Done.", backgroundTasks: nil),
        ])
        #expect(harness.events.contains(.agentSessionIDConfirmed("s-new")))
        #expect(harness.session.transcript.readableItems == [
            "user: Fix it", "thought: Looking", "tool edit-1 edit completed: Edit a.swift", "agent: Done.",
        ])
        #expect(harness.session.transcript.lastStopReason == .endTurn)
        let answer = try #require(agent.responses.first)
        #expect(answer.id == .int(0))
        #expect(answer.result == .success(["outcome": ["outcome": "selected", "optionId": "allow"]]))
        await harness.session.shutDown()
    }

    @Test func aPromptSentWhileATurnRunsWaitsForItsEnd() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let promptID = try await harness.send("First")
        harness.session.draft = "Second"
        #expect(!harness.session.canSend)
        #expect(harness.session.canQueue)
        #expect(harness.session.send())
        #expect(harness.session.draft.isEmpty)
        #expect(harness.session.queuedPrompts.map(\.text) == ["Second"])
        // The app's own prompts are not queued: its callers decide what to do with a refusal.
        #expect(!harness.session.send(text: "From the app"))
        let agent = try harness.agent()
        #expect(agent.requests(ACPMethod.sessionPrompt).count == 1)
        #expect(harness.session.transcript.readableItems == ["user: First"])

        try agent.finishPrompt(promptID)
        try await waitUntil("the queued prompt goes out") { agent.requests(ACPMethod.sessionPrompt).count == 2 }
        #expect(harness.session.queuedPrompts.isEmpty)
        #expect(harness.session.isTurnRunning)
        #expect(harness.session.transcript.readableItems == ["user: First", "user: Second"])
        await harness.session.shutDown()
    }

    @Test func queuedPromptsGoOutOneTurnAtATime() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let first = try await harness.send("First")
        for text in ["Second", "Third"] {
            harness.session.draft = text
            #expect(harness.session.send())
        }
        let agent = try harness.agent()
        try agent.finishPrompt(first)
        try await waitUntil("the second prompt goes out") { agent.requests(ACPMethod.sessionPrompt).count == 2 }
        #expect(harness.session.queuedPrompts.map(\.text) == ["Third"])
        try agent.finishPrompt(try #require(agent.requests(ACPMethod.sessionPrompt).last?.id))
        try await waitUntil("the third prompt goes out") { agent.requests(ACPMethod.sessionPrompt).count == 3 }
        #expect(harness.session.queuedPrompts.isEmpty)
        await harness.session.shutDown()
    }

    @Test func theOwnerHearsOfTheEndOnlyOnceTheQueueIsEmpty() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let first = try await harness.send("First")
        harness.session.draft = "Second"
        #expect(harness.session.send())
        func finishedCount() -> Int {
            harness.events.count { if case .agent(.turnFinished) = $0 { true } else { false } }
        }
        let agent = try harness.agent()
        try agent.finishPrompt(first)
        try await waitUntil("the queued prompt goes out") { agent.requests(ACPMethod.sessionPrompt).count == 2 }
        #expect(finishedCount() == 0)
        try agent.finishPrompt(try #require(agent.requests(ACPMethod.sessionPrompt).last?.id))
        try await waitUntil("the last turn ends") { !harness.session.isTurnRunning }
        #expect(finishedCount() == 1)
        await harness.session.shutDown()
    }

    @Test func aQueueEmptiedAsTheTurnEndsStillReportsTheEnd() async throws {
        let harness = ChatHarness()
        try await harness.start()
        try await harness.send("First")
        harness.session.draft = "Second"
        #expect(harness.session.send())
        // The row's X is clicked between the turn's end and the queued prompt going out.
        harness.session.endTurnState(continuesWithQueue: true)
        harness.session.queuedPrompts = []
        try await waitUntil("the end is reported") {
            harness.events.contains { if case .agent(.turnFinished) = $0 { true } else { false } }
        }
        await harness.session.shutDown()
    }

    @Test func aStoppedTurnGivesTheQueueBackToTheComposer() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let promptID = try await harness.send("First")
        for text in ["Second", "Third"] {
            harness.session.draft = text
            #expect(harness.session.send())
        }
        harness.session.draft = "Being typed"
        await harness.session.cancel()
        let agent = try harness.agent()
        try agent.finishPrompt(promptID, stopReason: "cancelled")
        try await waitUntil("the turn ends") { !harness.session.isTurnRunning }
        #expect(harness.session.queuedPrompts.isEmpty)
        #expect(harness.session.draft == "Second\n\nThird\n\nBeing typed")
        #expect(agent.requests(ACPMethod.sessionPrompt).count == 1)
        await harness.session.shutDown()
    }

    @Test func aQueuedPromptCanBeRemovedOrTakenBackForEditing() async throws {
        let harness = ChatHarness()
        try await harness.start()
        try await harness.send("First")
        for text in ["Second", "Third"] {
            harness.session.draft = text
            #expect(harness.session.send())
        }
        let second = try #require(harness.session.queuedPrompts.first)
        #expect(harness.session.removeQueuedPrompt(second.id)?.text == "Second")
        harness.session.editLastQueuedPrompt()
        #expect(harness.session.draft == "Third")
        #expect(harness.session.queuedPrompts.isEmpty)
        // Never over what is being typed.
        #expect(harness.session.send())
        harness.session.draft = "Typing"
        harness.session.editLastQueuedPrompt()
        #expect(harness.session.draft == "Typing")
        #expect(harness.session.queuedPrompts.map(\.text) == ["Third"])
        await harness.session.shutDown()
    }

    @Test func emptyDraftCannotBeSent() async throws {
        let harness = ChatHarness()
        try await harness.start()
        harness.session.draft = "  \n "
        #expect(!harness.session.canSend)
        await harness.session.shutDown()
    }

    @Test func attachmentsGoAsLinksOrImages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chatui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("main.swift")
        let image = directory.appendingPathComponent("shot.png")
        try Data("print(1)".utf8).write(to: source)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)

        for acceptsImages in [false, true] {
            var script = ScriptedAgent.Script()
            script.initialize = .result(ScriptedAgent.initializeResult(image: acceptsImages))
            let harness = ChatHarness(script: script)
            try await harness.start()
            let agent = try harness.agent()
            harness.session.draft = "Look"
            harness.session.addAttachments([source, image, source])
            #expect(harness.session.attachments == [source, image])
            #expect(harness.session.send())
            #expect(harness.session.attachments.isEmpty)
            try await waitUntil("the prompt arrives") { !agent.requests(ACPMethod.sessionPrompt).isEmpty }
            let prompt = try #require(agent.requests(ACPMethod.sessionPrompt).first?.params["prompt"]?.arrayValue)
            #expect(prompt.count == 3)
            #expect(prompt[0] == ["type": "text", "text": "Look"])
            #expect(prompt[1]["type"] == "resource_link")
            #expect(prompt[1]["uri"] == .string(source.absoluteString))
            #expect(prompt[1]["uri"]?.stringValue?.hasPrefix("file://") == true)
            #expect(prompt[1]["name"] == "main.swift")
            if acceptsImages {
                #expect(prompt[2]["type"] == "image")
                #expect(prompt[2]["mimeType"] == "image/png")
                #expect(prompt[2]["data"] == .string(Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()))
            } else {
                #expect(prompt[2]["type"] == "resource_link")
                #expect(prompt[2]["name"] == "shot.png")
            }
            await harness.session.shutDown()
        }
    }

    @Test func burstsAreFoldedWithoutLossOrReordering() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let agent = try harness.agent()
        let promptID = try await harness.send("Count")
        var expected = ""
        for number in 0..<1000 {
            try agent.agentText("s-new", "\(number),")
            expected += "\(number),"
        }
        try agent.finishPrompt(promptID)
        try await waitUntil("the turn ends") { !harness.session.isTurnRunning }
        #expect(harness.session.transcript.readableItems == ["user: Count", "agent: \(expected)"])
        #expect(harness.agentEvents.last == .turnFinished(message: expected, backgroundTasks: nil))
        // Throttled, so far fewer than one per chunk.
        #expect(harness.events.filter { $0 == .agent(.activity) }.count < 100)
        await harness.session.shutDown()
    }

    // MARK: Session id

    @Test func sessionIDIsConfirmedByTheFirstUpdateOfATurn() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let agent = try harness.agent()
        // Arrives without a prompt pending: proves nothing about the conversation.
        try agent.update("s-new", #"{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"compact","description":"Compact"}]}"#)
        try await waitUntil("commands arrive") { !harness.session.transcript.availableCommands.isEmpty }
        #expect(!harness.session.isAgentSessionIDConfirmed)
        #expect(!harness.events.contains(.agentSessionIDConfirmed("s-new")))

        let promptID = try await harness.send("Hi")
        #expect(!harness.session.isAgentSessionIDConfirmed)
        try agent.agentText("s-new", "Hello")
        try await waitUntil("the id is confirmed") { harness.session.isAgentSessionIDConfirmed }
        try agent.finishPrompt(promptID)
        try await waitUntil("the turn ends") { !harness.session.isTurnRunning }
        #expect(harness.events.filter { $0 == .agentSessionIDConfirmed("s-new") }.count == 1)
        await harness.session.shutDown()
    }

    @Test func sessionIDIsConfirmedByAResultWithoutUpdates() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let promptID = try await harness.send("/compact")
        try harness.agent().finishPrompt(promptID)
        try await waitUntil("the turn ends") { !harness.session.isTurnRunning }
        #expect(harness.session.isAgentSessionIDConfirmed)
        #expect(harness.events.contains(.agentSessionIDConfirmed("s-new")))
        await harness.session.shutDown()
    }

    // MARK: Permissions

    @Test func permissionRequestsQueueAndCanBeAnsweredOutOfOrder() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let agent = try harness.agent()
        try await harness.send("Edit both")
        try agent.update("s-new", Self.editCall)
        // Codex style: next to nothing in the request; the diff comes from the transcript.
        try agent.requestPermission(id: .int(0), sessionId: "s-new", toolCall: ["toolCallId": "edit-1"])
        // Never announced: the request creates the row.
        try agent.requestPermission(id: .string("p-2"), sessionId: "s-new", toolCall: ["toolCallId": "run-1", "title": "Run make", "kind": "execute"])
        try await waitUntil("both requests show") { harness.session.permissionRequests.count == 2 }

        let first = harness.session.permissionRequests[0]
        let second = harness.session.permissionRequests[1]
        #expect(first.id == .int(0))
        #expect(first.toolCall.title == "Edit a.swift")
        #expect(first.toolCall.content == [.diff(path: "/repo/a.swift", oldText: "let a = 1", newText: "let a = 2")])
        #expect(first.options.map(\.kind) == [.allowOnce, .allowAlways, .rejectOnce])
        #expect(second.toolCall.title == "Run make")
        #expect(harness.session.transcript.toolCall(id: "run-1")?.kind == .execute)

        harness.clearEvents()
        await harness.session.respond(to: second, optionId: "reject")
        #expect(harness.session.permissionRequests.map(\.id) == [.int(0)])
        // The chat still waits on the first, so the owner is asked to look again, not told it works.
        #expect(harness.events == [.agent(.attentionRequested(.permission, message: "Edit a.swift"))])
        await harness.session.respond(to: first, optionId: "allow")
        #expect(harness.session.permissionRequests.isEmpty)
        #expect(harness.events.last == .agent(.activity))
        try await waitUntil("both answers arrive") { agent.responses.count == 2 }
        #expect(agent.responses.map(\.id) == [.string("p-2"), .int(0)])
        #expect(agent.responses[0].result == .success(["outcome": ["outcome": "selected", "optionId": "reject"]]))
        #expect(agent.responses[1].result == .success(["outcome": ["outcome": "selected", "optionId": "allow"]]))
        await harness.session.shutDown()
    }

    @Test func permissionCardFollowsLaterToolUpdates() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let agent = try harness.agent()
        try await harness.send("Edit")
        try agent.requestPermission(id: .int(0), sessionId: "s-new", toolCall: ["toolCallId": "edit-1"])
        try await waitUntil("the request shows") { harness.session.permissionRequests.count == 1 }
        try agent.update("s-new", Self.editCall)
        try await waitUntil("the card has the title") { harness.session.permissionRequests.first?.toolCall.title == "Edit a.swift" }
        await harness.session.shutDown()
    }

    @Test func withdrawnRequestLeavesTheQueue() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let agent = try harness.agent()
        try await harness.send("Edit")
        try agent.requestPermission(id: .int(3), sessionId: "s-new", toolCall: ["toolCallId": "edit-1", "title": "Edit"])
        try await waitUntil("the request shows") { harness.session.permissionRequests.count == 1 }
        try agent.withdraw(.int(3))
        try await waitUntil("the request is gone") { harness.session.permissionRequests.isEmpty }
        await harness.session.shutDown()
    }

    @Test func cancelDuringAPermissionRequest() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let agent = try harness.agent()
        let promptID = try await harness.send("Edit")
        try agent.update("s-new", Self.editCall)
        try agent.requestPermission(id: .int(0), sessionId: "s-new", toolCall: ["toolCallId": "edit-1"])
        try await waitUntil("the request shows") { harness.session.permissionRequests.count == 1 }

        await harness.session.cancel()
        #expect(harness.session.isCancelling)
        #expect(harness.session.isTurnRunning)
        #expect(harness.session.permissionRequests.isEmpty)
        try await waitUntil("cancel and the answer arrive") {
            agent.notifications(ACPMethod.sessionCancel).count == 1 && agent.responses.count == 1
        }
        #expect(agent.notifications(ACPMethod.sessionCancel).first == ["sessionId": "s-new"])
        #expect(agent.responses.first?.result == .success(["outcome": ["outcome": "cancelled"]]))

        // Updates after the cancel still count.
        try agent.agentText("s-new", "Stopped.")
        try agent.finishPrompt(promptID, stopReason: "cancelled")
        try await waitUntil("the turn ends") { !harness.session.isTurnRunning }
        #expect(!harness.session.isCancelling)
        #expect(harness.session.transcript.lastAgentText == "Stopped.")
        #expect(harness.session.transcript.toolCall(id: "edit-1")?.status == .cancelled)
        #expect(harness.session.transcript.lastStopReason == .cancelled)
        await harness.session.shutDown()
    }

    @Test func codexStyleRejectEndsTheTurnWithoutAToolUpdate() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let agent = try harness.agent()
        let promptID = try await harness.send("Edit")
        try agent.update("s-new", #"{"sessionUpdate":"tool_call","toolCallId":"edit-1","title":"Edit a.swift","kind":"edit","status":"in_progress"}"#)
        try agent.requestPermission(id: .int(0), sessionId: "s-new", toolCall: ["toolCallId": "edit-1"])
        try await waitUntil("the request shows") { harness.session.permissionRequests.count == 1 }
        let request = try #require(harness.session.permissionRequests.first)
        await harness.session.respond(to: request, optionId: "reject")
        try await waitUntil("the answer arrives") { agent.responses.count == 1 }
        try agent.finishPrompt(promptID, stopReason: "cancelled")
        try await waitUntil("the turn ends") { !harness.session.isTurnRunning }
        #expect(harness.session.transcript.toolCall(id: "edit-1")?.status == .cancelled)
        #expect(harness.session.transcript.lastStopReason == .cancelled)
        #expect(harness.agentEvents.last == .turnFinished(message: nil, backgroundTasks: nil))
        await harness.session.shutDown()
    }

    // MARK: Failures during a turn

    @Test func failedPromptShowsAnInlineErrorUntilTheNextSend() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let agent = try harness.agent()
        let promptID = try await harness.send("Hi")
        try agent.update("s-new", #"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read","kind":"read","status":"in_progress"}"#)
        try agent.failPrompt(promptID, code: JSONRPCError.internalError, message: "Model overloaded")
        try await waitUntil("the turn ends") { !harness.session.isTurnRunning }
        #expect(harness.session.turnError == "The response couldn't be completed: Model overloaded")
        #expect(harness.session.phase == .ready)
        #expect(harness.session.transcript.toolCall(id: "t1")?.status == .cancelled)
        #expect(harness.agentEvents.last == .turnFinished(message: nil, backgroundTasks: nil))
        try await harness.send("Again")
        #expect(harness.session.turnError == nil)
        await harness.session.shutDown()
    }

    @Test func processExitMidTurnEndsTheChat() async throws {
        let harness = ChatHarness(stderr: "panic: out of memory\n")
        try await harness.start()
        let agent = try harness.agent()
        try await harness.send("Run it")
        try agent.update("s-new", #"{"sessionUpdate":"tool_call","toolCallId":"run","title":"make","kind":"execute","status":"in_progress"}"#)
        try agent.requestPermission(id: .int(0), sessionId: "s-new", toolCall: ["toolCallId": "run"])
        try await waitUntil("the request shows") { harness.session.permissionRequests.count == 1 }
        agent.close()
        try await waitUntil("the chat ends") { harness.session.phase.ending != nil }

        let ending = try #require(harness.session.phase.ending)
        #expect(!ending.isClean)
        #expect(ending.message == "The connection to Fake Agent was lost.")
        #expect(ending.details == "panic: out of memory")
        #expect(!harness.session.isTurnRunning)
        #expect(harness.session.permissionRequests.isEmpty)
        #expect(harness.session.transcript.toolCall(id: "run")?.status == .cancelled)
        #expect(harness.session.transcript.readableItems.first == "user: Run it")
        #expect(harness.agentEvents.last == .processExited(code: 1))
        #expect(!harness.session.canSend)
    }

    @Test func endingMessagesDescribeTheExit() {
        let harness = ChatHarness()
        #expect(harness.session.makeEnding(.exited(code: 0)).isClean)
        #expect(harness.session.makeEnding(.exited(code: 0)).message == "Fake Agent has quit.")
        #expect(harness.session.makeEnding(.exited(code: 3)).message == "Fake Agent quit unexpectedly (exit code 3).")
        #expect(harness.session.makeEnding(.exited(code: 3)).exitCode == 3)
        #expect(ChatSession.exitCode(reportedFor: .signaled(9)) == 137)
        #expect(ChatSession.exitCode(reportedFor: .exited(code: 2)) == 2)
    }

    // MARK: Sign-in

    private static let authMethods: [JSONValue] = [
        ["id": "chat-gpt", "name": "ChatGPT"],
        ["id": "api-key", "name": "API key", "type": "agent"],
        ["id": "login", "name": "Log in", "type": "terminal", "args": ["--login"]],
    ]

    @Test func signInAtSessionCreationThenRetry() async throws {
        var script = ScriptedAgent.Script()
        script.initialize = .result(ScriptedAgent.initializeResult(authMethods: Self.authMethods))
        script.newSession = [.error(JSONRPCError.authenticationRequired, "Authentication required"), .result(["sessionId": "s-new"])]
        let harness = ChatHarness(script: script)
        await harness.session.start()

        let failure = try #require(harness.session.phase.failure)
        guard case let .signInRequired(agentMethods, terminalMethods) = failure.reason else {
            Issue.record("expected sign-in, got \(failure.reason)")
            return
        }
        #expect(agentMethods.map(\.id) == ["chat-gpt", "api-key"])
        #expect(terminalMethods.map(\.id) == ["login"])
        #expect(terminalMethods.first?.args == ["--login"])
        #expect(failure.title == "Sign In to Fake Agent")
        #expect(harness.events == [.failed(failure)])

        await harness.session.authenticate(methodId: "chat-gpt")
        #expect(harness.session.phase == .ready)
        let agent = try harness.agent()
        #expect(agent.requests(ACPMethod.authenticate).first?.params == ["methodId": "chat-gpt"])
        #expect(agent.requests(ACPMethod.sessionNew).count == 2)
        #expect(harness.session.agentSessionID == "s-new")
        #expect(harness.events.last == .agent(.sessionStarted))
        await harness.session.shutDown()
    }

    @Test func signInAtFirstPromptResendsItWithoutASecondBubble() async throws {
        var script = ScriptedAgent.Script()
        script.initialize = .result(ScriptedAgent.initializeResult(authMethods: Self.authMethods))
        let harness = ChatHarness(script: script)
        try await harness.start()
        let agent = try harness.agent()
        let promptID = try await harness.send("Explain this repo")
        try agent.failPrompt(promptID, code: JSONRPCError.authenticationRequired, message: "Authentication required")
        try await waitUntil("sign-in is asked for") { harness.session.phase.failure != nil }
        #expect(!harness.session.isTurnRunning)
        #expect(!harness.session.isAgentSessionIDConfirmed)
        #expect(harness.session.transcript.readableItems == ["user: Explain this repo"])
        #expect(harness.session.turnError == nil)

        await harness.session.authenticate(methodId: "api-key")
        #expect(harness.session.phase == .ready)
        #expect(harness.session.isTurnRunning)
        try await waitUntil("the prompt is resent") { agent.requests(ACPMethod.sessionPrompt).count == 2 }
        let prompts = agent.requests(ACPMethod.sessionPrompt)
        #expect(prompts[0].params == prompts[1].params)
        #expect(harness.session.transcript.readableItems == ["user: Explain this repo"])
        try agent.finishPrompt(prompts[1].id)
        try await waitUntil("the turn ends") { !harness.session.isTurnRunning }
        await harness.session.shutDown()
    }

    @Test func retryAfterATerminalSignInResendsTheRefusedPrompt() async throws {
        var script = ScriptedAgent.Script()
        script.initialize = .result(ScriptedAgent.initializeResult(authMethods: Self.authMethods))
        let harness = ChatHarness(script: script)
        try await harness.start()
        let first = try harness.agent()
        let promptID = try await harness.send("Explain this repo")
        try first.failPrompt(promptID, code: JSONRPCError.authenticationRequired, message: "Authentication required")
        try await waitUntil("sign-in is asked for") { harness.session.phase.failure != nil }

        // The app ran the terminal method; the agent has to be started again to see the login.
        await harness.session.retry()
        #expect(harness.launchCount == 2)
        let second = try harness.agent()
        try await waitUntil("the prompt is resent") { second.requests(ACPMethod.sessionPrompt).count == 1 }
        #expect(second.requests(ACPMethod.sessionPrompt).first?.params["prompt"] == first.requests(ACPMethod.sessionPrompt).first?.params["prompt"])
        #expect(harness.session.transcript.readableItems == ["user: Explain this repo"])
        #expect(harness.session.isTurnRunning)
        await harness.session.shutDown()
    }

    @Test func failedSignInKeepsAskingAndSaysWhy() async throws {
        var script = ScriptedAgent.Script()
        script.initialize = .result(ScriptedAgent.initializeResult(authMethods: Self.authMethods))
        script.newSession = [.error(JSONRPCError.authenticationRequired, "Authentication required")]
        script.authenticate = .error(JSONRPCError.internalError, "Browser login was closed")
        let harness = ChatHarness(script: script)
        await harness.session.start()
        await harness.session.authenticate(methodId: "chat-gpt")
        #expect(harness.session.phase.failure?.title == "Sign In to Fake Agent")
        #expect(harness.session.notice == "Signing in to Fake Agent didn't finish. Browser login was closed")
        await harness.session.shutDown()
    }

    // MARK: Restoring

    private static let history = [
        #"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Fix it"}}"#,
        #"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Looking"}}"#,
        #"{"sessionUpdate":"tool_call","toolCallId":"edit-1","title":"Edit a.swift","kind":"edit","status":"completed"}"#,
        #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done."}}"#,
    ]

    @Test func replayIsSilentAndMatchesTheLiveTranscript() async throws {
        // Live.
        let live = ChatHarness()
        try await live.start()
        let liveAgent = try live.agent()
        let promptID = try await live.send("Fix it")
        for update in Self.history.dropFirst() { try liveAgent.update("s-new", update) }
        try liveAgent.finishPrompt(promptID)
        try await waitUntil("the live turn ends") { !live.session.isTurnRunning }
        await live.session.shutDown()

        // Replayed.
        var script = ScriptedAgent.Script()
        script.initialize = .result(ScriptedAgent.initializeResult(loadSession: true, resume: true))
        script.replay = Self.history + [
            #"{"sessionUpdate":"session_info_update","title":"Fix the bug"}"#,
            #"{"sessionUpdate":"usage_update","used":100,"size":1000}"#,
        ]
        let restored = ChatHarness(script: script, existingSessionID: "s-old")
        try await restored.start()
        let agent = try restored.agent()
        #expect(agent.requests(ACPMethod.sessionLoad).first?.params == ["sessionId": "s-old", "cwd": "/repo", "mcpServers": []])
        #expect(agent.requests(ACPMethod.sessionNew).isEmpty)
        #expect(agent.requests(ACPMethod.sessionResume).isEmpty)
        #expect(restored.session.transcript.readableItems == live.session.transcript.readableItems)
        #expect(!restored.session.transcript.isReplaying)
        #expect(restored.session.agentSessionID == "s-old")
        #expect(restored.session.isAgentSessionIDConfirmed)
        #expect(!restored.session.isHistoryUnavailable)
        // Nothing that would glow or notify; the replayed title and usage go out once, after it.
        #expect(restored.events == [.agent(.sessionStarted), .titleChanged("Fix the bug"), .usageChanged(used: 100, size: 1000)])
        await restored.session.shutDown()
    }

    @Test func resumeWhenLoadIsNotOffered() async throws {
        var script = ScriptedAgent.Script()
        script.initialize = .result(ScriptedAgent.initializeResult(loadSession: false, resume: true))
        let harness = ChatHarness(script: script, existingSessionID: "s-old")
        try await harness.start()
        let agent = try harness.agent()
        #expect(agent.requests(ACPMethod.sessionResume).first?.params == ["sessionId": "s-old", "cwd": "/repo", "mcpServers": []])
        #expect(agent.requests(ACPMethod.sessionNew).isEmpty)
        #expect(harness.session.agentSessionID == "s-old")
        #expect(harness.session.isAgentSessionIDConfirmed)
        #expect(harness.session.isHistoryUnavailable)
        #expect(harness.events == [.agent(.sessionStarted)])
        await harness.session.shutDown()
    }

    @Test func newSessionWhenNeitherLoadNorResumeIsOffered() async throws {
        let harness = ChatHarness(existingSessionID: "s-old")
        try await harness.start()
        let agent = try harness.agent()
        #expect(agent.requests(ACPMethod.sessionLoad).isEmpty)
        #expect(agent.requests(ACPMethod.sessionResume).isEmpty)
        #expect(agent.requests(ACPMethod.sessionNew).count == 1)
        #expect(harness.session.agentSessionID == "s-new")
        #expect(!harness.session.isAgentSessionIDConfirmed)
        #expect(harness.session.isHistoryUnavailable)
        await harness.session.shutDown()
    }

    @Test func unknownSessionOnLoadFallsBackToANewOne() async throws {
        var script = ScriptedAgent.Script()
        script.initialize = .result(ScriptedAgent.initializeResult(loadSession: true, resume: true))
        script.load = .error(JSONRPCError.resourceNotFound, "Session not found")
        let harness = ChatHarness(script: script, existingSessionID: "s-gone")
        try await harness.start()
        let agent = try harness.agent()
        #expect(agent.requests(ACPMethod.sessionLoad).count == 1)
        #expect(agent.requests(ACPMethod.sessionNew).count == 1)
        #expect(harness.session.agentSessionID == "s-new")
        #expect(!harness.session.isAgentSessionIDConfirmed)
        #expect(harness.session.isHistoryUnavailable)
        #expect(harness.session.transcript.items.isEmpty)
        await harness.session.shutDown()
    }

    @Test func unknownSessionOnResumeFallsBackToANewOne() async throws {
        var script = ScriptedAgent.Script()
        script.initialize = .result(ScriptedAgent.initializeResult(loadSession: false, resume: true))
        script.resume = .error(JSONRPCError.internalError, "No conversation found with session ID s-gone")
        let harness = ChatHarness(script: script, existingSessionID: "s-gone")
        try await harness.start()
        let agent = try harness.agent()
        #expect(agent.requests(ACPMethod.sessionResume).count == 1)
        #expect(agent.requests(ACPMethod.sessionNew).count == 1)
        #expect(harness.session.agentSessionID == "s-new")
        #expect(harness.session.isHistoryUnavailable)
        await harness.session.shutDown()
    }

    @Test func retryAfterACrashRestoresTheConversation() async throws {
        var script = ScriptedAgent.Script()
        script.initialize = .result(ScriptedAgent.initializeResult(loadSession: true))
        let harness = ChatHarness(script: script)
        try await harness.start()
        let first = try harness.agent()
        let promptID = try await harness.send("Hi")
        try first.finishPrompt(promptID)
        try await waitUntil("the turn ends") { !harness.session.isTurnRunning }
        first.close()
        try await waitUntil("the chat ends") { harness.session.phase.ending != nil }

        harness.editTemplate { $0.replay = [#"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Hi"}}"#] }
        await harness.session.retry()
        #expect(harness.session.phase == .ready)
        #expect(harness.launchCount == 2)
        let second = try harness.agent()
        #expect(second.requests(ACPMethod.sessionLoad).first?.params["sessionId"] == "s-new")
        #expect(harness.session.transcript.readableItems == ["user: Hi"])
        await harness.session.shutDown()
    }

    // MARK: Settings

    @Test func legacyModesBecomeOneModeControl() async throws {
        var script = ScriptedAgent.Script()
        script.newSession = [.result([
            "sessionId": "s-new",
            "modes": ["currentModeId": "default", "availableModes": [["id": "default", "name": "Default"], ["id": "plan", "name": "Plan"]]],
        ])]
        let harness = ChatHarness(script: script)
        try await harness.start()
        let control = try #require(harness.session.controls.first)
        #expect(harness.session.controls.count == 1)
        #expect(control.id == ChatControl.modeFallbackID)
        #expect(control.currentChoiceName == "Default")

        await harness.session.setControl(ChatControl.modeFallbackID, to: "plan")
        #expect(try harness.agent().requests(ACPMethod.sessionSetMode).first?.params == ["sessionId": "s-new", "modeId": "plan"])
        #expect(harness.session.transcript.currentModeId == "plan")
        #expect(harness.session.controls.first?.currentChoiceName == "Plan")
        await harness.session.shutDown()
    }

    @Test func configOptionsAreOrderedAndUpdatedFromTheAnswer() async throws {
        let options: JSONValue = [
            ["id": "fast", "name": "Fast", "type": "boolean", "currentValue": false],
            ["id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "sonnet",
             "options": [["value": "sonnet", "name": "Sonnet"], ["value": "opus", "name": "Opus"]]],
            ["id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": "default",
             "options": [["group": "basic", "name": "Basic", "options": [["value": "default", "name": "Default"]]]]],
        ]
        var script = ScriptedAgent.Script()
        script.newSession = [.result([
            "sessionId": "s-new", "configOptions": options,
            "modes": ["currentModeId": "default", "availableModes": [["id": "default", "name": "Default"]]],
        ])]
        var changed = options.arrayValue ?? []
        changed[1] = ["id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "opus",
                      "options": [["value": "sonnet", "name": "Sonnet"], ["value": "opus", "name": "Opus"]]]
        script.setConfigOption = .result(["configOptions": .array(changed)])
        let harness = ChatHarness(script: script)
        try await harness.start()
        #expect(harness.session.controls.map(\.id) == ["mode", "model", "fast"])
        #expect(harness.session.controls[0].value == .select(
            current: "default",
            groups: [ChatControl.ChoiceGroup(name: "Basic", choices: [ConfigOptionValue(value: "default", name: "Default")])]
        ))
        #expect(harness.session.controls[2].value == .toggle(false))

        await harness.session.setControl("model", to: "opus")
        #expect(try harness.agent().requests(ACPMethod.sessionSetConfigOption).first?.params == ["sessionId": "s-new", "configId": "model", "value": "opus"])
        #expect(harness.session.controls[1].currentChoiceName == "Opus")
        await harness.session.shutDown()
    }

    @Test func unsupportedSettingLeavesTheChatWorking() async throws {
        var script = ScriptedAgent.Script()
        script.newSession = [.result([
            "sessionId": "s-new",
            "modes": ["currentModeId": "default", "availableModes": [["id": "default", "name": "Default"], ["id": "plan", "name": "Plan"]]],
        ])]
        script.setMode = .error(JSONRPCError.methodNotFound, "Method not found")
        let harness = ChatHarness(script: script)
        try await harness.start()
        await harness.session.setControl(ChatControl.modeFallbackID, to: "plan")
        #expect(harness.session.notice == "Fake Agent can't change mode from here.")
        #expect(harness.session.transcript.currentModeId == "default")
        #expect(harness.session.phase == .ready)
        try await harness.send("Still here")
        #expect(harness.session.notice == nil)
        await harness.session.shutDown()
    }

    // MARK: Title and usage

    @Test func titleAndUsageAreReportedWhenTheyChange() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let agent = try harness.agent()
        let promptID = try await harness.send("Hi")
        try agent.update("s-new", #"{"sessionUpdate":"session_info_update","title":"Say hello"}"#)
        try agent.update("s-new", #"{"sessionUpdate":"session_info_update","_meta":{"threadStatus":"active"}}"#)
        try agent.update("s-new", #"{"sessionUpdate":"usage_update","used":10,"size":100}"#)
        try await waitUntil("usage is reported") { harness.events.contains(.usageChanged(used: 10, size: 100)) }
        // Unchanged usage is not reported again; a burst only reports where it ended up.
        try agent.update("s-new", #"{"sessionUpdate":"usage_update","used":10,"size":100}"#)
        try agent.update("s-new", #"{"sessionUpdate":"usage_update","used":15,"size":100}"#)
        try agent.update("s-new", #"{"sessionUpdate":"usage_update","used":20,"size":100}"#)
        try agent.finishPrompt(promptID)
        try await waitUntil("the turn ends") { !harness.session.isTurnRunning }
        #expect(harness.events.filter { if case .titleChanged = $0 { true } else { false } } == [.titleChanged("Say hello")])
        let usage = harness.events.filter { if case .usageChanged = $0 { true } else { false } }
        #expect(usage.first == .usageChanged(used: 10, size: 100))
        #expect(usage.last == .usageChanged(used: 20, size: 100))
        #expect(usage.filter { $0 == .usageChanged(used: 10, size: 100) }.count == 1)
        #expect(harness.session.transcript.title == "Say hello")
        await harness.session.shutDown()
    }

    // MARK: Stopping

    @Test func shutDownEndsQuietly() async throws {
        let harness = ChatHarness()
        try await harness.start()
        try await harness.send("Hi")
        harness.clearEvents()
        await harness.session.shutDown()
        #expect(harness.session.phase.ending?.isClean == true)
        #expect(!harness.session.isTurnRunning)
        #expect(harness.events.isEmpty)
        #expect(harness.session.transcript.readableItems == ["user: Hi"])
    }

    @Test func terminateNowStopsTheAgentAtOnce() async throws {
        let harness = ChatHarness()
        try await harness.start()
        harness.clearEvents()
        harness.session.terminateNow()
        #expect(harness.session.phase.ending != nil)
        // The fake's end of the pipe was closed, so the agent sees end of input.
        let agent = try harness.agent()
        #expect(throws: (any Error).self) { try agent.agentText("s-new", "late") }
        #expect(harness.events.isEmpty)
    }

    // MARK: Previews

    @Test func previewsShowTheirState() {
        #expect(ChatSession.preview(.empty).phase == .ready)
        #expect(ChatSession.preview(.empty).controls.map(\.id) == ["mode", "model", "effort"])
        #expect(ChatSession.preview(.streaming).isTurnRunning)
        #expect(ChatSession.preview(.awaitingPermission).permissionRequests.count == 1)
        #expect(ChatSession.preview(.installing).phase == .starting(.installing(agentName: "Claude Code", fraction: 0.42)))
        #expect(ChatSession.preview(.signInRequired).phase.failure?.title == "Sign In to Claude Code")
        #expect(ChatSession.preview(.nodeMissing).phase.failure?.reason == .nodeMissing)
        #expect(ChatSession.preview(.ended).phase.ending?.isClean == false)
        let finished = ChatSession.preview(.finished)
        #expect(finished.transcript.plan.count == 4)
        #expect(finished.transcript.items.count == 7)
        #expect(!finished.send(text: "Previews do nothing"))
    }
}
