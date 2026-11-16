import Foundation

/// A local web server a session announced in its output, such as Vite's
/// "Local: http://localhost:5173/".
public struct DevServerLink: Hashable, Sendable {
    /// The URL as the program printed it.
    public var url: URL
    public var port: Int
    /// Lowercased, without brackets: "localhost", "127.0.0.1", "0.0.0.0", "::1" or "::".
    public var host: String

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = url.host(percentEncoded: false)?.lowercased(),
              let port = url.port, (1...65535).contains(port)
        else { return nil }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard Self.localHosts.contains(host) else { return nil }
        self.url = url
        self.port = port
        self.host = host
    }

    static let localHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "::"]

    /// What a browser should open. A wildcard address is where the server
    /// listens, not somewhere a browser can go, so it becomes localhost.
    public var openURL: URL {
        guard host == "0.0.0.0" || host == "::",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.host = "localhost"
        return components.url ?? url
    }

    /// The short form shown on a tab, like ":5173".
    public var label: String { ":\(port)" }

    /// Loopback addresses to try when checking that the server still listens.
    /// "localhost" can resolve to either family, and Node's servers often bind
    /// only ::1, so both are tried.
    public var probeAddresses: [String] {
        switch host {
        case "127.0.0.1", "0.0.0.0": ["127.0.0.1"]
        case "::1": ["::1"]
        default: ["127.0.0.1", "::1"]
        }
    }
}

public enum DevServerDetector {
    // A port is required: a bare "http://localhost" is far more often part of
    // prose or config than a server that just came up.
    nonisolated(unsafe) private static let pattern =
        /(?i)https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):\d{1,5}(?!\d)(?:\/[^\s"'<>`)\]}|]*)?/

    /// Local server URLs in `text`, oldest first, one per port. A port printed
    /// again counts as its latest mention, since lower lines of a terminal are newer.
    public static func links(in text: String) -> [DevServerLink] {
        // Most polls see no URL at all; this keeps them away from the regex engine.
        guard text.contains("://") else { return [] }
        var links: [DevServerLink] = []
        for match in text.matches(of: pattern) {
            let raw = trimTrailingPunctuation(String(match.output))
            guard let url = URL(string: raw), let link = DevServerLink(url: url) else { continue }
            links.removeAll { $0.port == link.port }
            links.append(link)
        }
        return links
    }

    /// Folds a fresh scan into what is already known. Known ports keep their
    /// place, so text scrolling around never reorders them; new ones go last,
    /// which makes the last element the most recently started server.
    public static func merge(known: [DevServerLink], detected: [DevServerLink]) -> [DevServerLink] {
        var result = known
        for link in detected {
            if let index = result.firstIndex(where: { $0.port == link.port }) {
                result[index] = link
            } else {
                result.append(link)
            }
        }
        return result
    }

    /// Sentence punctuation right after a URL ("open http://localhost:3000.")
    /// is almost never part of the path.
    private static func trimTrailingPunctuation(_ string: String) -> String {
        var result = Substring(string)
        while let last = result.last, ".,;:!?".contains(last) {
            result = result.dropLast()
        }
        return String(result)
    }
}
