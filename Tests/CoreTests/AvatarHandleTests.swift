import ChickadeeTestSupport
import Core
import Foundation
import Testing

/// The handle is what a leaderboard identifies a student by, so these are as
/// much about the LISTS as about the generator. There is no moderation
/// anywhere in this feature: the lists are the safety mechanism, and the
/// properties below are the ones a reviewer cannot eyeball across more than
/// 30,000 handles.
@Suite struct AvatarHandleTests {

    /// The word lists, title case, that a handle shows as whole words.
    private static let wholeWords =
        AvatarHandle.dispositions + AvatarHandle.scienceWords + AvatarHandle.agents

    private static let compounds = HandleScheme.compound.allHandles

    @Test func listsHaveNoDuplicates() {
        for list in [
            AvatarHandle.dispositions, AvatarHandle.scienceWords, AvatarHandle.agents,
            AvatarHandle.compoundPrefixes, AvatarHandle.compoundSuffixes, AvatarHandle.scientists.map(\.name),
        ] {
            #expect(Set(list).count == list.count)
        }
    }

    /// One word, title case, letters only. A word with a space would produce a
    /// handle with an extra token; a lowercase one would render as a typo
    /// beside its neighbours. The compound suffixes are joined in lower case.
    @Test func everyWordIsASingleTitleCasedWord() {
        for word in Self.wholeWords + AvatarHandle.compoundPrefixes {
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
        for suffix in AvatarHandle.compoundSuffixes {
            let lowerLetters = !suffix.isEmpty && suffix.allSatisfy { $0.isLetter && $0.isLowercase }
            #expect(lowerLetters, "\(suffix) is not lower-case letters")
        }
    }

    /// A word in two lists of one scheme would let the generator produce
    /// "Cedar Cedar"; a word in the first position of two schemes would let
    /// two schemes produce the same handle.
    @Test func noWordAppearsInBothLists() {
        let pairs: [([String], [String])] = [
            (AvatarHandle.dispositions, AvatarHandle.scienceWords),
            (AvatarHandle.scienceWords, AvatarHandle.agents),
            (AvatarHandle.dispositions, AvatarHandle.scientists.map(\.name)),
        ]
        for (one, other) in pairs {
            let overlap = Set(one).intersection(other)
            #expect(overlap.isEmpty, "in both lists: \(overlap.sorted())")
        }
    }

    /// Headroom, not just size. A course draws without replacement, so the
    /// space has to stay at least four times the largest course we expect —
    /// otherwise the last students in a big course get whatever is left.
    @Test func theSpaceIsLargeEnoughForACourse() {
        #expect(AvatarHandle.combinationCount >= 4 * AvatarHandle.maxExpectedEnrollment)
        #expect(
            AvatarHandle.combinationCount
                == HandleScheme.allCases.reduce(0) { $0 + $1.combinationCount })
    }

