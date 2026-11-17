@testable import AgentKit
import ArchipelCore
import Foundation
import Testing

@Suite(.serialized)
struct HookServerTests {
    @Test func claudeHookThroughRealBinary() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socket.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)

        let sessionID = UUID()
        let run = try runHook(
            environment: ["ARCHIPEL_SESSION_ID": sessionID.uuidString, "ARCHIPEL_SOCKET": socket.path],
            stdin: Fixtures.permissionRequest
        )
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)

        let messages = await collect(1, from: server)
        #expect(messages == [HookMessage(
            sessionID: sessionID,
            event: .attentionRequested(.permission, message: "Bash"),
            agentSessionID: Fixtures.claudeSessionID
        )])
    }

    @Test func codexNotifyThroughRealBinary() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }

        let sessionID = UUID()
        let run = try runHook(
            arguments: ["codex-notify", Fixtures.codexTurnComplete],
            environment: ["ARCHIPEL_SESSION_ID": sessionID.uuidString, "ARCHIPEL_SOCKET": socket.path]
        )
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)

        let messages = await collect(1, from: server)
        #expect(messages == [HookMessage(
            sessionID: sessionID,
            event: .turnFinished(message: "Rename complete."),
            agentSessionID: "0199a213-81c0-7800-8aa1-bbab2a035a53"
        )])
    }

    @Test func manyConcurrentClients() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }

        let ids = (0..<24).map { _ in UUID() }
        try await withThrowingTaskGroup(of: Int32.self) { group in
            for id in ids {
                group.addTask {
                    try runHook(
                        environment: ["ARCHIPEL_SESSION_ID": id.uuidString, "ARCHIPEL_SOCKET": socket.path],
                        stdin: Fixtures.stop
                    ).status
                }
            }
            for try await status in group { #expect(status == 0) }
        }

        let messages = await collect(ids.count, from: server)
        #expect(Set(messages.map(\.sessionID)) == Set(ids))
        #expect(messages.allSatisfy { $0.event == .turnFinished(message: "I've completed the refactoring.", backgroundTasks: 0) })
    }

    @Test func garbageIsIgnoredAndServerKeepsWorking() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }

        // Not JSON on stdin: the helper drops it silently.
        let bad = try runHook(
            environment: ["ARCHIPEL_SESSION_ID": UUID().uuidString, "ARCHIPEL_SOCKET": socket.path],
            stdin: "not json"
        )
        #expect(bad.status == 0)
        // Not a UUID: the server drops the envelope.
        _ = try runHook(
            environment: ["ARCHIPEL_SESSION_ID": "nope", "ARCHIPEL_SOCKET": socket.path],
            stdin: Fixtures.stop
        )

        let sessionID = UUID()
        _ = try runHook(
            environment: ["ARCHIPEL_SESSION_ID": sessionID.uuidString, "ARCHIPEL_SOCKET": socket.path],
            stdin: Fixtures.sessionStart
        )
        let messages = await collect(1, from: server)
        #expect(messages.map(\.sessionID) == [sessionID])
        #expect(messages.first?.event == .sessionStarted)
    }

    @Test func replacesStaleSocketFile() throws {
        let socket = shortSocketURL()
        FileManager.default.createFile(atPath: socket.path, contents: Data("stale".utf8))
        let server = HookServer(socketURL: socket)
        try server.start()
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: socket.path))
        #expect(throws: HookServerError.stopped) { try server.start() }
    }

    @Test func secondServerLeavesARunningOneAlone() async throws {
        let socket = shortSocketURL()
        let first = HookServer(socketURL: socket)
        try first.start()
        defer { first.stop() }

        let second = HookServer(socketURL: socket)
        #expect(throws: HookServerError.socketInUse(path: socket.path)) { try second.start() }
        second.stop()
        #expect(FileManager.default.fileExists(atPath: socket.path))

        let sessionID = UUID()
        _ = try runHook(
            environment: ["ARCHIPEL_SESSION_ID": sessionID.uuidString, "ARCHIPEL_SOCKET": socket.path],
            stdin: Fixtures.stop
        )
        #expect(await collect(1, from: first).map(\.sessionID) == [sessionID])
    }

    @Test func stopKeepsASocketThatSomeoneElseTookOver() async throws {
        let socket = shortSocketURL()
        let first = HookServer(socketURL: socket)
        try first.start()
        // What clearing the support folder by hand does while the app is running.
        try FileManager.default.removeItem(at: socket)
        let second = HookServer(socketURL: socket)
        try second.start()
        defer { second.stop() }

        first.stop()
        #expect(FileManager.default.fileExists(atPath: socket.path))

        let sessionID = UUID()
        _ = try runHook(
            environment: ["ARCHIPEL_SESSION_ID": sessionID.uuidString, "ARCHIPEL_SOCKET": socket.path],
            stdin: Fixtures.stop
        )
        #expect(await collect(1, from: second).map(\.sessionID) == [sessionID])
    }

    @Test func silentClientIsDroppedAtTheDeadline() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket, limits: .init(readDeadline: 0.3))
        try server.start()
        defer { server.stop() }

        let client = try connectClient(to: socket)
        defer { close(client) }
        // Half a message and then nothing, like a helper that got stuck.
        #expect(write(client, "{", 1) == 1)
        let clock = ContinuousClock()
        let start = clock.now
        var byte: UInt8 = 0
        // Blocks until the server hangs up; the receive timeout fails the test instead of hanging it.
        #expect(read(client, &byte, 1) == 0)
        #expect(clock.now - start < .seconds(3))

        let sessionID = UUID()
        _ = try runHook(
            environment: ["ARCHIPEL_SESSION_ID": sessionID.uuidString, "ARCHIPEL_SOCKET": socket.path],
            stdin: Fixtures.stop
        )
        #expect(await collect(1, from: server).map(\.sessionID) == [sessionID])
    }

    @Test func connectionsBeyondTheCapAreTurnedAway() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket, limits: .init(readDeadline: 30, maxConnections: 2))
        try server.start()
        defer { server.stop() }

        let first = try connectClient(to: socket)
        let second = try connectClient(to: socket)
        defer { close(second) }
        // The server accepts in order, so by the time it reaches this one both slots are taken.
        let extra = try connectClient(to: socket)
        defer { close(extra) }
        var byte: UInt8 = 0
        #expect(read(extra, &byte, 1) == 0)

        // A slot comes back as soon as a client leaves.
        close(first)
        try await Task.sleep(for: .milliseconds(200))
        let sessionID = UUID()
        _ = try runHook(
            environment: ["ARCHIPEL_SESSION_ID": sessionID.uuidString, "ARCHIPEL_SOCKET": socket.path],
            stdin: Fixtures.stop
        )
        #expect(await collect(1, from: server).map(\.sessionID) == [sessionID])
    }

    @Test func oversizedPermissionRequestStillArrives() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }

        // A Write of a file larger than the server's 4 MiB cap on one message.
        let content = String(repeating: "let x = \"a/b\"\\n", count: 400_000)
        let payload: [String: Any] = [
            "session_id": Fixtures.claudeSessionID, "hook_event_name": "PermissionRequest", "tool_name": "Write",
            "tool_input": ["file_path": "/tmp/big.swift", "content": content],
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        #expect(json.utf8.count > 4 << 20)

        let sessionID = UUID()
        let run = try runHook(
            environment: ["ARCHIPEL_SESSION_ID": sessionID.uuidString, "ARCHIPEL_SOCKET": socket.path],
            stdin: json
        )
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
        #expect(await collect(1, from: server) == [HookMessage(
            sessionID: sessionID,
            event: .attentionRequested(.permission, message: "Write"),
            agentSessionID: Fixtures.claudeSessionID
        )])
    }

    @Test func oversizedFinalMessageIsCutShortNotLost() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }

        let payload: [String: Any] = [
            "session_id": Fixtures.claudeSessionID, "hook_event_name": "Stop",
            "last_assistant_message": "Done. " + String(repeating: "\u{e9}", count: 3 << 20),
        ]
        let sessionID = UUID()
        _ = try runHook(
            environment: ["ARCHIPEL_SESSION_ID": sessionID.uuidString, "ARCHIPEL_SOCKET": socket.path],
            stdin: String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        )
        let message = try #require(await collect(1, from: server).first)
        guard case .turnFinished(let text?, _) = message.event else {
            Issue.record("expected a finished turn with its message, got \(String(describing: message.event))")
            return
        }
        #expect(text.hasPrefix("Done. \u{e9}"))
        #expect(text.utf8.count < 64 << 10)
    }

    @Test func rejectsOverlongPath() {
        let path = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        let server = HookServer(socketURL: URL(fileURLWithPath: path))
        #expect(throws: HookServerError.pathTooLong(path: path, limit: 103)) { try server.start() }
    }

    @Test func helperExitsQuietlyWithoutApp() throws {
        let missing = try runHook(
            environment: ["ARCHIPEL_SESSION_ID": UUID().uuidString, "ARCHIPEL_SOCKET": "/tmp/ahk-missing.sock"],
            stdin: Fixtures.stop
        )
        #expect(missing.status == 0)
        #expect(missing.stdout.isEmpty)
        #expect(missing.duration < .seconds(1.5))

        let noEnvironment = try runHook(environment: [:], stdin: Fixtures.stop)
        #expect(noEnvironment.status == 0)
        #expect(noEnvironment.stdout.isEmpty)
    }
}
