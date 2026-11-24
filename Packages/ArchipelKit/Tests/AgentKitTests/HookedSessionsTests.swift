@testable import AgentKit
import ArchipelCore
import Foundation
import Testing

struct HookedSessionsTests {
    let id = UUID()

    private func message(_ source: String?, session: UUID? = nil) -> HookMessage {
        HookMessage(sessionID: session ?? id, event: .turnFinished(message: nil), agentSessionID: nil, source: source)
    }

    @Test func notifyCountsUntilTheFirstHook() {
        var hooked = HookedSessions()
        #expect(hooked.admit(message("codex"), agent: .codex) == .accepted)
        #expect(!hooked.contains(id))
        #expect(hooked.admit(message("codex-hooks"), agent: .codex) == .firstHook)
        #expect(hooked.contains(id))
        #expect(hooked.admit(message("codex-hooks"), agent: .codex) == .accepted)
        #expect(hooked.admit(message("codex"), agent: .codex) == .dropped)
    }

    @Test func otherSessionsAreUnaffected() {
        var hooked = HookedSessions()
        _ = hooked.admit(message("codex-hooks"), agent: .codex)
        #expect(hooked.admit(message("codex", session: UUID()), agent: .codex) == .accepted)
    }

    @Test func relaunchForgetsTheSession() {
        var hooked = HookedSessions()
        _ = hooked.admit(message("codex-hooks"), agent: .codex)
        hooked.reset(id)
        #expect(hooked.admit(message("codex"), agent: .codex) == .accepted)
    }

    @Test func agentsThatAlwaysReportThroughHooksAreNotTracked() {
        var hooked = HookedSessions()
        #expect(hooked.admit(message("claude"), agent: .claude) == .accepted)
        #expect(!hooked.contains(id))
    }

    @Test func hookedCodexReportsLifecycleThroughHooks() {
        #expect(!EffectiveAgent.resolve(persisted: .codex, runtime: nil).reportsLifecycleThroughHooks)
        #expect(EffectiveAgent.resolve(persisted: .codex, runtime: nil, hooksSeen: true).reportsLifecycleThroughHooks)
    }

    @Test func envelopeCarriesItsSource() throws {
        let line = Data(#"{"session": "\#(id.uuidString)", "source": "codex-hooks", "payload": {"hook_event_name": "Stop", "session_id": "s"}}"#.utf8)
        #expect(HookServer.decodeEnvelope(line)?.source == "codex-hooks")
    }
}
