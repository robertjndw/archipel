import Foundation

/// How full the context window of a Claude session is, from the status line input.
public struct SessionContext: Equatable, Sendable {
    public var usedTokens: Int
    public var windowSize: Int
    /// 0...100.
    public var usedPercent: Double
    public var transcriptPath: String?
    public var model: String?

    public init(usedTokens: Int, windowSize: Int, usedPercent: Double, transcriptPath: String?, model: String?) {
        self.usedTokens = usedTokens
        self.windowSize = windowSize
        self.usedPercent = usedPercent
        self.transcriptPath = transcriptPath
        self.model = model
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

    /// Where the user stopped a turn. Claude runs no hook for that, but it does write a line of
    /// its own to the transcript.
    public struct Interruption: Equatable, Sendable {
        /// The transcript entry's `uuid`, so the same interruption is not acted on twice.
        public var id: String
        public var date: Date

        public init(id: String, date: Date) {
            self.id = id
            self.date = date
        }
    }

    /// What Claude writes as the user's message when a turn is interrupted with Esc, and when a
    /// permission prompt is dismissed. Matched whole: text that merely starts like one can come
    /// from anywhere, such as a prompt quoting it.
    static let interruptionMarkers: Set<String> = [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]",
    ]

    /// The interruption the conversation ends on, or nil when its newest message is anything else:
    /// then the turn was not interrupted, or the conversation has moved on since.
    public static func interruption(inTail data: Data) -> Interruption? {
        // Newest first. A read can start mid-line; that line fails to parse and is skipped.
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  // Subagents write their own messages, and those say nothing about the main turn.
                  object["isSidechain"] as? Bool != true,
                  // Claude writes the body of a slash command or a skill as a user message of its
                  // own, flagged as meta. That text comes from the repository, not from the user
                  // stopping anything, and it is not where the conversation stands either.
                  object["isMeta"] as? Bool != true
            else { continue }
            guard type == "user",
                  let message = object["message"] as? [String: Any],
                  isInterruption(message["content"]),
                  let id = object["uuid"] as? String,
                  let date = (object["timestamp"] as? String).flatMap({
                      try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
                  })
            else { return nil }
            return Interruption(id: id, date: date)
        }
        return nil
    }

    /// Only the last few lines matter, and the interruption is a short one.
    public static func interruption(at url: URL) -> Interruption? {
        CodexSessionLogs.readTail(of: url, maxBytes: 256 << 10).flatMap { interruption(inTail: $0) }
    }

    /// What a transcript file looked like from outside at one look. Claude only ever appends, so
    /// a file with the same stamp has the same end.
    public struct Stamp: Equatable, Sendable {
        public var size: UInt64
        public var modified: Date

        public init(size: UInt64, modified: Date) {
            self.size = size
            self.modified = modified
        }

        /// Nil when the file cannot be examined, as before Claude has written its first line.
        public init?(of url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? UInt64,
                  let modified = attributes[.modificationDate] as? Date
            else { return nil }
            self.init(size: size, modified: modified)
        }
    }

    public enum Look: Equatable, Sendable {
        /// Nothing was written since the look that gave the stamp, so what it found still holds.
        case unchanged
        /// The stamp is nil when the file could not be examined; the next look reads again then.
        case read(Interruption?, stamp: Stamp?)
    }

    /// `interruption(at:)`, without reading a transcript that has not changed since `last`. A
    /// working session is looked at every few seconds, and most looks find the file as it was.
    public static func lookForInterruption(at url: URL, since last: Stamp?) -> Look {
        // Taken before reading: a line written in between then shows as a change next time.
        let stamp = Stamp(of: url)
        if let stamp, stamp == last { return .unchanged }
        return .read(interruption(at: url), stamp: stamp)
    }

    private static func isInterruption(_ content: Any?) -> Bool {
        if let text = content as? String { return interruptionMarkers.contains(text) }
        // The rejected tool's result can sit in the same message. Only the message's own text
        // counts: what a tool printed is in a result block, whatever it says.
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { block in
            block["type"] as? String == "text" && (block["text"] as? String).map(interruptionMarkers.contains) == true
        }
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
        let ttl: TimeInterval? = if hasTokens(creation?["ephemeral_1h_input_tokens"]) {
            3600
        } else if hasTokens(creation?["ephemeral_5m_input_tokens"]) {
            300
        } else {
            nil
        }
        let date = (object["timestamp"] as? String).flatMap {
            try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        return Request(id: id, date: date, ttl: ttl)
    }

    private static func hasTokens(_ value: Any?) -> Bool {
        UsageDecoder.number(value).map { $0.isFinite && $0 > 0 } ?? false
    }
}
