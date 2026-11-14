import Foundation

/// Lines added and removed in the working tree relative to HEAD, staged and unstaged together.
/// Untracked files are not part of it, since git has no diff for them without reading every file.
public struct GitDiffStat: Equatable, Sendable {
    public var insertions: Int
    public var deletions: Int

    public init(insertions: Int, deletions: Int) {
        self.insertions = insertions
        self.deletions = deletions
    }

    public static let zero = GitDiffStat(insertions: 0, deletions: 0)
}

extension GitClient {
    /// Throws on an unborn branch, where there is no HEAD to compare with.
    public func diffStat(in folder: URL) async throws -> GitDiffStat {
        // --numstat rather than --shortstat: the short form is a translated sentence, the numbers are not.
        let output = try await run(
            ["diff", "--numstat", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "HEAD"],
            in: folder
        )
        return GitParser.numstat(output)
    }
}

extension GitParser {
    /// Parses `git diff --numstat`: `added<TAB>deleted<TAB>path` per line, with `-` for both counts of a
    /// binary file, which then counts as nothing.
    static func numstat(_ output: String) -> GitDiffStat {
        var stat = GitDiffStat.zero
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            stat.insertions += Int(fields[0]) ?? 0
            stat.deletions += Int(fields[1]) ?? 0
        }
        return stat
    }
}
