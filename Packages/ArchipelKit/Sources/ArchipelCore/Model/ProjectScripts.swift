import Foundation

/// Shell snippets a project runs for its worktrees. Empty means "not configured".
public struct ProjectScripts: Codable, Equatable, Sendable {
    /// Run once in a freshly created worktree, e.g. installing dependencies or copying `.env`.
    public var setup: String
    /// Started on demand, e.g. a dev server.
    public var run: String

    public init(setup: String = "", run: String = "") {
        self.setup = setup
        self.run = run
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setup = try c.decodeIfPresent(String.self, forKey: .setup) ?? ""
        run = try c.decodeIfPresent(String.self, forKey: .run) ?? ""
    }

    public var setupCommand: String? { Self.command(from: setup) }
    public var runCommand: String? { Self.command(from: run) }

    /// True when neither script would execute anything.
    public var isEmpty: Bool { setupCommand == nil && runCommand == nil }

    /// Only blank lines are trimmed: indentation on the first line and spaces inside lines can be significant to a shell.
    private static func command(from script: String) -> String? {
        var lines = script.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)[...]
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}
