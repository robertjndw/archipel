import ACPKit
import ArchipelCore
import Foundation

/// A file or folder of the worktree that an @ in the composer can name.
struct FileMention: Hashable, Sendable, Identifiable {
    /// Relative to the worktree, without a trailing slash.
    var path: String
    var isDirectory = false
    /// Another file, or for a folder another folder, of the worktree has the same name.
    var isNameShared = false

    /// A folder's id ends in a slash, so a folder and a file of the same name stay apart.
    var id: String { isDirectory ? path + "/" : path }

    var name: String {
        path.utf8.lastIndex(of: FileMentions.slash).map { String(path[path.index(after: $0)...]) } ?? path
    }

    /// The folder the file is in, empty at the top of the worktree.
    var folder: String {
        path.utf8.lastIndex(of: FileMentions.slash).map { String(path[..<$0]) } ?? ""
    }

    func url(in root: URL) -> URL {
        root.appending(path: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }
}

/// The "@query" being typed at the cursor.
struct MentionToken: Equatable, Sendable {
    /// The whole word, from the @ to the next whitespace, in UTF-16 units as the text view counts
    /// them. Choosing a file replaces all of it: with the cursor moved back into a word, what
    /// stands behind the cursor is the rest of the same mention.
    var range: NSRange
    /// The text between the @ and the cursor.
    var query: String
}

/// Completion of the worktree's files behind an @ in the composer.
enum FileMentions {
    /// How many matches the list holds. More than anyone walks through with the arrow keys, and
    /// few enough that a keystroke in a repository of a hundred thousand files stays cheap to show.
    static let shownLimit = 50

    fileprivate static let slash = UInt8(ascii: "/")
    private static let at = unichar(UInt8(ascii: "@"))
    /// No file is looked for with more than this, and it bounds the walk back from the cursor in
    /// a pasted wall of text without a space.
    private static let maximumQueryLength = 200

    // MARK: The mention at the cursor

    /// The mention the cursor is in or right behind, or nil. An @ starts one at the start of the
    /// text or after whitespace, so `a@b.c` is an address and not a mention, and the query ends at
    /// whitespace. A selection is never a mention being typed.
    static func token(in draft: String, selection: NSRange) -> MentionToken? {
        let text = draft as NSString
        guard selection.length == 0, selection.location != NSNotFound, selection.location <= text.length else { return nil }
        let caret = selection.location
        var start: Int?
        var index = caret
        while index > 0, caret - index <= maximumQueryLength {
            let unit = text.character(at: index - 1)
            if isWhitespace(unit) { break }
            // An @ inside a word is part of the query: file names such as icon@2x.png have one.
            if unit == at, index == 1 || isWhitespace(text.character(at: index - 2)) {
                start = index - 1
                break
            }
            index -= 1
        }
        guard let start else { return nil }
        var end = caret
        while end < text.length, !isWhitespace(text.character(at: end)) { end += 1 }
        return MentionToken(
            range: NSRange(location: start, length: end - start),
            query: text.substring(with: NSRange(location: start + 1, length: caret - start - 1))
        )
    }

    /// What replaces the mention once a file is chosen: its name, and a space to type on behind
    /// unless one is there already.
    ///
    /// The file itself goes along as an attachment, which carries the full path. The name stays in
    /// the sentence because a mention is usually a word of it: "compare @a with @b" would read
    /// "compare with" as a chip alone, to the agent as much as in the transcript. The name and not
    /// the path, since the path is the attachment's job and would crowd a short prompt. Unless
    /// the worktree has the name more than once: "make Package.swift match Package.swift" says
    /// nothing, and which attachment goes with which word is then left to their order.
    static func edit(choosing file: FileMention, for token: MentionToken, in draft: String) -> (range: NSRange, text: String) {
        let text = draft as NSString
        let end = NSMaxRange(token.range)
        let isFollowedByWhitespace = end < text.length && isWhitespace(text.character(at: end))
        return (token.range, inlineText(for: file) + (isFollowedByWhitespace ? "" : " "))
    }

    static func inlineText(for file: FileMention) -> String {
        let text = file.isNameShared ? file.path : file.name
        return file.isDirectory ? text + "/" : text
    }

    /// `file` as it is on disk. A listing gives away a folder by its trailing slash, and git
    /// lists a submodule and a link to a folder without one, so the one entry that was chosen is
    /// looked at before its name goes into the text and its URL into the prompt.
    static func resolved(_ file: FileMention, in root: URL) -> FileMention {
        guard !file.isDirectory else { return file }
        let url = file.url(in: root).resolvingSymlinksInPath()
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return file }
        var folder = file
        folder.isDirectory = true
        return folder
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        // Half of a surrogate pair is no scalar, and no whitespace either.
        Unicode.Scalar(unit)?.properties.isWhitespace ?? false
    }

    // MARK: Candidates

