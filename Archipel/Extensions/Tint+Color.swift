import AppKit
import ArchipelCore
import SwiftUI

extension Tint {
    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .gray: .gray
        case .custom(let r, let g, let b): Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
    }

    var displayName: String {
        isCustom ? "Custom" : storedValue.capitalized
    }

    /// The nearest custom tint to a color from the color panel. Nil for a color that has no sRGB
    /// equivalent, such as a pattern.
    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        self = .custom(red: channel(rgb.redComponent), green: channel(rgb.greenComponent), blue: channel(rgb.blueComponent))
    }
}
