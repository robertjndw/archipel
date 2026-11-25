import Foundation

public enum Tint: Hashable, Sendable {
    case blue, purple, pink, red, orange, yellow, green, teal, gray
    /// An sRGB color from the color panel. 8 bits a channel because that is all the saved hex
    /// keeps, and anything finer would make a color unequal to itself after a reload.
    case custom(red: UInt8, green: UInt8, blue: UInt8)

    /// In swatch order.
    public static let presets: [Tint] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .gray]

    public var isCustom: Bool {
        if case .custom = self { true } else { false }
    }

    /// The name a preset is saved under, or `#RRGGBB` for a custom color.
    public var storedValue: String {
        switch self {
        case .blue: "blue"
        case .purple: "purple"
        case .pink: "pink"
        case .red: "red"
        case .orange: "orange"
        case .yellow: "yellow"
        case .green: "green"
        case .teal: "teal"
        case .gray: "gray"
        case .custom(let r, let g, let b): String(format: "#%02X%02X%02X", r, g, b)
        }
    }

    public init?(storedValue: String) {
        if let preset = Self.presets.first(where: { $0.storedValue == storedValue }) {
            self = preset
            return
        }
        guard storedValue.count == 7, storedValue.hasPrefix("#"),
              let rgb = UInt32(storedValue.dropFirst(), radix: 16)
        else { return nil }
        self = .custom(red: UInt8(rgb >> 16 & 0xFF), green: UInt8(rgb >> 8 & 0xFF), blue: UInt8(rgb & 0xFF))
    }
}

// Saved as one string, like back when Tint was a String enum, so old workspaces load as is.
// Older builds can't read a `#RRGGBB` tint and will move the workspace file aside as corrupt.
extension Tint: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let tint = Tint(storedValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown tint \"\(value)\"")
        }
        self = tint
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedValue)
    }
}
