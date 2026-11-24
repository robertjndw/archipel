import AgentKit
import ArchipelCore
import Foundation
import Testing

struct CodexHookDecodingTests {
    private func decode(_ json: String) throws -> DecodedHook {
        try #require(CodexAdapter().decodeHook(source: "codex", payload: payload(json), receivedAt: .now))
    }

    @Test func codexTurnComplete() throws {
        let result = try decode(Fixtures.codexTurnComplete)
        #expect(result.event == .turnFinished(message: "Rename complete."))
        #expect(result.agentSessionID == "0199a213-81c0-7800-8aa1-bbab2a035a53")
    }

    @Test func codexUnknownType() throws {
        let result = try decode(#"{"type": "approval-requested", "thread-id": "\#(thread)"}"#)
        #expect(result.event == nil)
        #expect(result.agentSessionID == thread)
    }

    @Test func lifecycleIsClaudesOnly() throws {
        #expect(try decode(Fixtures.sessionStart).lifecycle == nil)
    }

    private func decodeHooks(_ json: String) throws -> DecodedHook {
        try #require(CodexAdapter().decodeHook(source: "codex-hooks", payload: payload(json), receivedAt: .now))
    }

    private let thread = "0199a213-81c0-7800-8aa1-bbab2a035a53"
    private let common = #""session_id": "0199a213-81c0-7800-8aa1-bbab2a035a53", "transcript_path": "/t.jsonl", "cwd": "/w", "model": "gpt-5", "permission_mode": "default""#

    @Test func sessionStart() throws {
        let result = try decodeHooks(#"{\#(common), "hook_event_name": "SessionStart", "source": "startup"}"#)
        #expect(result.event == .sessionStarted)
        #expect(result.agentSessionID == thread)
        #expect(result.lifecycle == nil)
    }

    @Test func userPromptSubmit() throws {
        let result = try decodeHooks(#"{\#(common), "hook_event_name": "UserPromptSubmit", "turn_id": "t1", "prompt": "hi"}"#)
        #expect(result.event == .promptSubmitted)
    }

    @Test func toolUseIsActivity() throws {
        for name in ["PreToolUse", "PostToolUse"] {
            let result = try decodeHooks(#"{\#(common), "hook_event_name": "\#(name)", "turn_id": "t1", "tool_name": "Bash", "tool_input": {"command": "ls"}, "tool_use_id": "u1"}"#)
            #expect(result.event == .activity)
        }
    }

    @Test func permissionRequestNamesTheTool() throws {
        let result = try decodeHooks(#"{\#(common), "hook_event_name": "PermissionRequest", "turn_id": "t1", "tool_name": "Bash", "tool_input": {"command": "rm x", "description": "d"}}"#)
        #expect(result.event == .attentionRequested(.permission, message: "Bash: rm x"))

        // A subagent's request says which one asked, and Codex passes a command as its argv.
        let nested = try decodeHooks(#"{\#(common), "hook_event_name": "PermissionRequest", "agent_id": "a1", "tool_name": "shell", "tool_input": {"command": ["git", "push"]}}"#)
        #expect(nested.event == .attentionRequested(.permission, message: "shell: git push", subagent: "a1"))
    }

    @Test func stopFinishesTheTurn() throws {
        let result = try decodeHooks(#"{\#(common), "hook_event_name": "Stop", "turn_id": "t1", "stop_hook_active": false, "last_assistant_message": "Done."}"#)
        #expect(result.event == .turnFinished(message: "Done."))
    }

    @Test func subagentsAreTrackedById() throws {
        let start = try decodeHooks(#"{\#(common), "hook_event_name": "SubagentStart", "turn_id": "t1", "agent_id": "a1", "agent_type": "explorer"}"#)
        #expect(start.event == .subagentStarted(id: "a1"))
        let stop = try decodeHooks(#"{\#(common), "hook_event_name": "SubagentStop", "turn_id": "t1", "agent_id": "a1", "agent_transcript_path": "/a", "last_assistant_message": "x"}"#)
        #expect(stop.event == .subagentFinished(id: "a1"))
        let anonymous = try decodeHooks(#"{\#(common), "hook_event_name": "SubagentStart"}"#)
        #expect(anonymous.event == nil)
    }

    @Test func sessionEndCarriesNoEventButKeepsTheSession() throws {
        let result = try decodeHooks(#"{\#(common), "hook_event_name": "SessionEnd", "reason": "exit"}"#)
        #expect(result.event == nil)
        #expect(result.agentSessionID == thread)
    }

    @Test func routesBySource() {
        let data = Data(#"{"session_id": "s", "hook_event_name": "Stop"}"#.utf8)
        #expect(HookDecoder.decode(source: "codex-hooks", payload: data)?.event == .turnFinished(message: nil))
        #expect(HookDecoder.decode(source: "codex", payload: data)?.event == nil)
    }
}
