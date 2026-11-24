import AgentKit
import ArchipelCore
import Foundation
import Testing

struct OpenCodeAdapterTests {
    let opencode = OpenCodeAdapter()
    let pluginDirectory = URL(fileURLWithPath: "/Users/me/Library/Application Support/Archipel/opencode-plugin")

    func context(
        agentSessionID: String? = "ses_abc",
        userPlugins: [String]? = [],
        directory: URL? = URL(fileURLWithPath: "/Users/me/Library/Application Support/Archipel/opencode-plugin")
    ) -> LaunchContext {
        var context = LaunchFixture.context(agentSessionID: agentSessionID)
        context.opencodePluginDirectory = directory
        context.opencodeUserPlugins = userPlugins
        return context
    }

    @Test func freshAndResumeUseTheSessionFlag() throws {
        let fresh = opencode.launchCommand(for: context(agentSessionID: "ses_abc"))
        #expect(fresh.executable == "opencode")
        #expect(fresh.arguments == ["--session=ses_abc"])
        LaunchFixture.expectHookEnvironment(fresh)
        #expect(fresh.environment["ARCHIPEL_HOOK_BIN"] == LaunchFixture.hook.path)

        let resumed = try #require(opencode.resumeCommand(for: context(agentSessionID: "ses_old")))
        #expect(resumed.arguments == ["--session=ses_old"])
    }

    @Test func presetIDsAreAcceptedByOpenCode() {
        let first = opencode.makePresetSessionID()
        #expect(first.hasPrefix("ses_"))
        #expect(first.count == 32)
        #expect(first.dropFirst(4).allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(first != opencode.makePresetSessionID())
    }

    @Test func injectedConfigKeepsTheUsersPluginsFirst() throws {
        let command = opencode.launchCommand(for: context(userPlugins: [#""@scope/theirs""#, #"["local",{"a":1}]"#]))
        let json = try #require(command.environment["OPENCODE_CLI_CONFIG_CONTENT"])
        let plugins = try #require((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["plugins"] as? [Any])
        #expect(plugins.count == 3)
        #expect(plugins[0] as? String == "@scope/theirs")
        #expect((plugins[1] as? [Any])?.first as? String == "local")
        #expect(plugins[2] as? String == pluginDirectory.path)
    }

    @Test func nothingIsInjectedWithoutASafeBase() {
        #expect(opencode.launchCommand(for: context(userPlugins: nil)).environment["OPENCODE_CLI_CONFIG_CONTENT"] == nil)
        #expect(opencode.launchCommand(for: context(directory: nil)).environment["OPENCODE_CLI_CONFIG_CONTENT"] == nil)
    }

    @Test func capabilities() {
        let capabilities = opencode.capabilities
        #expect(capabilities.sessionID == .presetByApp)
        #expect(capabilities.lifecycle == .hooksOnceSeen)
        #expect(!capabilities.answersApprovalsInTerminal)
        #expect(capabilities.usage == nil)
        #expect(capabilities.settingsSections == [.openCodeIntegration])
        #expect(AgentRegistry.builtIn.adapter(forHookSource: "opencode")?.id == "opencode")
    }

    // MARK: cli.json

    @Test func readsPluginsFromJSONWithCommentsAndTrailingCommas() throws {
        let text = """
        {
          // where "plugins" live
          "theme": "https://example.com/a//b",
          "plugins": [
            "one", /* inline */
            ["two", {"k": "v"}],
          ],
        }
        """
        let plugins = try #require(OpenCodeCLIConfig.userPlugins(in: Data(text.utf8)))
        #expect(plugins == [#""one""#, #"["two",{"k":"v"}]"#])
    }

    @Test func missingPluginsMeansNone() {
        #expect(OpenCodeCLIConfig.userPlugins(in: Data(#"{"theme":"x"}"#.utf8)) == [])
        #expect(OpenCodeCLIConfig.userPlugins(in: Data("  \n".utf8)) == [])
    }

    @Test func unreadableConfigIsNotGuessedAt() {
        #expect(OpenCodeCLIConfig.userPlugins(in: Data("{ nope".utf8)) == nil)
        #expect(OpenCodeCLIConfig.userPlugins(in: Data(#"{"plugins":"x"}"#.utf8)) == nil)
        #expect(OpenCodeCLIConfig.userPlugins(in: Data("[1]".utf8)) == nil)
    }

    @Test func configLocationFollowsXDG() throws {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(OpenCodeCLIConfig.fileURL(environment: [:], homeDirectory: home).path == "/Users/me/.config/opencode/cli.json")
        #expect(OpenCodeCLIConfig.fileURL(environment: ["XDG_CONFIG_HOME": "/x"], homeDirectory: home).path == "/x/opencode/cli.json")

        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ["XDG_CONFIG_HOME": folder.path]
        #expect(OpenCodeCLIConfig.userPlugins(environment: environment, homeDirectory: home) == [])
        try FileManager.default.createDirectory(at: folder.appending(path: "opencode"), withIntermediateDirectories: true)
        try Data(#"{"plugins":["a"]}"#.utf8).write(to: folder.appending(path: "opencode/cli.json"))
        #expect(OpenCodeCLIConfig.userPlugins(environment: environment, homeDirectory: home) == [#""a""#])
    }

    // MARK: Hooks

    func decode(_ payload: [String: Any]) -> DecodedHook? {
        opencode.decodeHook(source: "opencode", payload: payload, receivedAt: Date())
    }

    @Test func decodesEveryEvent() {
        func event(_ name: String, _ extra: [String: Any] = [:]) -> AgentEvent? {
            decode(["event": name, "opencodeSessionID": "ses_1"].merging(extra) { $1 })?.event
        }
        #expect(event("started") == .sessionStarted)
        #expect(event("switched", ["running": true]) == .activity)
        #expect(event("switched", ["running": false]) == .sessionStarted)
        #expect(event("prompt") == .promptSubmitted)
        #expect(event("busy") == .activity)
        #expect(event("permission-replied") == .activity)
        #expect(event("idle") == .turnFinished(message: nil))
        #expect(event("error", ["message": "boom"]) == .turnFinished(message: "boom"))
        #expect(event("permission", ["action": "bash", "resources": ["ls", "pwd"]]) == .attentionRequested(.permission, message: "ls, pwd"))
        #expect(event("permission", ["action": "edit"]) == .attentionRequested(.permission, message: "edit"))
        #expect(event("question") == .attentionRequested(.question, message: nil))
        #expect(event("nonsense") == nil)
        #expect(decode(["event": "busy", "opencodeSessionID": "ses_1"])?.agentSessionID == "ses_1")
    }

    @Test func titleLosesItsPrefix() {
        #expect(opencode.conversationTitle(fromTerminalTitle: "OC | Fix the build") == "Fix the build")
        #expect(opencode.conversationTitle(fromTerminalTitle: "OpenCode") == nil)
        #expect(opencode.conversationTitle(fromTerminalTitle: "OC |  ") == nil)
        #expect(ClaudeAdapter().conversationTitle(fromTerminalTitle: "✳ Fix it") == "Fix it")
    }
}
