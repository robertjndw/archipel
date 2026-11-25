@testable import AgentKit
import ArchipelCore
import Foundation
import Testing

/// The app reads the transcript to notice an interrupted turn, so it has to know where the
/// transcript is from the first turn on, before there is a context window to report.
struct ClaudeTranscriptPathTests {
    private func decode(_ source: String, _ json: String) throws -> DecodedHook? {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return HookDecoder.decode(source: source, payload: object)
    }

    @Test func aStatusLineBeforeTheFirstReplyAlreadyNamesTheTranscript() throws {
        // No limits yet, and a context window without a reading.
        let json = #"{"session_id":"abc","transcript_path":"/tmp/t.jsonl","context_window":{"context_window_size":200000,"total_input_tokens":0,"current_usage":null}}"#
        let decoded = try #require(try decode(ClaudeAdapter.statusLineSource, json))
        #expect(decoded.context == nil)
        #expect(decoded.usage == nil)
        #expect(decoded.event == nil)
        #expect(decoded.transcriptPath == "/tmp/t.jsonl")
    }

    @Test func aStatusLineWithNothingToTellIsStillDropped() throws {
        #expect(try decode(ClaudeAdapter.statusLineSource, #"{"session_id":"abc","transcript_path":""}"#) == nil)
        #expect(try decode(ClaudeAdapter.statusLineSource, #"{"session_id":"abc"}"#) == nil)
    }

    @Test func theMainAgentsHooksNameItToo() throws {
        let json = #"{"session_id":"4f0c2a8e-9a51-4d3b-8c11-2b3f6f1e7a90","transcript_path":"/tmp/t.jsonl","hook_event_name":"UserPromptSubmit"}"#
        #expect(try decode("claude", json)?.transcriptPath == "/tmp/t.jsonl")
    }

    @Test func aSubagentsHookIsNotTakenAtItsWord() throws {
        let json = #"{"session_id":"4f0c2a8e-9a51-4d3b-8c11-2b3f6f1e7a90","transcript_path":"/tmp/side.jsonl","agent_id":"a1","hook_event_name":"PreToolUse"}"#
        let decoded = try #require(try decode("claude", json))
        #expect(decoded.event == .subagentActivity(id: "a1"))
        #expect(decoded.transcriptPath == nil)
    }

    @Test func theEnvelopeCarriesItToTheApp() throws {
        let session = UUID()
        let line = Data(#"{"session": "\#(session.uuidString)", "source": "claude-statusline", "payload": {"session_id": "abc", "transcript_path": "/tmp/t.jsonl"}}"#.utf8)
        let message = try #require(HookServer.decodeEnvelope(line))
        #expect(message.transcriptPath == "/tmp/t.jsonl")
        #expect(message.context == nil)
    }
}

/// Whether a permission request's banner may offer to answer it, as the adapters report it.
struct PartialRequestTests {
    private func event(_ source: String, _ payload: [String: Any]) -> AgentEvent? {
        HookDecoder.decode(source: source, payload: payload)?.event
    }

    private func request(tool: Any?, input: [String: Any]) -> [String: Any] {
        var payload: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "4f0c2a8e-9a51-4d3b-8c11-2b3f6f1e7a90", "tool_input": input]
        payload["tool_name"] = tool
        return payload
    }

    @Test(arguments: ["claude", CodexAdapter.hooksSource])
    func aRequestShownWholeIsNotPartial(source: String) {
        #expect(event(source, request(tool: "Bash", input: ["command": "rm x"]))
            == .attentionRequested(.permission, message: "Bash: rm x", subagent: nil, isPartial: false))
    }

    @Test(arguments: ["claude", CodexAdapter.hooksSource])
    func aRequestThatHidesSomethingIsPartial(source: String) {
        let long = "ls " + String(repeating: "a", count: 300)
        let hidden = "ls" + String(repeating: "\u{3164}", count: 200) + "; rm -rf ~"
        for command in [long, hidden] {
            guard case .attentionRequested(.permission, _, nil, let isPartial)? = event(source, request(tool: "Bash", input: ["command": command])) else {
                Issue.record("Expected a permission request")
                continue
            }
            #expect(isPartial)
        }
        // Nothing at all is known about a request without a tool name.
        #expect(event(source, request(tool: nil, input: ["command": "ls"]))
            == .attentionRequested(.permission, message: nil, subagent: nil, isPartial: true))
    }
}
