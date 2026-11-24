import Foundation

/// The models the user chose with an agent, latest first, as the one string `@AppStorage` keeps.
/// Kept by the app rather than the session: a new session of the same agent should know them.
enum RecentModels {
    /// More than a menu shows, so a recent one that the agent no longer offers does not cost a place.
    static let capacity = 10

    static func key(agentName: String) -> String { "chat.recentModels.\(agentName)" }

    static func values(in stored: String) -> [String] {
        stored.split(separator: "\n").map(String.init)
    }

    static func adding(_ value: String, to stored: String) -> String {
        ([value] + values(in: stored).filter { $0 != value }).prefix(capacity).joined(separator: "\n")
    }
}
