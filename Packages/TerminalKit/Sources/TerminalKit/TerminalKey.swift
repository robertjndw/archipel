import Carbon
import GhosttyKit

/// A single key press for `TerminalSession.sendKey`.
public enum TerminalKey: Equatable, Sendable {
    case enter
    case escape
    /// A digit or an unshifted ASCII letter.
    case character(Character)
}

extension TerminalSession {
    /// Presses and releases one key as if typed, through Ghostty's key encoder.
    ///
    /// Unlike `sendText`, this is never wrapped in bracketed paste, which matters for programs
    /// that read single keys from a menu: they take a pasted "1" as text, not as a choice. The
    /// encoder also honours whatever keyboard protocol the program asked for (kitty's, in the
    /// case of Codex), which raw bytes written to the pty would not.
    ///
    /// Returns false when the key has no physical equivalent on a US layout or the session is closed.
    @discardableResult
    public func sendKey(_ key: TerminalKey) -> Bool {
        guard let surface, let stroke = Self.stroke(for: key) else { return false }
        for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
            var event = ghostty_input_key_s()
            event.action = action
            event.mods = GHOSTTY_MODS_NONE
            event.consumed_mods = GHOSTTY_MODS_NONE
            event.keycode = stroke.keycode
            event.unshifted_codepoint = stroke.codepoint
            event.composing = false
            // Like a real keyDown, control keys carry no text; Ghostty encodes them from the keycode.
            if let text = stroke.text, action == GHOSTTY_ACTION_PRESS {
                text.withCString { pointer in
                    event.text = pointer
                    _ = ghostty_surface_key(surface, event)
                }
            } else {
                _ = ghostty_surface_key(surface, event)
            }
        }
        return true
    }

    private struct Stroke {
        var keycode: UInt32
        var codepoint: UInt32
        var text: String?
    }

    /// Ghostty identifies the physical key by its macOS virtual keycode. The ANSI (US) positions
    /// are used whatever the user's layout: the text carries the character, and the keycode only
    /// has to name a key that can produce it.
    private static func stroke(for key: TerminalKey) -> Stroke? {
        switch key {
        case .enter:
            return Stroke(keycode: UInt32(kVK_Return), codepoint: 0x0D, text: nil)
        case .escape:
            return Stroke(keycode: UInt32(kVK_Escape), codepoint: 0x1B, text: nil)
        case .character(let character):
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
                  let keycode = ansiKeycodes[character]
            else { return nil }
            return Stroke(keycode: UInt32(keycode), codepoint: scalar.value, text: String(character))
        }
    }

    private static let ansiKeycodes: [Character: Int] = [
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
    ]
}
