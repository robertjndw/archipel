import AgentKit
import ArchipelCore
import Foundation
import Testing

private final class BundleToken {}

/// `swift test` builds the helper next to the test bundle, so look there.
func hookBinaryURL() throws -> URL {
    let candidates = [Bundle(for: BundleToken.self), Bundle.main].map {
        $0.bundleURL.deletingLastPathComponent().appending(path: "archipel-hook")
    }
    return try #require(
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) },
        "archipel-hook not found next to the test bundle"
    )
}

/// sun_path holds about 104 bytes and NSTemporaryDirectory is long on macOS, so use /tmp.
func shortSocketURL() -> URL {
    URL(fileURLWithPath: "/tmp/ahk-\(UUID().uuidString.prefix(8)).sock")
}

struct HookRun {
    var status: Int32
    var stdout: Data
    var duration: Duration
}

func runHook(arguments: [String] = [], environment: [String: String], stdin: String = "") throws -> HookRun {
    let process = Process()
    process.executableURL = try hookBinaryURL()
    process.arguments = arguments
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output

    let clock = ContinuousClock()
    let start = clock.now
    try process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return HookRun(status: process.terminationStatus, stdout: stdout, duration: clock.now - start)
}

/// Collects `count` messages, or whatever arrived before the timeout.
func collect(_ count: Int, from server: HookServer, timeout: Duration = .seconds(5)) async -> [HookMessage] {
    await withTaskGroup(of: [HookMessage]?.self) { group in
        group.addTask {
            var received: [HookMessage] = []
            for await message in server.messages {
                received.append(message)
                if received.count == count { break }
            }
            return received
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? []
    }
}

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
