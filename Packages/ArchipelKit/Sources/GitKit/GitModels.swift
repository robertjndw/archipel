import Foundation

public struct GitError: Error, LocalizedError, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct GitWorktreeEntry: Equatable, Sendable {
    public var path: URL
    public var branch: String?
    public var isMain: Bool

    public init(path: URL, branch: String?, isMain: Bool) {
        self.path = path
        self.branch = branch
        self.isMain = isMain
    }
}

public enum GitChangeKind: Sendable {
    case modified, added, deleted, renamed, copied, typeChanged, untracked, conflicted
}

public struct GitFileChange: Identifiable, Equatable, Sendable {
    public var path: String
    public var originalPath: String?
    public var kind: GitChangeKind

    public init(path: String, originalPath: String? = nil, kind: GitChangeKind) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
    }

    public var id: String { path }
}

public struct GitStatus: Equatable, Sendable {
    public var branch: String?
    public var staged: [GitFileChange]
    public var unstaged: [GitFileChange]
    /// Short name of the upstream, e.g. `origin/main`; nil when the branch tracks nothing.
    public var upstream: String?
    public var ahead: Int
    public var behind: Int

    public init(
        branch: String?,
        staged: [GitFileChange],
        unstaged: [GitFileChange],
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0
    ) {
        self.branch = branch
        self.staged = staged
        self.unstaged = unstaged
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }

    public static let empty = GitStatus(branch: nil, staged: [], unstaged: [])
}

/// What a sidebar row needs about a worktree, cheap enough to poll for many of them.
public struct GitSummary: Equatable, Sendable {
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    /// Distinct paths, so a file that is both staged and modified again counts once.
    public var changedFiles: Int

    public init(branch: String?, upstream: String?, ahead: Int, behind: Int, changedFiles: Int) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changedFiles = changedFiles
    }
}

// MARK: - Parsers

/// Works on unicode scalars rather than Characters: a path that starts with a combining mark
/// would otherwise fuse with the preceding NUL or space into one grapheme and break the split.
enum GitParser {
    typealias Scalars = Substring.UnicodeScalarView

    /// Parses `git status --porcelain=v2 -z --branch`.
    static func status(_ output: String) -> GitStatus {
        var result = GitStatus.empty
        var fields = output.unicodeScalars.split(separator: "\0").makeIterator()

        while let field = fields.next() {
            guard let type = field.first else { continue }
            switch type {
            case "#":
                if let head = field.dropPrefix("# branch.head ") {
                    result.branch = head == "(detached)" ? nil : head
                } else if let upstream = field.dropPrefix("# branch.upstream ") {
                    result.upstream = upstream
                } else if let counts = field.dropPrefix("# branch.ab ") {
                    // Absent entirely when there is no upstream or it is gone, which leaves both at 0.
                    let parts = counts.split(separator: " ")
                    if parts.count == 2, parts[0].hasPrefix("+"), parts[1].hasPrefix("-"),
                       let ahead = Int(parts[0].dropFirst()), let behind = Int(parts[1].dropFirst()) {
                        result.ahead = ahead
                        result.behind = behind
                    }
                }
            case "1", "2":
                // The path is everything after the fixed columns, so it may contain spaces.
                guard let (columns, path) = split(field, fixedFields: type == "1" ? 8 : 9),
                      columns[1].count == 2 else { continue }
                let original = type == "2" ? fields.next().map(string) : nil
                for (code, isStaged) in zip(columns[1], [true, false]) where code != "." {
                    guard let kind = kind(for: code) else { continue }
                    let carriesOrigin = kind == .renamed || kind == .copied
                    let change = GitFileChange(path: path, originalPath: carriesOrigin ? original : nil, kind: kind)
                    if isStaged { result.staged.append(change) } else { result.unstaged.append(change) }
                }
            case "u":
                if let (_, path) = split(field, fixedFields: 10) {
                    result.unstaged.append(GitFileChange(path: path, kind: .conflicted))
                }
            case "?":
                result.unstaged.append(GitFileChange(path: string(field.dropFirst(2)), kind: .untracked))
            default:
                break
            }
        }
        return result
    }

    static func summary(_ output: String) -> GitSummary {
        let status = status(output)
        let paths = Set((status.staged + status.unstaged).map(\.path))
        return GitSummary(branch: status.branch, upstream: status.upstream, ahead: status.ahead,
                          behind: status.behind, changedFiles: paths.count)
    }

    /// Parses NUL-separated `ls-files -z` output.
    static func paths(_ output: String) -> [String] {
        output.unicodeScalars.split(separator: "\0").map { string($0) }
    }

    /// Parses `git worktree list --porcelain -z`: NUL-terminated lines, records separated by an empty line.
    static func worktrees(_ output: String) -> [GitWorktreeEntry] {
        var entries: [GitWorktreeEntry] = []
        var path: String?
        var branch: String?

        func flush() {
            if let path {
                entries.append(GitWorktreeEntry(path: URL(filePath: path, directoryHint: .isDirectory), branch: branch, isMain: entries.isEmpty))
            }
            path = nil
            branch = nil
        }

        for line in output.unicodeScalars.split(separator: "\0", omittingEmptySubsequences: false) {
            if line.isEmpty {
                flush()
            } else if let value = line.dropPrefix("worktree ") {
                flush()
                path = value
            } else if let ref = line.dropPrefix("branch ") {
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            }
        }
        flush()
        return entries
    }

    private static func kind(for code: Unicode.Scalar) -> GitChangeKind? {
        switch code {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .conflicted
        default: nil
        }
    }

    private static func split(_ field: Scalars, fixedFields: Int) -> ([Scalars], String)? {
        let parts = field.split(separator: " ", maxSplits: fixedFields, omittingEmptySubsequences: false)
        guard parts.count == fixedFields + 1 else { return nil }
        return (Array(parts.prefix(fixedFields)), string(parts[fixedFields]))
    }

    static func string(_ scalars: Scalars) -> String {
        String(String.UnicodeScalarView(scalars))
    }
}

extension Substring.UnicodeScalarView {
    func dropPrefix(_ prefix: String) -> String? {
        guard starts(with: prefix.unicodeScalars) else { return nil }
        return String(String.UnicodeScalarView(dropFirst(prefix.unicodeScalars.count)))
    }
}
