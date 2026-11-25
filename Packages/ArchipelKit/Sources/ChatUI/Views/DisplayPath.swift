import Foundation

/// A path as the chat shows it: relative to the session's working directory when the file is
/// inside it, with `~` for the home directory otherwise, and unchanged elsewhere.
///
/// Agents report the spelling they were given, so `/private/tmp/x` and `/tmp/x` can both name
/// the same file. Both sides are compared in one normalized form, worked out from the strings
/// alone: the disk is never asked, and this runs while a transcript scrolls.
func displayPath(_ path: String, relativeTo workingDirectory: String, home: String = NSHomeDirectory()) -> String {
    guard path.hasPrefix("/") else { return path }
    let target = normalizedPath(path)

    let directory = normalizedPath(workingDirectory)
    if workingDirectory.hasPrefix("/"), directory != "/" {
        if target == directory { return "." }
        if target.hasPrefix(directory + "/") { return String(target.dropFirst(directory.count + 1)) }
    }

    let home = normalizedPath(home)
    if home != "/" {
        if target == home { return "~" }
        if target.hasPrefix(home + "/") { return "~" + target.dropFirst(home.count) }
    }
    return path
}

/// Resolves `.`, `..`, repeated and trailing slashes, and the `/private` spelling of the system
/// links (`/tmp`, `/var`, `/etc`).
private func normalizedPath(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
        switch part {
        case ".": continue
        case "..": _ = parts.popLast()
        default: parts.append(part)
        }
    }
    if parts.first == "private", parts.count > 1, ["tmp", "var", "etc"].contains(parts[1]) {
        parts.removeFirst()
    }
    return "/" + parts.joined(separator: "/")
}
