@testable import ACPKit
import Foundation
import Testing

struct SessionUpdateDecodingTests {
    private func update(_ json: String) throws -> SessionUpdate {
        try decode(SessionUpdate.self, json)
    }

    @Test func messageChunks() throws {
        #expect(try update(UpdateSamples.userChunk) == .userMessageChunk(ContentChunk(content: .text("Fix the bug"))))
        #expect(try update(UpdateSamples.agentChunk) == .agentMessageChunk(ContentChunk(content: .text("Looking at "), messageId: "msg_1", meta: ["x": 1])))
        #expect(try update(UpdateSamples.thoughtChunk) == .agentThoughtChunk(ContentChunk(content: .text("The user wants"))))
    }

    @Test func toolCall() throws {
        let expected = ToolCall(
            toolCallId: "toolu_01",
            title: "Read src/main.swift",
            kind: .read,
            status: .pending,
            content: [.content(.text("reading"))],
            locations: [ToolCallLocation(path: "/repo/src/main.swift", line: 12)],
            rawInput: ["file_path": "/repo/src/main.swift", "limit": 40]
        )
        #expect(try update(UpdateSamples.toolCall) == .toolCall(expected))
    }

    @Test func toolCallUpdateKeepsOnlyWhatIsPresent() throws {
        let expected = ToolCallUpdate(
            toolCallId: "toolu_01",
            status: .completed,
            content: [.diff(path: "/repo/a.swift", oldText: "let a = 1", newText: "let a = 2"), .terminal(terminalId: "term-1")],
            rawOutput: ["ok": true]
        )
        #expect(try update(UpdateSamples.toolCallUpdate) == .toolCallUpdate(expected))
    }

    @Test func toolCallDefaults() throws {
        let decoded = try update(#"{"sessionUpdate":"tool_call","toolCallId":"t"}"#)
        #expect(decoded == .toolCall(ToolCall(toolCallId: "t", title: "", kind: .other, status: .pending)))
    }

    @Test func unknownToolKindAndStatus() throws {
        let decoded = try update(#"{"sessionUpdate":"tool_call","toolCallId":"t","title":"x","kind":"teleport","status":"warming_up"}"#)
        guard case let .toolCall(call) = decoded else { Issue.record("not a tool call"); return }
        #expect(call.kind == .other)
        #expect(call.status == .inProgress)

        let mistyped = try update(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","kind":7,"status":null,"content":null,"locations":"nope"}"#)
        #expect(mistyped == .toolCallUpdate(ToolCallUpdate(toolCallId: "t", kind: .other)))
    }

    @Test func badContentElementsAreDropped() throws {
        let decoded = try update(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","content":[{"type":"diff"},{"type":"content","content":{"type":"text","text":"ok"}},{"type":"hologram","x":1}]}"#)
        #expect(decoded == .toolCallUpdate(ToolCallUpdate(
            toolCallId: "t",
            content: [.content(.text("ok")), .unknown(["type": "hologram", "x": 1])]
        )))
    }

    @Test func plan() throws {
        #expect(try update(UpdateSamples.plan) == .plan([
            PlanEntry(content: "Read the code", priority: .high, status: .completed),
            PlanEntry(content: "Write the fix", priority: .medium, status: .inProgress),
            PlanEntry(content: "Run tests", priority: .low, status: .pending),
        ]))
        #expect(try update(#"{"sessionUpdate":"plan","entries":[{"content":"x","priority":"urgent","status":"blocked"}]}"#)
            == .plan([PlanEntry(content: "x", priority: .medium, status: .pending)]))
    }

    @Test func availableCommands() throws {
        #expect(try update(UpdateSamples.commands) == .availableCommands([
            AvailableCommand(name: "compact", description: "Compact the conversation"),
            AvailableCommand(name: "review", description: "Review changes", inputHint: "branch or path"),
        ]))
    }

    @Test func modeConfigInfoAndUsage() throws {
        #expect(try update(UpdateSamples.mode) == .currentMode(modeId: "plan"))
        #expect(try update(UpdateSamples.configOptions) == .configOptions([
            SessionConfigOption(
                id: "model",
                name: "Model",
                category: .model,
                type: .select,
                currentValue: "sonnet",
                options: .flat([ConfigOptionValue(value: "sonnet", name: "Sonnet"), ConfigOptionValue(value: "opus", name: "Opus", description: "Smartest")])
            ),
        ]))
        #expect(try update(UpdateSamples.sessionInfo) == .sessionInfo(SessionInfoUpdate(title: "Fix login bug", updatedAt: "2026-11-24T10:00:00Z")))
        #expect(try update(UpdateSamples.usage) == .usage(UsageUpdate(used: 53000, size: 200_000, cost: .init(amount: 0.42, currency: "USD"))))
    }

    @Test func unknownVariantIsKeptRaw() throws {
        let decoded = try update(UpdateSamples.unknown)
        #expect(decoded == .unknown(kind: "compaction_update", raw: [
            "sessionUpdate": "compaction_update", "phase": "started", "detail": ["tokens": 120_000],
        ]))
        #expect(decoded.kind == "compaction_update")
        #expect(try self.update(jsonString(decoded)) == decoded)
    }

    @Test func everyVariantRoundTrips() throws {
        let samples = [
            UpdateSamples.userChunk, UpdateSamples.agentChunk, UpdateSamples.thoughtChunk, UpdateSamples.toolCall,
            UpdateSamples.toolCallUpdate, UpdateSamples.plan, UpdateSamples.commands, UpdateSamples.mode,
            UpdateSamples.configOptions, UpdateSamples.sessionInfo, UpdateSamples.usage, UpdateSamples.unknown,
        ]
        for sample in samples {
            let decoded = try update(sample)
            let encoded = try jsonString(decoded)
            #expect(!encoded.contains("\n"))
            #expect(try update(encoded) == decoded, "\(sample)")
        }
    }

    @Test func notificationEnvelope() throws {
        let json = #"{"sessionId":"s1","update":\#(UpdateSamples.mode),"_meta":{"trace":"x"}}"#
        #expect(try decode(SessionNotification.self, json) == SessionNotification(sessionId: "s1", update: .currentMode(modeId: "plan")))
    }
}

