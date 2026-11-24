@testable import AgentKit
import Foundation
import Testing

/// Claude runs no hook when the user interrupts a turn. What it does do is end the conversation
/// on a message of its own, which is how the app learns that the turn is over.
struct ClaudeInterruptionTests {
    private func user(_ content: String, uuid: String = "u1", at time: String = "2026-11-19T14:00:05.250Z", sidechain: Bool = false) -> String {
        #"{"type":"user","isSidechain":\#(sidechain),"uuid":"\#(uuid)","timestamp":"\#(time)","message":{"role":"user","content":\#(content)}}"#
    }

    private func assistant(_ text: String = "Working on it.") -> String {
        #"{"type":"assistant","isSidechain":false,"uuid":"a1","timestamp":"2026-11-19T14:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private let interrupted = #"[{"type":"text","text":"[Request interrupted by user]"}]"#
    private let rejected = #"[{"type":"text","text":"[Request interrupted by user for tool use]"}]"#

    private func interruption(_ lines: [String]) -> ClaudeTranscript.Interruption? {
        ClaudeTranscript.interruption(inTail: Data(lines.joined(separator: "\n").utf8))
    }

    @Test func aConversationThatEndsOnAnInterruption() throws {
        let found = try #require(interruption([user(#""Fix the tests""#, uuid: "u0"), assistant(), user(interrupted)]))
        #expect(found.id == "u1")
        #expect(found.date == (try Date("2026-11-19T14:00:05.250Z", strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))))
    }

    @Test func aDismissedPermissionPromptCountsToo() {
        #expect(interruption([assistant(), user(rejected)])?.id == "u1")
        // The rejected tool's result may share the message.
        let withResult = #"[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"rejected"},{"type":"text","text":"[Request interrupted by user for tool use]"}]"#
        #expect(interruption([assistant(), user(withResult)])?.id == "u1")
        #expect(interruption([assistant(), user(#""[Request interrupted by user]""#)])?.id == "u1")
    }

    @Test func linesThatAreNotMessagesAreLookedPast() {
        let found = interruption([
            assistant(), user(interrupted),
            #"{"type":"system","subtype":"turn_duration","uuid":"s1","timestamp":"2026-11-19T14:00:06.000Z"}"#,
            #"{"type":"file-history-snapshot","messageId":"m"}"#,
            // What a subagent wrote says nothing about the main turn.
            user(#""keep going""#, uuid: "side", sidechain: true),
        ])
        #expect(found?.id == "u1")
    }

    @Test func aConversationThatMovedOnIsNotInterrupted() {
        #expect(interruption([user(interrupted), user(#""Try again""#, uuid: "u2")]) == nil)
        #expect(interruption([user(interrupted), assistant()]) == nil)
        #expect(interruption([assistant()]) == nil)
        #expect(interruption([user(#"[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]"#)]) == nil)
        #expect(interruption([]) == nil)
    }

    @Test func aPromptThatOnlyQuotesTheMarkerIsNotOne() {
        #expect(interruption([user(#""Why does it say [Request interrupted by user]?""#)]) == nil)
    }

    @Test func aLineWithoutIDOrTimeIsNotActedOn() {
        let noTime = #"{"type":"user","uuid":"u1","message":{"role":"user","content":"[Request interrupted by user]"}}"#
        let noID = #"{"type":"user","timestamp":"2026-11-19T14:00:05.250Z","message":{"role":"user","content":"[Request interrupted by user]"}}"#
        #expect(interruption([assistant(), noTime]) == nil)
        #expect(interruption([assistant(), noID]) == nil)
    }

    @Test func partialFirstLineIsSkipped() {
        #expect(interruption([#"ext":"cut off"}]}}"#, user(interrupted)])?.id == "u1")
    }

    @Test func readsTheTailOfAFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([assistant(), user(interrupted)].joined(separator: "\n").utf8).write(to: url)
        #expect(ClaudeTranscript.interruption(at: url)?.id == "u1")
        #expect(ClaudeTranscript.interruption(at: url.appending(path: "missing")) == nil)
    }

    /// What a tool printed, or what a file it read contained, is in a result block. A turn that
    /// goes on after such a result must not be taken for stopped because of what it says.
    @Test func theMarkerInsideAToolResultIsNotAnInterruption() {
        let asString = #"[{"type":"tool_result","tool_use_id":"t1","content":"[Request interrupted by user]"}]"#
        let asBlock = #"[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"[Request interrupted by user]"}]}]"#
        let withText = #"[{"type":"tool_result","tool_use_id":"t1","content":"ok","text":"[Request interrupted by user]"}]"#
        #expect(interruption([assistant(), user(asString)]) == nil)
        #expect(interruption([assistant(), user(asBlock)]) == nil)
        #expect(interruption([assistant(), user(withText)]) == nil)
    }

    @Test func onlyTheExactMarkersCount() {
        #expect(interruption([assistant(), user(#""[Request interrupted by user] and then some""#)]) == nil)
        #expect(interruption([assistant(), user(#""[Request interrupted by user for tool use] not quite""#)]) == nil)
        #expect(interruption([assistant(), user(#"[{"type":"text","text":"[Request interrupted by user because the skill says so]"}]"#)]) == nil)
        #expect(interruption([assistant(), user(#"[{"type":"text","text":" [Request interrupted by user]"}]"#)]) == nil)
    }

    private func meta(_ content: String, uuid: String = "m1") -> String {
        #"{"type":"user","isMeta":true,"isSidechain":false,"uuid":"\#(uuid)","timestamp":"2026-11-19T14:00:07.000Z","message":{"role":"user","content":\#(content)}}"#
    }

    /// The body of a slash command or a skill is written as a user message flagged as meta, and
    /// it comes out of the repository.
    @Test func aMetaMessageIsNeverAnInterruption() {
        #expect(interruption([assistant(), meta(interrupted)]) == nil)
        #expect(interruption([assistant(), meta(#""[Request interrupted by user]""#)]) == nil)
        #expect(interruption([user(#""Go""#, uuid: "u0"), meta(interrupted), assistant()]) == nil)
    }

    @Test func aMetaMessageAfterAnInterruptionDoesNotHideIt() {
        #expect(interruption([assistant(), user(interrupted), meta(#""Caveat: the messages below were generated by a local command""#)])?.id == "u1")
    }

    // MARK: Looking only when something was written

    private func transcript(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "transcript-\(UUID().uuidString).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        return url
    }

    @Test func anUnchangedTranscriptIsNotReadAgain() throws {
        let url = try transcript([assistant(), user(interrupted)])
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .read(let found, let stamp?) = ClaudeTranscript.lookForInterruption(at: url, since: nil) else {
            Issue.record("The first look has nothing to compare with and must read")
            return
        }
        #expect(found?.id == "u1")
        #expect(ClaudeTranscript.lookForInterruption(at: url, since: stamp) == .unchanged)
    }

    @Test func aTranscriptThatGrewIsReadAgain() throws {
        let url = try transcript([assistant()])
        defer { try? FileManager.default.removeItem(at: url) }
        let stamp = try #require(ClaudeTranscript.Stamp(of: url))
        #expect(ClaudeTranscript.lookForInterruption(at: url, since: stamp) == .unchanged)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + user(interrupted)).utf8))
        try handle.close()

        guard case .read(let found, let newStamp?) = ClaudeTranscript.lookForInterruption(at: url, since: stamp) else {
            Issue.record("A longer file must be read")
            return
        }
        #expect(found?.id == "u1")
        #expect(newStamp != stamp)
    }

    @Test func aRewriteOfTheSameLengthIsReadAgain() throws {
        let url = try transcript([assistant("aaaa")])
        defer { try? FileManager.default.removeItem(at: url) }
        let stamp = try #require(ClaudeTranscript.Stamp(of: url))
        try FileManager.default.setAttributes([.modificationDate: stamp.modified.addingTimeInterval(5)], ofItemAtPath: url.path)
        guard case .read = ClaudeTranscript.lookForInterruption(at: url, since: stamp) else {
            Issue.record("A newer modification time must be read")
            return
        }
    }

    @Test func aMissingTranscriptIsLookedForEveryTime() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).jsonl")
        #expect(ClaudeTranscript.lookForInterruption(at: missing, since: nil) == .read(nil, stamp: nil))
        #expect(ClaudeTranscript.Stamp(of: missing) == nil)
    }
}
