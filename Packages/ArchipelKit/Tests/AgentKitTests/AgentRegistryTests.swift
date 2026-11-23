import AgentKit
import ArchipelCore
import Foundation
import Testing

struct AgentRegistryTests {
    let registry = AgentRegistry.builtIn

    @Test func builtIns() {
        #expect(registry.adapters.map(\.id) == ["claude", "codex", "opencode", "shell"])
        #expect(registry.adapter(id: "codex")?.executableName == "codex")
        #expect(registry.adapter(id: "nope") == nil)
    }

    @Test func unknownKindsRunAsAShell() {
        #expect(AgentKind.claude.adapter.id == "claude")
        #expect(AgentKind.codex.adapter.id == "codex")
        #expect(AgentKind(rawValue: "gone").adapter.id == "shell")
    }

    @Test(arguments: [("claude", "claude"), ("claude-statusline", "claude"), ("codex", "codex")])
    func routesHookSources(source: String, adapterID: String) {
        #expect(registry.adapter(forHookSource: source)?.id == adapterID)
    }

    @Test func unclaimedSourcesHaveNoAdapter() {
        #expect(registry.adapter(forHookSource: "gemini") == nil)
        #expect(registry.adapter(forHookSource: "shell") == nil)
        #expect(registry.adapter(forHookSource: "") == nil)
    }

    @Test func usageProviders() {
        #expect(registry.adapter(forUsage: .claude)?.id == "claude")
        #expect(registry.adapter(forUsage: .codex)?.id == "codex")
    }
}

struct LaunchCommandTests {
    @Test func shellCommandLineQuoting() {
        let command = LaunchCommand(
            executable: "/Applications/My App.app/bin/tool",
            arguments: ["--flag", "it's", "", "plain-value_1.0", #"{"a": "$HOME"}"#],
            environment: [:]
        )
        #expect(command.shellCommandLine
            == #"'/Applications/My App.app/bin/tool' --flag 'it'\''s' '' plain-value_1.0 '{"a": "$HOME"}'"#)
    }
}
