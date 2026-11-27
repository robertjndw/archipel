import Foundation
import Synchronization
import SwiftUI

/// Turns file paths that a Markdown reply mentions as plain text into `file:` links, the way a
/// terminal makes printed paths clickable.
///
/// The text is untrusted, so this is careful about what it touches while drawing:
/// - A path only becomes a link if it names an existing regular file or folder. Devices, sockets
///   and FIFOs never do, since opening one can hang or have side effects.
/// - Automount and network locations (`/net`, `/Volumes`, …) are never looked up, unless they are
///   inside `base`. Looking one up can mount a share named by the text, or block on a server that
///   went away, all on the main thread. Symlinks are followed by hand so none can lead there
///   either; see `SafeFileLookup`.
/// - A link only says where the file is. Whoever opens it still decides what is safe to do with it.
///
/// Positions written as `path:line` or `path:line:column` go into the link as a `#L12` or `#L12C3`
/// fragment, the form GitHub uses.
public final class MarkdownPathLinker: Sendable {
    /// Relative paths resolve against this. Nil leaves them alone.
    public let base: URL?
    private let isLinkable: @Sendable (String) -> Bool
    /// A reply that is streaming in is parsed again with every chunk, so its paths would be
    /// looked up again each time. A stale answer only affects how the text looks: the click
    /// checks again.
    private let cache = Mutex<[String: Bool]>([:])

    static let cacheLimit = 2048
    /// The longest path worth looking up; PATH_MAX is 1024.
    static let maximumLength = 1024
    /// Lookups one piece of text may make, so a reply that is nothing but paths stays cheap.
    static let lookupsPerText = 200

    /// Never looked up from outside `base`; see the type's documentation.
    static let unsafePrefixes = ["/net", "/Network", "/Volumes", "/home", "/automount", "/System/Volumes", "/dev"]

    public convenience init(base: URL?) {
        let allowing = base.map { SafeFileLookup.spellings(of: $0.path(percentEncoded: false)) } ?? []
        self.init(base: base) { SafeFileLookup.lookUp($0, refusing: Self.unsafePrefixes, allowing: allowing) != nil }
    }

    init(base: URL?, isLinkable: @escaping @Sendable (String) -> Bool) {
        self.base = base.map { URL(filePath: NSString(string: $0.path(percentEncoded: false)).standardizingPath, directoryHint: .isDirectory) }
        self.isLinkable = isLinkable
    }

    // MARK: Finding paths

    /// The link for a token from running text, or nil when it is not a path to something that
    /// exists. Punctuation around the token, as in `(see /tmp/a.txt).`, is not part of the path.
    func link(forWord word: Substring) -> (range: Range<Substring.Index>, url: URL)? {
        guard let range = Self.trimmedRange(of: word) else { return nil }
        let candidate = word[range]
        guard Self.looksLikePath(candidate) else { return nil }
        return link(forPath: String(candidate)).map { (range, $0) }
    }

    /// The link for the whole of an inline code span, which has clear edges, so it may contain
    /// spaces or be a bare file name like `README.md`.
    func link(forCode code: String) -> URL? {
        let candidate = code.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty, !candidate.contains("://"), !candidate.contains(where: \.isNewline) else { return nil }
        // A bare name has to look like a file name, or every `true` and `nil` would be looked up.
        if !candidate.contains("/") && !candidate.dropFirst().contains(".") { return nil }
        return link(forPath: candidate)
    }

    /// For a Markdown link whose destination has no scheme, such as `src/a.swift#L12` or
    /// `src/a.swift:12`. Nil when it does not lead to anything, and the link stays as written.
    func link(forDestination destination: String) -> URL? {
        guard !destination.isEmpty, !destination.contains("://") else { return nil }
        var path = destination
        var fragment: String?
        if let hash = destination.firstIndex(of: "#") {
            path = String(destination[..<hash])
            fragment = String(destination[destination.index(after: hash)...])
        }
        // Destinations are URL-encoded, so `my%20file.md` is `my file.md`.
        guard let decoded = path.removingPercentEncoding, !decoded.isEmpty else { return nil }
        guard let url = link(forPath: decoded) else { return nil }
        // A position in the text wins over one in the fragment; only line fragments are kept, the
        // rest (`#setup`) mean nothing to a file.
        guard url.fragment() == nil, let fragment, MarkdownFilePosition(fragment: fragment) != nil else { return url }
        return Self.url(url, fragment: fragment)
    }

    /// Tries the path as written first, so a file really named `a.txt:12` wins over line 12 of
    /// `a.txt`.
    private func link(forPath candidate: String) -> URL? {
        // A NUL would end the path early for the system calls while the link kept the rest.
        guard candidate.utf8.count <= Self.maximumLength, !SafeFileLookup.containsControlCharacters(candidate) else { return nil }
        if let url = resolve(candidate) { return url }
        guard let (path, position) = Self.splitPosition(candidate), let url = resolve(path) else { return nil }
        return Self.url(url, fragment: position.fragment)
    }

