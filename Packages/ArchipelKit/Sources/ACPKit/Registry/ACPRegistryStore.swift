import Foundation

/// Where an index came from.
public enum ACPRegistrySource: Sendable, Equatable {
    case network
    case cache
    case bundled
}

public struct ACPRegistryResult: Sendable {
    public var index: ACPRegistryIndex
    public var source: ACPRegistrySource
    /// Why the network was not used, when a stale cache or the bundled snapshot stood in for it.
    public var fallbackReason: String?
}

/// Fetches the registry index and keeps a copy on disk.
public actor ACPRegistryStore {
    public static let defaultIndexURL = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")
        ?? URL(fileURLWithPath: "/")

    private let cacheFile: URL
    private let indexURL: URL

    /// Whether the index is read from a file on this Mac, as test registries are. Only then may
    /// its downloads be local files too; see `ACPInstaller.install(allowsFileArchives:)`.
    public nonisolated var isLocal: Bool { indexURL.isFileURL }
    private let session: URLSession
    private let now: @Sendable () -> Date

    /// `indexURL` is any URL URLSession understands, including `file://` for tests. `now` is
    /// passed in so freshness can be tested without sleeping.
    public init(
        cacheDirectory: URL,
        indexURL: URL = ACPRegistryStore.defaultIndexURL,
        timeout: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        cacheFile = cacheDirectory.appendingPathComponent("registry.json")
        self.indexURL = indexURL
        self.now = now
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        session = URLSession(configuration: configuration)
    }

    /// Never throws: the bundled snapshot is the last resort so the agent picker is never empty.
    public func index(maxAge: TimeInterval = 6 * 3600) async -> ACPRegistryResult {
        let cached = readCache()
        if let cached, now().timeIntervalSince(cached.modified) < maxAge {
            return ACPRegistryResult(index: cached.index, source: .cache, fallbackReason: nil)
        }
        do {
            return ACPRegistryResult(index: try await download(), source: .network, fallbackReason: nil)
        } catch {
            let reason = error.localizedDescription
            if let cached {
                return ACPRegistryResult(index: cached.index, source: .cache, fallbackReason: reason)
            }
            return ACPRegistryResult(index: ACPBundledRegistry.index, source: .bundled, fallbackReason: reason)
        }
    }

    /// The cached index however old it is, or the bundled snapshot when nothing is cached. Never
    /// touches the network, so starting an agent that is already installed works offline and
    /// does not wait on a slow connection.
    public func offlineIndex() -> ACPRegistryResult {
        if let cached = readCache() {
            return ACPRegistryResult(index: cached.index, source: .cache, fallbackReason: nil)
        }
        return ACPRegistryResult(index: ACPBundledRegistry.index, source: .bundled, fallbackReason: nil)
    }

    private func readCache() -> (index: ACPRegistryIndex, modified: Date)? {
        guard let data = try? Data(contentsOf: cacheFile),
              let index = try? JSONDecoder().decode(ACPRegistryIndex.self, from: data),
              let attributes = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return (index, modified)
    }

    private func download() async throws -> ACPRegistryIndex {
        let (data, response) = try await session.data(from: indexURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        // Decode before caching so a captive-portal page never replaces a good cache.
        let index = try JSONDecoder().decode(ACPRegistryIndex.self, from: data)
        let directory = cacheFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
        return index
    }
}
