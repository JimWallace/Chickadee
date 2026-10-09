import ChickadeeTestSupport
import Core
import Foundation
import Testing

/// The handle is what a leaderboard identifies a student by, so these are as
/// much about the WORD LISTS as about the generator. There is no moderation
/// anywhere in this feature: the lists are the safety mechanism, and the
/// properties below are the ones a reviewer cannot eyeball across 4,096 pairs.
@Suite struct AvatarHandleTests {

    @Test func listsHaveNoDuplicates() {
        for list in Self.wordLists + [AvatarHandle.scientists.map(\.handle)] {
            #expect(Set(list).count == list.count)
        }
    }

    /// One word, title case, letters only. A word with a space would produce a
    /// three-token handle that `isWellFormed` then rejects; a lowercase one
    /// would render as a typo beside its neighbours.
    @Test func everyWordIsASingleTitleCasedWord() {
        for word in AvatarHandle.dispositions + AvatarHandle.scienceNouns + AvatarHandle.agents
            + AvatarHandle.compoundPrefixes
        {
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
        let overlap = Set(AvatarHandle.scienceNouns).intersection(AvatarHandle.agents)
        #expect(overlap.isEmpty, "in both lists: \(overlap.sorted())")
    }

    /// Headroom, not just size. A course draws without replacement, so the
    /// space has to stay at least four times the largest course we expect —
    /// otherwise the last students in a big course get whatever is left.
    @Test func theSpaceIsLargeEnoughForACourse() {
        #expect(AvatarHandle.combinationCount >= 4 * AvatarHandle.maxExpectedEnrollment)
        #expect(
            AvatarHandle.combinationCount
                == AvatarHandle.dispositions.count * AvatarHandle.scientists.count
                + AvatarHandle.scienceNouns.count * AvatarHandle.agents.count
                + AvatarHandle.compoundPrefixes.count * AvatarHandle.compoundSuffixes.count)
    }

    @Test func generatesAWellFormedHandle() throws {
        let handle = try #require(AvatarHandle.make(fromSeed: 7))
        #expect(AvatarHandle.isWellFormed(handle))
        #expect((1...3).contains(handle.split(separator: " ").count))
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
        let all = Set(AvatarHandle.allHandles)
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

    // MARK: - Word-list review (docs/student-avatars.md §3, Tools/handle-review)

    /// Alphabetised, so a reviewer can find a word and a diff shows a change
    /// in place rather than as an append.
    @Test func listsAreAlphabetised() {
        for list in Self.wordLists + [AvatarHandle.scientists.map(\.handle)] {
            #expect(list == list.sorted())
        }
    }

    /// Short enough to say and to fit a leaderboard row, long enough to be a
    /// real word.
    @Test func everyWordIsThreeToTwelveLetters() {
        for word in Self.wordLists.joined() {
            #expect((3...12).contains(word.count), "\(word) has \(word.count) letters")
        }
    }

    /// The same lists the review tool reads. A word on any of them is a red
    /// flag there and a failure here, so the tool and the tests cannot
    /// disagree about what is allowed.
    @Test(arguments: [
        "first-names.txt", "surnames.txt", "skin-tone.txt", "traits.txt", "slang.txt", "testing.txt",
    ])
    func noWordIsOnAReviewList(file: String) throws {
        let listed = try Self.reviewList(file)
        #expect(!listed.isEmpty, "\(file) is empty")
        let words =
            AvatarHandle.dispositions + AvatarHandle.scienceNouns + AvatarHandle.agents
            + AvatarHandle.handles(in: .compound)
        for word in words {
            #expect(!listed.contains(word.lowercased()), "\(word) is in \(file)")
        }
    }

    /// No pair is a known brand, title, place or idiom.
    @Test func noPairIsAKnownPhrase() throws {
        let phrases = try Self.reviewList("phrases.txt")
        #expect(!phrases.isEmpty)
        for noun in AvatarHandle.scienceNouns {
            for agent in AvatarHandle.agents {
                let pair = "\(noun) \(agent)".lowercased()
                #expect(!phrases.contains(pair), "\(noun) \(agent) is in phrases.txt")
            }
        }
    }

    /// The words left out on purpose stay out.
    @Test func excludedWordsAreInNeitherList() {
        let words = Set(Self.wordLists.joined())
        let readmitted = words.intersection(AvatarHandle.excludedWords)
        #expect(readmitted.isEmpty, "excluded words are back: \(readmitted.sorted())")
    }

    /// New draws come from the current lists only.
    @Test func drawsOnlyFromTheCurrentLists() throws {
        for seed in 0..<500 as Range<UInt64> {
            let handle = try #require(AvatarHandle.make(fromSeed: seed))
            #expect(AvatarHandle.isWellFormed(handle), "\(handle) is not from the current lists")
        }
    }

    /// A stored handle is judged by its form, not by the lists, so that a list
    /// change renames nobody. "Quiet Cedar" is from the lists before the Fall
    /// 2026 review.
    @Test func aStoredHandleFromAnEarlierListKeepsItsShape() {
        #expect(AvatarHandle.hasHandleShape("Quiet Cedar"))
        #expect(!AvatarHandle.isWellFormed("Quiet Cedar"))
        #expect(!AvatarHandle.hasHandleShape("quiet cedar"))
        #expect(AvatarHandle.hasHandleShape("Quiet"))
        #expect(AvatarHandle.hasHandleShape("Quiet Cedar Grove"))
        #expect(!AvatarHandle.hasHandleShape("Quiet Cedar Grove Path"))
        #expect(!AvatarHandle.hasHandleShape("Quiet  Cedar"))
        #expect(!AvatarHandle.hasHandleShape("Quiet C3dar"))
        #expect(!AvatarHandle.hasHandleShape(""))
    }

    /// The five word lists.
    private static let wordLists = [
        AvatarHandle.dispositions, AvatarHandle.scienceNouns, AvatarHandle.agents, AvatarHandle.compoundPrefixes,
        AvatarHandle.compoundSuffixes,
    ]

    /// One review list from Tools/handle-review/data, lower-cased. Lines that
    /// start with `#` are comments.
    private static func reviewList(_ file: String) throws -> Set<String> {
        let root = repositoryRoot
        let url = root.appendingPathComponent("Tools/handle-review/data/\(file)")
        let text = try String(contentsOf: url, encoding: .utf8)
        return Set(
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { $0.lowercased() })
    }
}
