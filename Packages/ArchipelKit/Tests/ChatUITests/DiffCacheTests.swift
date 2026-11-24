@testable import ChatUI
import Foundation
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DiffCacheTests {
    /// A cache whose analyses are counted, along with whether any ran on the main thread.
    private func countingCache(capacity: Int = 64) -> (DiffCache, Locked<(runs: Int, onMain: Bool)>) {
        let record = Locked((runs: 0, onMain: false))
        let cache = DiffCache(capacity: capacity) { key in
            record.withLock {
                $0.runs += 1
                $0.onMain = $0.onMain || Thread.isMainThread
            }
            return LineDiff.analysis(old: key.oldText, new: key.newText)
        }
        return (cache, record)
    }

    @Test func equalTextsAreAnalysedOnceOffTheMainThread() async throws {
        let (cache, record) = countingCache()
        // Built separately, so the strings are equal without sharing storage.
        let first = cache.entry(for: .init(oldText: "a\nb\n", newText: String("a\nB\n")))
        let second = cache.entry(for: .init(oldText: String("a\nb\n"), newText: "a\nB\n"))
        #expect(first === second)
        try await waitUntil("the analysis is ready") { first.analysis != nil }
        #expect(first.analysis?.stats == LineDiff.Stats(added: 1, removed: 1))
        #expect(first.analysis?.lines.map(\.kind) == [.context, .removed, .added])
        _ = cache.entry(for: .init(oldText: "a\nb\n", newText: "a\nB\n"))
        #expect(cache.analysesStarted == 1)
        #expect(record.withLock { $0.runs } == 1)
        #expect(!record.withLock { $0.onMain })
    }

    @Test func theLeastRecentlyUsedEntryGoesFirst() async throws {
        let (cache, _) = countingCache(capacity: 2)
        _ = cache.entry(for: .init(oldText: nil, newText: "1"))
        _ = cache.entry(for: .init(oldText: nil, newText: "2"))
        _ = cache.entry(for: .init(oldText: nil, newText: "1"))
        _ = cache.entry(for: .init(oldText: nil, newText: "3"))
        #expect(cache.count == 2)
        #expect(cache.analysesStarted == 3)
        // "1" was used after "2", so "2" was dropped and has to be worked out again.
        _ = cache.entry(for: .init(oldText: nil, newText: "1"))
        #expect(cache.analysesStarted == 3)
        _ = cache.entry(for: .init(oldText: nil, newText: "2"))
        #expect(cache.analysesStarted == 4)
    }

    @Test func textsTooLongToCompareAreMarkedApproximate() {
        let old = (0...LineDiff.maximumLines).map { "old \($0)" }.joined(separator: "\n")
        let analysis = LineDiff.analysis(old: old, new: "new\n")
        #expect(analysis.isApproximate)
        #expect(analysis.stats == LineDiff.Stats(added: 1, removed: LineDiff.maximumLines + 1))
        #expect(analysis.lines.count == LineDiff.maximumShownLines)
        #expect(analysis.hiddenLineCount == LineDiff.maximumLines + 2 - LineDiff.maximumShownLines)
        #expect(!LineDiff.analysis(old: "a\n", new: "b\n").isApproximate)
    }
}
