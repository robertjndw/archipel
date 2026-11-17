import Foundation

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
        var isLocked = false
        var isPrunable = false
        var isBare = false

        func flush() {
            if let path {
                entries.append(GitWorktreeEntry(
                    path: URL(filePath: path, directoryHint: .isDirectory),
                    branch: branch,
                    isMain: entries.isEmpty,
                    isLocked: isLocked,
                    isPrunable: isPrunable,
                    isBare: isBare
                ))
            }
            path = nil
            branch = nil
            isLocked = false
            isPrunable = false
            isBare = false
        }

        for line in output.unicodeScalars.split(separator: "\0", omittingEmptySubsequences: false) {
            if line.isEmpty {
                flush()
            } else if let value = line.dropPrefix("worktree ") {
                flush()
                path = value
            } else if let ref = line.dropPrefix("branch ") {
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line.elementsEqual("locked".unicodeScalars) || line.dropPrefix("locked ") != nil {
                isLocked = true
            } else if line.elementsEqual("prunable".unicodeScalars) || line.dropPrefix("prunable ") != nil {
                isPrunable = true
            } else if line.elementsEqual("bare".unicodeScalars) {
                isBare = true
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
