import AgentKit
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
        #expect(messages.allSatisfy { $0.event == .turnFinished(message: "I've completed the refactoring.") })
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
