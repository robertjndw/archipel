import Foundation

public struct FuzzyMatch: Equatable, Sendable {
    public var score: Int
    /// Offsets (in Characters of the candidate) that matched, ascending; for highlighting.
    public var positions: [Int]

    public init(score: Int, positions: [Int]) {
        self.score = score
        self.positions = positions
    }
}

public enum FuzzyMatcher {
    /// nil when `query` is not a subsequence of `candidate` (case and diacritic insensitive). An empty query matches everything with score 0.
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let terms = Self.terms(of: query)
        if terms.isEmpty { return FuzzyMatch(score: 0, positions: []) }
        var scratch = Scratch()
        guard let score = scratch.run(terms, candidate, wantPositions: true) else { return nil }
        return FuzzyMatch(score: score, positions: scratch.result())
    }

    /// Filters and ranks. Stable for equal scores (keeps input order). `limit` caps the result.
    public static func rank<Item>(
        _ items: [Item],
        query: String,
        limit: Int,
        key: (Item) -> String
    ) -> [(item: Item, match: FuzzyMatch)] {
        guard limit > 0 else { return [] }
        let terms = Self.terms(of: query)
        if terms.isEmpty {
            return items.prefix(limit).map { ($0, FuzzyMatch(score: 0, positions: [])) }
        }

        var scratch = Scratch()
        // Scoring is cheap; positions need a traceback and an array, so they are only built for the survivors.
        var scored: [(score: Int, index: Int)] = []
        for (index, item) in items.enumerated() {
            if let score = scratch.run(terms, key(item), wantPositions: false) {
                scored.append((score, index))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }

        return scored.prefix(limit).map { entry in
            let item = items[entry.index]
            let score = scratch.run(terms, key(item), wantPositions: true) ?? entry.score
            return (item, FuzzyMatch(score: score, positions: scratch.result()))
        }
    }

    // MARK: Scoring constants

    // Consecutive has to outweigh a boundary hop, otherwise "abc" prefers a_b_c over a contiguous "abc".
    private static let matchScore = 16
    private static let consecutiveBonus = 48
    private static let startBonus = 30
    private static let slashBonus = 30
    private static let separatorBonus = 24
    private static let camelBonus = 20
    private static let basenameBonus = 8
    private static let basenamePrefixBonus = 100
    private static let basenameExactBonus = 50
    private static let leadingGapPenalty = 1
    private static let innerGapPenalty = 2
    private static let lengthPenaltyCap = 200
    private static let negative = Int.min / 2

    // MARK: Query preparation

    private static func terms(of query: String) -> [[UInt32]] {
        query.split(whereSeparator: \.isWhitespace).map { $0.map(fold) }
    }

    /// One folded scalar per Character keeps match offsets equal to Character offsets. Only the first scalar of a
    /// multi-scalar fold survives (ß becomes s), which is fine for a lenient match.
    private static func fold(_ ch: Character) -> UInt32 {
        if let a = ch.asciiValue, ch != "\r\n" {
            return (a >= 65 && a <= 90) ? UInt32(a + 32) : UInt32(a)
        }
        let folded = String(ch).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.unicodeScalars.first?.value ?? 0
    }

    private static func isSeparator(_ scalar: UInt32) -> Bool {
        scalar == 45 || scalar == 95 || scalar == 46 || scalar == 32 // - _ . space
    }

    // MARK: Per-candidate state

    /// Buffers reused across candidates so ranking tens of thousands of paths does not allocate per candidate.
    private struct Scratch {
        var folded: [UInt32] = []
        var bonus: [Int] = []
        var d: [Int] = []
        var m: [Int] = []
        var positions: [Int] = []
        var lo: [Int] = []
        var hi: [Int] = []
        var baseStart = 0

        init() {
            folded.reserveCapacity(256)
            bonus.reserveCapacity(256)
        }

        func result() -> [Int] { positions.sorted() }

        mutating func run(_ terms: [[UInt32]], _ candidate: String, wantPositions: Bool) -> Int? {
            prepare(candidate)
            for term in terms where !isSubsequence(term) { return nil }
            positions.removeAll(keepingCapacity: true)
            var total = 0
            for term in terms {
                total += score(term, wantPositions: wantPositions)
            }
            if wantPositions {
                // Two terms can highlight the same character.
                positions.sort()
                var unique: [Int] = []
                unique.reserveCapacity(positions.count)
                for p in positions where unique.last != p { unique.append(p) }
                positions = unique
            }
            return total - min(folded.count, FuzzyMatcher.lengthPenaltyCap)
        }

        private mutating func prepare(_ candidate: String) {
            folded.removeAll(keepingCapacity: true)
            bonus.removeAll(keepingCapacity: true)
            baseStart = 0

            let asciiDone: Bool? = candidate.utf8.withContiguousStorageIfAvailable { bytes in
                var prev: UInt8 = 0
                for (j, c) in bytes.enumerated() {
                    // CR is excluded because "\r\n" is a single Character and would shift offsets.
                    if c >= 128 || c == 13 { return false }
                    let isUpper = c >= 65 && c <= 90
                    folded.append(isUpper ? UInt32(c + 32) : UInt32(c))
                    if j == 0 {
                        bonus.append(FuzzyMatcher.startBonus)
                    } else if prev == 47 {
                        bonus.append(FuzzyMatcher.slashBonus)
                        baseStart = j
                    } else if FuzzyMatcher.isSeparator(UInt32(prev)) {
                        bonus.append(FuzzyMatcher.separatorBonus)
                    } else if isUpper && prev >= 97 && prev <= 122 {
                        bonus.append(FuzzyMatcher.camelBonus)
                    } else {
                        bonus.append(0)
                    }
                    prev = c
                }
                return true
            }
            if asciiDone == true { return }

            folded.removeAll(keepingCapacity: true)
            bonus.removeAll(keepingCapacity: true)
            baseStart = 0
            var prevScalar: UInt32 = 0
            var prevLower = false
            var j = 0
            for ch in candidate {
                folded.append(FuzzyMatcher.fold(ch))
                let isUpper = ch.isUppercase
                if j == 0 {
                    bonus.append(FuzzyMatcher.startBonus)
                } else if prevScalar == 47 {
                    bonus.append(FuzzyMatcher.slashBonus)
                    baseStart = j
                } else if FuzzyMatcher.isSeparator(prevScalar) {
                    bonus.append(FuzzyMatcher.separatorBonus)
                } else if isUpper && prevLower {
                    bonus.append(FuzzyMatcher.camelBonus)
                } else {
                    bonus.append(0)
                }
                prevScalar = ch.unicodeScalars.count == 1 ? ch.unicodeScalars.first!.value : 0
                prevLower = ch.isLowercase
                j += 1
            }
        }

        private func isSubsequence(_ term: [UInt32]) -> Bool {
            var i = 0
            for c in folded where i < term.count && c == term[i] { i += 1 }
            return i == term.count
        }

        /// Best alignment of one term by dynamic programming. `d` holds the best score with query char i matched
        /// exactly at candidate index j; `m` holds the best score with char i matched at or before j.
        private mutating func score(_ term: [UInt32], wantPositions: Bool) -> Int {
            let n = folded.count
            let q = term.count
            let neg = FuzzyMatcher.negative
            let size = n * q
            if d.count < size {
                d = [Int](repeating: neg, count: size)
                m = [Int](repeating: neg, count: size)
            }

            // Char i can only sit between its earliest greedy position from the left and its latest from the right;
            // cells outside that window are never written, so every read of the previous row is window-checked.
            if lo.count < q {
                lo = [Int](repeating: 0, count: q)
                hi = [Int](repeating: 0, count: q)
            }
            var next = 0
            for i in 0..<q {
                while folded[next] != term[i] { next += 1 }
                lo[i] = next
                next += 1
            }
            next = n - 1
            for i in stride(from: q - 1, through: 0, by: -1) {
                while folded[next] != term[i] { next -= 1 }
                hi[i] = next
                next -= 1
            }

            // Unchecked buffers: this loop is the hot path and bounds-checked Array access dominates it in debug builds.
            folded.withUnsafeBufferPointer { f in
            bonus.withUnsafeBufferPointer { bo in
            d.withUnsafeMutableBufferPointer { d in
            m.withUnsafeMutableBufferPointer { m in
            term.withUnsafeBufferPointer { t in
            lo.withUnsafeBufferPointer { lo in
            hi.withUnsafeBufferPointer { hi in
                let baseStart = self.baseStart
                for i in 0..<q {
                    let row = i * n
                    let want = t[i]
                    for j in lo[i]...hi[i] {
                        var best = neg
                        if f[j] == want {
                            let base = FuzzyMatcher.matchScore + (j >= baseStart ? FuzzyMatcher.basenameBonus : 0)
                            if i == 0 {
                                best = base + bo[j] - FuzzyMatcher.leadingGapPenalty * j
                            } else if j > lo[i - 1] {
                                // Past the previous row's window the best earlier match is its last cell plus a gap.
                                let edge = min(j - 1, hi[i - 1])
                                let above = row - n + edge
                                let carried = m[above]
                                if carried > neg {
                                    let gapped = carried - FuzzyMatcher.innerGapPenalty * (j - 1 - edge)
                                    best = gapped + base + bo[j]
                                }
                                if edge == j - 1 {
                                    let run = d[above]
                                    if run > neg {
                                        best = max(best, run + base + max(bo[j], FuzzyMatcher.consecutiveBonus))
                                    }
                                }
                            }
                        }
                        d[row + j] = best
                        var carried = best
                        if j > lo[i] {
                            let left = m[row + j - 1]
                            if left > neg { carried = max(carried, left - FuzzyMatcher.innerGapPenalty) }
                        }
                        m[row + j] = carried
                    }
                }
            }}}}}}}

            let last = (q - 1) * n
            var endJ = lo[q - 1]
            var best = neg
            for j in lo[q - 1]...hi[q - 1] where d[last + j] > best {
                best = d[last + j]
                endJ = j
            }

            // Walk back to recover the alignment; needed for the prefix bonus as well as for highlighting.
            var matched = [Int](repeating: 0, count: q)
            var j = endJ
            var i = q - 1
            while true {
                matched[i] = j
                if i == 0 { break }
                let row = i * n
                let base = FuzzyMatcher.matchScore + (j >= baseStart ? FuzzyMatcher.basenameBonus : 0)
                let run = j - 1 >= lo[i - 1] && j - 1 <= hi[i - 1] ? d[row - n + j - 1] : neg
                if run > neg, d[row + j] == run + base + max(bonus[j], FuzzyMatcher.consecutiveBonus) {
                    j -= 1
                } else {
                    var k = min(j - 1, hi[i - 1])
                    while d[row - n + k] != m[row - n + k] { k -= 1 }
                    j = k
                }
                i -= 1
            }

            var total = best
            var contiguous = true
            for k in 1..<max(q, 1) where matched[k] != matched[k - 1] + 1 { contiguous = false }
            if contiguous, matched[0] == baseStart {
                total += FuzzyMatcher.basenamePrefixBonus
                if q == n - baseStart { total += FuzzyMatcher.basenameExactBonus }
            }
            if wantPositions { positions.append(contentsOf: matched) }
            return total
        }
    }
}
