import Foundation
import Synchronization

/// Why a connection ended. Delivered as the last event of a connection.
public enum ACPCloseReason: Sendable, Hashable, CustomStringConvertible {
    /// The agent closed its output without the process being seen to exit.
    case endOfStream
    case exited(code: Int32)
    case signaled(Int32)
    /// The agent broke the protocol badly enough that the connection could not go on.
    case protocolError(String)
    /// Writing to the agent failed.
    case transportError(String)
    case closedByClient

    public var description: String {
        switch self {
        case .endOfStream: "The agent closed the connection"
        case let .exited(code): "The agent exited with status \(code)"
        case let .signaled(signal): "The agent was terminated by signal \(signal)"
        case let .protocolError(message): "Protocol error: \(message)"
        case let .transportError(message): "Connection error: \(message)"
        case .closedByClient: "Closed"
        }
    }
}

/// A byte pipe to an agent. One message is written per `send`; reads come back as raw chunks
/// that the connection splits into messages itself.
public protocol ACPTransport: Sendable {
    /// Bytes from the agent in the order received, chunked arbitrarily. Finishes at end of input.
    var incoming: AsyncStream<Data> { get }

    /// Writes one message followed by a newline. `line` must not contain a newline itself.
    func send(_ line: Data) async throws

    /// Why input ended. Asked once, after `incoming` finished.
    func closeReason() async -> ACPCloseReason

    /// Stops the transport, and the agent behind it. Safe to call more than once.
    func close() async
}

public struct ACPTransportClosed: Error, Sendable, Equatable, CustomStringConvertible {
    public init() {}

    public var description: String { "The transport is closed" }
}

/// One end of an in-memory connection, for tests and previews. Everything sent on one end
/// arrives on the other as a single chunk; `sendRaw` lets a test chunk bytes any way it likes.
public final class InMemoryTransport: ACPTransport {
    public let incoming: AsyncStream<Data>
    private let inbox: AsyncStream<Data>.Continuation
    /// Where sends go; nil once this end is closed.
    private let peer = Mutex<AsyncStream<Data>.Continuation?>(nil)

    private init(incoming: AsyncStream<Data>, inbox: AsyncStream<Data>.Continuation) {
        self.incoming = incoming
        self.inbox = inbox
    }

    /// Two ends wired to each other.
    public static func pair() -> (client: InMemoryTransport, agent: InMemoryTransport) {
        let (clientStream, clientInbox) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let (agentStream, agentInbox) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let client = InMemoryTransport(incoming: clientStream, inbox: clientInbox)
        let agent = InMemoryTransport(incoming: agentStream, inbox: agentInbox)
        client.peer.withLock { $0 = agentInbox }
        agent.peer.withLock { $0 = clientInbox }
        return (client, agent)
    }

    public func send(_ line: Data) async throws {
        var framed = line
        framed.append(0x0A)
        try sendRaw(framed)
    }

    /// Delivers bytes to the other end exactly as given, without adding a newline.
    public func sendRaw(_ bytes: Data) throws {
        guard let peer = peer.withLock({ $0 }) else { throw ACPTransportClosed() }
        if case .terminated = peer.yield(bytes) { throw ACPTransportClosed() }
    }

    public func closeReason() async -> ACPCloseReason {
        .endOfStream
    }

    public func close() async {
        closeNow()
    }

    /// Ends both directions: the other end sees end of input, and so does this one.
    public func closeNow() {
        let peer = peer.withLock { peer in
            defer { peer = nil }
            return peer
        }
        peer?.finish()
        inbox.finish()
    }
}
