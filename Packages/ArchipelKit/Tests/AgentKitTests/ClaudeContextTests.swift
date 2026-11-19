@testable import AgentKit
import ArchipelCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func json(_ string: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
}

struct SessionContextTests {
    @Test func decodesTheContextWindow() throws {
        let payload = try json("""
        {"transcript_path": "/tmp/t.jsonl", "model": {"id": "claude-opus-5-5", "display_name": "Opus 5.5"},
         "context_window": {"total_input_tokens": 72609, "total_output_tokens": 222, "context_window_size": 200000,
           "current_usage": {"input_tokens": 2}, "used_percentage": 36, "remaining_percentage": 64}}
        """)
        #expect(UsageDecoder.claudeContext(payload) == SessionContext(
            usedTokens: 72609, windowSize: 200_000, usedPercent: 36,
            transcriptPath: "/tmp/t.jsonl", model: "Opus 5.5"
        ))
    }

    @Test func modelFallsBackToIDAndOptionalFieldsMayBeMissing() throws {
        let payload = try json(#"""
        {"model": {"id": "claude-x"}, "context_window": {"total_input_tokens": 100, "context_window_size": 1000, "current_usage": {}}}
        """#)
        let context = try #require(UsageDecoder.claudeContext(payload))
        #expect(context.model == "claude-x")
        #expect(context.transcriptPath == nil)
    }

    @Test func missingWindowOrSizeIsNil() throws {
        #expect(UsageDecoder.claudeContext(try json(#"{"model": {"id": "x"}}"#)) == nil)
        #expect(UsageDecoder.claudeContext(try json(#"{"context_window": {"total_input_tokens": 5, "current_usage": {}}}"#)) == nil)
        #expect(UsageDecoder.claudeContext(try json(#"{"context_window": {"total_input_tokens": 5, "context_window_size": 0, "current_usage": {}}}"#)) == nil)
    }

    @Test func noReplyYetIsNil() throws {
        let payload = try json(#"{"context_window": {"total_input_tokens": 0, "context_window_size": 200000, "current_usage": null, "used_percentage": null}}"#)
        #expect(UsageDecoder.claudeContext(payload) == nil)
    }

    @Test func percentIsComputedWhenMissingAndClamped() throws {
        let computed = try json(#"{"context_window": {"total_input_tokens": 50000, "context_window_size": 200000, "current_usage": {}, "used_percentage": null}}"#)
        #expect(UsageDecoder.claudeContext(computed)?.usedPercent == 25)
        let over = try json(#"{"context_window": {"total_input_tokens": 50000, "context_window_size": 200000, "current_usage": {}, "used_percentage": 400}}"#)
        #expect(UsageDecoder.claudeContext(over)?.usedPercent == 100)
    }

    @Test func garbageNumbersAreRejected() throws {
        let boolSize = try json(#"{"context_window": {"total_input_tokens": 5, "context_window_size": true, "current_usage": {}}}"#)
        #expect(UsageDecoder.claudeContext(boolSize) == nil)
        let hugeSize = try json(#"{"context_window": {"total_input_tokens": 5, "context_window_size": 1e300, "current_usage": {}}}"#)
        #expect(UsageDecoder.claudeContext(hugeSize) == nil)
        let garbage = try json(#"{"context_window": {"total_input_tokens": "x", "total_output_tokens": 1e300, "context_window_size": 1000, "current_usage": {}, "used_percentage": "lots"}}"#)
        let context = try #require(UsageDecoder.claudeContext(garbage))
        #expect(context.usedTokens == 0)
        #expect(context.usedPercent.isFinite)
    }
}

struct ClaudeTranscriptTests {
    private func line(
        id: String, at timestamp: String, h1: Int = 0, m5: Int = 0, model: String = "claude-opus-5-5",
        sidechain: Bool = false, type: String = "assistant"
    ) -> String {
        """
        {"type":"\(type)","timestamp":"\(timestamp)","isSidechain":\(sidechain),"message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":2,"cache_creation_input_tokens":\(h1 + m5),"cache_read_input_tokens":71872,"output_tokens":222,"cache_creation":{"ephemeral_1h_input_tokens":\(h1),"ephemeral_5m_input_tokens":\(m5)}}}}
        """
    }

    private func state(_ lines: [String]) -> PromptCacheState? {
        ClaudeTranscript.cacheState(inTail: Data(lines.joined(separator: "\n").utf8))
    }

    private func date(_ iso: String) -> Date {
        try! Date(iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    @Test func oneHourTTL() {
        let result = state([line(id: "a", at: "2026-11-19T14:56:53.167Z", h1: 735)])
        #expect(result == PromptCacheState(lastRequestAt: date("2026-11-19T14:56:53.167Z"), ttl: 3600))
    }

    @Test func fiveMinuteTTL() {
        #expect(state([line(id: "a", at: "2026-11-19T14:56:53.167Z", m5: 10)])?.ttl == 300)
    }

    @Test func fullCacheHitUsesTheEarlierTTLButTheNewerTime() {
        let result = state([
            line(id: "a", at: "2026-11-19T14:00:00.000Z", h1: 500),
            line(id: "b", at: "2026-11-19T14:10:00.000Z"),
        ])
        #expect(result == PromptCacheState(lastRequestAt: date("2026-11-19T14:10:00.000Z"), ttl: 3600))
    }

    @Test func fullCacheHitWithNoKnownTTLIsNil() {
        #expect(state([line(id: "b", at: "2026-11-19T14:10:00.000Z")]) == nil)
    }

    @Test func sidechainAndSyntheticLinesAreIgnored() {
        let result = state([
            line(id: "a", at: "2026-11-19T14:00:00.000Z", m5: 5),
            line(id: "side", at: "2026-11-19T15:00:00.000Z", h1: 5, sidechain: true),
            line(id: "syn", at: "2026-11-19T16:00:00.000Z", h1: 5, model: "<synthetic>"),
        ])
        #expect(result == PromptCacheState(lastRequestAt: date("2026-11-19T14:00:00.000Z"), ttl: 300))
    }

    @Test func linesOfOneMessageUseTheEarliestTimestamp() {
        let result = state([
            line(id: "a", at: "2026-11-19T14:00:00.000Z", m5: 5),
            line(id: "b", at: "2026-11-19T14:10:05.000Z", h1: 9),
            line(id: "b", at: "2026-11-19T14:10:01.000Z", h1: 9),
            line(id: "b", at: "2026-11-19T14:10:09.000Z", h1: 9),
        ])
        #expect(result == PromptCacheState(lastRequestAt: date("2026-11-19T14:10:01.000Z"), ttl: 3600))
    }

    @Test func partialFirstLineIsSkipped() {
        let result = state([
            #"cache_read_input_tokens":1}}}"#,
            line(id: "a", at: "2026-11-19T14:00:00.000Z", m5: 5),
        ])
        #expect(result?.ttl == 300)
    }

    @Test func noAssistantLinesIsNil() {
        #expect(state([line(id: "u", at: "2026-11-19T14:00:00.000Z", h1: 5, type: "user"), "{}"]) == nil)
        #expect(state([]) == nil)
    }

    @Test func warmUntilTheTTLRunsOut() {
        let cache = PromptCacheState(lastRequestAt: now, ttl: 300)
        #expect(cache.expiresAt == now.addingTimeInterval(300))
        #expect(cache.isWarm(at: now.addingTimeInterval(299)))
        #expect(!cache.isWarm(at: now.addingTimeInterval(300)))
    }

    @Test func readsTheTailOfAFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(line(id: "a", at: "2026-11-19T14:00:00.000Z", h1: 1).utf8).write(to: url)
        #expect(ClaudeTranscript.cacheState(at: url)?.ttl == 3600)
        #expect(ClaudeTranscript.cacheState(at: url.appending(path: "missing")) == nil)
    }
}
