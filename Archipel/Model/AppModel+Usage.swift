import AgentKit
import ArchipelCore
import Foundation

extension AppModel {
    /// Claude's readings arrive through its status line. They are kept across launches, because Claude
    /// only sends them again once a session is running.
    func recordUsage(_ reading: ProviderUsage) {
        // The status line redraws far more often than the numbers change; skip the identical ones
        // so the bar does not re-render and the defaults are not rewritten on every keystroke.
        if let previous = usage[reading.provider], previous.windows == reading.windows,
           reading.updatedAt.timeIntervalSince(previous.updatedAt) < 60 {
            return
        }
        usage[reading.provider] = reading
        UsageArchive.save(usage)
    }

    /// Codex has no live feed, so its session logs are read at launch and after each Codex turn.
    func refreshCodexUsage() {
        Task {
            let reading = await Task.detached(priority: .utility) { CodexSessionLogs.latestUsage() }.value
            if let reading { recordUsage(reading) }
        }
    }
}

/// The last readings in UserDefaults: a few hundred bytes, and losing them only costs a blank bar.
enum UsageArchive {
    private static let key = "usage.lastReadings"

    static func load(defaults: UserDefaults = .standard) -> [UsageProvider: ProviderUsage] {
        guard
            let data = defaults.data(forKey: key),
            let readings = try? JSONDecoder().decode([ProviderUsage].self, from: data)
        else { return [:] }
        return Dictionary(readings.map { ($0.provider, $0) }, uniquingKeysWith: { $1 })
    }

    static func save(_ usage: [UsageProvider: ProviderUsage], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(Array(usage.values)) else { return }
        defaults.set(data, forKey: key)
    }
}
