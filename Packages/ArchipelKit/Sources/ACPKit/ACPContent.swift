import Foundation

/// A piece of content in a prompt, a message chunk or a tool call.
public enum ContentBlock: Sendable, Hashable, Codable {
    case text(String)
    /// Base64 image data. Agents only accept it when they advertise `promptCapabilities.image`.
    case image(data: String, mimeType: String, uri: String? = nil)
    case audio(data: String, mimeType: String)
    case resourceLink(ResourceLink)
    /// Inline file contents. Agents only accept it when they advertise `embeddedContext`.
    case resource(EmbeddedResource)
    /// A block type this client does not know, kept as sent.
    case unknown(JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type, text, data, mimeType, uri, resource
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = container.lenient(String.self, forKey: .type) ?? ""
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            self = .image(
                data: container.lenient(String.self, forKey: .data) ?? "",
                mimeType: container.lenient(String.self, forKey: .mimeType) ?? "",
                uri: container.lenient(String.self, forKey: .uri)
            )
        case "audio":
            self = .audio(
                data: container.lenient(String.self, forKey: .data) ?? "",
                mimeType: container.lenient(String.self, forKey: .mimeType) ?? ""
            )
        case "resource_link":
            self = .resourceLink(try ResourceLink(from: decoder))
        case "resource":
            self = .resource(try container.decode(EmbeddedResource.self, forKey: .resource))
        default:
            self = .unknown(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case let .unknown(raw) = self {
            return try raw.encode(to: encoder)
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .image(data, mimeType, uri):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encodeIfPresent(uri, forKey: .uri)
        case let .audio(data, mimeType):
            try container.encode("audio", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        case let .resourceLink(link):
            try container.encode("resource_link", forKey: .type)
            try link.encode(to: encoder)
        case let .resource(resource):
            try container.encode("resource", forKey: .type)
            try container.encode(resource, forKey: .resource)
        case .unknown:
            break
        }
    }

    /// The text of a text block, nil for every other kind.
    public var text: String? {
        if case let .text(text) = self { text } else { nil }
    }
}

/// A reference to a file or other resource the agent can read itself.
public struct ResourceLink: Sendable, Hashable, Codable {
    public var uri: String
    public var name: String
    public var mimeType: String?
    public var title: String?
    public var description: String?
    public var size: Int?

    public init(uri: String, name: String, mimeType: String? = nil, title: String? = nil, description: String? = nil, size: Int? = nil) {
        self.uri = uri
        self.name = name
        self.mimeType = mimeType
        self.title = title
        self.description = description
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case uri, name, mimeType, title, description, size
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uri = try container.decode(String.self, forKey: .uri)
        // The name is required by the schema but only ever shown, so a missing one falls back to the uri.
        name = container.lenient(String.self, forKey: .name) ?? uri
        mimeType = container.lenient(String.self, forKey: .mimeType)
        title = container.lenient(String.self, forKey: .title)
        description = container.lenient(String.self, forKey: .description)
        size = container.lenient(Int.self, forKey: .size)
    }
}

/// File contents sent inline with a prompt.
public struct EmbeddedResource: Sendable, Hashable, Codable {
    public enum Contents: Sendable, Hashable {
        case text(String)
        /// Base64 data.
        case blob(String)
    }

    public var uri: String
    public var mimeType: String?
    public var contents: Contents

    public init(uri: String, mimeType: String? = nil, contents: Contents) {
        self.uri = uri
        self.mimeType = mimeType
        self.contents = contents
    }

    private enum CodingKeys: String, CodingKey {
        case uri, mimeType, text, blob
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uri = container.lenient(String.self, forKey: .uri) ?? ""
        mimeType = container.lenient(String.self, forKey: .mimeType)
        if let text = container.lenient(String.self, forKey: .text) {
            contents = .text(text)
        } else {
            contents = .blob(try container.decode(String.self, forKey: .blob))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uri, forKey: .uri)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        switch contents {
        case let .text(text): try container.encode(text, forKey: .text)
        case let .blob(blob): try container.encode(blob, forKey: .blob)
        }
    }
}
