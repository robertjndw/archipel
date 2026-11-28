import AgentKit
import ArchipelCore
import Foundation
import Testing

struct HookDecoderTests {
    @Test func routesBySourceThroughTheRegistry() throws {
        let claude = try #require(HookDecoder.decode(source: "claude", payload: Data(Fixtures.stop.utf8)))
        #expect(claude.event == .turnFinished(message: "I've completed the refactoring.", backgroundTasks: 0, subagents: []))
        let codex = try #require(HookDecoder.decode(source: "codex", payload: Data(Fixtures.codexTurnComplete.utf8)))
        #expect(codex.event == .turnFinished(message: "Rename complete."))
        #expect(HookDecoder.decode(source: "gemini", payload: Data(Fixtures.stop.utf8)) == nil)
    }

    @Test func aRegistryDecidesWhichSourcesAreKnown() {
        let onlyCodex = AgentRegistry(adapters: [CodexAdapter()])
        #expect(HookDecoder.decode(source: "claude", payload: Data(Fixtures.stop.utf8), registry: onlyCodex) == nil)
        #expect(HookDecoder.decode(source: "codex", payload: Data(Fixtures.codexTurnComplete.utf8), registry: onlyCodex) != nil)
    }

    @Test(arguments: ["", "not json", "[1, 2]", "42", #"{"hook_event_name": 7, "session_id": 3}"#, "{"])
    func malformedInput(json: String) {
        for source in ["claude", "codex"] {
            let result = HookDecoder.decode(source: source, payload: Data(json.utf8))
            #expect(result?.event == nil)
            #expect(result?.agentSessionID == nil)
        }
    }
}
