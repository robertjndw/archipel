import AgentKit
import ArchipelCore
import Testing

struct SessionInterfaceChoiceTests {
    @Test func aChatRunsAsAChatWhenNothingGetsInTheWay() {
        for agent in [AgentKind.claude, .codex, .opencode] {
            #expect(Session(title: "s", agent: agent, interface: .acp).effectiveInterface == .acp)
        }
    }

    @Test func aTerminalSessionStaysATerminal() {
        #expect(Session(title: "s", agent: .claude).effectiveInterface == .terminal)
    }

    @Test func aShellHasNoChat() {
        #expect(Session(title: "s", agent: .shell, interface: .acp).effectiveInterface == .terminal)
    }

    @Test func aPresetKeepsTheSessionInTheTerminal() {
        #expect(Session(title: "s", agent: .claude, arguments: "--model opus", interface: .acp).effectiveInterface == .terminal)
    }

    @Test func aScriptTabIsATerminal() {
        #expect(Session(title: "s", agent: .claude, script: .run, interface: .acp).effectiveInterface == .terminal)
    }

    @Test func aNewSessionFollowsThePreference() {
        let claude = ClaudeAdapter()
        #expect(SessionInterface.forNewSession(of: claude, preferred: .acp, usesPreset: false) == .acp)
        #expect(SessionInterface.forNewSession(of: claude, preferred: .terminal, usesPreset: false) == .terminal)
    }

    @Test func aNewSessionWithAPresetIsATerminal() {
        #expect(SessionInterface.forNewSession(of: ClaudeAdapter(), preferred: .acp, usesPreset: true) == .terminal)
    }

    @Test func aNewShellIsATerminal() {
        #expect(SessionInterface.forNewSession(of: ShellAdapter(), preferred: .acp, usesPreset: false) == .terminal)
    }
}
