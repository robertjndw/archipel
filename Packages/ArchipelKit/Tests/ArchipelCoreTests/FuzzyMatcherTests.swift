import Foundation
import Testing
@testable import ArchipelCore

struct FuzzyMatcherTests {
    private func order(_ query: String, _ candidates: [String]) -> [String] {
        FuzzyMatcher.rank(candidates, query: query, limit: 100, key: { $0 }).map(\.item)
    }

    @Test func nonSubsequenceDoesNotMatch() {
        #expect(FuzzyMatcher.match("xyz", in: "abc") == nil)
        #expect(FuzzyMatcher.match("ba", in: "ab") == nil)
        #expect(FuzzyMatcher.match("aa", in: "a") == nil)
    }

    @Test func emptyQueryMatchesEverythingWithZero() {
        #expect(FuzzyMatcher.match("", in: "anything") == FuzzyMatch(score: 0, positions: []))
        #expect(FuzzyMatcher.match("  ", in: "") == FuzzyMatch(score: 0, positions: []))
        let ranked = FuzzyMatcher.rank(["b", "a", "c"], query: "", limit: 2, key: { $0 })
        #expect(ranked.map(\.item) == ["b", "a"])
    }

    @Test func caseAndDiacriticsAreIgnored() {
        #expect(FuzzyMatcher.match("MAIN", in: "src/main.swift") != nil)
        #expect(FuzzyMatcher.match("uber", in: "Über") != nil)
        #expect(FuzzyMatcher.match("ü", in: "uber") != nil)
    }

    @Test func positionsAreAscendingCharacterOffsets() throws {
        let m = try #require(FuzzyMatcher.match("fb", in: "foo/bar"))
        #expect(m.positions == [0, 4])
    }

    @Test func positionsCountCharactersNotScalarsOrBytes() throws {
        let umlaut = try #require(FuzzyMatcher.match("sx", in: "Süße x"))
        #expect(umlaut.positions == [0, 5])
        // The flag is two scalars and the family emoji is seven, but each is one Character.
        let emoji = try #require(FuzzyMatcher.match("ab", in: "🇩🇪a👨‍👩‍👧b"))
        #expect(emoji.positions == [1, 3])
        let decomposed = try #require(FuzzyMatcher.match("eb", in: "e\u{301}b"))
        #expect(decomposed.positions == [0, 1])
    }

    @Test func contiguousRunBeatsScatteredAlignment() throws {
        let m = try #require(FuzzyMatcher.match("abc", in: "a_b_c_abc"))
        #expect(m.positions == [6, 7, 8])
    }

    @Test func consecutiveMatchesRankHigher() {
        #expect(order("abc", ["axbxc", "abxxc", "abc"]) == ["abc", "abxxc", "axbxc"])
    }

    @Test func wordBoundariesRankHigher() {
        #expect(order("fb", ["foobar", "foo-bar", "foo/bar"]).first != "foobar")
        #expect(order("fb", ["foobar", "fooBar"]) == ["fooBar", "foobar"])
        #expect(order("fb", ["xfxbx", "xf_bx"]) == ["xf_bx", "xfxbx"])
        #expect(order("b", ["a.b", "ab"]) == ["a.b", "ab"])
        #expect(order("b", ["a b", "ab"]) == ["a b", "ab"])
    }

    @Test func startOfStringIsABoundary() {
        #expect(order("a", ["xa", "ab"])[0] == "ab")
    }

    @Test func lastPathComponentBeatsDirectoryName() {
        #expect(order("foo", ["foo/zzz.txt", "zzz/foo.txt"]).first == "zzz/foo.txt")
        #expect(order("view", ["views/a.swift", "app/Views.swift"]).first == "app/Views.swift")
    }

    @Test func shorterCandidateWinsTies() {
        #expect(order("foo", ["foobar", "foo"]) == ["foo", "foobar"])
        #expect(order("foo", ["src/foo.swift", "src/foo"]) == ["src/foo", "src/foo.swift"])
    }

