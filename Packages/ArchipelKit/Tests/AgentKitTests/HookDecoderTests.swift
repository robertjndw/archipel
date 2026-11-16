import AgentKit
import ArchipelCore
import Foundation
import Testing

/// Payloads shaped after the examples in the Claude Code hooks reference and the Codex
/// `notify` documentation.
enum Fixtures {
    static let common = #""session_id": "4f0c2a8e-9a51-4d3b-8c11-2b3f6f1e7a90", "transcript_path": "/Users/me/.claude/projects/x/4f0c.jsonl", "cwd": "/Users/me/project", "permission_mode": "default""#

    static let sessionStart = #"{\#(common), "hook_event_name": "SessionStart", "source": "startup", "model": "claude-opus-5"}"#
    static let userPromptSubmit = #"{\#(common), "hook_event_name": "UserPromptSubmit", "prompt": "Write a factorial function"}"#
    static let preToolUse = #"{\#(common), "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "npm test"}, "tool_use_id": "toolu_01ABC"}"#
    static let postToolUse = #"{\#(common), "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": "npm test"}, "tool_response": {}, "tool_use_id": "toolu_01ABC"}"#
    static let permissionRequest = #"{\#(common), "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": {"command": "rm -rf node_modules"}, "permission_suggestions": []}"#
    static func notification(_ type: String) -> String {
        #"{\#(common), "hook_event_name": "Notification", "message": "Claude needs your permission", "title": "Permission needed", "notification_type": "\#(type)"}"#
    }
    static let stop = #"{\#(common), "hook_event_name": "Stop", "stop_hook_active": false, "last_assistant_message": "I've completed the refactoring.", "background_tasks": [], "session_crons": []}"#
    static let stopFailure = #"{\#(common), "hook_event_name": "StopFailure", "error": "rate_limit", "last_assistant_message": "API Error: Rate limit reached"}"#
    static let sessionEnd = #"{\#(common), "hook_event_name": "SessionEnd", "reason": "prompt_input_exit"}"#
    static let codexTurnComplete = #"{"type": "agent-turn-complete", "thread-id": "0199a213-81c0-7800-8aa1-bbab2a035a53", "turn-id": "12", "cwd": "/Users/me/project", "input-messages": ["Rename foo to bar"], "last-assistant-message": "Rename complete."}"#

    static let claudeSessionID = "4f0c2a8e-9a51-4d3b-8c11-2b3f6f1e7a90"
}

struct HookDecoderTests {
    private func claude(_ json: String) -> (event: AgentEvent?, agentSessionID: String?) {
        HookDecoder.decode(source: .claude, payload: Data(json.utf8))
    }

    @Test(arguments: [
        (Fixtures.sessionStart, AgentEvent.sessionStarted),
        (Fixtures.userPromptSubmit, .promptSubmitted),
        (Fixtures.preToolUse, .activity),
        (Fixtures.postToolUse, .activity),
        (Fixtures.permissionRequest, .attentionRequested(.permission, message: "Bash")),
        (Fixtures.notification("permission_prompt"), .attentionRequested(.permission, message: "Claude needs your permission")),
        (Fixtures.notification("elicitation_dialog"), .attentionRequested(.question, message: "Claude needs your permission")),
        (Fixtures.notification("elicitation_url_dialog"), .attentionRequested(.question, message: "Claude needs your permission")),
        (Fixtures.notification("agent_needs_input"), .attentionRequested(.question, message: "Claude needs your permission")),
        (Fixtures.stop, .turnFinished(message: "I've completed the refactoring.")),
        (Fixtures.stopFailure, .turnFinished(message: "API Error: Rate limit reached")),
    ])
    func claudeEvents(json: String, expected: AgentEvent) {
        let result = claude(json)
        #expect(result.event == expected)
        #expect(result.agentSessionID == Fixtures.claudeSessionID)
    }

    @Test(arguments: [
        Fixtures.sessionEnd,
        Fixtures.notification("idle_prompt"),
        Fixtures.notification("auth_success"),
        Fixtures.notification("elicitation_complete"),
        #"{"session_id": "abc", "hook_event_name": "SomethingNew"}"#,
    ])
    func claudeEventsWithoutStatusMeaning(json: String) {
        let result = claude(json)
        #expect(result.event == nil)
        #expect(result.agentSessionID != nil)
    }

    @Test func stopWithoutMessage() {
        let result = claude(#"{"session_id": "abc", "hook_event_name": "Stop"}"#)
        #expect(result.event == .turnFinished(message: nil))
    }

    @Test(arguments: [
        (#"{"session_id": "abc", "hook_event_name": "SubagentStart", "agent_id": "a1", "agent_type": "Explore"}"#, AgentEvent.subagentStarted(id: "a1")),
        (#"{"session_id": "abc", "hook_event_name": "SubagentStop", "agent_id": "a1", "agent_type": "Explore"}"#, .subagentFinished(id: "a1")),
        (#"{"session_id": "abc", "hook_event_name": "PreToolUse", "agent_id": "a1", "tool_name": "Read"}"#, .subagentActivity(id: "a1")),
        // A failing subagent must not end its parent's turn.
        (#"{"session_id": "abc", "hook_event_name": "StopFailure", "agent_id": "a1", "error": "rate_limit"}"#, .subagentFinished(id: "a1")),
        // A subagent asking for approval still needs the user.
        (#"{"session_id": "abc", "hook_event_name": "PermissionRequest", "agent_id": "a1", "tool_name": "Bash"}"#, .attentionRequested(.permission, message: "Bash")),
    ])
    func subagentEvents(json: String, expected: AgentEvent) {
        #expect(claude(json).event == expected)
    }

    @Test func codexTurnComplete() {
        let result = HookDecoder.decode(source: .codex, payload: Data(Fixtures.codexTurnComplete.utf8))
        #expect(result.event == .turnFinished(message: "Rename complete."))
        #expect(result.agentSessionID == "0199a213-81c0-7800-8aa1-bbab2a035a53")
    }

    @Test func codexUnknownType() {
        let result = HookDecoder.decode(source: .codex, payload: Data(#"{"type": "approval-requested", "thread-id": "t"}"#.utf8))
        #expect(result.event == nil)
        #expect(result.agentSessionID == "t")
    }

    @Test(arguments: ["", "not json", "[1, 2]", "42", #"{"hook_event_name": 7, "session_id": 3}"#, "{"])
    func malformedInput(json: String) {
        for source in [HookSource.claude, .codex] {
            let result = HookDecoder.decode(source: source, payload: Data(json.utf8))
            #expect(result.event == nil)
            #expect(result.agentSessionID == nil)
        }
    }
}
