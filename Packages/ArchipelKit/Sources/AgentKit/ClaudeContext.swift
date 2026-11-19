import Foundation

/// How full the context window of a Claude session is, from the status line input.
public struct SessionContext: Equatable, Sendable {
    public var usedTokens: Int
    public var windowSize: Int
    /// 0...100.
    public var usedPercent: Double
    public var outputTokens: Int
    public var transcriptPath: String?
    public var model: String?
    public var updatedAt: Date

    public init(
        usedTokens: Int, windowSize: Int, usedPercent: Double, outputTokens: Int,
        transcriptPath: String?, model: String?, updatedAt: Date
    ) {
        self.usedTokens = usedTokens
        self.windowSize = windowSize
        self.usedPercent = usedPercent
        self.outputTokens = outputTokens
        self.transcriptPath = transcriptPath
        self.model = model
        self.updatedAt = updatedAt
    }
}

/// When the prompt cache of a session goes cold, going by the last request that touched it.
public struct PromptCacheState: Equatable, Sendable {
    public var lastRequestAt: Date
    public var ttl: TimeInterval

    public init(lastRequestAt: Date, ttl: TimeInterval) {
        self.lastRequestAt = lastRequestAt
        self.ttl = ttl
    }

    public var expiresAt: Date { lastRequestAt.addingTimeInterval(ttl) }

    public func isWarm(at date: Date) -> Bool { date < expiresAt }
}

/// Reads cache activity out of a Claude Code transcript (JSONL).
public enum ClaudeTranscript {
    /// Every request that reads or writes the cache restarts its TTL, and a request that wrote cache
    /// says which TTL it asked for. One that only read it does not, so that falls back to the TTL of
    /// the newest earlier request that wrote. Nil when none is known.
    public static func cacheState(inTail data: Data) -> PromptCacheState? {
        var newestID: String?
        var earliest: Date?
        var ttl: TimeInterval?

        // Newest first. A read can start mid-line; that line fails to parse and is skipped.
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let request = request(from: line) else { continue }
            if newestID == nil { newestID = request.id }
            if request.id == newestID {
                // One API response is written as a line per content block. The timestamp is written
                // once the response is complete, so the earliest line is the closest to the request.
                if let date = request.date { earliest = min(earliest ?? date, date) }
                if ttl == nil { ttl = request.ttl }
                continue
            }
            if ttl == nil { ttl = request.ttl }
            if ttl != nil { break }
        }
        guard let earliest, let ttl else { return nil }
        return PromptCacheState(lastRequestAt: earliest, ttl: ttl)
    }

    public static func cacheState(at url: URL) -> PromptCacheState? {
        CodexSessionLogs.readTail(of: url, maxBytes: 1 << 20).flatMap { cacheState(inTail: $0) }
    }

    private struct Request {
        var id: String
        var date: Date?
        var ttl: TimeInterval?
    }

    private static func request(from line: Data.SubSequence) -> Request? {
        // Cheap check first: most lines are not assistant messages and some are huge.
        guard line.range(of: Data(#""usage""#.utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "assistant",
              object["isSidechain"] as? Bool != true,
              let message = object["message"] as? [String: Any],
              let id = message["id"] as? String,
              message["model"] as? String != "<synthetic>",
              let usage = message["usage"] as? [String: Any]
        else { return nil }
        let creation = usage["cache_creation"] as? [String: Any]
        let ttl: TimeInterval? = if count(creation?["ephemeral_1h_input_tokens"]) > 0 {
            3600
        } else if count(creation?["ephemeral_5m_input_tokens"]) > 0 {
            300
        } else {
            nil
        }
        let date = (object["timestamp"] as? String).flatMap {
            try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        return Request(id: id, date: date, ttl: ttl)
    }

    private static func count(_ value: Any?) -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return 0 }
        return number.doubleValue
    }
}
