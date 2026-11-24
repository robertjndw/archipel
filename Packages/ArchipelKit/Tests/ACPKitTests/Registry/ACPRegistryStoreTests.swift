import Foundation
import Testing

@testable import ACPKit

@Suite("ACP registry store")
struct ACPRegistryStoreTests {
    private func agent(_ id: String) -> String {
        #"{"id":"\#(id)","name":"\#(id)","version":"1","distribution":{"npx":{"package":"\#(id)@1"}}}"#
    }

    private func writeSource(_ agents: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source.json")
        try RegistryTestSupport.index(agents: agents).write(to: url)
        return url
    }

    private func writeCache(_ agents: String, in cache: URL, age: TimeInterval) throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent("registry.json")
        try RegistryTestSupport.index(agents: agents).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
    }

    @Test func freshCacheIsUsedWithoutFetching() async throws {
        let dir = try RegistryTestSupport.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("cache")
        try writeCache(agent("cached"), in: cache, age: 60)
        // The source does not exist, so any fetch attempt would show up as a fallback reason.
        let store = ACPRegistryStore(cacheDirectory: cache, indexURL: dir.appendingPathComponent("missing.json"))
        let result = await store.index(maxAge: 3600)
        #expect(result.source == .cache)
        #expect(result.fallbackReason == nil)
        #expect(result.index.agents.map(\.id) == ["cached"])
    }

    @Test func staleCacheIsRefetchedAndWrittenAtomically() async throws {
        let dir = try RegistryTestSupport.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("cache")
        try writeCache(agent("old"), in: cache, age: 7200)
        let source = try writeSource(agent("new"), in: dir)
        let store = ACPRegistryStore(cacheDirectory: cache, indexURL: source)
        let result = await store.index(maxAge: 3600)
        #expect(result.source == .network)
        #expect(result.index.agents.map(\.id) == ["new"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path) == ["registry.json"])
        let second = await store.index(maxAge: 3600)
        #expect(second.source == .cache)
        #expect(second.index.agents.map(\.id) == ["new"])
    }

    @Test func fetchFailureFallsBackToStaleCacheThenBundled() async throws {
        let dir = try RegistryTestSupport.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("cache")
        let missing = dir.appendingPathComponent("missing.json")
        try writeCache(agent("stale"), in: cache, age: 7200)
        let store = ACPRegistryStore(cacheDirectory: cache, indexURL: missing)
        let stale = await store.index(maxAge: 3600)
        #expect(stale.source == .cache)
        #expect(stale.fallbackReason != nil)
        #expect(stale.index.agents.map(\.id) == ["stale"])

        let empty = ACPRegistryStore(cacheDirectory: dir.appendingPathComponent("nothing"), indexURL: missing)
        let bundled = await empty.index(maxAge: 3600)
        #expect(bundled.source == .bundled)
        #expect(bundled.fallbackReason != nil)
        #expect(Set(bundled.index.agents.map(\.id)) == ["claude-acp", "codex-acp", "opencode"])
    }

    @Test func garbageResponseDoesNotReplaceTheCache() async throws {
        let dir = try RegistryTestSupport.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("cache")
        try writeCache(agent("good"), in: cache, age: 7200)
        let source = dir.appendingPathComponent("source.json")
        try Data("<html>captive portal</html>".utf8).write(to: source)
        let store = ACPRegistryStore(cacheDirectory: cache, indexURL: source)
        let result = await store.index(maxAge: 3600)
        #expect(result.source == .cache)
        #expect(result.index.agents.map(\.id) == ["good"])
    }

    @Test func offlineIndexUsesAnyCacheOrTheBundledSnapshotWithoutFetching() async throws {
        let dir = try RegistryTestSupport.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("cache")
        try writeCache(agent("ancient"), in: cache, age: 365 * 24 * 3600)
        // A readable source proves the network is not asked: it would answer with another agent.
        let source = try writeSource(agent("new"), in: dir)
        let store = ACPRegistryStore(cacheDirectory: cache, indexURL: source)
        let cached = await store.offlineIndex()
        #expect(cached.source == .cache)
        #expect(cached.index.agents.map(\.id) == ["ancient"])

        let empty = ACPRegistryStore(cacheDirectory: dir.appendingPathComponent("nothing"), indexURL: source)
        let bundled = await empty.offlineIndex()
        #expect(bundled.source == .bundled)
        #expect(Set(bundled.index.agents.map(\.id)) == ["claude-acp", "codex-acp", "opencode"])
    }

    @Test func injectedClockDecidesFreshness() async throws {
        let dir = try RegistryTestSupport.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("cache")
        try writeCache(agent("cached"), in: cache, age: 0)
        let source = try writeSource(agent("new"), in: dir)
        let future = Date().addingTimeInterval(10_000)
        let store = ACPRegistryStore(cacheDirectory: cache, indexURL: source, now: { future })
        let result = await store.index(maxAge: 3600)
        #expect(result.source == .network)
    }
}
