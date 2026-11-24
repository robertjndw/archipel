import Foundation

/// Splits a user-typed argument string the way a shell would for the simple cases:
/// whitespace separates words, single and double quotes group, backslash escapes
/// the next character outside single quotes. No expansion of any kind happens.
public enum ArgumentSplitter {
    public static func split(_ text: String) -> [String] {
        parse(text).words
    }

    /// False for an unterminated quote or a trailing backslash. `split` still returns what was
    /// typed so far, so this is the only way to tell such input from a deliberate one.
    public static func isWellFormed(_ text: String) -> Bool {
        parse(text).isWellFormed
    }

    private static func parse(_ text: String) -> (words: [String], isWellFormed: Bool) {
        var words: [String] = []
        var current = ""
        // A quoted empty string ("") is still a word, so track it apart from `current`.
        var hasWord = false
        var quote: Character?
        var escaping = false

        for character in text {
            if escaping {
                current.append(character)
                escaping = false
            } else if character == "\\", quote != "'" {
                escaping = true
                hasWord = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                hasWord = true
            } else if character.isWhitespace {
                if hasWord { words.append(current) }
                current = ""
                hasWord = false
            } else {
                current.append(character)
                hasWord = true
            }
        }
        // An unterminated quote or trailing backslash keeps what was typed so far.
        if hasWord { words.append(current) }
        return (words, quote == nil && !escaping)
    }
}
