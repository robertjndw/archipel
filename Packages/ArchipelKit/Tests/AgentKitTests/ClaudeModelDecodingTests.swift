@testable import AgentKit
import ArchipelCore
import Foundation
import Testing

/// The status line names the model from its first draw, while the context only follows the first reply.
struct ClaudeModelDecodingTests {
    private func decode(_ json: String) throws -> DecodedHook? {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return HookDecoder.decode(source: ClaudeAdapter.statusLineSource, payload: object)
    }

    @Test func aStatusLineBeforeTheFirstReplyStillYieldsTheModel() throws {
        let json = #"{"session_id":"abc","model":{"id":"claude-fable-5","display_name":"Fable 5"},"context_window":{"context_window_size":200000,"total_input_tokens":0,"current_usage":null}}"#
        let decoded = try #require(try decode(json))
        #expect(decoded.context == nil)
        #expect(decoded.model == "Fable 5")
    }

    @Test func aStatusLineWithOnlyAModelStillDecodes() throws {
        #expect(try decode(#"{"model":{"id":"claude-fable-5"}}"#)?.model == "claude-fable-5")
    }

    @Test func anEmptyDisplayNameFallsBackToTheID() throws {
        #expect(try decode(#"{"model":{"id":"claude-fable-5","display_name":""}}"#)?.model == "claude-fable-5")
    }

    @Test func theModelReachesTheHookMessage() throws {
        let session = UUID()
        let line = Data(#"{"session": "\#(session.uuidString)", "source": "claude-statusline", "payload": {"model": {"display_name": "Fable 5"}}}"#.utf8)
        #expect(HookServer.decodeEnvelope(line)?.model == "Fable 5")
    }
}