struct ContentBlockTests {
    @Test func everyKind() throws {
        #expect(try decode(ContentBlock.self, #"{"type":"text","text":"hi","annotations":{"priority":1}}"#) == .text("hi"))
        #expect(try decode(ContentBlock.self, #"{"type":"image","data":"AAAA","mimeType":"image/png","uri":"file:///a.png"}"#)
            == .image(data: "AAAA", mimeType: "image/png", uri: "file:///a.png"))
        #expect(try decode(ContentBlock.self, #"{"type":"audio","data":"BBBB","mimeType":"audio/wav"}"#) == .audio(data: "BBBB", mimeType: "audio/wav"))
        #expect(try decode(ContentBlock.self, #"{"type":"resource_link","uri":"file:///repo/a.swift","name":"a.swift","mimeType":"text/x-swift","size":120}"#)
            == .resourceLink(ResourceLink(uri: "file:///repo/a.swift", name: "a.swift", mimeType: "text/x-swift", size: 120)))
        #expect(try decode(ContentBlock.self, #"{"type":"resource","resource":{"uri":"file:///a.txt","text":"body","mimeType":"text/plain"}}"#)
            == .resource(EmbeddedResource(uri: "file:///a.txt", mimeType: "text/plain", contents: .text("body"))))
        #expect(try decode(ContentBlock.self, #"{"type":"resource","resource":{"uri":"file:///a.bin","blob":"AAEC"}}"#)
            == .resource(EmbeddedResource(uri: "file:///a.bin", contents: .blob("AAEC"))))
        #expect(try decode(ContentBlock.self, #"{"type":"video","url":"x"}"#) == .unknown(["type": "video", "url": "x"]))
    }

    @Test func encodesTheWireShape() throws {
        let link = ContentBlock.resourceLink(ResourceLink(uri: "file:///repo/a.swift", name: "a.swift"))
        #expect(try decode(JSONValue.self, jsonString(link)) == ["type": "resource_link", "uri": "file:///repo/a.swift", "name": "a.swift"])
        let blocks: [ContentBlock] = [
            .text("x"), link, .image(data: "AA", mimeType: "image/png"), .audio(data: "BB", mimeType: "audio/wav"),
            .resource(EmbeddedResource(uri: "u", contents: .text("t"))), .unknown(["type": "new"]),
        ]
        for block in blocks {
            #expect(try decode(ContentBlock.self, jsonString(block)) == block)
        }
    }
}

