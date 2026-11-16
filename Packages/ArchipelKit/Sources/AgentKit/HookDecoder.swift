import ArchipelCore
import Foundation

public enum HookSource: String, Sendable {
    case claude
    case codex
}

/// Maps raw hook payloads to `AgentEvent`s. Field names follow the Claude Code hooks reference
/// and the Codex `notify` documentation; anything unrecognised maps to nil rather than failing.
public enum HookDecoder {
    public static func decode(
        source: HookSource,
        payload: [String: Any]
    ) -> (event: AgentEvent?, agentSessionID: String?) {
        switch source {
        case .claude:
            return (claudeEvent(payload), nonEmptyString(payload["session_id"]))
        case .codex:
            return (codexEvent(payload), nonEmptyString(payload["thread-id"]))
        }
    }

    public static func decode(
        source: HookSource,
        payload: Data
    ) -> (event: AgentEvent?, agentSessionID: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return (nil, nil)
        }
        return decode(source: source, payload: object)
    }

    private static func claudeEvent(_ payload: [String: Any]) -> AgentEvent? {
        // Hooks fired inside a subagent carry its id. They must not be read as the main agent's:
        // a subagent's StopFailure would otherwise end the parent's turn.
        if let agentID = nonEmptyString(payload["agent_id"]) {
            switch payload["hook_event_name"] as? String {
            case "SubagentStart": return .subagentStarted(id: agentID)
            case "SubagentStop", "StopFailure", "Stop": return .subagentFinished(id: agentID)
            case "PreToolUse", "PostToolUse": return .subagentActivity(id: agentID)
            default: break
            }
        }
        switch payload["hook_event_name"] as? String {
        case "SessionStart":
            return .sessionStarted
        case "UserPromptSubmit":
            return .promptSubmitted
        case "PreToolUse", "PostToolUse":
            return .activity
        case "PermissionRequest":
            return .attentionRequested(.permission, message: nonEmptyString(payload["tool_name"]))
        case "Notification":
            let message = nonEmptyString(payload["message"])
            switch payload["notification_type"] as? String {
            case "permission_prompt":
                return .attentionRequested(.permission, message: message)
            case "idle_prompt":
                // Claude sends this about a minute after any turn ends, when nobody has typed. It
                // carries nothing new: the turn is already finished, and real questions arrive as a
                // permission request or an elicitation. Treating it as attention turned every
                // finished turn into "waiting for you".
                return nil
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                return .attentionRequested(.question, message: message)
            default:
                return nil
            }
        case "Stop", "StopFailure":
            return .turnFinished(message: nonEmptyString(payload["last_assistant_message"]))
        default:
            // SessionEnd included: the terminal reports the process exit with its real code.
            return nil
        }
    }

    private static func codexEvent(_ payload: [String: Any]) -> AgentEvent? {
        switch payload["type"] as? String {
        case "agent-turn-complete":
            return .turnFinished(message: nonEmptyString(payload["last-assistant-message"]))
        default:
            return nil
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
