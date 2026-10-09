import ChickadeeTestSupport
import Core
import Foundation
import Testing

/// The three handle schemes (docs/student-avatars.md §3): disposition +
/// scientist, science noun + agent, and compound word.  These check the draw,
/// the data and the rules that came with the schemes.
@Suite struct AvatarHandleSchemeTests {

    @Test(arguments: AvatarHandle.Scheme.allCases)
    func everySchemeCanProduceHandles(scheme: AvatarHandle.Scheme) {
        #expect(!AvatarHandle.handles(in: scheme).isEmpty)
        let drawn = (0..<300 as Range<UInt64>).compactMap { AvatarHandle.make(fromSeed: $0) }
        #expect(drawn.contains { AvatarHandle.scheme(of: $0) == scheme }, "no draw used \(scheme)")
    }

    /// Each scheme is drawn at its weight: 1 in 3 for equal weights.
    @Test func eachSchemeIsDrawnAtItsWeight() throws {
        let draws = 3_000
        var counts: [AvatarHandle.Scheme: Int] = [:]
        for seed in 0..<UInt64(draws) {
            let handle = try #require(AvatarHandle.make(fromSeed: seed))
            let scheme = try #require(AvatarHandle.scheme(of: handle))
            counts[scheme, default: 0] += 1
        }
        let total = AvatarHandle.Scheme.allCases.reduce(0) { $0 + (AvatarHandle.schemeWeights[$1] ?? 0) }
        for scheme in AvatarHandle.Scheme.allCases {
            let expected = Double(draws * (AvatarHandle.schemeWeights[scheme] ?? 0)) / Double(total)
            let actual = Double(counts[scheme] ?? 0)
            #expect(abs(actual - expected) <= 0.1 * expected, "\(scheme): \(actual) draws, expected \(expected)")
        }
    }

    /// No handle can come from two schemes, and `scheme(of:)` names the one
    /// that formed it.
    @Test func theSchemesDoNotOverlap() {
        var owner: [String: AvatarHandle.Scheme] = [:]
        for scheme in AvatarHandle.Scheme.allCases {
            for handle in AvatarHandle.handles(in: scheme) {
                #expect(owner[handle] == nil, "\(handle) is in two schemes")
                owner[handle] = scheme
            }
        }
        let misread = owner.filter { AvatarHandle.scheme(of: $0.key) != $0.value }.keys.sorted()
        #expect(misread.isEmpty, "scheme(of:) misreads \(misread.prefix(10))")
        #expect(owner.count == AvatarHandle.combinationCount)
    }

    /// The database stores bytes, so a handle in another normal form would be
    /// a different value there.  Compare scalars: `String ==` ignores the form.
    @Test func everyHandleIsInNFC() {
        let decomposed = AvatarHandle.allHandles.filter {
            Array($0.unicodeScalars) != Array($0.precomposedStringWithCanonicalMapping.unicodeScalars)
        }
        #expect(decomposed.isEmpty, "not NFC: \(decomposed.prefix(10))")
    }

    /// A drawn handle must pass the stored-handle check, or `AvatarStore`
    /// would draw again on every page load.
    @Test func everyHandleHasTheStoredShape() {
        let misshapen = AvatarHandle.allHandles.filter { !AvatarHandle.hasHandleShape($0) }
        #expect(misshapen.isEmpty, "wrong shape: \(misshapen.prefix(10))")
    }

    /// The join can form a word that neither part holds ("Ion" + "spark").
    @Test func noCompoundContainsABannedSubstring() throws {
        let banned = try Self.reviewList("substrings.txt")
        #expect(!banned.isEmpty)
        for compound in AvatarHandle.handles(in: .compound) {
            let word = compound.lowercased()
            let found = banned.filter { word.contains($0) }.sorted()
            #expect(found.isEmpty, "\(compound) holds \(found)")
        }
    }

    @Test func noDispositionScientistPairIsAKnownPhrase() throws {
        let phrases = try Self.reviewList("phrases.txt")
        #expect(!phrases.isEmpty)
        let known = AvatarHandle.handles(in: .scientist).filter { phrases.contains($0.lowercased()) }
        #expect(known.isEmpty, "in phrases.txt: \(known)")
    }

    /// A positive trait describes the scientist, so it may stand only before
    /// a scientist's name.  Anywhere else it reads as a judgement of the
    /// student.
    @Test func aPositiveTraitIsOnlyADisposition() throws {
        let positive = try Self.reviewList("positive-traits.txt")
        #expect(!positive.isEmpty)
        let elsewhere =
            AvatarHandle.scienceNouns + AvatarHandle.agents + AvatarHandle.compoundPrefixes
            + AvatarHandle.compoundSuffixes + AvatarHandle.handles(in: .compound)
        for word in elsewhere {
            #expect(!positive.contains(word.lowercased()), "\(word) is a positive trait")
        }
        let dispositions = Set(AvatarHandle.dispositions.map { $0.lowercased() })
        for word in elsewhere {
            #expect(!dispositions.contains(word.lowercased()), "\(word) is also a disposition")
        }
    }

