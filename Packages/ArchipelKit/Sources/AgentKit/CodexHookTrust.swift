import ArchipelCore
import Foundation

/// Whether Codex runs the app's hooks, which it only does once the user has trusted them, judged
/// from what Codex sessions send. Settings shows the answer, and it is kept across launches.
public struct CodexHookTrust: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case trusted
        case untrusted
    }

    /// When a hook last proved the trust, in this run of the app.
    private var confirmedAt: ContinuousClock.Instant?

    public init() {}

    /// What a message a Codex session was admitted with says about the trust, or nil when it
    /// says nothing. `launchedAt` is when that session's Codex was started.
    public mutating func judge(
        _ message: HookMessage,
        admission: HookedSessions.Admission,
        launchedAt: ContinuousClock.Instant?,
        now: ContinuousClock.Instant = .now
    ) -> Verdict? {
        switch admission {
        case .dropped, .foreign:
            return nil
        case .accepted, .firstHook:
            break
        }
        if message.source == CodexAdapter.hooksSource {
            confirmedAt = now
            return .trusted
        }
        guard message.source == CodexAdapter.notifySource, case .turnFinished? = message.event else { return nil }
        // A whole turn went by without a hook, so this session runs without them. That only
        // speaks against the trust if the session started after it was last proven: Codex reads
        // its trust at startup, and one started before the user granted it stays hookless for
        // good. With nothing proven in this run, the trust on record is from an earlier one, and
        // every session is newer than that.
        guard let launchedAt else { return nil }
        if let confirmedAt, launchedAt <= confirmedAt { return nil }
        return .untrusted
    }
}
