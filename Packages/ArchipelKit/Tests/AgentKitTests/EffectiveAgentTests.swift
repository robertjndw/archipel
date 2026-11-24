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

    @Test(arguments: [AgentKind.claude, .codex])
    func onlyShellsTakeTheDetectedAgent(persisted: AgentKind) {
        let agent = EffectiveAgent.resolve(persisted: persisted, runtime: detected)
        #expect(agent.kind == persisted)
        #expect(!agent.isDetected)
        #expect(agent.reportsLifecycleThroughHooks == persisted.adapter.capabilities.reportsLifecycleThroughHooks)
    }
}