    /// A real name cannot change, but a name with a slang or testing reading
    /// stays off the list.  Each word and each hyphenated part is checked.
    @Test(arguments: ["slang.txt", "testing.txt"])
    func noScientistNameHoldsAWordOnAReviewList(file: String) throws {
        let listed = try Self.reviewList(file)
        #expect(!listed.isEmpty, "\(file) is empty")
        for scientist in AvatarHandle.scientists {
            let parts = scientist.handle.lowercased().split { $0 == " " || $0 == "-" }.map(String.init)
            #expect(!parts.contains(where: listed.contains), "\(scientist.handle) holds a word in \(file)")
        }
    }

    /// The parser drops a line it cannot read, so a broken line would vanish
    /// from the draw without a sound.  Every data line must parse.
    @Test func everyScientistEntryHasAllOfItsFields() {
        #expect(AvatarHandle.scientists.count == AvatarHandle.scientistRecordLines.count)
        for line in AvatarHandle.scientistRecordLines {
            #expect(AvatarHandle.Scientist(record: line) != nil, "cannot parse: \(line)")
        }
        for scientist in AvatarHandle.scientists {
            let fields = [scientist.handle, scientist.fullName, scientist.field, scientist.born, scientist.note]
            let diedIsAYear = scientist.died.map(Self.isYear) ?? true
            #expect(!fields.contains(""), "\(scientist.handle) has an empty field")
            #expect(Self.isYear(scientist.born), "\(scientist.handle): born \(scientist.born)")
            #expect(diedIsAYear, "\(scientist.handle): died \(scientist.died ?? "")")
            #expect(scientist.died?.isEmpty != true, "\(scientist.handle): an empty year of death must be nil")
            #expect((1...2).contains(scientist.handle.split(separator: " ").count), "\(scientist.handle)")
        }
    }

    /// Two classmates should not share a scientist ("Bold Noether" and
    /// "Keen Noether") while another scientist is free.
    @Test func theDrawPrefersAScientistNobodyUses() throws {
        let free = try #require(AvatarHandle.scientists.last).handle
        let disposition = try #require(AvatarHandle.dispositions.first)
        let taken = Set(AvatarHandle.scientists.dropLast().map { "\(disposition) \($0.handle)" })
        var scientistDraws = 0
        for seed in 0..<300 as Range<UInt64> {
            let handle = try #require(AvatarHandle.make(fromSeed: seed, excluding: taken))
            guard AvatarHandle.scheme(of: handle) == .scientist else { continue }
            scientistDraws += 1
            #expect(handle.hasSuffix(" \(free)"), "\(handle) names a scientist in use")
        }
        #expect(scientistDraws > 0)
    }

    /// When every scientist is in use, the draw takes any free handle.
    @Test func theDrawFallsBackWhenEveryScientistIsInUse() throws {
        let disposition = try #require(AvatarHandle.dispositions.first)
        let taken = Set(AvatarHandle.scientists.map { "\(disposition) \($0.handle)" })
        var schemes: Set<AvatarHandle.Scheme> = []
        for seed in 0..<300 as Range<UInt64> {
            let handle = try #require(AvatarHandle.make(fromSeed: seed, excluding: taken))
            #expect(!taken.contains(handle))
            schemes.formUnion(AvatarHandle.scheme(of: handle).map { [$0] } ?? [])
        }
        #expect(schemes.contains(.scientist), "the fallback never drew a free scientist handle")
    }

    /// The stored-handle shape accepts every form the schemes make, and still
    /// refuses a value of the wrong form.
    @Test func theStoredShapeAcceptsTheNewForms() {
        for handle in [
            "Curious Noether", "Bold Wang Zhenyi", "Photon Navigator", "Ionspark", "Keen Schrödinger",
            "Brave Joliot-Curie", "Gentle McClintock", "Plucky Ōmura",
        ] {
            #expect(AvatarHandle.hasHandleShape(handle), "\(handle)")
        }
        for handle in [
            "Bold O'Neil", "Bold Noether Wang Zhenyi", "bold Noether", "Bold -Curie", "Bold Curie-",
            "Bold Joliot--Curie", "Bold  Noether", " Bold", "Bold Noether2",
        ] {
            #expect(!AvatarHandle.hasHandleShape(handle), "\(handle)")
        }
    }

    @Test func listedHandlesAreWellFormed() {
        #expect(AvatarHandle.isWellFormed("Curious Noether"))
        #expect(AvatarHandle.isWellFormed("Bold Wang Zhenyi"))
        #expect(AvatarHandle.isWellFormed("Photon Navigator"))
        #expect(AvatarHandle.isWellFormed("Ionspark"))
        #expect(!AvatarHandle.isWellFormed("Photon Noether"))
        #expect(!AvatarHandle.isWellFormed("Curious Navigator"))
        #expect(!AvatarHandle.isWellFormed("IonSpark"))
        #expect(!AvatarHandle.isWellFormed("Ion"))
    }

    /// "~" marks an approximate year and "-" a year BCE.
    private static func isYear(_ text: String) -> Bool {
        var digits = Substring(text)
        if digits.first == "~" { digits = digits.dropFirst() }
        if digits.first == "-" { digits = digits.dropFirst() }
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// One review list from Tools/handle-review/data, lower-cased. Lines that
    /// start with `#` are comments.
    private static func reviewList(_ file: String) throws -> Set<String> {
        let url = repositoryRoot.appendingPathComponent("Tools/handle-review/data/\(file)")
        let text = try String(contentsOf: url, encoding: .utf8)
        return Set(
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { $0.lowercased() })
    }
}
