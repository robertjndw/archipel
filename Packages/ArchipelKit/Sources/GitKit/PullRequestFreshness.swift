import Foundation

/// How long a pull request answer for a branch is trusted before `gh` is asked again.
///
/// A found PR rarely changes behind the user's back, so it can wait. "None yet" on a pushed branch
/// goes stale fast, because agents push first and run `gh pr create` a minute later. A failure (no
/// network, expired login) is retried soon, but if it keeps failing the remote is probably not on
/// GitHub, and then once a minute is too often.
public enum PullRequestFreshness {
    public enum Answer: Equatable, Sendable {
        case found
        case none
        case failed(repeatedly: Bool)
    }

    public static let foundLifetime = Duration.seconds(300)
    public static let noneLifetime = Duration.seconds(60)
    /// A branch that was never pushed rarely has a pull request; one opened from a pushed branch
    /// of another name is still found, just later.
    public static let unpushedLifetime = Duration.seconds(300)
    public static let failedLifetime = Duration.seconds(60)

    public static func lifetime(of answer: Answer, hasUpstream: Bool) -> Duration {
        switch answer {
        case .found: foundLifetime
        case .none: hasUpstream ? noneLifetime : unpushedLifetime
        case .failed(let repeatedly): repeatedly ? foundLifetime : failedLifetime
        }
    }

    /// Whether an answer of `age` should be asked again. `requestedAge` is the caller's own limit:
    /// a poll passes a long one, an event that probably changed something (a push, an agent turn
    /// ending) passes zero.
    public static func isDue(_ answer: Answer, age: Duration, hasUpstream: Bool, requestedAge: Duration) -> Bool {
        age >= min(requestedAge, lifetime(of: answer, hasUpstream: hasUpstream))
    }
}
