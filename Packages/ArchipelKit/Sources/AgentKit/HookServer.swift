import ArchipelCore
import Darwin
import Foundation
import Synchronization

/// Which hook configuration a message came through.
public enum HookOrigin: String, Sendable {
    /// The `--settings` the app passes to an agent it launches.
    case launch
    /// The user's own Claude settings, for a Claude started by hand in a shell tab.
    case userSettings = "user-settings"
}

/// The start or end of a Claude conversation, with Claude's `source` or `reason` for it.
public enum HookLifecycle: Equatable, Sendable {
    case started(source: String?)
    case ended(reason: String?)
}

public struct HookMessage: Equatable, Sendable {
    public var sessionID: UUID
    public var event: AgentEvent?
    public var agentSessionID: String?
    /// Subscription limits, from Claude's status line. Never set together with an event.
    public var usage: ProviderUsage?
    public var origin: HookOrigin
    /// The envelope's source, which says which of an adapter's hook configurations sent it.
    public var source: String?
    public var lifecycle: HookLifecycle?
    /// The processes above the hook helper, its parent first, so the app can tell which Claude sent
    /// it. Only hooks from the user's settings carry them, and older helpers send none.
    public var ancestorPIDs: [Int32]

    /// Context window fill, from Claude's status line. Never set together with an event.
    public var context: SessionContext?

    public init(
        sessionID: UUID,
        event: AgentEvent?,
        agentSessionID: String?,
        usage: ProviderUsage? = nil,
        context: SessionContext? = nil,
        origin: HookOrigin = .launch,
        source: String? = nil,
        lifecycle: HookLifecycle? = nil,
        ancestorPIDs: [Int32] = []
    ) {
        self.sessionID = sessionID
        self.event = event
        self.agentSessionID = agentSessionID
        self.usage = usage
        self.context = context
        self.origin = origin
        self.source = source
        self.lifecycle = lifecycle
        self.ancestorPIDs = ancestorPIDs
    }
}

