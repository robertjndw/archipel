import Foundation

/// Checks on the conversation ids agents report. They arrive over the hook socket, which anything
/// running in a session's terminal can write to, and come back as a word on the agent's command
/// line at the next launch. Shell quoting keeps such a word in one piece, but the agent would
/// still read `--dangerously-skip-permissions` as a flag, so an id has to look like one.
public enum AgentSessionID {
    /// The 8-4-4-4-12 hex form, in either case.
    public static func isUUID(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard scalars.count == 36 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard scalar == "-" else { return false }
            } else {
                guard scalar.isASCII, scalar.properties.isASCIIHexDigit else { return false }
            }
        }
        return true
    }

    /// ASCII letters, digits, `-` and `_`, starting with a letter or digit so it can never be an
    /// option. For agents whose id shape is not known more precisely.
    public static func isPlainWord(_ id: String, maxLength: Int = 128) -> Bool {
        let scalars = id.unicodeScalars
        guard let first = scalars.first, scalars.count <= maxLength, isAlphanumeric(first) else { return false }
        return scalars.allSatisfy { isAlphanumeric($0) || $0 == "-" || $0 == "_" }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9": true
        default: false
        }
    }
}
