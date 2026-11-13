import Foundation

/// One file's unified diff, as git printed it.
public struct GitFileDiff: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case modified, added, deleted, renamed
    }

    public var oldPath: String?
    public var newPath: String?
    public var status: Status
    public var isBinary: Bool
    public var hunks: [GitDiffHunk]

    public init(oldPath: String?, newPath: String?, status: Status, isBinary: Bool = false, hunks: [GitDiffHunk] = []) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
        self.isBinary = isBinary
        self.hunks = hunks
    }
}

public struct GitDiffHunk: Equatable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [GitDiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [GitDiffLine] = []) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct GitDiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case context, added, removed
    }

    public var kind: Kind
    /// The line without its diff prefix or line feed. A CRLF file keeps its `\r`.
    public var text: String
    /// False for the last line of a side that has no trailing newline.
    public var hasNewline: Bool

    public init(_ kind: Kind, _ text: String, hasNewline: Bool = true) {
        self.kind = kind
        self.text = text
        self.hasNewline = hasNewline
    }
}

// MARK: - Parser

extension GitParser {
    /// Parses `git diff` output with the default `a/` and `b/` prefixes.
    ///
    /// Hunk bodies are consumed by the line counts in their `@@` header rather than by prefix, so
    /// content that happens to start with `diff ` or `@@` is never mistaken for a header.
    static func fileDiffs(_ output: String) -> [GitFileDiff] {
        var files: [GitFileDiff] = []
        var current: GitFileDiff?
        var oldRemaining = 0
        var newRemaining = 0

        func flush() {
            if let file = current { files.append(file) }
            current = nil
            oldRemaining = 0
            newRemaining = 0
        }

        var lines = output.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }

        for line in lines {
            if oldRemaining > 0 || newRemaining > 0, let hunk = current?.hunks.indices.last {
                // diff.suppressBlankEmpty prints an empty context line without its leading space.
                switch line.first {
                case " ", nil, "-", "+":
                    let kind: GitDiffLine.Kind = line.first == "-" ? .removed : line.first == "+" ? .added : .context
                    if kind != .added { oldRemaining -= 1 }
                    if kind != .removed { newRemaining -= 1 }
                    current?.hunks[hunk].lines.append(GitDiffLine(kind, string(line.dropFirst())))
                    continue
                case "\\":
                    break
                default:
                    // A truncated hunk: stop counting and read the line as a header.
                    oldRemaining = 0
                    newRemaining = 0
                }
            }

            if line.first == "\\" {
                markMissingNewline(in: &current)
            } else if line.starts(with: "diff ".unicodeScalars) {
                flush()
                current = GitFileDiff(oldPath: nil, newPath: nil, status: .modified)
            } else if current != nil, let header = line.dropPrefix("@@ "), let hunk = hunkHeader(header) {
                current?.hunks.append(hunk)
                oldRemaining = hunk.oldCount
                newRemaining = hunk.newCount
            } else if current != nil {
                header(line, into: &current!)
            }
        }
        flush()
        return files.map(resolvingPaths)
    }

    /// Finds the source of a staged rename in `git diff --name-status -z` output.
    static func renameOrigin(of path: String, in nameStatus: String) -> String? {
        var fields = nameStatus.unicodeScalars.split(separator: "\0").map(string).makeIterator()
        while let status = fields.next() {
            if status.hasPrefix("R") || status.hasPrefix("C") {
                guard let source = fields.next(), let destination = fields.next() else { return nil }
                if destination == path, status.hasPrefix("R") { return source }
            } else {
                _ = fields.next()
            }
        }
        return nil
    }

    private static func header(_ line: Scalars, into file: inout GitFileDiff) {
        if line.starts(with: "new file mode".unicodeScalars) {
            file.status = .added
        } else if line.starts(with: "deleted file mode".unicodeScalars) {
            file.status = .deleted
        } else if let path = line.dropPrefix("rename from ") {
            file.status = .renamed
            file.oldPath = unquote(path)
        } else if let path = line.dropPrefix("rename to ") {
            file.status = .renamed
            file.newPath = unquote(path)
        } else if line.starts(with: "Binary files ".unicodeScalars) || line.starts(with: "GIT binary patch".unicodeScalars) {
            file.isBinary = true
        } else if let path = line.dropPrefix("--- ") {
            if file.oldPath == nil { file.oldPath = diffPath(path, prefix: "a/") }
        } else if let path = line.dropPrefix("+++ ") {
            if file.newPath == nil { file.newPath = diffPath(path, prefix: "b/") }
        }
    }

    /// `/dev/null` sides are dropped here so a rename or binary file without `---` lines still
    /// ends up with sensible paths.
    private static func resolvingPaths(_ file: GitFileDiff) -> GitFileDiff {
        var file = file
        if file.status == .added { file.oldPath = nil }
        if file.status == .deleted { file.newPath = nil }
        return file
    }

    private static func markMissingNewline(in file: inout GitFileDiff?) {
        guard let hunkIndex = file?.hunks.indices.last,
              let lineIndex = file?.hunks[hunkIndex].lines.indices.last else { return }
        file?.hunks[hunkIndex].lines[lineIndex].hasNewline = false
    }

    /// `-a,b +c,d @@ section`; a missing count means 1.
    static func hunkHeader(_ header: String) -> GitDiffHunk? {
        let parts = header.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("-"), parts[1].hasPrefix("+"),
              let old = range(parts[0].dropFirst()), let new = range(parts[1].dropFirst()) else { return nil }
        return GitDiffHunk(oldStart: old.start, oldCount: old.count, newStart: new.start, newCount: new.count)
    }

    private static func range(_ text: Substring) -> (start: Int, count: Int)? {
        let numbers = text.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(numbers[0]) else { return nil }
        if numbers.count == 1 { return (start, 1) }
        guard numbers.count == 2, let count = Int(numbers[1]) else { return nil }
        return (start, count)
    }

    private static func diffPath(_ raw: String, prefix: String) -> String? {
        // git ends the name with a tab when it contains a space, to keep it parseable by patch(1).
        var path = raw.hasSuffix("\t") ? String(raw.dropLast()) : raw
        if path == "/dev/null" { return nil }
        path = unquote(path)
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Undoes git's C-style quoting, which it still applies to names with control characters,
    /// quotes or backslashes even when core.quotepath is off.
    static func unquote(_ path: String) -> String {
        guard path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") else { return path }
        var bytes: [UInt8] = []
        var iterator = Array(path.utf8.dropFirst().dropLast()).makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "\\"), let escaped = iterator.next() else {
                bytes.append(byte)
                continue
            }
            switch escaped {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(escaped - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = iterator.next() else { break }
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(escaped)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
