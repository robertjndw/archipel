import Foundation

/// Any JSON value. Used for payloads ACP leaves open (`rawInput`, `rawOutput`, `_meta`) and for
/// messages this client does not model, so they can be kept instead of failing to decode.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            // Ids and counts round-trip as integers; `1.0` would be a different id to some agents.
            if let integer = Int64(exactly: value) {
                try container.encode(integer)
            } else {
                try container.encode(value)
            }
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

public extension JSONValue {
    var isNull: Bool {
        if case .null = self { true } else { false }
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { value } else { nil }
    }

    var doubleValue: Double? {
        if case let .number(value) = self { value } else { nil }
    }

    /// The number as an integer, when it is one exactly.
    var intValue: Int? {
        if case let .number(value) = self { Int(exactly: value) } else { nil }
    }

    var stringValue: String? {
        if case let .string(value) = self { value } else { nil }
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { value } else { nil }
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { value } else { nil }
    }

    /// The member named `key`, or nil when this is not an object or has no such member.
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// The element at `index`, or nil when this is not an array or the index is out of range.
    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Converts any encodable value, by way of its JSON encoding.
    init(encoding value: some Encodable) throws {
        let data = try ACPCoding.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value as `type`, by way of its JSON encoding.
    func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: ACPCoding.encode(self))
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}

/// The one place that decides how ACP messages are serialized.
enum ACPCoding {
    /// Compact output keeps a message on one line, which the newline framing depends on.
    /// Slashes stay unescaped because paths and URIs are everywhere in ACP and `\/` only bloats them.
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
