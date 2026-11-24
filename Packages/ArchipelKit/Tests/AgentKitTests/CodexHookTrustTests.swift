@testable import AgentKit
import ArchipelCore
import Foundation
import Testing

/// Settings says whether Codex runs the app's hooks. Codex decides that when it starts, so only
/// some sessions can speak for it.
struct CodexHookTrustTests {
    private let start = ContinuousClock.now

    private func at(_ seconds: Int) -> ContinuousClock.Instant { start + .seconds(seconds) }

    private func hook(_ event: AgentEvent? = .activity) -> HookMessage {
        HookMessage(sessionID: UUID(), event: event, agentSessionID: nil, source: CodexAdapter.hooksSource)
    }

    private func notify(_ event: AgentEvent? = .turnFinished(message: nil)) -> HookMessage {
        HookMessage(sessionID: UUID(), event: event, agentSessionID: nil, source: CodexAdapter.notifySource)
    }

    @Test func anyHookProvesTheTrust() {
        var trust = CodexHookTrust()
        #expect(trust.judge(hook(.sessionStarted), admission: .firstHook, launchedAt: at(0), now: at(1)) == .trusted)
        // Not only a session's first: the setting may have been cleared in between.
        #expect(trust.judge(hook(), admission: .accepted, launchedAt: at(0), now: at(2)) == .trusted)
        #expect(trust.judge(hook(nil), admission: .accepted, launchedAt: nil, now: at(3)) == .trusted)
    }

    @Test func aTurnThatEndsThroughNotifyAloneSpeaksAgainstIt() {
        var trust = CodexHookTrust()
        // Trusted in an earlier run of the app, and the first session of this one has no hooks.
        #expect(trust.judge(notify(), admission: .accepted, launchedAt: at(0), now: at(5)) == .untrusted)
    }

    /// Started before the user trusted the hooks, such a session never gets them, and each of
    /// its turns would otherwise take back what the newer sessions prove.
    @Test func aSessionStartedBeforeTheTrustWasProvenDoesNotCount() {
        var trust = CodexHookTrust()
        _ = trust.judge(hook(), admission: .firstHook, launchedAt: at(10), now: at(11))
        #expect(trust.judge(notify(), admission: .accepted, launchedAt: at(0), now: at(20)) == nil)
        #expect(trust.judge(notify(), admission: .accepted, launchedAt: at(11), now: at(20)) == nil)
        // One started since then ran a whole turn without them: the trust is gone.
        #expect(trust.judge(notify(), admission: .accepted, launchedAt: at(15), now: at(30)) == .untrusted)
        // And proven again by the next hook.
        #expect(trust.judge(hook(), admission: .accepted, launchedAt: at(40), now: at(41)) == .trusted)
        #expect(trust.judge(notify(), admission: .accepted, launchedAt: at(15), now: at(50)) == nil)
    }

    @Test func whatSaysNothing() {
        var trust = CodexHookTrust()
        // A fallback for a session that has hooks, and another agent's message.
        #expect(trust.judge(notify(), admission: .dropped, launchedAt: at(0), now: at(1)) == nil)
        #expect(trust.judge(hook(), admission: .foreign, launchedAt: at(0), now: at(1)) == nil)
        // Not the end of a turn.
        #expect(trust.judge(notify(nil), admission: .accepted, launchedAt: at(0), now: at(1)) == nil)
        // Nothing known about when the session started.
        #expect(trust.judge(notify(), admission: .accepted, launchedAt: nil, now: at(1)) == nil)
        let claude = HookMessage(sessionID: UUID(), event: .turnFinished(message: nil), agentSessionID: nil, source: "claude")
        #expect(trust.judge(claude, admission: .accepted, launchedAt: at(0), now: at(1)) == nil)
        // None of it counted as proof either.
        #expect(trust.judge(notify(), admission: .accepted, launchedAt: at(0), now: at(2)) == .untrusted)
    }
}
