import AgentKit
import ArchipelCore
import Foundation
import Testing

/// A conversation id comes from the hook socket and ends up on the agent's command line, so one
/// that could be read as an option has to be turned away at both ends.
struct AgentSessionIDTests {
    static let uuid = "0199a213-81c0-7800-8aa1-bbab2a035a53"
    static let hostile = [
        "--dangerously-skip-permissions", "-p", "--", "", " ", "--resume=x", "a b", "a;b", "$(id)", "a\nb", "../x", "é",
    ]

    @Test func uuids() {
        #expect(AgentSessionID.isUUID(Self.uuid))
        #expect(AgentSessionID.isUUID(Self.uuid.uppercased()))
        for id in Self.hostile + ["0199a213-81c0-7800-8aa1-bbab2a035a5", "0199a21381c078008aa1bbab2a035a53", "-199a213-81c0-7800-8aa1-bbab2a035a53", "0199a213-81c0-7800-8aa1-bbab2a035a5g", "0199a213;81c0 7800$8aa1)bbab2a035a53"] {
            #expect(!AgentSessionID.isUUID(id), "\(id)")
        }
    }

    @Test func plainWords() {
        for id in ["abc", "ses_4f2a", "thread-1", "A1_b-2"] {
            #expect(AgentSessionID.isPlainWord(id), "\(id)")
        }
        for id in Self.hostile + ["_x", String(repeating: "a", count: 129)] {
            #expect(!AgentSessionID.isPlainWord(id), "\(id)")
        }
    }

    @Test func eachAgentAcceptsItsOwnShape() {
        #expect(ClaudeAdapter().acceptsSessionID(Self.uuid))
        #expect(ClaudeAdapter().acceptsSessionID(ClaudeAdapter().makePresetSessionID()))
        #expect(!ClaudeAdapter().acceptsSessionID("ses_4f2a"))
        #expect(CodexAdapter().acceptsSessionID(Self.uuid))
        #expect(!CodexAdapter().acceptsSessionID("thread"))
        #expect(OpenCodeAdapter().acceptsSessionID(OpenCodeAdapter().makePresetSessionID()))
        #expect(OpenCodeAdapter().acceptsSessionID("ses_4f2a9c01b7deXyZ0123456789AbC"))
        for id in ["ses_", "ses", "ses_a-b", "ses_a_b", Self.uuid, "ses_" + String(repeating: "a", count: 61), "abcd4f2a9c01", "sesX4f2a"] {
            #expect(!OpenCodeAdapter().acceptsSessionID(id), "\(id)")
        }
    }

    @Test(arguments: hostile)
    func hooksCannotReportAnOptionAsTheConversation(id: String) throws {
        let claude = try #require(ClaudeAdapter().decodeHook(
            source: "claude", payload: ["hook_event_name": "Stop", "session_id": id], receivedAt: .now
        ))
        // The event still counts. Only the id is not kept.
        #expect(claude.event == .turnFinished(message: nil))
        #expect(claude.agentSessionID == nil)

        let notify = try #require(CodexAdapter().decodeHook(
            source: "codex", payload: ["type": "agent-turn-complete", "thread-id": id], receivedAt: .now
        ))
        #expect(notify.agentSessionID == nil)
        let hooks = try #require(CodexAdapter().decodeHook(
            source: "codex-hooks", payload: ["hook_event_name": "Stop", "session_id": id], receivedAt: .now
        ))
        #expect(hooks.agentSessionID == nil)

        let opencode = try #require(OpenCodeAdapter().decodeHook(
            source: "opencode", payload: ["event": "idle", "opencodeSessionID": id], receivedAt: .now
        ))
        #expect(opencode.agentSessionID == nil)
    }

    /// An id saved by an earlier version sits in the workspace file unchecked.
    @Test(arguments: hostile)
    func aSavedOptionNeverReachesTheCommandLine(id: String) {
        let context = LaunchFixture.context(agentSessionID: id)
        let adapters: [any AgentAdapter] = [ClaudeAdapter(), CodexAdapter(), OpenCodeAdapter(), ShellAdapter()]
        for adapter in adapters {
            #expect(adapter.resumeCommand(for: context) == nil, "\(adapter.id)")
            #expect(adapter.resumeCommand(for: context, agentSessionID: id) == nil, "\(adapter.id)")
        }
        // A fresh start then goes without an id, and the agent picks its own.
        #expect(ClaudeAdapter().launchCommand(for: context).arguments.first == "--settings")
        #expect(OpenCodeAdapter().launchCommand(for: context).arguments.isEmpty)
    }

    /// An adapter added later might build its resume command without checking the id itself.
    /// The protocol's own entry point has to turn a saved option away regardless.
    @Test(arguments: hostile)
    func theSharedResumeEntryPointChecksTheIDForEveryAdapter(id: String) {
        #expect(UncheckedResumeAdapter().resumeCommand(for: LaunchFixture.context(agentSessionID: id)) == nil)
        #expect(UncheckedResumeAdapter().resumeCommand(for: LaunchFixture.context(agentSessionID: "thread-1")) != nil)
    }

    @Test func idsAreAttachedToTheirOption() throws {
        let claude = try #require(ClaudeAdapter().resumeCommand(for: LaunchFixture.context(agentSessionID: Self.uuid)))
        #expect(claude.arguments.first == "--resume=\(Self.uuid)")
        let opencode = try #require(OpenCodeAdapter().resumeCommand(for: LaunchFixture.context(agentSessionID: "ses_4f2a")))
        #expect(opencode.arguments == ["--session=ses_4f2a"])
    }
}

/// Resumes with whatever id it is handed and relies on the protocol's default id rule.
private struct UncheckedResumeAdapter: AgentAdapter {
    let id = "unchecked"
    let displayName = "Unchecked"
    let symbolName = "terminal"
    let executableName = "unchecked"
    let hookSources: Set<String> = []
    var capabilities: AgentCapabilities {
        AgentCapabilities(
            sessionID: .none,
            lifecycle: .terminal,
            acceptsPrompts: false,
            answersApprovalsInTerminal: false,
            usage: nil,
            tracksSubagents: false,
            presetPlaceholder: "",
            settingsSections: []
        )
    }

    func launchCommand(for context: LaunchContext) -> LaunchCommand {
        LaunchCommand(executable: executableName, arguments: [], environment: [:])
    }

    func resumeCommand(for context: LaunchContext, agentSessionID: String) -> LaunchCommand? {
        LaunchCommand(executable: executableName, arguments: ["--resume", agentSessionID], environment: [:])
    }

    func attentionReason(forTerminalNotification body: String) -> AttentionReason? { nil }
}