    /// `a.swift:12` and `a.swift:12:3`. Parsed by hand: a lazy regex backtracks quadratically on a
    /// long word full of colons, and this runs on the main thread for every word.
    static func splitPosition(_ candidate: String) -> (String, MarkdownFilePosition)? {
        func trailingNumber(_ text: Substring) -> (rest: Substring, number: Int)? {
            guard let colon = text.lastIndex(of: ":") else { return nil }
            let digits = text[text.index(after: colon)...]
            guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(digits), number >= 1 else { return nil }
            return (text[..<colon], number)
        }
        guard let last = trailingNumber(candidate[...]) else { return nil }
        if let first = trailingNumber(last.rest), !first.rest.isEmpty {
            return (String(first.rest), MarkdownFilePosition(line: first.number, column: last.number))
        }
        guard !last.rest.isEmpty else { return nil }
        return (String(last.rest), MarkdownFilePosition(line: last.number))
    }

    private func resolve(_ path: String) -> URL? {
        let absolute: String
        if path.hasPrefix("/") {
            absolute = path
        } else if path.hasPrefix("~/") {
            absolute = NSString(string: path).expandingTildeInPath
        } else if path.hasPrefix("~") {
            // `~user/…` would look up another account's home directory.
            return nil
        } else if let base {
            absolute = base.appending(path: path).path(percentEncoded: false)
        } else {
            return nil
        }
        let standardized = NSString(string: absolute).standardizingPath
        guard standardized.hasPrefix("/"), standardized != "/" else { return nil }
        // The lookup refuses these as well, but checking first keeps them out of the cache.
        guard isInsideBase(standardized) || !Self.unsafePrefixes.contains(where: { SafeFileLookup.isPath(standardized, inside: $0) }) else {
            return nil
        }
        guard lookUp(standardized) else { return nil }
        return URL(filePath: standardized)
    }

    private func isInsideBase(_ path: String) -> Bool {
        guard let base else { return false }
        return SafeFileLookup.isPath(path, inside: base.path(percentEncoded: false))
    }

    private func lookUp(_ path: String) -> Bool {
        if let known = cache.withLock({ $0[path] }) { return known }
        let result = isLinkable(path)
        cache.withLock { cache in
            if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[path] = result
        }
        return result
    }

    // MARK: Words

    /// Only things that are written like a path get looked up: absolute, `~/`, `./` and `../`
    /// paths, and relative ones with at least one slash, like `Sources/App/main.swift`.
    static func looksLikePath(_ word: Substring) -> Bool {
        guard word.contains("/"), !word.contains("://"), !word.hasPrefix("//") else { return false }
        if word.hasPrefix("/") || word.hasPrefix("~/") || word.hasPrefix("./") || word.hasPrefix("../") { return true }
        guard let first = word.unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(first) || first == "_" || first == "."
    }

    private static let leadingPunctuation: Set<Character> = ["(", "[", "{", "<", "\"", "'", "“", "‘", "«"]
    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "\"", "'", "”", "’", "»", "…",
    ]

    /// The word without the punctuation the sentence put around it. Nil when nothing is left.
    static func trimmedRange(of word: Substring) -> Range<Substring.Index>? {
        var start = word.startIndex
        var end = word.endIndex
        while start < end, leadingPunctuation.contains(word[start]) { start = word.index(after: start) }
        while start < end {
            let last = word.index(before: end)
            guard trailingPunctuation.contains(word[last]) else { break }
            // `./` and `../` keep their dots.
            if word[last] == ".", word[start..<end].allSatisfy({ $0 == "." }) { break }
            end = last
        }
        return start < end ? start..<end : nil
    }

    // MARK: Helpers

    private static func url(_ url: URL, fragment: String) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = fragment
        return components?.url ?? url
    }
}

/// A line, and maybe a column, in a file a link points to, carried in the link's fragment.
public struct MarkdownFilePosition: Equatable, Sendable {
    public var line: Int
    public var column: Int?

    public init(line: Int, column: Int? = nil) {
        self.line = line
        self.column = column
    }

    /// Reads `L12`, `L12C3` and ranges like `L12-L20`, which start at their first line.
    public init?(fragment: String) {
        guard fragment.utf8.count <= 40, let match = fragment.wholeMatch(of: /L(\d+)(?:C(\d+))?(?:-L?\d+(?:C\d+)?)?/),
              let line = Int(match.1), line >= 1
        else { return nil }
        self.line = line
        column = match.2.flatMap { Int($0) }.flatMap { $0 >= 1 ? $0 : nil }
    }

    var fragment: String {
        column.map { "L\(line)C\($0)" } ?? "L\(line)"
    }
}

extension EnvironmentValues {
    /// Set to have `MarkdownText` link the file paths it shows. Off by default: only a host that
    /// knows where relative paths start, and checks links before opening them, should turn it on.
    @Entry public var markdownPathLinker: MarkdownPathLinker?
}
