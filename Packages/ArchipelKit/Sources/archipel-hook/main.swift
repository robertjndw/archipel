// Forwards one agent hook payload to the Archipel app over its Unix socket.
//
//   Claude Code: archipel-hook                      (payload on stdin)
//   Codex:       archipel-hook codex-notify <json>  (payload appended as the last argument)
//
// This runs inside the agent's hook machinery, so it must never print to stdout (Claude parses
// hook stdout), never exit non-zero (exit 2 blocks Claude), and never hang. Every failure path
// therefore ends in a silent exit(0).

import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)

// Watchdog: whatever blocks (a stdin that never closes, a wedged socket),
// the agent gets its exit 0 within two seconds.
DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(0) }

func run() {
    let environment = ProcessInfo.processInfo.environment
    guard
        let session = environment["ARCHIPEL_SESSION_ID"], !session.isEmpty,
        let socketPath = environment["ARCHIPEL_SOCKET"], !socketPath.isEmpty
    else { return }

    let arguments = CommandLine.arguments
    let source: String
    let rawPayload: Data
    if arguments.count >= 3, arguments[1] == "codex-notify" {
        source = "codex"
        rawPayload = Data(arguments[arguments.count - 1].utf8)
    } else {
        source = "claude"
        rawPayload = FileHandle.standardInput.readDataToEndOfFile()
    }

    // Re-serialising guarantees a single line, which is how the server frames messages.
    guard
        let payload = try? JSONSerialization.jsonObject(with: rawPayload),
        var envelope = try? JSONSerialization.data(
            withJSONObject: ["session": session, "source": source, "payload": payload]
        )
    else { return }
    envelope.append(UInt8(ascii: "\n"))

    send(envelope, to: socketPath)
}

func send(_ data: Data, to path: String) {
    var address = sockaddr_un()
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }

    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return }

    data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return }
            offset += written
        }
    }
}

run()
exit(0)
