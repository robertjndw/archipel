import AgentKit
import Foundation
import Testing

struct LaunchPresetTests {
    @Test func defaultsAreClaudeModels() {
        #expect(LaunchPreset.defaults.allSatisfy { $0.agentID == ClaudeAdapter().id })
        #expect(LaunchPreset.defaults.map(\.name) == ["Fable", "Opus", "Sonnet", "Haiku"])
        #expect(LaunchPreset.defaults.first?.arguments == "--model fable")
        #expect(Set(LaunchPreset.defaults.map(\.id)).count == LaunchPreset.defaults.count)
    }

    @Test func defaultIdsStayTheSameAcrossLaunches() {
        #expect(LaunchPreset.defaults.first?.id.uuidString == "5A0F1C2E-3B4D-4E5F-8A6B-7C8D9E0F1A01")
    }

    @Test func blankNamesGetATitle() {
        #expect(LaunchPreset(agentID: "claude", name: "  ", arguments: "").title == "Untitled Preset")
        #expect(LaunchPreset(agentID: "claude", name: " Opus ", arguments: "").title == "Opus")
    }

    @Test func roundTrips() throws {
        let preset = LaunchPreset(agentID: "codex", name: "Plan", arguments: #"--model gpt-5 -c "x y""#)
        let decoded = try JSONDecoder().decode(LaunchPreset.self, from: JSONEncoder().encode(preset))
        #expect(decoded == preset)
    }

    @Test func migrationTurnsExtraArgumentsIntoADefaultPreset() {
        let codex = LaunchPreset(agentID: "codex", name: "Mini", arguments: "--model gpt-5-mini")
        let result = LaunchPreset.migrating(
            extraArguments: ["claude": "--model opus", "codex": "--model gpt-5"],
            into: LaunchPreset.defaults + [codex]
        )
        // Each new preset goes in front of that agent's own presets.
        #expect(result.presets.map(\.name) == ["Default", "Fable", "Opus", "Sonnet", "Haiku", "Default", "Mini"])
        #expect(result.presets[0].arguments == "--model opus")
        #expect(result.defaultIDs["claude"] == result.presets[0].id)
        #expect(result.defaultIDs["codex"] == result.presets[5].id)
    }

    @Test func migrationSkipsEmptyArgumentsAndAgentsWithoutPresets() {
        let result = LaunchPreset.migrating(extraArguments: ["claude": "  ", "codex": "--model gpt-5"], into: LaunchPreset.defaults)
        #expect(result.defaultIDs["claude"] == nil)
        #expect(result.presets.last?.agentID == "codex")
        #expect(result.defaultIDs["codex"] == result.presets.last?.id)
    }
}