    /// What can be mentioned, given the files of a worktree as relative paths: the files and every
    /// folder that holds one, the top of the worktree first and by path within one depth, upper
    /// and lower case alike as the Files inspector lists them. What is hidden, or inside
    /// something hidden, comes after everything else: `.github` is rarely what an @ is for.
    ///
    /// That order is what an empty query shows, and what equal matches fall back to, so it is
    /// worked out once here and not on every keystroke.
    static func candidates(fromFiles paths: [String]) -> [FileMention] {
        var folders = Set<Substring>()
        var entries: [(isHidden: Bool, depth: Int, key: String, mention: FileMention)] = []
        func add(_ path: some StringProtocol, isDirectory: Bool) {
            // Lowercased once here, and not in every comparison of the sort.
            entries.append((isHidden(path), depth(of: path), path.lowercased(), FileMention(path: String(path), isDirectory: isDirectory)))
        }
        entries.reserveCapacity(paths.count + paths.count / 8)
        var lastParent: Substring?
        for var path in paths {
            // git lists a repository nested in the worktree as one entry with a trailing slash.
            // A submodule comes without one; `WorktreeFileIndex` adds it from `.gitmodules`.
            let isFolder = path.utf8.last == slash
            if isFolder { path.removeLast() }
            guard !path.isEmpty else { continue }
            if isFolder {
                if folders.insert(path[...]).inserted { add(path, isDirectory: true) }
            } else {
                add(path, isDirectory: false)
            }
            guard let cut = path.utf8.lastIndex(of: slash) else { continue }
            var parent = path[..<cut]
            // Listings come sorted, so most files share their folder with the one before.
            if parent == lastParent { continue }
            lastParent = parent
            while folders.insert(parent).inserted {
                add(parent, isDirectory: true)
                guard let up = parent.utf8.lastIndex(of: slash) else { break }
                parent = parent[..<up]
            }
        }
        entries.sort { a, b in
            if a.isHidden != b.isHidden { return !a.isHidden }
            if a.depth != b.depth { return a.depth < b.depth }
            if a.key != b.key { return a.key < b.key }
            // Names that differ in case alone still need one order.
            if a.mention.path != b.mention.path { return a.mention.path < b.mention.path }
            return !a.mention.isDirectory && b.mention.isDirectory
        }
        var mentions = entries.map(\.mention)
        markSharedNames(in: &mentions)
        return mentions
    }

    /// Files apart from folders: a folder named like a file is told from it by its slash.
    private static func markSharedNames(in mentions: inout [FileMention]) {
        var counts: [Bool: [String: Int]] = [false: [:], true: [:]]
        for mention in mentions { counts[mention.isDirectory]?[mention.name, default: 0] += 1 }
        for index in mentions.indices where (counts[mentions[index].isDirectory]?[mentions[index].name] ?? 0) > 1 {
            mentions[index].isNameShared = true
        }
    }