    @Test func generatesAWellFormedHandle() throws {
        let handle = try #require(AvatarHandle.make(fromSeed: 7))
        #expect(AvatarHandle.isWellFormed(handle))
        #expect(AvatarHandle.hasHandleShape(handle))
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
        #expect(AvatarHandle.make(excluding: AvatarHandle.allHandles) == nil)
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

    // MARK: - The three schemes

    /// Each scheme makes exactly its own handles, and says so.
    @Test(arguments: HandleScheme.allCases)
    func everySchemeMakesItsOwnHandles(scheme: HandleScheme) {
        let handles = scheme.allHandles
        #expect(handles.count == scheme.combinationCount)
        #expect(Set(handles).count == handles.count)
        let others = HandleScheme.allCases.filter { $0 != scheme }
        for handle in handles {
            #expect(AvatarHandle.scheme(of: handle) == scheme, "\(handle)")
            #expect(!others.contains { $0.canMake(handle) }, "\(handle) is in two schemes")
        }
    }

    /// Equal weights: each scheme is drawn about one time in three.
    @Test func eachSchemeIsDrawnAboutOneTimeInThree() throws {
        var counts: [HandleScheme: Int] = [:]
        for seed in 0..<3_000 as Range<UInt64> {
            let handle = try #require(AvatarHandle.make(fromSeed: seed))
            let scheme = try #require(AvatarHandle.scheme(of: handle))
            counts[scheme, default: 0] += 1
        }
        for scheme in HandleScheme.allCases {
            let count = counts[scheme, default: 0]
            #expect((850...1_150).contains(count), "\(scheme) was drawn \(count) times in 3,000")
        }
    }

    /// The draw names a scientist nobody in the course has yet: with every
    /// scientist but one in use, a scientist handle names that one.
    @Test func aDrawPrefersAScientistNobodyHas() throws {
        let free = try #require(AvatarHandle.scientists.last).name
        let taken = Set(
            AvatarHandle.scientists.dropLast().map { "\(AvatarHandle.dispositions[0]) \($0.name)" })
        var scientistDraws = 0
        for seed in 0..<300 as Range<UInt64> {
            let handle = try #require(AvatarHandle.make(fromSeed: seed, excluding: taken))
            guard AvatarHandle.scheme(of: handle) == .scientist else { continue }
            scientistDraws += 1
            #expect(handle.split(separator: " ").dropFirst().joined(separator: " ") == free, "\(handle)")
        }
        #expect(scientistDraws > 0)
    }

    /// When every scientist is in use, the scheme still draws a free pair.
    @Test func aCourseThatUsesEveryScientistStillGetsAScientistHandle() throws {
        let taken = Set(AvatarHandle.scientists.map { "\(AvatarHandle.dispositions[0]) \($0.name)" })
        var sawScientist = false
        for seed in 0..<100 as Range<UInt64> {
            let handle = try #require(AvatarHandle.make(fromSeed: seed, excluding: taken))
            #expect(!taken.contains(handle))
            sawScientist = sawScientist || AvatarHandle.scheme(of: handle) == .scientist
        }
        #expect(sawScientist)
    }

    /// The database's unique index compares bytes, so one text must have one
    /// encoding: Unicode NFC, as the source files store it.
    @Test func everyHandleIsInUnicodeNFC() {
        for handle in AvatarHandle.allHandles where handle != handle.precomposedStringWithCanonicalMapping {
            Issue.record("\(handle) is not in NFC form")
        }
    }

    // MARK: - The scientists (docs/student-avatars.md §3)

    @Test func everyScientistHasEveryField() {
        for person in AvatarHandle.scientists {
            #expect(AvatarHandle.hasHandleShape(person.name), "\(person.name)")
            #expect((1...2).contains(person.name.split(separator: " ").count), "\(person.name)")
            #expect(!person.fullName.isEmpty && !person.field.isEmpty && !person.note.isEmpty, "\(person.name)")
            #expect(person.isLiving == person.years.hasPrefix("born "), "\(person.name): \(person.years)")
        }
    }

    /// The people removed for balance stay out until a balance review.
    @Test func noScientistRemovedForBalanceIsBack() {
        let back = Set(AvatarHandle.scientists.map(\.name)).intersection(AvatarHandle.removedForBalance)
        #expect(back.isEmpty, "removed for balance, but back: \(back.sorted())")
    }

    // MARK: - Word-list review (docs/student-avatars.md §3, Tools/handle-review)

    /// Alphabetised, so a reviewer can find a word and a diff shows a change
    /// in place rather than as an append.
    @Test func listsAreAlphabetised() {
        for list in [
            AvatarHandle.dispositions, AvatarHandle.scienceWords, AvatarHandle.agents,
            AvatarHandle.compoundPrefixes, AvatarHandle.compoundSuffixes, AvatarHandle.scientists.map(\.name),
        ] {
            #expect(list == list.sorted())
        }
    }

    /// Short enough to say and to fit a leaderboard row, long enough to be a
    /// real word.
    @Test func everyWordIsThreeToTwelveLetters() {
        for word in Self.wholeWords + AvatarHandle.compoundPrefixes + AvatarHandle.compoundSuffixes {
            #expect((3...12).contains(word.count), "\(word) has \(word.count) letters")
        }
        for compound in Self.compounds {
            #expect((6...16).contains(compound.count), "\(compound) has \(compound.count) letters")
        }
    }

    /// The same lists the review tool reads. A word on any of them is a red
    /// flag there and a failure here, so the tool and the tests cannot
    /// disagree about what is allowed. A compound is checked as the one word
    /// it shows.
    @Test(arguments: [
        "first-names.txt", "surnames.txt", "skin-tone.txt", "traits.txt", "slang.txt", "testing.txt",
    ])
    func noWordIsOnAReviewList(file: String) throws {
        let listed = try Self.reviewList(file)
        #expect(!listed.isEmpty, "\(file) is empty")
        // A positive disposition may be a trait; it stands only before a name.
        let allowed = file == "traits.txt" ? try Self.reviewList("positive-traits.txt") : []
        for word in Self.wholeWords + Self.compounds where !allowed.contains(word.lowercased()) {
            #expect(!listed.contains(word.lowercased()), "\(word) is in \(file)")
        }
    }

    /// Every disposition that is a trait is one of the positive traits.
    @Test func everyDispositionThatIsATraitIsPositive() throws {
        let traits = try Self.reviewList("traits.txt")
        let positive = try Self.reviewList("positive-traits.txt")
        #expect(!positive.isEmpty)
        #expect(positive.isSubset(of: traits))
        for word in AvatarHandle.dispositions where traits.contains(word.lowercased()) {
            #expect(positive.contains(word.lowercased()), "\(word) is a trait that is not positive")
        }
    }

    /// A scientist's name is checked as the one name it is: "Tan" alone is a
    /// skin-tone word, but "Tan Yunxian" is a person.
    @Test(arguments: ["skin-tone.txt", "slang.txt", "testing.txt"])
    func noScientistIsOnAReviewList(file: String) throws {
        let listed = try Self.reviewList(file)
        for person in AvatarHandle.scientists {
            #expect(!listed.contains(person.name.lowercased()), "\(person.name) is in \(file)")
        }
    }

    /// No compound hides a word across the join.
    @Test func noCompoundHidesAWord() throws {
        let sequences = try Self.reviewList("substrings.txt")
        #expect(!sequences.isEmpty)
        for compound in Self.compounds {
            let lower = compound.lowercased()
            for sequence in sequences where lower.contains(sequence) {
                Issue.record("\(compound) contains \"\(sequence)\"")
            }
        }
    }

    /// No pair is a known brand, title, place or idiom.
    @Test func noPairIsAKnownPhrase() throws {
        let phrases = try Self.reviewList("phrases.txt")
        #expect(!phrases.isEmpty)
        let twoWordHandles = HandleScheme.scientist.allHandles + HandleScheme.scienceAndAgent.allHandles
        for handle in twoWordHandles where phrases.contains(handle.lowercased()) {
            Issue.record("\(handle) is in phrases.txt")
        }
    }

    /// The words left out on purpose stay out.
    @Test func excludedWordsAreInNeitherList() {
        let words = Set(Self.wholeWords + AvatarHandle.compoundPrefixes)
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
        #expect(!AvatarHandle.hasHandleShape("Quiet  Cedar"))
        #expect(!AvatarHandle.hasHandleShape("Quiet C3dar"))
        #expect(!AvatarHandle.hasHandleShape(""))
    }

    /// One to three words, letters from any script, real hyphens and internal
    /// capitals; never an apostrophe, a stray hyphen or a fourth word.
    @Test func theShapeFitsEverySchemeAndNothingElse() {
        for handle in [
            "Ionspark", "Photon Navigator", "Bold Wang Zhenyi", "Keen Ōmura", "Kind Joliot-Curie",
            "Brave McClintock", "Ardent Qudrat-i-Khuda",
        ] {
            #expect(AvatarHandle.hasHandleShape(handle), "\(handle)")
        }
        for handle in [
            "Bold O'Brien", "Quiet Cedar Grove Path", "Bold -Cedar", "Bold Cedar-", "Bold Ce--dar",
            "ionspark", " Ionspark", "Ionspark ",
        ] {
            #expect(!AvatarHandle.hasHandleShape(handle), "\(handle)")
        }
    }

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
