@testable import AgentKit
import ArchipelCore
import Foundation
import Testing

/// Clients that misbehave in ways the helper never does, talking to the server over a real socket.
@Suite(.serialized)
struct HookServerEdgeCaseTests {
    @Test func everyLineOfAConnectionArrivesEvenWhenSplitAcrossWrites() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }

        let first = UUID()
        let second = UUID()
        let bytes = Array((envelope(first, message: "one") + "\n\n" + envelope(second, message: "two") + "\n").utf8)
        let client = try connectClient(to: socket)
        // One byte at a time, so the server has to put the lines together across many reads.
        for byte in bytes {
            var byte = byte
            #expect(write(client, &byte, 1) == 1)
        }
        close(client)

        let messages = await collect(2, from: server)
        #expect(messages.map(\.sessionID) == [first, second])
        #expect(messages.map(\.event) == [.turnFinished(message: "one"), .turnFinished(message: "two")])
    }

    @Test func aMessageCountsOnlyOnceItsSenderHasClosed() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket, limits: .init(readDeadline: 0.3))
        try server.start()
        defer { server.stop() }

        // A whole line, but the connection stays open past the deadline.
        let held = try connectClient(to: socket)
        defer { close(held) }
        let line = Array((envelope(UUID(), message: "held") + "\n").utf8)
        #expect(write(held, line, line.count) == line.count)
        var byte: UInt8 = 0
        #expect(read(held, &byte, 1) == 0)

        let delivered = UUID()
        try send(envelope(delivered, message: "sent") + "\n", to: socket)
        #expect(await collect(1, from: server).map(\.sessionID) == [delivered])
    }

    @Test func oversizedConnectionIsDroppedAndTheServerCarriesOn() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }

        // Decodable apart from its size, so only the cap can be what drops it.
        let big = envelope(UUID(), message: String(repeating: "x", count: 5 << 20)) + "\n"
        try send(big, to: socket, toleratingHangUp: true)

        let sessionID = UUID()
        try send(envelope(sessionID, message: "small") + "\n", to: socket)
        #expect(await collect(1, from: server).map(\.sessionID) == [sessionID])
    }

    @Test func timedOutClientsGiveTheirSlotBack() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket, limits: .init(readDeadline: 0.3, maxConnections: 1))
        try server.start()
        defer { server.stop() }

        let silent = try connectClient(to: socket)
        defer { close(silent) }
        var byte: UInt8 = 0
        // The server hangs up and gives the slot back in one step on its queue, so once this read
        // sees the hang-up, the next connection is accepted.
        #expect(read(silent, &byte, 1) == 0)

        let sessionID = UUID()
        _ = try runHook(
            environment: ["ARCHIPEL_SESSION_ID": sessionID.uuidString, "ARCHIPEL_SOCKET": socket.path],
            stdin: Fixtures.stop
        )
        #expect(await collect(1, from: server).map(\.sessionID) == [sessionID])
    }

    @Test func stopFinishesTheStreamAndIsSafeTwice() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket)
        try server.start()
        let open = try connectClient(to: socket)
        defer { close(open) }
        // Whether the server got to accept it before the stop is up to timing; either way a late
        // write must fail quietly rather than raise SIGPIPE in the test process.
        var on: Int32 = 1
        setsockopt(open, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        server.stop()
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: socket.path))
        var count = 0
        for await _ in server.messages { count += 1 }
        #expect(count == 0)
        #expect(throws: HookServerError.stopped) { try server.start() }

        // A client still connected from before the stop goes nowhere and harms nothing.
        let line = Array((envelope(UUID(), message: "late") + "\n").utf8)
        _ = write(open, line, line.count)
    }

    @Test func startCreatesTheSocketsFolder() throws {
        let folder = URL(fileURLWithPath: "/tmp/ahk-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appending(path: "nested/hook.sock")
        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socket.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSocket)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    }

    @Test func leftoverSocketOfADeadServerIsReplaced() async throws {
        let socket = shortSocketURL()
        // A socket file nobody listens on any more, as a crash leaves it.
        let dead = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socket.path.utf8) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(dead, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        close(dead)
        #expect(FileManager.default.fileExists(atPath: socket.path))

        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }
        let sessionID = UUID()
        try send(envelope(sessionID, message: "after crash") + "\n", to: socket)
        #expect(await collect(1, from: server).map(\.sessionID) == [sessionID])
    }

    // MARK: Envelopes

    @Test func envelopesThatAreNotHooksAreDropped() {
        let session = UUID().uuidString
        func decode(_ json: String) -> HookMessage? {
            HookServer.decodeEnvelope(Data(json.utf8), receivedAt: Date(timeIntervalSince1970: 1_000))
        }
        #expect(decode(#"{"session": "\#(session)", "source": "gemini", "payload": {}}"#) == nil)
        #expect(decode(#"{"session": "\#(session)", "source": "claude", "payload": []}"#) == nil)
        #expect(decode(#"{"session": "\#(session)", "payload": {"hook_event_name": "Stop"}}"#) == nil)
        #expect(decode(#"{"session": 7, "source": "claude", "payload": {}}"#) == nil)
        #expect(decode(#"["not", "an", "object"]"#) == nil)
        #expect(decode("") == nil)
        // The status line with nothing usable in it is no message at all, not an empty event.
        #expect(decode(#"{"session": "\#(session)", "source": "claude-statusline", "payload": {"rate_limits": {}}}"#) == nil)
    }

    @Test func statusLineEnvelopeCarriesOnlyUsage() throws {
        let session = UUID()
        let json = #"""
        {"session": "\#(session.uuidString)", "source": "claude-statusline",
         "payload": {"rate_limits": {"five_hour": {"used_percentage": 250, "resets_at": 2000}}}}
        """#
        let message = try #require(HookServer.decodeEnvelope(Data(json.utf8), receivedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(message.sessionID == session)
        #expect(message.event == nil)
        #expect(message.agentSessionID == nil)
        // Clamped, since the status bar draws it as a fraction of a bar.
        #expect(message.usage?.windows == [UsageWindow(usedPercent: 100, windowMinutes: 300, resetsAt: Date(timeIntervalSince1970: 2000))])
    }

    @Test func statusLineEnvelopeWithOnlyContextOrOnlyUsage() throws {
        let session = UUID().uuidString
        func decode(_ payload: String) -> HookMessage? {
            let json = #"{"session": "\#(session)", "source": "claude-statusline", "payload": \#(payload)}"#
            return HookServer.decodeEnvelope(Data(json.utf8), receivedAt: Date(timeIntervalSince1970: 1_000))
        }
        let window = #""context_window": {"total_input_tokens": 1000, "context_window_size": 200000, "current_usage": {}}"#
        let limits = #""rate_limits": {"five_hour": {"used_percentage": 5, "resets_at": 2000}}"#

        let onlyContext = try #require(decode("{\(window)}"))
        #expect(onlyContext.usage == nil)
        #expect(onlyContext.context?.usedTokens == 1000)
        #expect(onlyContext.event == nil)

        let onlyUsage = try #require(decode("{\(limits)}"))
        #expect(onlyUsage.usage != nil)
        #expect(onlyUsage.context == nil)

        let both = try #require(decode("{\(window), \(limits)}"))
        #expect(both.usage != nil && both.context != nil)

        #expect(decode(#"{"context_window": {"total_input_tokens": 0, "context_window_size": 200000, "current_usage": null}}"#) == nil)
    }

    // MARK: Helpers

    private func envelope(_ session: UUID, message: String) -> String {
        let payload: [String: Any] = [
            "session_id": Fixtures.claudeSessionID, "hook_event_name": "Stop", "last_assistant_message": message,
        ]
        let data = try! JSONSerialization.data(withJSONObject: ["session": session.uuidString, "source": "claude", "payload": payload])
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes everything and closes. A server that hangs up early, which is what the size cap does,
    /// is only allowed when `toleratingHangUp` says so.
    private func send(_ text: String, to socket: URL, toleratingHangUp: Bool = false) throws {
        let client = try connectClient(to: socket)
        defer { close(client) }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            if written <= 0 {
                // The error for a hang-up depends on how far the server got with closing the socket.
                if toleratingHangUp && [EPIPE, ECONNRESET, ENOTCONN].contains(errno) { return }
                throw HookServerError.system(call: "write", errno: errno)
            }
            offset += written
        }
    }
}