    /// The paths of the submodules a `.gitmodules` file names.
    static func submodulePaths(inGitmodules text: String) -> Set<String> {
        var paths = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "path" else { continue }
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { paths.insert(path) }
        }
        return paths
    }

    private static func depth(of path: some StringProtocol) -> Int {
        path.utf8.reduce(0) { $1 == slash ? $0 + 1 : $0 }
    }

    /// Whether any part of the path starts with a dot.
    private static func isHidden(_ path: some StringProtocol) -> Bool {
        let dot = UInt8(ascii: ".")
        var isStart = true
        for byte in path.utf8 {
            if isStart, byte == dot { return true }
            isStart = byte == slash
        }
        return false
    }

    // MARK: Ranking

    /// `FuzzyMatcher.rank` cannot be cancelled, so a long list goes through it in pieces.
    private static let chunkSize = 5_000
    /// What a folder gives up against a file. About what an exact name earns over a name that
    /// merely starts with the query: `@views` still finds the Views folder first, while `@chat`
    /// offers ChatView.swift before the ChatUI folder. Files are what is mentioned most.
    private static let folderPenalty = 40

    /// The candidates to show for `query`, best first, or nil when `isCancelled` said to stop.
    ///
    /// The query has to be in the name in order, not necessarily in one piece, or in the path in
    /// one piece; see `MentionGate`. Among those, a match in the file's name beats one in its
    /// folders, the start of the name and of a word beat the middle, and a short path beats a
    /// long one: `FuzzyMatcher` scores all of that, as it does for the command palette's files.
    /// An empty query shows the files of `recent` (candidate ids, newest first) and then the top
    /// of the worktree. A file that is attached already is offered like any other: choosing it
    /// again writes its name into the sentence a second time.
    static func rank(
        _ candidates: [FileMention],
        query: String,
        recent: [String] = [],
        limit: Int = shownLimit,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> [FileMention]? {
        guard limit > 0 else { return [] }
        if query.isEmpty { return unfiltered(candidates, recent: recent, limit: limit) }

        let gate = MentionGate(query: query)
        var hits: [(score: Int, index: Int)] = []
        var start = 0
        while start < candidates.count {
            if isCancelled() { return nil }
            let end = min(start + chunkSize, candidates.count)
            var files: [Int] = []
            var folders: [Int] = []
            for index in start..<end where gate.admits(candidates[index].path) {
                if candidates[index].isDirectory { folders.append(index) } else { files.append(index) }
            }
            // Apart, so the penalty cannot push a file out of a piece's best that a folder took.
            for (index, match) in FuzzyMatcher.rank(files, query: query, limit: limit, key: { candidates[$0].path }) {
                hits.append((match.score, index))
            }
            for (index, match) in FuzzyMatcher.rank(folders, query: query, limit: limit, key: { candidates[$0].path }) {
                hits.append((match.score - folderPenalty, index))
            }
            start = end
        }
        if isCancelled() { return nil }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return hits.prefix(limit).map { candidates[$0.index] }
    }

    private static func unfiltered(_ candidates: [FileMention], recent: [String], limit: Int) -> [FileMention] {
        if recent.isEmpty { return Array(candidates.prefix(limit)) }
        let recency = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        var recents: [(position: Int, mention: FileMention)] = []
        var rest: [FileMention] = []
        for candidate in candidates {
            // Recent files can be anywhere in the list; once all are found the top is enough.
            if rest.count >= limit, recents.count == recency.count { break }
            if let position = recency[candidate.id] {
                recents.append((position, candidate))
            } else if rest.count < limit {
                rest.append(candidate)
            }
        }
        recents.sort { $0.position < $1.position }
        return Array((recents.map(\.mention) + rest).prefix(limit))
    }

    /// What a query has to do to a path before the fuzzy match gets to see it.
    ///
    /// Any letters in order anywhere in a path is too little for a word behind an @: prompts are
    /// full of "@escaping" and "@Sendable", and a long enough path holds the letters of either
    /// scattered over its folders. So the query has to be in the name in order, where "cmpsr"
    /// finds ChatComposer.swift, or in the path in one piece, where "views" finds what is under
    /// Views. A query with a slash in it narrows by folder and is left to the fuzzy match whole.
    ///
    /// Works on bytes, folding ASCII case alone, so a hundred thousand candidates cost no
    /// allocation each. Anything outside ASCII, in the query or the path, is let through.
    private struct MentionGate {
        private let needle: [UInt8]
        private let admitsAll: Bool

        init(query: String) {
            var bytes = Array(query.utf8)
            admitsAll = bytes.isEmpty || bytes.contains { $0 == slash || $0 >= 0x80 }
            for index in bytes.indices { bytes[index] = Self.folded(bytes[index]) }
            needle = bytes
        }

        func admits(_ path: String) -> Bool {
            if admitsAll { return true }
            if let answer = path.utf8.withContiguousStorageIfAvailable({ admits($0) }) { return answer }
            return Array(path.utf8).withUnsafeBufferPointer { admits($0) }
        }

        private func admits(_ path: UnsafeBufferPointer<UInt8>) -> Bool {
            var nameStart = 0
            for index in path.indices {
                if path[index] >= 0x80 { return true }
                if path[index] == slash { nameStart = index + 1 }
            }
            var matched = 0
            for index in nameStart..<path.count where Self.folded(path[index]) == needle[matched] {
                matched += 1
                if matched == needle.count { return true }
            }
            guard path.count >= needle.count else { return false }
            search: for start in 0...(path.count - needle.count) {
                for offset in needle.indices where Self.folded(path[start + offset]) != needle[offset] { continue search }
                return true
            }
            return false
        }

        private static func folded(_ byte: UInt8) -> UInt8 {
            byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte | 0x20 : byte
        }
    }

    // MARK: Attachments

    /// The id a file URL has as a candidate of the worktree at `root`, or nil outside it.
    static func id(of url: URL, in root: URL) -> String? {
        var base = root.standardizedFileURL.path(percentEncoded: false)
        if !base.hasSuffix("/") { base += "/" }
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(base), path.utf8.count > base.utf8.count else { return nil }
        return String(path.dropFirst(base.count))
    }

    /// The worktree's files that went along with earlier prompts, as candidate ids, the newest
    /// prompt first: what someone is most likely to mention again.
    static func recentIDs(in items: [ChatItem], root: URL) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for case let .userMessage(message) in items.reversed() {
            for block in message.attachments {
                let uri: String? = switch block {
                case let .resourceLink(link): link.uri
                case let .image(_, _, uri): uri
                default: nil
                }
                guard let url = uri.flatMap(URL.init(string:)), url.isFileURL, let id = id(of: url, in: root) else { continue }
                if seen.insert(id).inserted { ids.append(id) }
            }
        }
        return ids
    }
}
