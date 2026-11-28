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

func payload(_ json: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

struct ClaudeHookDecodingTests {
    private func claude(_ json: String) throws -> DecodedHook {
        try #require(ClaudeAdapter().decodeHook(source: "claude", payload: payload(json), receivedAt: .now))
    }

    @Test(arguments: [
        (Fixtures.sessionStart, AgentEvent.sessionStarted),
        (Fixtures.userPromptSubmit, .promptSubmitted),
        (Fixtures.preToolUse, .activity),
        (Fixtures.postToolUse, .activity),
        (Fixtures.permissionRequest, .attentionRequested(.permission, message: "Bash: rm -rf node_modules")),
        (Fixtures.notification("permission_prompt"), .attentionReminder(.permission, message: "Claude needs your permission")),
        (Fixtures.notification("elicitation_dialog"), .attentionRequested(.question, message: "Claude needs your permission")),
        (Fixtures.notification("elicitation_url_dialog"), .attentionRequested(.question, message: "Claude needs your permission")),
        (Fixtures.notification("agent_needs_input"), .attentionRequested(.question, message: "Claude needs your permission")),
        (Fixtures.stop, .turnFinished(message: "I've completed the refactoring.", backgroundTasks: 0, subagents: [])),
        (Fixtures.stopFailure, .turnFinished(message: "API Error: Rate limit reached")),
    ])
    func claudeEvents(json: String, expected: AgentEvent) throws {
        let result = try claude(json)
        #expect(result.event == expected)
        #expect(result.agentSessionID == Fixtures.claudeSessionID)
    }

    @Test(arguments: [
        Fixtures.sessionEnd,
        Fixtures.notification("idle_prompt"),
        Fixtures.notification("auth_success"),
        Fixtures.notification("elicitation_complete"),
        #"{"session_id": "\#(Fixtures.claudeSessionID)", "hook_event_name": "SomethingNew"}"#,
        // Compacting restarts nothing, so the subagents of the running turn stay listed.
        #"{\#(Fixtures.common), "hook_event_name": "SessionStart", "source": "compact"}"#,
    ])
    func claudeEventsWithoutStatusMeaning(json: String) throws {
        let result = try claude(json)
        #expect(result.event == nil)
        #expect(result.agentSessionID != nil)
    }

    @Test func stopWithoutMessage() throws {
        let result = try claude(#"{"session_id": "abc", "hook_event_name": "Stop"}"#)
        #expect(result.event == .turnFinished(message: nil))
    }

    @Test func stopTellsSubagentsFromOtherBackgroundTasks() throws {
        let result = try claude(#"""
        {"session_id": "abc", "hook_event_name": "Stop", "background_tasks": [
            {"id": "b1", "type": "shell", "status": "running", "description": "build", "command": "make"},
            {"id": "m1", "type": "monitor", "status": "running", "description": "ci"},
            {"id": "a1", "type": "subagent", "status": "running", "description": "explore", "agent_type": "Explore"}
        ]}
        """#)
        #expect(result.event == .turnFinished(message: nil, backgroundTasks: 2, subagents: ["a1"]))
    }

    @Test(arguments: [
        (#"{"session_id": "abc", "hook_event_name": "SubagentStart", "agent_id": "a1", "agent_type": "Explore"}"#, AgentEvent.subagentStarted(id: "a1")),
        (#"{"session_id": "abc", "hook_event_name": "SubagentStop", "agent_id": "a1", "agent_type": "Explore"}"#, .subagentFinished(id: "a1")),
        (#"{"session_id": "abc", "hook_event_name": "PreToolUse", "agent_id": "a1", "tool_name": "Read"}"#, .subagentActivity(id: "a1")),
        // A failing subagent must not end its parent's turn.
        (#"{"session_id": "abc", "hook_event_name": "StopFailure", "agent_id": "a1", "error": "rate_limit"}"#, .subagentFinished(id: "a1")),
        // A subagent asking for approval still needs the user.
        (#"{"session_id": "abc", "hook_event_name": "PermissionRequest", "agent_id": "a1", "tool_name": "Bash"}"#, .attentionRequested(.permission, message: "Bash", subagent: "a1")),
    ])
    func subagentEvents(json: String, expected: AgentEvent) throws {
        #expect(try claude(json).event == expected)
    }

    @Test(arguments: [
        (Fixtures.sessionStart, HookLifecycle?.some(.started(source: "startup"))),
        (Fixtures.sessionEnd, .ended(reason: "prompt_input_exit")),
        (#"{"session_id": "abc", "hook_event_name": "SessionStart"}"#, .started(source: nil)),
        (#"{"session_id": "abc", "hook_event_name": "SessionEnd", "reason": ""}"#, .ended(reason: nil)),
        (Fixtures.stop, nil),
        (Fixtures.preToolUse, nil),
    ])
    func claudeLifecycle(json: String, expected: HookLifecycle?) throws {
        #expect(try claude(json).lifecycle == expected)
    }
}
