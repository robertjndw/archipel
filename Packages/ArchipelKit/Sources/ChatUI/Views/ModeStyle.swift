import ACPKit
import Foundation

extension ChatControl {
    /// How a mode shows in the bar.
    struct ModeStyle: Equatable {
        var symbol: String
        /// The agent acts without asking and without a sandbox: Claude's bypass, Codex's full access.
        var isUnrestricted = false
    }

    /// Agents name their modes freely, so the symbol goes by the words they share: first the ones
    /// in the mode's id and name, then, for a name that says nothing, the ones in its description.
    ///
    /// A mode no word places still gets a symbol of its own, so two of them can be told apart in
    /// the bar: its initial in a circle, or its place among `choices` when another unplaced mode
    /// has the same initial or the name does not start with a letter. A new agent needs no change
    /// here to look right, only to look better.
    static func modeStyle(for choice: ConfigOptionValue, among choices: [ConfigOptionValue] = []) -> ModeStyle {
        if let known = ModeWords.style(for: choice) { return known }
        let initial = ModeWords.initial(of: choice.name)
        let isShared = choices.contains { other in
            other.value != choice.value && ModeWords.style(for: other) == nil && ModeWords.initial(of: other.name) == initial
        }
        if let initial, !isShared { return ModeStyle(symbol: "\(initial).circle") }
        // SF Symbols has the numbers up to 50 in a circle.
        if let index = choices.firstIndex(where: { $0.value == choice.value }), index < 50 {
            return ModeStyle(symbol: "\(index + 1).circle")
        }
        return ModeStyle(symbol: "switch.2")
    }

    /// Nil for anything but a mode with a current choice.
    var currentModeStyle: ModeStyle? {
        guard category == .mode, case let .select(current?, groups) = value else { return nil }
        let choices = groups.flatMap(\.choices)
        guard let choice = choices.first(where: { $0.value == current }) else { return nil }
        return Self.modeStyle(for: choice, among: choices)
    }

    /// The choice after the current one, the first after the last: what Shift-Tab moves the mode to.
    var nextChoice: ConfigOptionValue? {
        nextChoice(after: nil)
    }

    /// The same, going on from `pending` when there is one: the choice that was asked for and
    /// that the agent has not confirmed yet, so the control still shows the one before it.
    func nextChoice(after pending: String?) -> ConfigOptionValue? {
        guard case let .select(current, groups) = value else { return nil }
        let choices = groups.flatMap(\.choices)
        guard choices.count > 1 else { return nil }
        guard let index = choices.firstIndex(where: { $0.value == pending ?? current }) else { return choices.first }
        return choices[(index + 1) % choices.count]
    }
}

/// The words that place a mode, and how they are found in what an agent sends.
enum ModeWords {
    /// One kind of mode. A word is one or more words in a row, and one ending in `*` also stands
    /// for the longer words that start with it ("plan*" for "planning").
    private struct Kind {
        var style: ChatControl.ModeStyle
        /// Looked for in the id and the name.
        var names: [String]
        /// Looked for in the description. Fewer and longer than `names`: prose uses "edit",
        /// "auto" and "default" for anything, where a name of two words means them.
        var prose: [String] = []
    }

    /// In the order they are tried. The modes that take limits away come first, so "Auto (full
    /// access)" is never shown as harmless; then the phrases, which say more than the single
    /// words in them ("Ask before edits" is not an editing mode).
    private static let kinds: [Kind] = [
        Kind(
            style: .init(symbol: "exclamationmark.shield", isUnrestricted: true),
            names: ["bypass*", "full access", "yolo", "danger*", "unrestricted", "skip permission*", "no sandbox"],
            prose: ["bypass*", "full access", "unrestricted", "skip permission*", "no sandbox", "without asking", "without approval"]
        ),
        // Claude's "Don't ask" refuses whatever was not allowed beforehand. It never asks, but
        // it is the opposite of full access.
        Kind(style: .init(symbol: "hand.raised.slash"), names: ["dont ask", "never ask"]),
        Kind(
            style: .init(symbol: "hand.raised"),
            names: ["ask before", "always ask", "ask first"],
            prose: ["always ask*", "ask* before", "ask first", "require* approval"]
        ),
        Kind(style: .init(symbol: "list.clipboard"), names: ["plan*", "architect*"], prose: ["plan*"]),
        Kind(style: .init(symbol: "eye"), names: ["read", "readonly"], prose: ["read only", "readonly"]),
        Kind(
            style: .init(symbol: "pencil"),
            names: ["accept*", "edit*", "write*", "writing", "workspace"],
            prose: ["file edits", "edit* files", "write* files"]
        ),
        Kind(style: .init(symbol: "sparkles"), names: ["auto*", "smart*"]),
        Kind(style: .init(symbol: "hammer"), names: ["build*", "agent", "code", "coder", "act", "implement*"]),
        // A mode called just "Ask" answers questions and changes nothing (Cursor, Zed).
        Kind(style: .init(symbol: "bubble.left"), names: ["ask", "chat", "question*"]),
        Kind(style: .init(symbol: "hand.raised"), names: ["default", "manual*", "approve*", "confirm*", "supervis*"]),
        Kind(style: .init(symbol: "ladybug"), names: ["debug*"], prose: ["debug*"]),
        Kind(style: .init(symbol: "checklist"), names: ["review*", "audit*"], prose: ["review*"]),
        Kind(style: .init(symbol: "magnifyingglass"), names: ["explor*", "research*", "search*"], prose: ["explor*", "research*"]),
    ]

    /// Every symbol a mode can be given by its words, for the tests to hold against SF Symbols.
    static var symbols: [String] { kinds.map(\.style.symbol) }

    /// Nil when neither the names nor the description say what kind of mode this is.
    static func style(for choice: ConfigOptionValue) -> ChatControl.ModeStyle? {
        let names = words(in: "\(choice.value) \(choice.name)")
        if let kind = kinds.first(where: { $0.names.contains { matches($0, in: names) } }) { return kind.style }
        guard let description = choice.description else { return nil }
        let prose = words(in: description)
        return kinds.first { $0.prose.contains { matches($0, in: prose) } }?.style
    }

    /// The text as lowercase words: "acceptEdits" is "accept" and "edits", "read-only" is "read"
    /// and "only", and "Don't" is "dont".
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var word = ""
        var previousWasLowercase = false
        for character in text where character != "'" && character != "’" {
            if character.isLetter || character.isNumber {
                if character.isUppercase, previousWasLowercase, !word.isEmpty {
                    words.append(word)
                    word = ""
                }
                word += character.lowercased()
                previousWasLowercase = character.isLowercase
            } else {
                if !word.isEmpty { words.append(word) }
                word = ""
                previousWasLowercase = false
            }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }

    private static func matches(_ phrase: String, in words: [String]) -> Bool {
        let parts = phrase.split(separator: " ")
        guard words.count >= parts.count else { return false }
        return (0...(words.count - parts.count)).contains { start in
            parts.enumerated().allSatisfy { offset, part in
                let word = words[start + offset]
                return part.hasSuffix("*") ? word.hasPrefix(part.dropLast()) : word == part
            }
        }
    }

    /// The first letter of the name as SF Symbols spells it, "e" for "Éditeur". Nil when the
    /// name starts with anything else.
    static func initial(of name: String) -> Character? {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return nil }
        let plain = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard let letter = plain.first, plain.count == 1, letter.isASCII, letter.isLetter else { return nil }
        return letter
    }
}
