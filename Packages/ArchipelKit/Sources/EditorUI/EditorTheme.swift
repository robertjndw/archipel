import AppKit

/// Colours and metrics shared by the file and diff viewers. Every colour is dynamic, so drawing
/// picks the right variant for the current appearance and a theme switch needs no re-highlighting.
@MainActor
enum EditorTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    static let tabWidth = 4

    static let gutterDigitWidth = ("8" as NSString).size(withAttributes: [.font: gutterFont]).width
    static let characterWidth = ("M" as NSString).size(withAttributes: [.font: font]).width

    /// Fixed so both sides of a diff, and the gutter beside them, always agree on where a line is.
    static let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up) + 2

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = characterWidth * CGFloat(tabWidth)
        style.tabStops = []
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }()

    static var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle]
    }

    static func color(for scope: SyntaxScope) -> NSColor {
        palette[Int(scope.rawValue)]
    }

    /// Xcode's "Default (Light)" and "Default (Dark)" source colours.
    private static let palette: [NSColor] = {
        func pair(_ light: UInt32, _ dark: UInt32) -> NSColor {
            NSColor(name: nil) { $0.isDark ? NSColor(hex: dark) : NSColor(hex: light) }
        }
        let colors: [SyntaxScope: NSColor] = [
            .plain: .textColor,
            .keyword: pair(0x9B2393, 0xFC5FA3),
            .string: pair(0xC41A16, 0xFC6A5D),
            .comment: pair(0x5D6C79, 0x6C7986),
            .number: pair(0x1C00CF, 0xD0BF69),
            .typeName: pair(0x3900A0, 0xD0A8FF),
            .typeDeclaration: pair(0x0B4F79, 0x5DD8FF),
            .declaration: pair(0x0F68A0, 0x41A1C0),
            .functionCall: pair(0x6C36A9, 0xA167E6),
            .preprocessor: pair(0x643820, 0xFD8F3F),
            .attribute: pair(0x815F03, 0xBF8555),
            .url: pair(0x0E0EFF, 0x5482FF),
            .variable: pair(0x326D74, 0x67B7A4),
            .addition: .systemGreen,
            .deletion: .systemRed,
        ]
        let count = Int(SyntaxScope.deletion.rawValue) + 1
        return (0..<count).map { colors[SyntaxScope(rawValue: UInt8($0))!] ?? .textColor }
    }()

    // MARK: Diff

    static let removedLine = tint(.systemRed, light: 0.10, dark: 0.16)
    static let addedLine = tint(.systemGreen, light: 0.10, dark: 0.14)
    static let removedEmphasis = tint(.systemRed, light: 0.22, dark: 0.34)
    static let addedEmphasis = tint(.systemGreen, light: 0.22, dark: 0.30)
    static let removedGutter = tint(.systemRed, light: 0.16, dark: 0.22)
    static let addedGutter = tint(.systemGreen, light: 0.16, dark: 0.20)
    static let filler = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.06) }
    static let foldBackground = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.035) }

    private static func tint(_ base: NSColor, light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { base.withAlphaComponent($0.isDark ? dark : light) }
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
