import AgentKit
import Foundation
import Testing

@Suite(.serialized)
struct StatusLineHookTests {
    private static let payload = #"{"session_id":"abc","workspace":{"project_dir":"/nonexistent"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1800003600}}}"#

    private func configDirectory(statusLine: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "claude-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let statusLine {
            let settings = try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": statusLine]])
            try settings.write(to: dir.appending(path: "settings.json"))
        }
        return dir
    }

    @Test func sendsLimitsAndRunsTheUsersStatusLine() async throws {
        let socket = shortSocketURL()
        let server = HookServer(socketURL: socket)
        try server.start()
        defer { server.stop() }
        // Reads its input like a real status line, so a broken pipe would show.
        let config = try configDirectory(statusLine: #"cat | grep -q rate_limits && printf 'mine'"#)
        defer { try? FileManager.default.removeItem(at: config) }

        let sessionID = UUID()
        let run = try runHook(
            arguments: ["statusline"],
            environment: [
                "ARCHIPEL_SESSION_ID": sessionID.uuidString, "ARCHIPEL_SOCKET": socket.path,
                "CLAUDE_CONFIG_DIR": config.path, "PATH": "/usr/bin:/bin",
            ],
            stdin: Self.payload
        )
        #expect(run.status == 0)
        #expect(String(decoding: run.stdout, as: UTF8.self) == "mine")

        let messages = await collect(1, from: server)
        #expect(messages.count == 1)
        #expect(messages.first?.sessionID == sessionID)
        #expect(messages.first?.event == nil)
        #expect(messages.first?.usage?.windows.first?.usedPercent == 42)
    }

    @Test func printsNothingWithoutAStatusLineOfTheirOwn() throws {
        let config = try configDirectory(statusLine: nil)
        defer { try? FileManager.default.removeItem(at: config) }
        let run = try runHook(arguments: ["statusline"], environment: ["CLAUDE_CONFIG_DIR": config.path], stdin: Self.payload)
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
    }

    @Test func neverRunsItself() throws {
        let config = try configDirectory(statusLine: "/somewhere/archipel-hook statusline")
        defer { try? FileManager.default.removeItem(at: config) }
        let run = try runHook(arguments: ["statusline"], environment: ["CLAUDE_CONFIG_DIR": config.path], stdin: Self.payload)
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
    }
}
