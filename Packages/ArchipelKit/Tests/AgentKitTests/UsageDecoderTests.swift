import AgentKit
import ArchipelCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func json(_ string: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
}

struct UsageDecoderTests {
    @Test func claudeStatusLineLimits() throws {
        let payload = try json("""
        {"session_id": "abc", "rate_limits": {
          "five_hour": {"used_percentage": 42, "resets_at": 1800003600},
          "seven_day": {"used_percentage": 18.5, "resets_at": 1800400000}
        }}
        """)
        let usage = try #require(UsageDecoder.claudeStatusLine(payload, at: now))
        #expect(usage == ProviderUsage(provider: .claude, windows: [
            UsageWindow(usedPercent: 42, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 1_800_003_600)),
            UsageWindow(usedPercent: 18.5, windowMinutes: 10080, resetsAt: Date(timeIntervalSince1970: 1_800_400_000)),
        ], updatedAt: now))
        #expect(usage.windows.map(\.shortLabel) == ["5h", "week"])
        #expect(usage.windows.map(\.longLabel) == ["5-hour", "Weekly"])
    }

    @Test func claudeKeepsTheWindowsItStillSends() throws {
        // Claude drops a window once it has reset.
        let payload = try json(#"{"rate_limits": {"seven_day": {"used_percentage": 3, "resets_at": 1800400000}}}"#)
        #expect(UsageDecoder.claudeStatusLine(payload, at: now)?.windows.map(\.windowMinutes) == [10080])
    }

    @Test func claudeWithoutLimits() throws {
        // API key accounts, and subscriptions before their first reply.
        #expect(UsageDecoder.claudeStatusLine(try json(#"{"model": {"id": "x"}}"#), at: now) == nil)
        #expect(UsageDecoder.claudeStatusLine(try json(#"{"rate_limits": {}}"#), at: now) == nil)
        #expect(UsageDecoder.claudeStatusLine(try json(#"{"rate_limits": {"five_hour": {"used_percentage": true}}}"#), at: now) == nil)
    }

    @Test func codexLogKeepsTheNewestReading() throws {
        let log = """
        {"timestamp":"2026-11-06T22:40:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1800001000},"secondary":null}}}
        {"timestamp":"2026-11-06T22:41:00Z","type":"response_item","payload":{"type":"message"}}
        {"timestamp":"2026-11-06T22:45:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1800001000},"secondary":{"used_percent":4.0,"window_minutes":10080,"resets_at":1800500000},"plan_type":"plus"}}}
        {"timestamp":"2026-11-06T22:46:00Z","type":"response_item","payl
        """
        let usage = try #require(UsageDecoder.latestCodexUsage(inLog: Data(log.utf8), at: now))
        #expect(usage.provider == .codex)
        #expect(usage.windows.map(\.usedPercent) == [12, 4])
        #expect(usage.windows.map(\.shortLabel) == ["5h", "week"])
    }

    @Test func codexWindowLengthThatIsNoUsableNumberIsSkipped() throws {
        // Converting these to Int the plain way traps.
        let huge = try json(#"{"primary": {"used_percent": 2.0, "window_minutes": 1e300}, "secondary": {"used_percent": 4.0, "window_minutes": 10080}}"#)
        #expect(UsageDecoder.codexRateLimits(huge, at: now)?.windows.map(\.windowMinutes) == [10080])

        for value in [Double.nan, .infinity, -.infinity, -1e300] {
            let limits: [String: Any] = ["primary": ["used_percent": 2.0, "window_minutes": NSNumber(value: value)]]
            #expect(UsageDecoder.codexRateLimits(limits, at: now) == nil)
        }
        let fractional = try json(#"{"primary": {"used_percent": 2.0, "window_minutes": 300.9}}"#)
        #expect(UsageDecoder.codexRateLimits(fractional, at: now)?.windows.map(\.windowMinutes) == [300])
    }

    @Test func percentThatIsNoUsableNumberIsSkippedOrClamped() throws {
        // The status bar rounds the percentage to an Int, which traps on all of these.
        for value in [Double.nan, .infinity, -.infinity] {
            let limits: [String: Any] = ["primary": ["used_percent": NSNumber(value: value), "window_minutes": 300]]
            #expect(UsageDecoder.codexRateLimits(limits, at: now) == nil)
            let payload: [String: Any] = ["rate_limits": ["five_hour": ["used_percentage": NSNumber(value: value)]]]
            #expect(UsageDecoder.claudeStatusLine(payload, at: now) == nil)
        }
        let outOfRange = try json(#"{"primary": {"used_percent": 1e300, "window_minutes": 300}, "secondary": {"used_percent": -1e300, "window_minutes": 10080}}"#)
        #expect(UsageDecoder.codexRateLimits(outOfRange, at: now)?.windows.map(\.usedPercent) == [100, 0])
        let claude = try json(#"{"rate_limits": {"five_hour": {"used_percentage": 1e300}}}"#)
        #expect(UsageDecoder.claudeStatusLine(claude, at: now)?.windows.map(\.usedPercent) == [100])
    }

    @Test func codexMonthlyWindowOnTheFreePlan() throws {
        let limits = try json(#"{"primary": {"used_percent": 2.0, "window_minutes": 43200, "resets_at": 1796590778}, "secondary": null}"#)
        let usage = try #require(UsageDecoder.codexRateLimits(limits, at: now))
        #expect(usage.windows.map(\.shortLabel) == ["month"])
        #expect(usage.windows.map(\.longLabel) == ["Monthly"])
    }

    @Test func aResetWindowCountsAsEmpty() {
        let window = UsageWindow(usedPercent: 80, windowMinutes: 300, resetsAt: now)
        #expect(window.usedPercent(at: now.addingTimeInterval(-1)) == 80)
        #expect(window.usedPercent(at: now) == 0)
    }
}

struct CodexSessionLogsTests {
    @Test func findsTheNewestLogWithLimits() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "codex-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let line = { (percent: Int) in
            #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(percent),"window_minutes":300,"resets_at":1800001000}}}}"#
        }
        try write("2026/10/31/rollout-a.jsonl", line(50) + "\n")
        try write("2026/11/06/rollout-b.jsonl", line(7) + "\n")
        // Newest, but the session never got a reply.
        try write("2026/11/07/rollout-c.jsonl", #"{"type":"session_meta","payload":{}}"# + "\n")

        #expect(CodexSessionLogs.newest(in: root, limit: 5).map(\.lastPathComponent) == ["rollout-c.jsonl", "rollout-b.jsonl", "rollout-a.jsonl"])
        #expect(CodexSessionLogs.latestUsage(in: root, at: now)?.windows.first?.usedPercent == 7)
    }

    @Test func missingFolder() {
        let root = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(CodexSessionLogs.latestUsage(in: root, at: now) == nil)
    }
}
