@testable import ACPKit
import Foundation
import Testing

struct ChatTranscriptTests {
    private func agent(_ text: String, id: String? = nil) -> SessionUpdate {
        .agentMessageChunk(ContentChunk(content: .text(text), messageId: id))
    }

    private func thought(_ text: String) -> SessionUpdate {
        .agentThoughtChunk(ContentChunk(content: .text(text)))
    }

    private func user(_ text: String) -> SessionUpdate {
        .userMessageChunk(ContentChunk(content: .text(text)))
    }

    private func folded(_ updates: [SessionUpdate]) -> ChatTranscript {
        var transcript = ChatTranscript()
        updates.forEach { transcript.apply($0) }
        return transcript
    }

    @Test func chunksOfOneRoleMerge() {
        let transcript = folded([agent("Hel"), agent("lo, "), agent("world")])
        #expect(transcript.items == [.agentMessage(ChatMessage(id: "message-0", text: "Hello, world"))])
        #expect(transcript.lastAgentText == "Hello, world")
    }

    @Test func aDifferentItemInBetweenStartsANewMessage() {
        let transcript = folded([
            thought("Think"), thought("ing"),
            agent("A"), agent("B"),
            .toolCall(ToolCall(toolCallId: "t1", title: "Read")),
            agent("C"),
            thought("More"),
            agent("D"),
        ])
        #expect(transcript.items.map(\.id) == ["message-0", "message-1", "tool:t1", "message-2", "message-3", "message-4"])
        #expect(transcript.items.compactMap(\.message?.text) == ["Thinking", "AB", "C", "More", "D"])
        #expect(transcript.lastAgentText == "D")
    }

    @Test func messageIdsSplitMessages() {
        let transcript = folded([agent("one ", id: "m1"), agent("more", id: "m1"), agent("two", id: "m2"), agent(" and more")])
        #expect(transcript.items.compactMap(\.message?.text) == ["one more", "two and more"])
        #expect(transcript.items.compactMap(\.message?.messageId) == ["m1", "m2"])
    }

    @Test func aMissingIdAdoptsTheNextOne() {
        let transcript = folded([agent("a"), agent("b", id: "m1"), agent("c", id: "m1"), agent("d", id: "m2")])
        #expect(transcript.items.compactMap(\.message?.text) == ["abc", "d"])
    }

    @Test func nonTextBlocksBecomeAttachments() {
        let link = ContentBlock.resourceLink(ResourceLink(uri: "file:///a.swift", name: "a.swift"))
        let image = ContentBlock.image(data: "AA", mimeType: "image/png")
        let transcript = folded([
            agent("See "),
            .agentMessageChunk(ContentChunk(content: link)),
            agent("this"),
            .agentMessageChunk(ContentChunk(content: image)),
        ])
        #expect(transcript.items == [.agentMessage(ChatMessage(id: "message-0", text: "See this", attachments: [link, image]))])
    }

