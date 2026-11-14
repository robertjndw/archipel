import ArchipelCore
import Darwin
import Foundation
import Synchronization

public struct HookMessage: Equatable, Sendable {
    public var sessionID: UUID
    public var event: AgentEvent?
    public var agentSessionID: String?
    /// Subscription limits, from Claude's status line. Never set together with an event.
    public var usage: ProviderUsage?

    public init(sessionID: UUID, event: AgentEvent?, agentSessionID: String?, usage: ProviderUsage? = nil) {
        self.sessionID = sessionID
        self.event = event
        self.agentSessionID = agentSessionID
        self.usage = usage
    }
}

public enum HookServerError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(path: String, limit: Int)
    case alreadyStarted
    case stopped
    case system(call: String, errno: Int32)

    public var description: String {
        switch self {
        case let .pathTooLong(path, limit):
            "Socket path is \(path.utf8.count) bytes, the limit is \(limit): \(path)"
        case .alreadyStarted:
            "Hook server is already running"
        case .stopped:
            "Hook server was stopped and cannot be restarted"
        case let .system(call, code):
            "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Receives newline-terminated JSON envelopes from `archipel-hook` on a Unix domain socket.
/// Each connection carries one short message, so connections are read to EOF and closed.
/// `messages` finishes when the server is stopped; a stopped server cannot be restarted.
public final class HookServer: Sendable {
    public let socketURL: URL
    public let messages: AsyncStream<HookMessage>

    private enum State {
        case idle
        case running(any DispatchSourceRead)
        case stopped
    }

    private let continuation: AsyncStream<HookMessage>.Continuation
    private let queue = DispatchQueue(label: "archipel.hook-server")
    private let state = Mutex<State>(.idle)

    public init(socketURL: URL) {
        self.socketURL = socketURL
        (messages, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        stop()
    }

    public func start() throws {
        try state.withLock { state in
            switch state {
            case .running: throw HookServerError.alreadyStarted
            case .stopped: throw HookServerError.stopped
            case .idle: break
            }
            let fd = try Self.makeListeningSocket(path: socketURL.path)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let continuation = self.continuation
            let queue = self.queue
            source.setEventHandler {
                Self.acceptPending(on: fd, queue: queue, continuation: continuation)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            state = .running(source)
        }
    }

    public func stop() {
        let previous = state.withLock { state in
            defer { state = .stopped }
            return state
        }
        if case let .running(source) = previous {
            source.cancel()
            unlink(socketURL.path)
        }
        continuation.finish()
    }

    private static func makeListeningSocket(path: String) throws -> Int32 {
        var address = sockaddr_un()
        let limit = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.utf8.count <= limit else { throw HookServerError.pathTooLong(path: path, limit: limit) }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // A previous run that crashed leaves the socket file behind and bind would fail.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookServerError.system(call: "socket", errno: errno) }
        do {
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: path.utf8)
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw HookServerError.system(call: "bind", errno: errno) }
            guard chmod(path, 0o600) == 0 else { throw HookServerError.system(call: "chmod", errno: errno) }
            guard listen(fd, SOMAXCONN) == 0 else { throw HookServerError.system(call: "listen", errno: errno) }
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
                throw HookServerError.system(call: "fcntl", errno: errno)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func acceptPending(
        on listener: Int32,
        queue: DispatchQueue,
        continuation: AsyncStream<HookMessage>.Continuation
    ) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            Connection(fd: fd, queue: queue) { line in
                if let message = decodeEnvelope(line) {
                    continuation.yield(message)
                }
            }.start()
        }
    }

    static func decodeEnvelope(_ line: Data, receivedAt date: Date = .now) -> HookMessage? {
        guard
            let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let session = (envelope["session"] as? String).flatMap(UUID.init(uuidString:)),
            let payload = envelope["payload"] as? [String: Any]
        else { return nil }
        // Not a hook: the status line runs on every redraw and carries no event, only the limits.
        if envelope["source"] as? String == "claude-statusline" {
            guard let usage = UsageDecoder.claudeStatusLine(payload, at: date) else { return nil }
            return HookMessage(sessionID: session, event: nil, agentSessionID: nil, usage: usage)
        }
        guard let source = (envelope["source"] as? String).flatMap(HookSource.init(rawValue:)) else { return nil }
        let decoded = HookDecoder.decode(source: source, payload: payload)
        return HookMessage(sessionID: session, event: decoded.event, agentSessionID: decoded.agentSessionID)
    }
}

/// One accepted client. Only touched on the server queue, which is what makes the
/// unchecked Sendable conformance sound.
private final class Connection: @unchecked Sendable {
    // Claude's Stop payload carries the whole final message; anything beyond this is not a hook.
    private static let maxBytes = 4 << 20

    private let fd: Int32
    private let source: any DispatchSourceRead
    private let onLine: (Data) -> Void
    private var buffer = Data()

    init(fd: Int32, queue: DispatchQueue, onLine: @escaping (Data) -> Void) {
        self.fd = fd
        self.source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.onLine = onLine
    }

    func start() {
        // The handlers keep the connection alive until the source is cancelled.
        source.setEventHandler { self.readAvailable() }
        source.setCancelHandler { close(self.fd) }
        source.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[..<count])
                if buffer.count > Self.maxBytes { return finish(deliver: false) }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN {
                return
            } else {
                return finish(deliver: count == 0)
            }
        }
    }

    private func finish(deliver: Bool) {
        if deliver {
            for line in buffer.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                onLine(Data(line))
            }
        }
        buffer = Data()
        source.cancel()
    }
}
