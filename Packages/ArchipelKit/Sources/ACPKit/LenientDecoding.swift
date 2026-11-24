import Foundation

// Agents are written against different revisions of the schema and add fields freely, so
// everything optional is read leniently: a missing, null or mistyped optional field reads as
// absent instead of failing the whole message.

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// Decodes an array, dropping elements that fail to decode instead of failing the array.
    func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
        lenient([Lossy<T>].self, forKey: key)?.compactMap(\.value)
    }

    /// ACP capability markers are `true` or an object such as `{}`. Anything present that is not
    /// null or false counts as supported; a missing marker means unsupported.
    func capability(_ key: Key) -> Bool {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return false }
        if let flag = try? decode(Bool.self, forKey: key) { return flag }
        return true
    }
}

/// Wraps an element so a bad one decodes to nil and the surrounding array keeps going.
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// A string-backed enum whose unknown values are kept or mapped rather than rejected. Public only
/// because the Codable witnesses of public types live in its extension.
public protocol OpenStringEnum: Codable, Hashable, Sendable {
    init(rawString: String)
    var rawString: String { get }
}

extension OpenStringEnum {
    public init(from decoder: any Decoder) throws {
        self.init(rawString: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawString)
    }
}
