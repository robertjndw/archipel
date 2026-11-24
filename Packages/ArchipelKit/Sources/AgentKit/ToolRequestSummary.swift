import ArchipelCore
import Foundation

/// One line that says what a permission request is for, such as "Bash: npm publish", so a
/// notification with an Allow button shows what is being allowed.
public struct ToolRequestSummary: Equatable, Sendable {
    public var text: String
    /// The text is all of the request's name and detail, and short enough that a banner shows it
    /// whole. Anything less and the user would be approving something they could not read.
    public var isComplete: Bool

    /// The `tool_input` fields that say what a tool is about to touch, most telling first: a
    /// command, the file an edit or write goes to, the address of a fetch. Other input, such as
    /// the contents of a Write, is never shown. Keep in step with `summarisedInputKeys` in
    /// archipel-hook, which cuts large payloads down to these.
    static let detailKeys = ["command", "file_path", "notebook_path", "path", "url", "query", "pattern"]
    static let nameLimit = 80
    static let detailLimit = 200
    /// A banner on macOS gives the body two lines before it cuts it off with an ellipsis of its
    /// own, some 45 columns each at the default text size. Past this the user would have to
    /// expand the notification to see the rest, and the buttons are there without doing so.
    static let bannerColumns = 80

    /// Nil without a tool name. Both arguments are the payload's values as decoded from JSON.
    public init?(toolName: Any?, toolInput: Any?) {
        guard let name = (toolName as? String).map({ DisplayLine($0, limit: Self.nameLimit, blanks: .marked) }),
              !name.text.isEmpty
        else { return nil }
        var line = name
        if let input = toolInput as? [String: Any] {
            for key in Self.detailKeys {
                guard let detail = Self.text(input[key]).map({ DisplayLine($0, limit: Self.detailLimit, blanks: .marked) }),
                      !detail.text.isEmpty
                else { continue }
                line = DisplayLine(text: "\(name.text): \(detail.text)", isFaithful: name.isFaithful && detail.isFaithful)
                break
            }
        }
        text = line.text
        isComplete = line.isFaithful && line.columns <= Self.bannerColumns
    }

    /// Codex passes a command as its argv.
    private static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let words = value as? [String] { return words.joined(separator: " ") }
        return nil
    }
}