struct MessageDecodingTests {
    @Test func initializeResponseWithMarkersAsBoolsAndObjects() throws {
        let json = #"""
        {"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true,"audio":false,"embeddedContext":{}},
        "mcpCapabilities":{"http":{},"sse":null},"sessionCapabilities":{"resume":{},"close":{"_meta":{}},"list":false},"auth":{"logout":{}},"future":{"x":1}},
        "agentInfo":{"name":"claude-agent-acp","title":"Claude Code","version":"0.110.0"},
        "authMethods":[{"id":"claude-login","name":"Log in with Claude","description":"Opens a browser"},
        {"id":"terminal-login","name":"Log in in a terminal","type":"terminal","args":["--login"],"env":{"FORCE":"1"}},
        {"id":"pairs","name":"Pairs","type":"terminal","env":[{"name":"A","value":"b"}]},
        {"id":"novel","name":"New kind","type":"webauthn"},{"name":"missing id"}]}
        """#
        let response = try decode(InitializeResponse.self, json)
        #expect(response.protocolVersion == 1)
        let capabilities = response.agentCapabilities
        #expect(capabilities.loadSession)
        #expect(capabilities.promptCapabilities == .init(image: true, audio: false, embeddedContext: true))
        #expect(capabilities.mcpCapabilities == .init(http: true, sse: false))
        #expect(capabilities.sessionCapabilities == .init(list: false, resume: true, close: true, delete: false))
        #expect(capabilities.auth.logout)
        #expect(response.agentInfo == Implementation(name: "claude-agent-acp", title: "Claude Code", version: "0.110.0"))
        #expect(response.authMethods == [
            AuthMethod(id: "claude-login", name: "Log in with Claude", description: "Opens a browser"),
            AuthMethod(id: "terminal-login", name: "Log in in a terminal", type: .terminal, args: ["--login"], env: ["FORCE": "1"]),
            AuthMethod(id: "pairs", name: "Pairs", type: .terminal, env: ["A": "b"]),
            AuthMethod(id: "novel", name: "New kind", type: .unknown("webauthn")),
        ])
    }

    @Test func minimalInitializeResponse() throws {
        let response = try decode(InitializeResponse.self, #"{"protocolVersion":1}"#)
        #expect(response == InitializeResponse(protocolVersion: 1))
    }

    @Test func initializeRequestShape() throws {
        let request = InitializeRequest(
            protocolVersion: 1,
            clientCapabilities: ClientCapabilities(auth: .init(terminal: true)),
            clientInfo: Implementation(name: "archipel", version: "1.0")
        )
        #expect(try decode(JSONValue.self, jsonString(request)) == [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false, "auth": ["terminal": true]],
            "clientInfo": ["name": "archipel", "version": "1.0"],
        ])
    }

    @Test func newSessionWithModesAndGroupedConfigOptions() throws {
        let json = #"""
        {"sessionId":"sess_1","modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default"},{"id":"plan","name":"Plan","description":"Read only"}]},
        "configOptions":[
          {"id":"model","name":"Model","type":"select","currentValue":"gpt-5","options":[
            {"group":"openai","name":"OpenAI","options":[{"value":"gpt-5","name":"GPT-5"}]},
            {"group":"local","name":"Local","options":[{"value":"llama","name":"Llama"}]}]},
          {"id":"fast","name":"Fast mode","category":"custom","type":"boolean","currentValue":false},
          {"id":"slider","name":"Temperature","type":"range","currentValue":0.5},
          {"id":"effort","name":"Effort","category":"brand_new","type":"select","currentValue":"high","options":[{"value":"high","name":"High"}]}
        ]}
        """#
        let response = try decode(NewSessionResponse.self, json)
        #expect(response.sessionId == "sess_1")
        #expect(response.modes == SessionModeState(currentModeId: "default", availableModes: [
            SessionMode(id: "default", name: "Default"), SessionMode(id: "plan", name: "Plan", description: "Read only"),
        ]))
        let options = try #require(response.configOptions)
        #expect(options.map(\.id) == ["model", "fast", "effort"])
        #expect(options[0].options == .grouped([
            ConfigOptionGroup(group: "openai", name: "OpenAI", options: [ConfigOptionValue(value: "gpt-5", name: "GPT-5")]),
            ConfigOptionGroup(group: "local", name: "Local", options: [ConfigOptionValue(value: "llama", name: "Llama")]),
        ]))
        #expect(options[0].options.allValues.map(\.value) == ["gpt-5", "llama"])
        #expect(options[1].type == .boolean)
        #expect(options[1].currentValue == false)
        #expect(options[1].category == .custom)
        #expect(options[2].category == .unknown("brand_new"))
        #expect(try decode(NewSessionResponse.self, jsonString(response)) == response)
    }

    @Test func sessionRequestsCarryEmptyMCPServers() throws {
        #expect(try decode(JSONValue.self, jsonString(NewSessionRequest(cwd: "/repo"))) == ["cwd": "/repo", "mcpServers": []])
        #expect(try decode(JSONValue.self, jsonString(ExistingSessionRequest(sessionId: "s", cwd: "/repo")))
            == ["sessionId": "s", "cwd": "/repo", "mcpServers": []])
    }

    @Test func stopReasons() throws {
        for (raw, reason) in [("end_turn", StopReason.endTurn), ("max_tokens", .maxTokens), ("max_turn_requests", .maxTurnRequests), ("refusal", .refusal), ("cancelled", .cancelled), ("paused", .unknown("paused"))] {
            #expect(try decode(PromptResponse.self, #"{"stopReason":"\#(raw)"}"#).stopReason == reason)
            #expect(try jsonString(reason) == "\"\(raw)\"")
        }
        #expect(try decode(PromptResponse.self, "{}").stopReason == .endTurn)
    }

    @Test func permissionRequest() throws {
        let json = #"""
        {"sessionId":"s1","toolCall":{"toolCallId":"toolu_9","title":"rm -rf build","kind":"execute","status":"pending","rawInput":{"command":"rm -rf build"}},
        "options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"always","name":"Always allow","kind":"allow_always"},
        {"optionId":"reject","name":"Reject","kind":"reject_once"},{"optionId":"never","name":"Never","kind":"reject_always"},{"optionId":"x","name":"Maybe","kind":"ask_later"}]}
        """#
        let request = try decode(RequestPermissionRequest.self, json)
        #expect(request.sessionId == "s1")
        #expect(request.toolCall == ToolCallUpdate(toolCallId: "toolu_9", title: "rm -rf build", kind: .execute, status: .pending, rawInput: ["command": "rm -rf build"]))
        #expect(request.options.map(\.kind) == [.allowOnce, .allowAlways, .rejectOnce, .rejectAlways, .unknown("ask_later")])
        #expect(request.options.map(\.kind.isAllow) == [true, true, false, false, false])
    }

    @Test func permissionOutcomes() throws {
        #expect(try decode(JSONValue.self, jsonString(RequestPermissionResponse(outcome: .selected(optionId: "allow"))))
            == ["outcome": ["outcome": "selected", "optionId": "allow"]])
        #expect(try decode(JSONValue.self, jsonString(RequestPermissionResponse(outcome: .cancelled)))
            == ["outcome": ["outcome": "cancelled"]])
        #expect(try decode(RequestPermissionResponse.self, #"{"outcome":{"outcome":"selected","optionId":"a"}}"#).outcome == .selected(optionId: "a"))
        #expect(try decode(RequestPermissionResponse.self, #"{"outcome":{"outcome":"cancelled"}}"#).outcome == .cancelled)
    }

    @Test func emptyResultsDecodeFromAnything() throws {
        #expect(try decode(EmptyResult.self, "{}") == EmptyResult())
        #expect(try decode(EmptyResult.self, #"{"_meta":{}}"#) == EmptyResult())
        #expect(try jsonString(EmptyResult()) == "{}")
    }
}