public enum HookServerError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(path: String, limit: Int)
    case alreadyStarted
    case stopped
    /// Another process is listening on the socket, most likely a second copy of the app.
    case socketInUse(path: String)
    case system(call: String, errno: Int32)

    public var description: String {
        switch self {
        case let .pathTooLong(path, limit):
            "Socket path is \(path.utf8.count) bytes, the limit is \(limit): \(path)"
        case .alreadyStarted:
            "Hook server is already running"
        case .stopped:
            "Hook server was stopped and cannot be restarted"
        case let .socketInUse(path):
            "Another Archipel is already listening on \(path)"
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
    /// Decides which adapter reads an envelope, by its `source`.
    public let registry: AgentRegistry

    private enum State {
        case idle
        case running(any DispatchSourceRead, socket: FileIdentity?)
        case stopped
    }

    /// Bounds on what clients may hold. The helper gives up after a second or two on its own, so an
    /// honest connection never comes near the deadline; it is there for a client that connects and
    /// then says nothing, which would otherwise keep its descriptor for good.
    struct Limits: Sendable {
        var readDeadline: TimeInterval = 5
        /// Well under the 256 descriptors a GUI app gets by default, most of which the terminals need.
        var maxConnections = 64
    }

    private let continuation: AsyncStream<HookMessage>.Continuation
    private let queue = DispatchQueue(label: "archipel.hook-server")
    private let state = Mutex<State>(.idle)
    private let limits: Limits

    public convenience init(socketURL: URL, registry: AgentRegistry = .builtIn) {
        self.init(socketURL: socketURL, limits: Limits(), registry: registry)
    }

    init(socketURL: URL, limits: Limits, registry: AgentRegistry = .builtIn) {
        self.socketURL = socketURL
        self.registry = registry
        self.limits = limits
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
            let limits = self.limits
            let registry = self.registry
            let clients = Clients()
            source.setEventHandler {
                Self.acceptPending(on: fd, queue: queue, clients: clients, limits: limits, registry: registry, continuation: continuation)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            state = .running(source, socket: FileIdentity(path: socketURL.path))
        }
    }

    public func stop() {
        let previous = state.withLock { state in
            defer { state = .stopped }
            return state
        }
        if case let .running(source, socket) = previous {
            source.cancel()
            // Someone may have cleared the path and started listening there since. Removing their
            // socket would cut them off from every agent without either side noticing.
            if let socket, FileIdentity(path: socketURL.path) == socket {
                unlink(socketURL.path)
            }
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
        // A previous run that crashed leaves the socket file behind and bind would fail. One that is
        // still running answers, though, and taking the path from it would silence its agents.
        guard !isAnswering(path: path) else { throw HookServerError.socketInUse(path: path) }
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

    private static func isAnswering(path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // A leftover file refuses at once, and so does anything that is not a socket. A listener
        // accepts from its backlog even while its process is busy, so this never waits on it.
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    private static func acceptPending(
        on listener: Int32,
        queue: DispatchQueue,
        clients: Clients,
        limits: Limits,
        registry: AgentRegistry,
        continuation: AsyncStream<HookMessage>.Continuation
    ) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else {
                switch errno {
                case EINTR, ECONNABORTED:
                    continue
                case EAGAIN:
                    return
                default:
                    // Out of descriptors, typically. The pending client keeps the listener readable,
                    // so returning right away would have the source fire again at once and spin.
                    // Sleeping holds up the queue, which is fine: nothing can be accepted anyway.
                    usleep(100_000)
                    return
                }
            }
            guard clients.open < limits.maxConnections else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            clients.open += 1
            let connection = Connection(fd: fd, queue: queue, clients: clients) { line in
                if let message = decodeEnvelope(line, registry: registry) {
                    continuation.yield(message)
                }
            }
            connection.start(deadline: limits.readDeadline)
        }
    }

    static func decodeEnvelope(_ line: Data, receivedAt date: Date = .now, registry: AgentRegistry = .builtIn) -> HookMessage? {
        guard
            let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let session = (envelope["session"] as? String).flatMap(UUID.init(uuidString:)),
            let payload = envelope["payload"] as? [String: Any],
            let source = envelope["source"] as? String,
            let decoded = HookDecoder.decode(source: source, payload: payload, receivedAt: date, registry: registry)
        else { return nil }
        // Older helpers send no origin. Treat a missing or unknown one as `.launch`, which the app
        // only acts on for sessions it launched.
        let origin = (envelope["origin"] as? String).flatMap(HookOrigin.init(rawValue:)) ?? .launch
        return HookMessage(
            sessionID: session,
            event: decoded.event,
            agentSessionID: decoded.agentSessionID,
            usage: decoded.usage,
            context: decoded.context,
            origin: origin,
            source: source,
            lifecycle: decoded.lifecycle,
            ancestorPIDs: ((envelope["ancestorPIDs"] as? [Any]) ?? []).compactMap { ($0 as? Int).flatMap(Int32.init(exactly:)) }
        )
    }
}

/// Which file a path names right now, so a path that was cleared and reused is not taken for the original.
private struct FileIdentity: Equatable {
    var device: dev_t
    var inode: ino_t

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

/// What the connections of one server share. The status line connects on every redraw, so one read
/// buffer is reused rather than a fresh 64 KiB per read. Only touched on the server's serial queue,
/// hence the unchecked Sendable.
private final class Clients: @unchecked Sendable {
    var bytes = [UInt8](repeating: 0, count: 64 * 1024)
    var open = 0
}

/// One accepted client. Only touched on the server queue, which is what makes the
/// unchecked Sendable conformance sound.
private final class Connection: @unchecked Sendable {
    // Claude's Stop payload carries the whole final message; anything beyond this is not a hook.
    private static let maxBytes = 4 << 20

    private let fd: Int32
    private let queue: DispatchQueue
    private let source: any DispatchSourceRead
    private let onLine: (Data) -> Void
    private let clients: Clients
    private var buffer = Data()
    private var isFinished = false

    init(fd: Int32, queue: DispatchQueue, clients: Clients, onLine: @escaping (Data) -> Void) {
        self.fd = fd
        self.queue = queue
        self.clients = clients
        self.source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.onLine = onLine
    }

    func start(deadline: TimeInterval) {
        // The handlers keep the connection alive until the source is cancelled.
        source.setEventHandler { self.readAvailable() }
        source.setCancelHandler {
            close(self.fd)
            self.clients.open -= 1
        }
        source.resume()
        // Weak, so a connection that finished in time is not kept around until the deadline.
        // Whatever arrived by then is dropped: a message only counts once its sender closed.
        queue.asyncAfter(deadline: .now() + deadline) { [weak self] in
            self?.finish(deliver: false)
        }
    }

    private func readAvailable() {
        while !isFinished {
            let count = clients.bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: clients.bytes[..<count])
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
        guard !isFinished else { return }
        isFinished = true
        if deliver {
            for line in buffer.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                onLine(Data(line))
            }
        }
        buffer = Data()
        source.cancel()
    }
}
