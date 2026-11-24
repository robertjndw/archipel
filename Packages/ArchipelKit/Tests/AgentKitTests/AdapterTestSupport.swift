import AgentKit
import Foundation
import Testing

/// The launch context every adapter test builds commands from. The hook path has a space and a
/// quote in it so quoting mistakes show up.
enum LaunchFixture {
    static let sessionID = UUID(uuidString: "6B1D8B39-2C7C-4F5E-9A3E-0F4C3B2A1D00")!
    static let hook = URL(fileURLWithPath: "/Applications/Archipel's Copy.app/Contents/Helpers/archipel-hook")
    static let stableHook = URL(fileURLWithPath: "/Users/me/Library/Application Support/Archipel/bin/archipel-hook")
    static let socket = URL(fileURLWithPath: "/tmp/archipel.sock")

    static func context(agentSessionID: String?, stableHook: URL? = stableHook) -> LaunchContext {
        LaunchContext(
            archipelSessionID: sessionID,
            agentSessionID: agentSessionID,
            hookExecutableURL: hook,
            stableHookURL: stableHook,
            socketURL: socket
        )
    }

    static func expectHookEnvironment(_ command: LaunchCommand) {
        #expect(command.environment["ARCHIPEL_SESSION_ID"] == sessionID.uuidString)
        #expect(command.environment["ARCHIPEL_SOCKET"] == "/tmp/archipel.sock")
    }

    static func settings(after flag: String, in arguments: [String]) throws -> [String: Any] {
        let index = try #require(arguments.firstIndex(of: flag))
        let json = try #require(arguments.indices.contains(index + 1) ? arguments[index + 1] : nil)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}
