import Foundation

/// The github.com repository a remote URL points at.
public struct GitHubRemote: Equatable, Sendable {
    public var owner: String
    public var repository: String

    /// Understands the forms git writes into a config: `https://github.com/o/r.git`,
    /// `git@github.com:o/r.git` and `ssh://git@github.com/o/r`. Any other host gives nil.
    public init?(remoteURL: String) {
        var rest = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        if let user = rest.firstIndex(of: "@") { rest = String(rest[rest.index(after: user)...]) }

        let host = "github.com"
        guard rest.lowercased().hasPrefix(host) else { return nil }
        rest = String(rest.dropFirst(host.count))
        // scp-like URLs separate host and path with a colon, the others with a slash (after an optional port).
        guard let separator = rest.first, separator == ":" || separator == "/" else { return nil }
        var parts = rest.dropFirst().split(separator: "/")[...]
        // `ssh://git@github.com:22/o/r` carries a port where the scp form has the owner.
        if separator == ":", parts.count > 2, parts.first?.allSatisfy(\.isNumber) == true { parts = parts.dropFirst() }
        guard parts.count >= 2 else { return nil }

        owner = String(parts[parts.startIndex])
        let name = String(parts[parts.startIndex + 1])
        repository = name.hasSuffix(".git") ? String(name.dropLast(4)) : name
        guard !owner.isEmpty, !repository.isEmpty else { return nil }
    }

    /// The owner's avatar, which is what github.com itself shows next to the repository.
    public func avatarURL(size: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(owner).png"
        components.queryItems = [URLQueryItem(name: "size", value: String(size))]
        return components.url
    }
}
