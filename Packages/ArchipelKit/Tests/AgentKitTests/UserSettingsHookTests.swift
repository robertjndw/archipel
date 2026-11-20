import AgentKit
import Foundation
import Testing

@Suite(.serialized)
struct UserSettingsHookTests {
    private static let payload = #"{"hook_event_name":"SessionStart","session_id":"abc","source":"clear","reason":"x"}"#

    private func environment(session: UUID? = UUID(), socket: URL?, extra: [String: String] = [:]) -> [String: String] {
        var result = ["PATH": "/usr/bin:/bin"]
        if let session { result["ARCHIPEL_SESSION_ID"] = session.uuidString }
        if let socket { result["ARCHIPEL_SOCKET"] = socket.path }
        return result.merging(extra) { $1 }
    }

    /// Whether anything reached the server within a short wait.
    private func received(from server: HookServer, within timeout: Duration = .milliseconds(400)) async -> [HookMessage] {
        await collect(1, from: server, timeout: timeout)
    }

    @Test func forwardsLikeALaunchHook() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }

        let session = UUID()
        let run = try runHook(
            arguments: [ClaudeUserHooks.modeArgument, socket.path],
            environment: environment(session: session, socket: socket),
            stdin: Self.payload
        )
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)

        let messages = await collect(1, from: server)
        #expect(messages.count == 1)
        #expect(messages.first?.sessionID == session)
        #expect(messages.first?.event != nil)
    }

    @Test func staysSilentInsideAnArchipelLaunchedClaude() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }

        let run = try runHook(
            arguments: [ClaudeUserHooks.modeArgument, socket.path],
            environment: environment(socket: socket, extra: [ClaudeUserHooks.launchedByArchipelVariable: "settings"]),
            stdin: Self.payload
        )
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
        #expect(await received(from: server).isEmpty)
    }

    @Test func staysSilentForAnotherArchipelsSocket() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }

        let other = shortSocketURL()
        let run = try runHook(
            arguments: [ClaudeUserHooks.modeArgument, other.path],
            environment: environment(socket: socket),
            stdin: Self.payload
        )
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
        #expect(await received(from: server).isEmpty)
    }

    @Test func staysSilentOutsideAnArchipelTab() throws {
        let socket = shortSocketURL()
        for env in [environment(session: nil, socket: socket), environment(socket: nil), [:]] {
            let run = try runHook(arguments: [ClaudeUserHooks.modeArgument, socket.path], environment: env, stdin: Self.payload)
            #expect(run.status == 0)
            #expect(run.stdout.isEmpty)
        }
    }

    @Test func survivesBadInputAndAnUnreachableSocket() throws {
        let socket = shortSocketURL()
        for input in ["", "not json", Self.payload] {
            let run = try runHook(
                arguments: [ClaudeUserHooks.modeArgument, socket.path],
                environment: environment(socket: socket),
                stdin: input
            )
            #expect(run.status == 0)
            #expect(run.stdout.isEmpty)
        }
    }

    @Test func reportsItsAncestorsForTheApp() throws {
        let socket = shortSocketURL()
        let listener = socket_listen(at: socket)
        defer { close(listener); unlink(socket.path) }

        let run = try runHook(
            arguments: [ClaudeUserHooks.modeArgument, socket.path],
            environment: environment(socket: socket),
            stdin: Self.payload
        )
        #expect(run.status == 0)

        let client = accept(listener, nil, nil)
        try #require(client >= 0)
        defer { close(client) }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(client, &buffer, buffer.count)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(buffer.prefix(max(count, 0)))) as? [String: Any]
        )
        #expect(envelope["origin"] as? String == "user-settings")
        let ancestors = try #require(envelope["ancestorPIDs"] as? [Int])
        // The test process launched the helper directly, so it is the first ancestor.
        #expect(ancestors.first == Int(getpid()))
        #expect(ancestors.count <= 6)
        #expect(!ancestors.contains(1))
    }

    /// A bare listening socket, to see the envelope exactly as the helper wrote it.
    private func socket_listen(at url: URL) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: url.path.utf8) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        listen(fd, 1)
        return fd
    }
}
