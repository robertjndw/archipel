import AgentKit
import Foundation
import Testing

struct ShellAdapterTests {
    let shell = ShellAdapter()

    @Test func launch() {
        let command = shell.launchCommand(for: LaunchFixture.context(agentSessionID: nil))
        #expect(command.executable.hasPrefix("/"))
        #expect(command.arguments == ["-l"])
        LaunchFixture.expectHookEnvironment(command)
        #expect(shell.resumeCommand(for: LaunchFixture.context(agentSessionID: "x")) == nil)
    }

    @Test func isLookedUpByItsFullPath() {
        #expect(shell.executableToLocate == ShellAdapter.loginShellPath)
        #expect(shell.executableName == (ShellAdapter.loginShellPath as NSString).lastPathComponent)
        #expect(ClaudeAdapter().executableToLocate == "claude")
    }

    @Test func capabilities() {
        let capabilities = shell.capabilities
        #expect(capabilities.sessionID == .none)
        #expect(capabilities.lifecycle == .terminal)
        #expect(!capabilities.acceptsPrompts)
        #expect(capabilities.usage == nil)
        #expect(shell.hookSources.isEmpty)
        #expect(shell.attentionReason(forTerminalNotification: "done") == .question)
    }
}