    @Test func toolCallsAreCreatedReplacedAndMerged() {
        var transcript = ChatTranscript()
        transcript.apply(.toolCall(ToolCall(toolCallId: "t1", title: "Run tests", kind: .execute, status: .pending, rawInput: ["command": "swift test"])))
        transcript.apply(agent("Running"))
        transcript.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: "t1", status: .inProgress)))
        transcript.apply(.toolCallUpdate(ToolCallUpdate(
            toolCallId: "t1",
            status: .completed,
            content: [.content(.text("All passed"))],
            rawOutput: ["exit": 0]
        )))

        #expect(transcript.items.count == 2)
        guard case let .toolCall(call) = transcript.items[0] else { Issue.record("not a tool call"); return }
        #expect(call == ToolCall(
            toolCallId: "t1",
            title: "Run tests",
            kind: .execute,
            status: .completed,
            content: [.content(.text("All passed"))],
            rawInput: ["command": "swift test"],
            rawOutput: ["exit": 0]
        ))

        // Announcing the same id again replaces it in place.
        transcript.apply(.toolCall(ToolCall(toolCallId: "t1", title: "Run tests again")))
        #expect(transcript.items.count == 2)
        #expect(transcript.items[0] == .toolCall(ToolCall(toolCallId: "t1", title: "Run tests again")))
        // An update to a call does not interrupt the message after it.
        transcript.apply(agent(" still"))
        #expect(transcript.items.count == 2)
        #expect(transcript.lastAgentText == "Running still")
    }

    @Test func interleavedToolCalls() {
        let transcript = folded([
            .toolCall(ToolCall(toolCallId: "a", title: "A")),
            .toolCall(ToolCall(toolCallId: "b", title: "B")),
            .toolCallUpdate(ToolCallUpdate(toolCallId: "a", status: .completed)),
            .toolCallUpdate(ToolCallUpdate(toolCallId: "b", status: .failed, locations: [ToolCallLocation(path: "/x")])),
            .toolCallUpdate(ToolCallUpdate(toolCallId: "a", title: "A done")),
        ])
        #expect(transcript.items == [
            .toolCall(ToolCall(toolCallId: "a", title: "A done", status: .completed)),
            .toolCall(ToolCall(toolCallId: "b", title: "B", status: .failed, locations: [ToolCallLocation(path: "/x")])),
        ])
    }

    @Test func updateForAnUnknownIdCreatesTheCall() {
        let transcript = folded([.toolCallUpdate(ToolCallUpdate(toolCallId: "ghost", title: "Edit", kind: .edit, status: .inProgress))])
        #expect(transcript.items == [.toolCall(ToolCall(toolCallId: "ghost", title: "Edit", kind: .edit, status: .inProgress))])
        #expect(transcript.items.first?.id == "tool:ghost")
    }

    @Test func planIsReplacedAndSessionStateTracked() {
        var transcript = folded([
            .plan([PlanEntry(content: "one"), PlanEntry(content: "two")]),
            .plan([PlanEntry(content: "only", status: .inProgress)]),
            .availableCommands([AvailableCommand(name: "compact", description: "")]),
            .currentMode(modeId: "plan"),
            .configOptions([SessionConfigOption(id: "fast", name: "Fast", type: .boolean, currentValue: false)]),
            .usage(UsageUpdate(used: 10, size: 100)),
            .sessionInfo(SessionInfoUpdate(title: "Title")),
            .sessionInfo(SessionInfoUpdate(updatedAt: "now")),
            .unknown(kind: "future", raw: [:]),
        ])
        #expect(transcript.plan == [PlanEntry(content: "only", status: .inProgress)])
        #expect(transcript.availableCommands.map(\.name) == ["compact"])
        #expect(transcript.currentModeId == "plan")
        #expect(transcript.configOptions.map(\.id) == ["fast"])
        #expect(transcript.usage == UsageUpdate(used: 10, size: 100))
        #expect(transcript.title == "Title")
        #expect(transcript.items.isEmpty)

        transcript.apply(SessionSetup(modes: SessionModeState(currentModeId: "default", availableModes: [SessionMode(id: "default", name: "Default")])))
        #expect(transcript.currentModeId == "default")
        #expect(transcript.availableModes.map(\.id) == ["default"])
        #expect(transcript.configOptions.map(\.id) == ["fast"])
        transcript.setConfigOptions([])
        #expect(transcript.configOptions.isEmpty)
    }

    @Test func cancelMarksOnlyUnfinishedCalls() {
        var transcript = folded([
            .toolCall(ToolCall(toolCallId: "done", title: "", status: .completed)),
            .toolCall(ToolCall(toolCallId: "running", title: "", status: .inProgress)),
            .toolCall(ToolCall(toolCallId: "waiting", title: "", status: .pending)),
            .toolCall(ToolCall(toolCallId: "broken", title: "", status: .failed)),
        ])
        transcript.markUnfinishedToolCallsCancelled()
        let statuses = transcript.items.compactMap { item -> ToolCallStatus? in
            if case let .toolCall(call) = item { call.status } else { nil }
        }
        #expect(statuses == [.completed, .cancelled, .cancelled, .failed])
    }

    @Test func oneCallCanBeMarkedCancelledAndTheAgentStillHasTheLastWord() {
        var transcript = folded([
            .toolCall(ToolCall(toolCallId: "refused", title: "", status: .pending)),
            .toolCall(ToolCall(toolCallId: "running", title: "", status: .inProgress)),
            .toolCall(ToolCall(toolCallId: "done", title: "", status: .completed)),
        ])
        transcript.markToolCallCancelled(id: "refused")
        transcript.markToolCallCancelled(id: "done")
        transcript.markToolCallCancelled(id: "unknown")
        #expect(transcript.toolCall(id: "refused")?.status == .cancelled)
        #expect(transcript.toolCall(id: "running")?.status == .inProgress)
        #expect(transcript.toolCall(id: "done")?.status == .completed)
        // An agent that does report what became of the call overwrites the guess.
        transcript.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: "refused", status: .failed)))
        #expect(transcript.toolCall(id: "refused")?.status == .failed)
    }

    @Test func liveUserChunksAreIgnoredByDefault() {
        var live = ChatTranscript()
        #expect(live.ignoresUserMessageChunks)
        live.appendUserPrompt([.text("Fix it")])
        live.apply(user("Fix it"))
        live.apply(agent("Done"))
        #expect(live.items.compactMap(\.message?.text) == ["Fix it", "Done"])

        var replay = ChatTranscript()
        replay.beginReplay()
        replay.apply(user("Fix it"))
        replay.apply(agent("Done"))
        replay.endReplay()
        #expect(replay.items == live.items)

        var echoing = ChatTranscript()
        echoing.ignoresUserMessageChunks = false
        echoing.apply(user("Typed elsewhere"))
        #expect(echoing.items.compactMap(\.message?.text) == ["Typed elsewhere"])
    }

    @Test func promptsAreSeparateMessages() {
        var transcript = ChatTranscript()
        let link = ContentBlock.resourceLink(ResourceLink(uri: "file:///a", name: "a"))
        transcript.appendUserPrompt([.text("first "), link, .text("part")])
        transcript.appendUserPrompt([.text("second")])
        #expect(transcript.items == [
            .userMessage(ChatMessage(id: "message-0", text: "first part", attachments: [link])),
            .userMessage(ChatMessage(id: "message-1", text: "second")),
        ])
    }

    @Test func turnBoundaryStartsANewMessage() {
        var transcript = folded([agent("first turn")])
        transcript.endTurn(.endTurn)
        transcript.apply(agent("second turn"))
        #expect(transcript.items.compactMap(\.message?.text) == ["first turn", "second turn"])
        #expect(transcript.lastStopReason == .endTurn)
        transcript.endTurn(.cancelled)
        #expect(transcript.lastStopReason == .cancelled)
    }

    /// A `session/load` replay must end in the same state as the session did live.
    @Test func replayEqualsLive() throws {
        let recorded: [SessionUpdate] = try [
            UpdateSamples.userChunk, UpdateSamples.thoughtChunk, UpdateSamples.agentChunk,
            #"{"sessionUpdate":"agent_message_chunk","messageId":"msg_1","content":{"type":"text","text":"the code."}}"#,
            UpdateSamples.toolCall, UpdateSamples.plan, UpdateSamples.toolCallUpdate,
            #"{"sessionUpdate":"agent_message_chunk","messageId":"msg_2","content":{"type":"text","text":"Fixed."}}"#,
            UpdateSamples.usage, UpdateSamples.unknown, UpdateSamples.sessionInfo,
        ].map { try decode(SessionUpdate.self, $0) }

        var live = ChatTranscript()
        live.appendUserPrompt([.text("Fix the bug")])
        recorded.forEach { live.apply($0) }
        live.endTurn(.endTurn)

        var replay = ChatTranscript()
        replay.beginReplay()
        recorded.forEach { replay.apply($0) }
        replay.endReplay()
        replay.endTurn(.endTurn)

        #expect(replay == live)
        #expect(live.items.map(\.id) == ["message-0", "message-1", "message-2", "tool:toolu_01", "message-3"])
        #expect(live.lastAgentText == "Fixed.")
        #expect(live.title == "Fix login bug")
    }

    @Test func lastAgentTextIgnoresLaterThoughtsAndTools() {
        let transcript = folded([agent("answer"), thought("hmm"), .toolCall(ToolCall(toolCallId: "t", title: ""))])
        #expect(transcript.lastAgentText == "answer")
        #expect(ChatTranscript().lastAgentText == nil)
    }

    @Test func longStreamStaysFast() {
        var transcript = ChatTranscript()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for index in 0..<40000 {
                transcript.apply(agent("chunk \(index) "))
            }
        }
        #expect(transcript.items.count == 1)
        #expect(transcript.lastAgentText?.hasSuffix("chunk 39999 ") == true)
        // Quadratic copying would take far longer; this only guards against that, not a benchmark.
        #expect(elapsed < .seconds(5))
    }
}
