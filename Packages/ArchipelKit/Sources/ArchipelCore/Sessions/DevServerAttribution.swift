import Foundation

/// Decides whose pill an open port is. A port is open for everyone, so a tab that merely prints
/// another tab's URL would get a pill too; but plenty of real servers are held by processes that
/// no tab owns (Docker, podman, `supabase start`, `brew services`, pm2), so ownership can only veto,
/// never be required.
public enum DevServerAttribution {
    public enum Verdict: Equatable, Sendable {
        case accept
        /// Another session's processes hold the listener; the pill is theirs.
        case veto
        /// Open, but the process scan may not have seen the listener yet. Not a failed probe.
        case wait
    }

    /// The active resource scan runs every 4 seconds, plus time for the scan itself.
    public static let scanGrace: Duration = .seconds(5)
    /// In the background the resource scan runs every 15 seconds and its sleep is not cut short
    /// when the app comes back, so what it knows on return can be that old.
    public static let resumeGrace: Duration = .seconds(16)

    /// - Parameters:
    ///   - listeners: the ports each session's processes listen on, as of the last resource scan.
    ///   - isSettled: whether that scan has had a chance to see this listener, see `isSettled`.
    public static func verdict<ID: Hashable>(for session: ID, port: Int, listeners: [ID: Set<Int>], isSettled: Bool) -> Verdict {
        if listeners[session]?.contains(port) == true { return .accept }
        if listeners.contains(where: { $0.key != session && $0.value.contains(port) }) { return .veto }
        return isSettled ? .accept : .wait
    }

    /// Whether a port first seen open at `openSince` has been open long enough for the process
    /// scan to have attributed it, counting from the app's return to the front when that was later.
    public static func isSettled(
        openSince: ContinuousClock.Instant,
        resumedAt: ContinuousClock.Instant?,
        now: ContinuousClock.Instant
    ) -> Bool {
        if let resumedAt, now < resumedAt.advanced(by: resumeGrace) { return false }
        return now >= openSince.advanced(by: scanGrace)
    }
}
