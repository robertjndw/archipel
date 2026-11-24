import AppKit
import GhosttyKit

/// VoiceOver reads the terminal as a text area holding what is on screen.
/// Nothing is pushed on redraw; the text is read when accessibility asks.
/// Ranges count UTF-16 units, as NSRange does.
extension SurfaceView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityRoleDescription() -> String? { "terminal" }
    override func accessibilityLabel() -> String? { "Terminal" }
    // The file editor is a text area too, so UI tests need this to tell the two apart.
    override func accessibilityIdentifier() -> String { "terminal.surface" }
    override func accessibilityValue() -> Any? { accessibilityScreenText }
    override func accessibilityNumberOfCharacters() -> Int { (accessibilityScreenText as NSString).length }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }

    override func accessibilitySelectedText() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)), as: UTF8.self)
    }

    /// Ghostty reports the selection in grid cells, which do not line up with
    /// the screen text once trailing blanks are trimmed, so it is looked up
    /// in the text instead. A repeated selection resolves to its first copy.
    override func accessibilitySelectedTextRange() -> NSRange {
        guard let selected = accessibilitySelectedText() else { return NSRange(location: 0, length: 0) }
        let range = (accessibilityScreenText as NSString).range(of: selected)
        return range.location == NSNotFound ? NSRange(location: 0, length: 0) : range
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let text = accessibilityScreenText as NSString
        guard range.location >= 0, NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }

    override func accessibilityLine(for index: Int) -> Int {
        let text = accessibilityScreenText as NSString
        let end = min(max(index, 0), text.length)
        return text.substring(to: end).utf16.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        var location = 0
        for (number, content) in accessibilityScreenText.components(separatedBy: "\n").enumerated() {
            let length = (content as NSString).length
            if number == line { return NSRange(location: location, length: length) }
            location += length + 1
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    /// The viewport as plain text, read at most once per pass of the run loop.
    private var accessibilityScreenText: String {
        if let accessibilityTextCache { return accessibilityTextCache }
        guard let surface else { return "" }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        let screen = text.text.map {
            String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(text.text_len)), as: UTF8.self)
        } ?? ""
        accessibilityTextCache = screen
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.accessibilityTextCache = nil }
        }
        return screen
    }
}
