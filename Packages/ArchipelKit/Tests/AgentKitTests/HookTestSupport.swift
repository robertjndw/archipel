import AgentKit
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

/// A raw client, for the things the helper never does. Reads give up after five seconds so a
/// server that fails to hang up fails the test instead of blocking it.
func connectClient(to socketURL: URL) throws -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketURL.path.utf8) }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        close(fd)
        throw HookServerError.system(call: "connect", errno: errno)
    }
    return fd
}
