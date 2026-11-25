import Foundation

/// A JSON-RPC request id. Each side picks its own, as a string or an integer.
public enum JSONRPCID: Sendable, Hashable, Codable, CustomStringConvertible {
    case int(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self), let integer = Int(exactly: value) {
            self = .int(integer)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "A request id is a string or an integer")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .int(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case let .int(value): String(value)
        case let .string(value): value
        }
    }
}

public struct JSONRPCError: Error, Sendable, Hashable, Codable, CustomStringConvertible {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? container.decode(Int.self, forKey: .code)) ?? Self.internalError
        message = (try? container.decode(String.self, forKey: .message)) ?? ""
        data = try? container.decodeIfPresent(JSONValue.self, forKey: .data)
    }

    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    public static let requestCancelled = -32800
    /// ACP: the agent wants the user to authenticate before it goes on.
    public static let authenticationRequired = -32000
    /// ACP: the session or other resource does not exist.
    public static let resourceNotFound = -32002

    public var isAuthenticationRequired: Bool { code == Self.authenticationRequired }

    public var description: String {
        message.isEmpty ? "JSON-RPC error \(code)" : "\(message) (\(code))"
    }
}

/// One JSON-RPC message, classified by its shape.
public enum JSONRPCMessage: Sendable, Equatable {
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    /// A reply to one of the receiver's requests. The id is nil only for errors about a message
    /// the peer could not even read.
    case response(id: JSONRPCID?, result: Result<JSONValue, JSONRPCError>)

    /// Reads one line. Throws when it is not JSON or not shaped like any JSON-RPC message.
    public static func decode(_ line: Data) throws -> JSONRPCMessage {
        let header = try ACPCoding.decode(JSONRPCHeader.self, from: line)
        switch header.kind {
        case let .request(id, method):
            let envelope = try ACPCoding.decode(ParamsEnvelope<JSONValue>.self, from: line)
            return .request(id: id, method: method, params: envelope.params)
        case let .notification(method):
            let envelope = try ACPCoding.decode(ParamsEnvelope<JSONValue>.self, from: line)
            return .notification(method: method, params: envelope.params)
        case let .response(id, error):
            if let error { return .response(id: id, result: .failure(error)) }
            let envelope = try ACPCoding.decode(ResultEnvelope<JSONValue>.self, from: line)
            return .response(id: id, result: .success(envelope.result ?? .null))
        }
    }

    /// The message as a single line of compact JSON, without the trailing newline.
    public func encoded() throws -> Data {
        switch self {
        case let .request(id, method, params):
            try JSONRPCEncoding.request(id: id, method: method, params: params)
        case let .notification(method, params):
            try JSONRPCEncoding.notification(method: method, params: params)
        case let .response(id, .success(result)):
            try JSONRPCEncoding.response(id: id, result: result)
        case let .response(id, .failure(error)):
            try JSONRPCEncoding.response(id: id, error: error)
        }
    }
}

/// Just enough of a message to tell what it is, without decoding its payload.
struct JSONRPCHeader: Decodable {
    enum Kind {
        case request(JSONRPCID, method: String)
        case notification(method: String)
        case response(JSONRPCID?, error: JSONRPCError?)
    }

    let kind: Kind

    private enum CodingKeys: String, CodingKey {
        case id, method, result, error
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A null id counts as absent: such a "request" could never be answered anyway.
        let id = try? container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        if let method = try container.decodeIfPresent(String.self, forKey: .method) {
            kind = id.map { .request($0, method: method) } ?? .notification(method: method)
        } else if container.contains(.error), !((try? container.decodeNil(forKey: .error)) ?? true) {
            kind = .response(id, error: try container.decode(JSONRPCError.self, forKey: .error))
        } else if container.contains(.result) {
            kind = .response(id, error: nil)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Neither a request, a notification nor a response"))
        }
    }
}

struct ParamsEnvelope<Params: Decodable>: Decodable {
    let params: Params?
}

struct ResultEnvelope<Result: Decodable>: Decodable {
    let result: Result?
}

/// Builds outgoing messages straight from typed payloads, so they are encoded once.
enum JSONRPCEncoding {
    private struct Request<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: JSONRPCID
        let method: String
        let params: Params?
    }

    private struct Notification<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let method: String
        let params: Params?
    }

    private struct Success<Result: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: JSONRPCID?
        let result: Result

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(jsonrpc, forKey: .jsonrpc)
            // JSON-RPC wants the id present even when null.
            try container.encode(id, forKey: .id)
            try container.encode(result, forKey: .result)
        }

        private enum CodingKeys: String, CodingKey { case jsonrpc, id, result }
    }

    private struct Failure: Encodable {
        let jsonrpc = "2.0"
        let id: JSONRPCID?
        let error: JSONRPCError

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(jsonrpc, forKey: .jsonrpc)
            try container.encode(id, forKey: .id)
            try container.encode(error, forKey: .error)
        }

        private enum CodingKeys: String, CodingKey { case jsonrpc, id, error }
    }

    static func request(id: JSONRPCID, method: String, params: (some Encodable)?) throws -> Data {
        try ACPCoding.encode(Request(id: id, method: method, params: params))
    }

    static func notification(method: String, params: (some Encodable)?) throws -> Data {
        try ACPCoding.encode(Notification(method: method, params: params))
    }

    static func response(id: JSONRPCID?, result: some Encodable) throws -> Data {
        try ACPCoding.encode(Success(id: id, result: result))
    }

    static func response(id: JSONRPCID?, error: JSONRPCError) throws -> Data {
        try ACPCoding.encode(Failure(id: id, error: error))
    }
}

/// Splits a byte stream into newline-delimited messages.
///
/// Splits strictly on byte 0x0A. Line APIs such as `FileHandle.bytes.lines` also break on
/// U+2028 and U+2029, which JSON allows unescaped inside strings, so they would cut a message
/// in half. A trailing `\r` is dropped and blank lines are skipped.
public struct JSONRPCLineFramer: Sendable {
    /// Lines longer than this are a protocol violation rather than a message worth buffering.
    public let maximumLineLength: Int
    private var buffer = Data()
    /// Where to resume looking for a newline, so a long line arriving in many chunks is scanned once.
    private var scanned = 0

    public struct LineTooLong: Error, Sendable, Equatable {
        public let limit: Int
    }

    public init(maximumLineLength: Int = 256 << 20) {
        self.maximumLineLength = maximumLineLength
    }

    /// Bytes received but not yet terminated by a newline.
    public var pendingByteCount: Int { buffer.count }

    /// Adds a chunk and returns every message it completed, in order.
    public mutating func append(_ chunk: Data) throws(LineTooLong) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        var lineStart = buffer.startIndex
        var searchFrom = buffer.startIndex + scanned
        while let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
            var end = newline
            if end > lineStart, buffer[end - 1] == 0x0D { end -= 1 }
            let line = buffer[lineStart..<end]
            if line.contains(where: { !Self.isWhitespace($0) }) {
                lines.append(Data(line))
            }
            lineStart = newline + 1
            searchFrom = lineStart
        }
        if lineStart > buffer.startIndex {
            buffer = Data(buffer[lineStart...])
        }
        scanned = buffer.count
        if buffer.count > maximumLineLength { throw LineTooLong(limit: maximumLineLength) }
        return lines
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D
    }
}