    @Test func basenamePrefixRanksVeryHigh() {
        let result = order("main", ["src/domain/mainframe-a-long-name/x.swift", "docs/readme-main.md", "src/main.swift"])
        #expect(result.first == "src/main.swift")
        #expect(order("ma", ["x/amazing.txt", "deeply/nested/dir/mail.txt"]).first == "deeply/nested/dir/mail.txt")
    }

    @Test func termsAreOrderIndependentAndCombined() throws {
        let a = try #require(FuzzyMatcher.match("view model", in: "Sources/ViewModel.swift"))
        let b = try #require(FuzzyMatcher.match("model view", in: "Sources/ViewModel.swift"))
        #expect(a.positions == b.positions)
        #expect(a.score == b.score)
        #expect(a.positions == Array(8...11) + Array(12...16))
        #expect(FuzzyMatcher.match("view zzz", in: "Sources/ViewModel.swift") == nil)
        #expect(order("sess list", ["SessionList.swift", "Sessions.swift", "List.swift"]) == ["SessionList.swift"])
    }

    @Test func rankIsStableAndLimited() {
        let items = ["ab1", "ab2", "ab3", "ab4"]
        let ranked = FuzzyMatcher.rank(items, query: "ab", limit: 3, key: { $0 })
        #expect(ranked.map(\.item) == ["ab1", "ab2", "ab3"])
        #expect(FuzzyMatcher.rank(items, query: "ab", limit: 0, key: { $0 }).isEmpty)
        #expect(ranked[0].match.positions == [0, 1])
    }

    @Test func rankMatchesSingleMatchResults() throws {
        let items = ["src/Alpha.swift", "src/beta.swift", "Docs/alpha.md"]
        for entry in FuzzyMatcher.rank(items, query: "alp", limit: 10, key: { $0 }) {
            #expect(try FuzzyMatcher.match("alp", in: entry.item).unwrapped() == entry.match)
        }
    }

    @Test func positionsAlwaysFormTheQueryAsSubsequence() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("abAB/_-. ")
        func random(_ length: Int) -> String {
            String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
        }
        for _ in 0..<2_000 {
            let candidate = random(Int.random(in: 0...14, using: &rng))
            let query = random(Int.random(in: 1...4, using: &rng)).filter { $0 != " " }
            var it = candidate.lowercased().makeIterator()
            let isSubsequence = query.lowercased().allSatisfy { q in
                while let c = it.next() { if c == q { return true } }
                return false
            }
            let match = FuzzyMatcher.match(query, in: candidate)
            #expect((match != nil) == isSubsequence)
            guard let match else { continue }
            let chars = Array(candidate.lowercased())
            #expect(match.positions == match.positions.sorted())
            #expect(match.positions.map { chars[$0] } == Array(query.lowercased()))
        }
    }

    @Test func ranksFiftyThousandPathsQuickly() {
        let dirs = ["Sources", "Tests", "Packages", "App", "Views", "Models", "Support", "Core"]
        let paths = (0..<50_000).map { i in
            "\(dirs[i % 8])/\(dirs[(i / 8) % 8])/module\(i % 97)/Feature\(i)View.swift"
        }
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure {
            count = FuzzyMatcher.rank(paths, query: "feat view", limit: 50, key: { $0 }).count
        }
        let rare = clock.measure {
            _ = FuzzyMatcher.rank(paths, query: "fvs", limit: 50, key: { $0 })
        }
        print("fuzzy rank 50k: \(elapsed) / \(rare)")
        #expect(count == 50)
        // About a second on a recent Mac, but swift test builds without optimizations and CI
        // runners are several times slower. The bound is only there to catch a blowup, such as
        // the matcher going quadratic, which would take minutes, not seconds.
        #expect(elapsed < .seconds(10))
        #expect(rare < .seconds(10))
    }
}
