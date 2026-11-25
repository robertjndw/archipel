import AgentKit
import ArchipelCore
import Testing

struct EffectiveAgentTests {
    let detected = RuntimeAgent(kind: .claude, process: ProcessIdentity(pid: 1234, startTime: 1))

    @Test func aPlainShellIsAShell() {
        let agent = EffectiveAgent.resolve(persisted: .shell, runtime: nil)
        #expect(agent == EffectiveAgent(kind: .shell, acceptsPrompts: false, reportsLifecycleThroughHooks: false, isDetected: false))
    }

    @Test func claudeInAShellWithoutHooks() {
        let agent = EffectiveAgent.resolve(persisted: .shell, runtime: detected)
        #expect(agent == EffectiveAgent(kind: .claude, acceptsPrompts: true, reportsLifecycleThroughHooks: false, isDetected: true))
        #expect(agent.adapter.symbolName == ClaudeAdapter().symbolName)
    }

    @Test func claudeInAShellWithHooks() {
        var hooked = detected
        hooked.reportsThroughHooks = true
        let agent = EffectiveAgent.resolve(persisted: .shell, runtime: hooked)
        #expect(agent.reportsLifecycleThroughHooks)
        #expect(agent.isDetected)
    }

    @Test func aCodexChatReportsPreciselyFromTheStart() {
        // The terminal Codex only does once its hooks have been seen.
        #expect(!EffectiveAgent.resolve(persisted: .codex, runtime: nil).reportsLifecycleThroughHooks)
        let chat = EffectiveAgent.resolve(persisted: .codex, runtime: nil, hooksSeen: false, interface: .acp)
        #expect(chat == EffectiveAgent(kind: .codex, acceptsPrompts: true, reportsLifecycleThroughHooks: true, isDetected: false))
    }

    @Test func aChatIgnoresAnAgentFoundInTheTerminal() {
        let chat = EffectiveAgent.resolve(persisted: .shell, runtime: detected, interface: .acp)
        #expect(chat.kind == .shell)
        #expect(!chat.isDetected)
    }

    @Test func theTerminalInterfaceChangesNothing() {
        #expect(EffectiveAgent.resolve(persisted: .shell, runtime: detected, interface: .terminal)
            == EffectiveAgent.resolve(persisted: .shell, runtime: detected))
    }

    @Test(arguments: [AgentKind.claude, .codex])
    func onlyShellsTakeTheDetectedAgent(persisted: AgentKind) {
        let agent = EffectiveAgent.resolve(persisted: persisted, runtime: detected)
        #expect(agent.kind == persisted)
        #expect(!agent.isDetected)
        #expect(agent.reportsLifecycleThroughHooks == persisted.adapter.capabilities.reportsLifecycleThroughHooks)
    }
}
