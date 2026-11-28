import Foundation
import Testing
@testable import ArchipelCore

/// SplitMix64, so a seed always gives the same sequence.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct PlaceholderNameTests {
    private static let excluded: Set<String> = [
        "main", "master", "head", "dev", "test", "fix", "branch", "merge", "origin", "remote", "base", "tree", "island",
    ]

    @Test func seededGeneratorIsDeterministicAndWellFormed() {
        var first = SeededGenerator(state: 42)
        var second = SeededGenerator(state: 42)
        let name = PlaceholderName.random(using: &first)
        #expect(name == PlaceholderName.random(using: &second))
        #expect(name.wholeMatch(of: /[a-z]+-[a-z]+/) != nil)
    }

    @Test func wordListsAreCleanAndUnique() {
        for words in [PlaceholderName.adjectives, PlaceholderName.nouns] {
            #expect(Set(words).count == words.count)
            #expect(words.count >= 60)
            for word in words {
                #expect((3...8).contains(word.count), "\(word)")
                #expect(word.wholeMatch(of: /[a-z]+/) != nil, "\(word)")
                #expect(!Self.excluded.contains(word), "\(word)")
            }
        }
    }

    @Test func unusedSkipsTakenNames() {
        var preview = SeededGenerator(state: 7)
        let first = PlaceholderName.random(using: &preview)
        let second = PlaceholderName.random(using: &preview)
        var generator = SeededGenerator(state: 7)
        #expect(PlaceholderName.unused(using: &generator) { $0 == first } == second)
    }

    @Test func unusedFallsBackToANumericSuffix() {
        var generator = SeededGenerator(state: 1)
        // Every plain name is taken and so is the first suffix.
        let name = PlaceholderName.unused(using: &generator, attempts: 3) { candidate in
            candidate.split(separator: "-").count == 2 || candidate.hasSuffix("-2")
        }
        #expect(name.wholeMatch(of: /[a-z]+-[a-z]+-3/) != nil)
    }
}
