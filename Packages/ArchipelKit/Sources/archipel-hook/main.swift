// Forwards one agent hook payload to the Archipel app over its Unix socket.
//
//   Claude Code: archipel-hook                      (payload on stdin)
//   Codex:       archipel-hook codex-notify <json>  (payload appended as the last argument)
//   Claude Code: archipel-hook statusline           (status line input on stdin)
//
// As a hook this runs inside the agent's hook machinery, so it must never print to stdout (Claude
// parses hook stdout), never exit non-zero (exit 2 blocks Claude), and never hang. Every failure
// path therefore ends in a silent exit(0).
//
// As the status line, stdout is what Claude draws under the prompt. The rate limits go to the app,
// then the user's own status line command runs and its output is passed through untouched.

import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
let isStatusLine = arguments.count >= 2 && arguments[1] == "statusline"

// Watchdog: whatever blocks (a stdin that never closes, a wedged socket, a slow status line
// script), the agent gets its exit 0. The user's status line gets more time, since it may run git.
DispatchQueue.global().asyncAfter(deadline: .now() + (isStatusLine ? 5 : 2)) { exit(0) }

func run() {
    let source: String
    let rawPayload: Data
    if arguments.count >= 3, arguments[1] == "codex-notify" {
        source = "codex"
        rawPayload = Data(arguments[arguments.count - 1].utf8)
    } else {
        source = isStatusLine ? "claude-statusline" : "claude"
        rawPayload = FileHandle.standardInput.readDataToEndOfFile()
    }
    let payload = try? JSONSerialization.jsonObject(with: rawPayload)

    if isStatusLine {
        // This runs on every redraw and the input has the whole session state in it. The app only
        // cares about the limits, so send just those, and nothing at all when there are none.
        if let limits = (payload as? [String: Any])?["rate_limits"] {
            forward(["rate_limits": limits], source: source)
        }
    } else if let payload {
        forward(slimmed(payload, rawSize: rawPayload.count), source: source)
    }

    if isStatusLine {
        runUserStatusLine(input: rawPayload, payload: payload as? [String: Any])
    }
}

/// The keys `HookDecoder` in the app reads, for Claude and Codex alike. Keep the two in step.
let decodedKeys = [
    "hook_event_name", "session_id", "agent_id", "tool_name", "notification_type", "message",
    "last_assistant_message", "type", "thread-id", "last-assistant-message",
]

/// The app drops anything over 4 MiB, and a permission request for a large Write carries the
/// whole file in `tool_input`, so the one event the user has to answer would be the one that gets
/// lost. A big payload is therefore cut down to what the app looks at. Small ones go through
/// whole, so a key the app starts reading tomorrow does not need a new helper for the usual case.
func slimmed(_ payload: Any, rawSize: Int) -> Any {
    // Far enough below the app's limit that JSON escaping cannot push the envelope over it.
    guard rawSize > 512 << 10, let object = payload as? [String: Any] else { return payload }
    // The messages only feed a notification and a row's subtitle, neither of which shows this much.
    let longestString = 64 << 10
    var slim: [String: Any] = [:]
    for key in decodedKeys {
        guard let value = object[key] else { continue }
        if let string = value as? String, string.utf8.count > longestString {
            slim[key] = String(String.UnicodeScalarView(string.unicodeScalars.prefix(longestString / 4)))
        } else if value is String {
            slim[key] = value
        }
    }
    // Not a string, so the loop above skips it. Each entry is capped by Claude, and without the
    // list the app could not tell that the agent left something running.
    if let tasks = object["background_tasks"] as? [Any] { slim["background_tasks"] = tasks }
    return slim
}

func forward(_ payload: Any, source: String) {
    let environment = ProcessInfo.processInfo.environment
    guard
        let session = environment["ARCHIPEL_SESSION_ID"], !session.isEmpty,
        let socketPath = environment["ARCHIPEL_SOCKET"], !socketPath.isEmpty
    else { return }

    // Re-serialising guarantees a single line, which is how the server frames messages.
    guard var envelope = try? JSONSerialization.data(
        withJSONObject: ["session": session, "source": source, "payload": payload]
    ) else { return }
    envelope.append(UInt8(ascii: "\n"))

    send(envelope, to: socketPath)
}

/// Archipel's `--settings` outranks the user's own settings, so their status line would vanish inside
/// Archipel. Look it up the way Claude would have without us and run it with the same input.
func runUserStatusLine(input: Data, payload: [String: Any]?) {
    let workspace = payload?["workspace"] as? [String: Any]
    let projectDirectory = (workspace?["project_dir"] as? String) ?? (payload?["cwd"] as? String)
    guard let command = userStatusLineCommand(projectDirectory: projectDirectory) else { return }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    // A folder that has gone away would make run() throw, and the user would lose their status line.
    var isDirectory: ObjCBool = false
    if let projectDirectory, FileManager.default.fileExists(atPath: projectDirectory, isDirectory: &isDirectory), isDirectory.boolValue {
        process.currentDirectoryURL = URL(fileURLWithPath: projectDirectory, isDirectory: true)
    }
    let stdin = Pipe()
    process.standardInput = stdin
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return }
    try? stdin.fileHandleForWriting.write(contentsOf: input)
    try? stdin.fileHandleForWriting.close()
    process.waitUntilExit()
}

/// Same precedence as Claude: local project settings, shared project settings, then user settings.
func userStatusLineCommand(projectDirectory: String?) -> String? {
    let environment = ProcessInfo.processInfo.environment
    var files: [URL] = []
    if let projectDirectory {
        let claude = URL(fileURLWithPath: projectDirectory, isDirectory: true).appending(path: ".claude")
        files += [claude.appending(path: "settings.local.json"), claude.appending(path: "settings.json")]
    }
    let configDirectory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        ?? URL.homeDirectory.appending(path: ".claude", directoryHint: .isDirectory)
    files.append(configDirectory.appending(path: "settings.json"))

    for file in files {
        guard
            let data = try? Data(contentsOf: file),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let statusLine = settings["statusLine"] as? [String: Any]
        else { continue }
        // The first file that sets a status line decides, even when it is not a command we can run.
        guard
            statusLine["type"] as? String == "command",
            let command = statusLine["command"] as? String,
            !command.trimmingCharacters(in: .whitespaces).isEmpty,
            // Someone pasted ours into their own settings; running it again would loop.
            !command.contains("archipel-hook")
        else { return nil }
        return command
    }
    return nil
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
