import Core
import Testing

/// The handle is what a leaderboard identifies a student by, so these are as
/// much about the WORD LISTS as about the generator. There is no moderation
/// anywhere in this feature: the lists are the safety mechanism, and the
/// properties below are the ones a reviewer cannot eyeball across 6,400 pairs.
@Suite struct AvatarHandleTests {

    @Test func listsHaveNoDuplicates() {
        #expect(Set(AvatarHandle.adjectives).count == AvatarHandle.adjectives.count)
        #expect(Set(AvatarHandle.nouns).count == AvatarHandle.nouns.count)
    }

    /// One word, title case, letters only. A word with a space would produce a
    /// three-token handle that `isWellFormed` then rejects; a lowercase one
    /// would render as a typo beside its neighbours.
    @Test func everyWordIsASingleTitleCasedWord() {
        for word in AvatarHandle.adjectives + AvatarHandle.nouns {
            // Computed before the expectation: #expect decomposes a function
            // call into a rethrows-typed helper, so `allSatisfy` inside one
            // fails to compile.
            let lettersOnly = word.allSatisfy { $0.isLetter }
            let titleCased =
                word.first?.isUppercase == true
                && word.dropFirst().allSatisfy { $0.isLowercase }
            #expect(!word.isEmpty)
            #expect(lettersOnly, "\(word) is not letters only")
            #expect(titleCased, "\(word) is not title case")
        }
    }

    /// A word in both lists would let the generator produce "Cedar Cedar".
    @Test func noWordAppearsInBothLists() {
        let overlap = Set(AvatarHandle.adjectives).intersection(AvatarHandle.nouns)
        #expect(overlap.isEmpty, "in both lists: \(overlap.sorted())")
    }

    /// Headroom, not just size. A course draws without replacement, so the
    /// space has to stay comfortably larger than any course we expect —
    /// otherwise the last students in a big course get whatever is left.
    @Test func theSpaceIsLargeEnoughForACourse() {
        #expect(AvatarHandle.combinationCount >= 6_000)
        #expect(AvatarHandle.combinationCount == AvatarHandle.adjectives.count * AvatarHandle.nouns.count)
    }

    @Test func generatesAWellFormedHandle() throws {
        let handle = try #require(AvatarHandle.make(fromSeed: 7))
        #expect(AvatarHandle.isWellFormed(handle))
        #expect(handle.split(separator: " ").count == 2)
    }

    @Test func neverReturnsATakenHandle() {
        var taken: Set<String> = []
        for seed in 0..<200 as Range<UInt64> {
            guard let handle = AvatarHandle.make(fromSeed: seed, excluding: taken) else {
                Issue.record("space exhausted after \(taken.count)")
                return
            }
            #expect(!taken.contains(handle))
            taken.insert(handle)
        }
        #expect(taken.count == 200)
    }

    /// Exhaustion is a real state — a course bigger than the lists — and the
    /// answer is nil, not a duplicate and not a hang.
    @Test func returnsNilWhenTheSpaceIsExhausted() {
        var all: Set<String> = []
        for adjective in AvatarHandle.adjectives {
            for noun in AvatarHandle.nouns { all.insert("\(adjective) \(noun)") }
        }
        #expect(AvatarHandle.make(excluding: all) == nil)
    }

    @Test func rejectsHandlesOutsideTheLists() {
        #expect(!AvatarHandle.isWellFormed("Quiet"))
        #expect(!AvatarHandle.isWellFormed("Quiet Cedar Grove"))
        #expect(!AvatarHandle.isWellFormed("Sneaky Cedar"))
        #expect(!AvatarHandle.isWellFormed("quiet cedar"))
        #expect(!AvatarHandle.isWellFormed(""))
    }

    @Test func drawIsReproducibleFromASeed() {
        #expect(AvatarHandle.make(fromSeed: 42) == AvatarHandle.make(fromSeed: 42))
    }
}
