import Foundation

/// A key the app presses in an agent's terminal to answer a prompt. Real key presses, not pasted
/// text: both agents read their menus key by key, and a bracketed paste would be taken as input.
public enum PromptKey: Equatable, Sendable {
    case escape
    case enter
    case character(Character)
}

/// The yes/no approval menu Claude Code or Codex draws when it wants permission, read back from
/// the terminal screen so an answer is only typed when that menu is really what the agent shows.
///
/// Both agents draw a numbered list, the cursor marker in front of the focused row:
///
///     Do you want to proceed?                      Would you like to run the following command?
///     ❯ 1. Yes                                     › 1. Yes, proceed (y)
///       2. Yes, and don't ask again for ...          2. Yes, and don't ask again for this command (a)
///       3. No, and tell Claude what to do ... (esc)  3. No, and tell Codex what to do differently (esc)
public struct ApprovalPrompt: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var number: Int
        /// The whole label, including the lines it wrapped onto in a narrow pane.
        public var label: String
        /// The key shown in parentheses at the end of the row, e.g. "y" or "esc".
        public var shortcut: String?
        /// Whether the row carries the selection cursor, i.e. Return would pick it.
        public var isFocused: Bool
    }

    public var options: [Option]
    /// The narrowest "yes": a one-off approval, never one that also changes future permissions.
    public var allow: PromptKey
    /// Esc is what both agents bind to rejecting the request and handing the turn back.
    public var deny: PromptKey

    /// How many non-empty lines may follow the menu. The agents put a hint or a status line or two
    /// below it; a list further up is part of the transcript, not something waiting for an answer.
    static let maximumLinesBelowMenu = 6

    /// Nil unless the bottom of the screen shows a live numbered menu with a one-off "Yes" and a "No".
    public static func parse(screen: String) -> ApprovalPrompt? {
        guard let scan = scanTrailingMenu(in: screen),
              // Text between two rows that is not glued to either could be the rest of a label we
              // failed to attach, so we cannot be sure what pressing a row's key would agree to.
              !scan.hasStrayText,
              scan.options.count(where: \.isFocused) == 1
        else { return nil }
        let options = scan.options
        guard options.contains(where: { isRejection($0.label) }),
              let yes = options.first(where: { isOneOffApproval($0.label) })
        else { return nil }
        let allow: PromptKey
        if let shortcut = yes.shortcut, shortcut.count == 1, let letter = shortcut.first, letter.isLetter {
            allow = .character(letter)
        } else if yes.number <= 9, let digit = String(yes.number).first {
            allow = .character(digit)
        } else {
            return nil
        }
        return ApprovalPrompt(options: options, allow: allow, deny: .escape)
    }

    /// The live numbered menu at the bottom of the screen, if there is one. Any such menu, approval
    /// or not, means typed text would be read as a choice rather than as a message.
    ///
    /// A menu only counts while one of its rows has the selection cursor: a numbered list at the end
    /// of the agent's own message looks the same otherwise, and is just transcript.
    public static func trailingMenu(in screen: String) -> [Option]? {
        scanTrailingMenu(in: screen)?.options
    }

    private struct Scan {
        var options: [Option]
        var hasStrayText: Bool
    }

    private static func scanTrailingMenu(in screen: String) -> Scan? {
        var menu: [Option] = []
        // The raw text of the last row so far, its wrapped lines joined; parsed once it is complete
        // so a shortcut hint that wrapped to the next line is still found at the end.
        var lastRowText = ""
        var lastRowFocused = false
        // Whether the line above belongs to the last row, so the next unnumbered line continues it.
        // A blank line ends a row: both agents leave one before the hints under the menu.
        var continuesRow = false
        var strayLineSinceRow = false
        var hasStrayText = false
        var linesSinceMenu = 0

        func closeRow() {
            guard !menu.isEmpty, let option = option(number: menu[menu.count - 1].number, text: lastRowText, focused: lastRowFocused)
            else { return }
            menu[menu.count - 1] = option
        }

        for line in screen.split(separator: "\n", omittingEmptySubsequences: false) {
            let (text, focused) = normalized(line)
            if let row = numberedRow(in: text) {
                if row.number == 1 {
                    menu = [Option(number: 1, label: "", shortcut: nil, isFocused: focused)]
                    hasStrayText = false
                } else if let last = menu.last, row.number == last.number + 1 {
                    closeRow()
                    menu.append(Option(number: row.number, label: "", shortcut: nil, isFocused: focused))
                    if strayLineSinceRow { hasStrayText = true }
                } else {
                    // A number out of sequence is an ordinary list in the transcript.
                    menu = []
                    continuesRow = false
                    strayLineSinceRow = false
                    linesSinceMenu = 0
                    continue
                }
                lastRowText = row.text
                lastRowFocused = focused
                continuesRow = true
                strayLineSinceRow = false
                linesSinceMenu = 0
            } else if text.isEmpty {
                continuesRow = false
            } else {
                if continuesRow, !menu.isEmpty {
                    lastRowText += " " + text
                } else if !menu.isEmpty {
                    strayLineSinceRow = true
                }
                linesSinceMenu += 1
            }
        }
        closeRow()
        guard menu.count >= 2, linesSinceMenu <= maximumLinesBelowMenu,
              menu.contains(where: \.isFocused)
        else { return nil }
        return Scan(options: menu, hasStrayText: hasStrayText)
    }

    private static let decoration = CharacterSet(charactersIn: "│┃|╭╮╰╯─").union(.whitespaces)
    /// Claude Code draws "❯" in front of the focused row and Codex "›"; the rest cover older or
    /// other builds. Treating more glyphs as a cursor only makes a menu easier to recognize, which
    /// for a reply means opening the session instead of typing, the safe side.
    private static let cursorMarkers: [Character] = ["❯", "›", ">", "▶", "→", "▸"]

    private static func normalized(_ line: Substring) -> (text: String, focused: Bool) {
        var text = line.trimmingCharacters(in: decoration)
        var focused = false
        if let first = text.first, cursorMarkers.contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            focused = true
        }
        return (text, focused)
    }

    private static func numberedRow(in text: String) -> (number: Int, text: String)? {
        guard let match = text.wholeMatch(of: /(\d{1,2})[.)]\s+(.+)/), let number = Int(match.1) else { return nil }
        return (number, String(match.2))
    }

    private static func option(number: Int, text: String, focused: Bool) -> Option? {
        var label = text.trimmingCharacters(in: .whitespaces)
        var shortcut: String?
        if let hint = label.firstMatch(of: /\s*\((esc|[a-zA-Z])\)\s*$/) {
            shortcut = String(hint.1).lowercased()
            label.removeSubrange(hint.range)
        }
        return Option(number: number, label: label, shortcut: shortcut, isFocused: focused)
    }

    /// Phrases that turn a "yes" into a standing rule, a looser mode or a reset.
    private static let broadeningPhrases = [
        "don't ask again", "dont ask again", "always", "auto-accept", "auto accept", "bypass",
        "for this session", "for the session", "for this conversation", "in the future", "allow all",
        "clear context",
    ]

    private static func isOneOffApproval(_ label: String) -> Bool {
        let lowered = label.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard lowered.hasPrefix("yes") else { return false }
        // Compared without spaces: a word too long for the pane is hard wrapped mid-word ("auto-"
        // then "accept"), and joining the lines with a space would otherwise hide the phrase.
        let compact = lowered.filter { !$0.isWhitespace }
        return !broadeningPhrases.contains { compact.contains($0.filter { !$0.isWhitespace }) }
    }

    private static func isRejection(_ label: String) -> Bool {
        let lowered = label.lowercased()
        return lowered == "no" || lowered.hasPrefix("no,") || lowered.hasPrefix("no ") || lowered.hasPrefix("deny")
    }
}
