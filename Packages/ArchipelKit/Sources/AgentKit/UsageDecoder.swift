import ArchipelCore
import Foundation

/// Reads subscription rate limits from what the agents already expose: the JSON Claude Code passes to
/// its status line command, and the `token_count` events Codex writes to its session logs.
/// Anything missing or malformed yields nil rather than a guess.
public enum UsageDecoder {
    /// `rate_limits.five_hour` / `seven_day` from Claude's status line input. Claude only sends them for
    /// subscription accounts, after the first reply, and drops a window once it has reset.
    public static func claudeStatusLine(_ payload: [String: Any], at date: Date) -> ProviderUsage? {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        let known = [("five_hour", 5 * 60), ("seven_day", 7 * 24 * 60)]
        let windows = known.compactMap { key, minutes in
            (limits[key] as? [String: Any]).flatMap {
                window($0, percentKey: "used_percentage", minutes: minutes)
            }
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(provider: .claude, windows: windows, updatedAt: date)
    }

    /// The `rate_limits` object of a Codex `token_count` event. Codex names its windows primary and
    /// secondary and says how long each one is, which differs by plan.
    public static func codexRateLimits(_ limits: [String: Any], at date: Date) -> ProviderUsage? {
        let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
            guard let raw = limits[key] as? [String: Any], let minutes = number(raw["window_minutes"]) else { return nil }
            return window(raw, percentKey: "used_percent", minutes: Int(minutes))
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(provider: .codex, windows: windows, updatedAt: date)
    }

    /// The newest rate limits in a Codex session log (JSON lines), or nil when it has none.
    public static func latestCodexUsage(inLog data: Data, at date: Date) -> ProviderUsage? {
        let marker = Data("\"rate_limits\"".utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let payload = object["payload"] as? [String: Any],
                let limits = payload["rate_limits"] as? [String: Any],
                let usage = codexRateLimits(limits, at: date)
            else { continue }
            return usage
        }
        return nil
    }

    private static func window(_ raw: [String: Any], percentKey: String, minutes: Int) -> UsageWindow? {
        guard let percent = number(raw[percentKey]) else { return nil }
        return UsageWindow(usedPercent: percent, windowMinutes: minutes, resetsAt: resetDate(raw["resets_at"]))
    }

    /// Epoch seconds in both agents today; an ISO 8601 string is accepted too in case that changes.
    private static func resetDate(_ value: Any?) -> Date? {
        if let seconds = number(value) { return Date(timeIntervalSince1970: seconds) }
        if let string = value as? String {
            return (try? Date(string, strategy: .iso8601))
                ?? (try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        // JSONSerialization hands back NSNumber, and Bool also bridges to it.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}

/// Finds the newest Codex session logs. Codex keeps them in `$CODEX_HOME/sessions/YYYY/MM/DD/*.jsonl`.
public enum CodexSessionLogs {
    public static func defaultSessionsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.homeDirectory.appending(path: ".codex", directoryHint: .isDirectory)
        return home.appending(path: "sessions", directoryHint: .isDirectory)
    }

    /// Newest first. Walks the date folders from the newest down instead of listing every log ever written.
    public static func newest(in sessions: URL, limit: Int) -> [URL] {
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        func folders(_ url: URL) -> [URL] {
            children(url).filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var found: [URL] = []
        for year in folders(sessions) {
            for month in folders(year) {
                for day in folders(month) {
                    let logs = children(day)
                        .filter { $0.pathExtension == "jsonl" }
                        .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
                        .sorted { $0.1 > $1.1 }
                        .map(\.0)
                    found += logs
                    if found.count >= limit { return Array(found.prefix(limit)) }
                }
            }
        }
        return found
    }

    /// The newest rate limits across the last few logs. A log that never got a reply has none, so the
    /// newest file alone is not enough.
    public static func latestUsage(in sessions: URL = defaultSessionsDirectory(), at date: Date = .now) -> ProviderUsage? {
        for log in newest(in: sessions, limit: 5) {
            guard let tail = readTail(of: log, maxBytes: 1 << 20) else { continue }
            let modified = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? date
            if let usage = UsageDecoder.latestCodexUsage(inLog: tail, at: modified) { return usage }
        }
        return nil
    }

    /// Logs of long sessions run to many megabytes and the limits we want are near the end.
    private static func readTail(of url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        // The read can start mid-line. That first line won't parse and gets skipped.
        return try? handle.readToEnd()
    }
}
