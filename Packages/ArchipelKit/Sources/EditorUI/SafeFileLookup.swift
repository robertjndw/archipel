import Darwin
import Foundation

/// Looks up a path named by untrusted text without letting it reach places where a lookup alone
/// has side effects.
///
/// `stat` and `realpath` follow symlinks on their own, so a link planted in a worktree
/// (`notes -> /net/evil/share`) would take them into an automount and connect to whatever server
/// it names. Here every component is visited with `lstat`, every link read with `readlink`, and
/// each step checked against `refusing` before anything touches it.
public enum SafeFileLookup {
    public enum Kind: Sendable { case file, folder }

    /// Automount points: looking anything up below them can mount a share.
    public static let automountPrefixes = ["/net", "/Network", "/home", "/automount"]

    /// Symlink hops before giving up, like the kernel's MAXSYMLINKS.
    static let maximumHops = 32

    /// The real path of `path` and what it is, or nil when it does not exist, is not a regular
    /// file or folder, or would pass through a prefix in `refusing`. A step inside `allowing`
    /// is always fine, so a project that lives on a network volume still works.
    public static func lookUp(_ path: String, refusing: [String], allowing: [String] = []) -> (path: String, kind: Kind)? {
        guard path.hasPrefix("/"), !containsControlCharacters(path) else { return nil }
        let isAllowed = { (candidate: String) in
            allowing.contains { isPath(candidate, inside: $0) } || !refusing.contains { isPath(candidate, inside: $0) }
        }
        var pending = components(of: path)
        var resolved: [Substring] = []
        var hops = 0
        while !pending.isEmpty {
            let name = pending.removeFirst()
            if name == "." { continue }
            if name == ".." {
                _ = resolved.popLast()
                continue
            }
            let next = "/" + (resolved + [name]).joined(separator: "/")
            guard isAllowed(next) else { return nil }
            var info = stat()
            guard lstat(next, &info) == 0 else { return nil }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                hops += 1
                guard hops <= maximumHops, let target = readLink(next), !containsControlCharacters(target) else { return nil }
                if target.hasPrefix("/") { resolved = [] }
                pending = components(of: target) + pending
            case S_IFDIR:
                resolved.append(name)
            case S_IFREG:
                // Only the last component can be a file.
                guard pending.allSatisfy({ $0 == "." }) else { return nil }
                resolved.append(name)
                return ("/" + resolved.joined(separator: "/"), .file)
            default:
                return nil
            }
        }
        guard !resolved.isEmpty else { return nil }
        return ("/" + resolved.joined(separator: "/"), .folder)
    }

    /// `path` and the real path it leads to, for checking that one folder holds another however
    /// either is spelled. Only for paths the user chose, since it follows links freely.
    public static func spellings(of path: String) -> [String] {
        var spellings = [NSString(string: path).standardizingPath]
        if let real = realpath(path, nil) {
            spellings.append(String(cString: real))
            free(real)
        }
        return spellings
    }

    static func isPath(_ path: String, inside directory: String) -> Bool {
        let directory = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return path == directory || path.hasPrefix(directory + "/")
    }

    static func containsControlCharacters(_ string: String) -> Bool {
        string.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private static func components(of path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }

    private static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, Int(PATH_MAX))
        guard count > 0 else { return nil }
        return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
