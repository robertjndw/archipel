import Foundation

/// Text an agent sent, made safe to show on one line of a notification or a sidebar row. It comes
/// from the agent, and through it from whatever the agent read, so anything that could break the
/// line, reorder it on screen or hide part of it is taken out.
public struct DisplayLine: Equatable, Sendable {
    public var text: String
    /// The line shows all there was: nothing was cut off at the limit, and nothing in it draws as
    /// blank. Only then does reading the line tell the user what the agent sent.
    public var isFaithful: Bool

    public enum Blanks: Sendable {
        /// Characters without a shape of their own are dropped, except the joiners and variation
        /// selectors that emoji and several scripts are written with. For text that is only read.
        case dropped
        /// Every run of characters that draw as nothing is shown as `blankMark` and makes the line
        /// unfaithful. For text the user decides on, where `ls` followed by a screenful of
        /// invisible filler must not read as `ls`.
        case marked
    }

    public static let blankMark: Unicode.Scalar = "\u{FFFD}"

    public init(text: String, isFaithful: Bool) {
        self.text = text
        self.isFaithful = isFaithful
    }

    /// `limit` counts the characters kept, without the ellipsis that marks a cut.
    public init(_ source: String, limit: Int, blanks: Blanks) {
        var result = String.UnicodeScalarView()
        var count = 0
        var pendingSpace = false
        var inBlankRun = false
        var faithful = true

        // False when the limit is reached, and the line ends there.
        func append(_ scalar: Unicode.Scalar) -> Bool {
            if count >= limit { return false }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(scalar)
            count += 1
            return true
        }

        for scalar in source.unicodeScalars {
            let fate = Self.fate(of: scalar, blanks: blanks)
            if fate != .blank { inBlankRun = false }
            switch fate {
            case .dropped:
                continue
            case .space:
                pendingSpace = !result.isEmpty
            case .blank:
                faithful = false
                if inBlankRun { continue }
                inBlankRun = true
                fallthrough
            case .kept:
                guard append(fate == .blank ? Self.blankMark : scalar) else {
                    result.append("…")
                    self.text = String(result)
                    self.isFaithful = false
                    return
                }
            }
        }
        self.text = String(result)
        self.isFaithful = faithful
    }

    private enum Fate {
        case kept, space, dropped, blank
    }

    private static func fate(of scalar: Unicode.Scalar, blanks: Blanks) -> Fate {
        let category = scalar.properties.generalCategory
        switch category {
        case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return .space
        default:
            break
        }
        let shapeless = switch category {
        case .format, .surrogate, .privateUse, .unassigned: true
        default: false
        }
        switch blanks {
        case .marked:
            return shapeless || drawsAsBlank(scalar) ? .blank : .kept
        case .dropped:
            // ZWNJ and ZWJ: Persian and Indic text and emoji families need them, and neither can
            // reorder or hide anything.
            if scalar == "\u{200C}" || scalar == "\u{200D}" { return .kept }
            return shapeless ? .dropped : .kept
        }
    }

    /// Default-ignorable code points (Hangul fillers, variation selectors, tags, joiners) take no
    /// space unless a font says otherwise. The rest are assigned a shape that happens to be empty.
    private static func drawsAsBlank(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isDefaultIgnorableCodePoint { return true }
        switch scalar.value {
        case 0x2800, // braille pattern blank
             0xFFFC, // object replacement character
             0x1D159: // musical symbol null notehead
            return true
        default:
            return false
        }
    }

    /// How many columns the text takes, counting East Asian wide characters and emoji as two.
    /// An estimate for judging whether a line fits a banner, not a layout measurement.
    public var columns: Int {
        text.unicodeScalars.reduce(0) { $0 + (Self.isWide($1) ? 2 : 1) }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
