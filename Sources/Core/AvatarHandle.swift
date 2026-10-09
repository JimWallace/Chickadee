// Core/AvatarHandle.swift
//
// The pseudonym beside a student's chickadee.  Each handle comes from one of
// three schemes:
//
// - a positive disposition and a scientist: "Curious Noether", "Bold Wang Zhenyi"
// - a science noun and an agent: "Photon Navigator"
// - a compound word, with the suffix joined in lower case: "Ionspark"
//
// This — not the picture — is what a leaderboard identifies a student by.  The
// reasoning is in docs/student-avatars.md; the short version is that uniqueness
// has to hold at the granularity a viewer can distinguish at the size they see
// it, and two 24px birds can share every visible slot.  A handle also gives a
// row the text a screen reader needs, and gives a student something they can
// say out loud.
//
// The word lists are in AvatarHandleWords.swift and the scientists are in
// AvatarHandleScientists.swift.  Tools/handle-review checks both against the
// data in Tools/handle-review/data, and AvatarHandleTests reads the same files.
// Run the review tool after any edit to a list:
//
//     node Tools/handle-review/review.mjs > /tmp/handles.html
//
// Lists change between terms, never during one, and a list change renames
// nobody.  A stored handle is kept as it is, whichever list it came from
// (`hasHandleShape` checks only its form): a handle is per (user, course) and
// each term's offering is a new course, so a handle from an older list ages
// out on its own.  A handle that must go is replaced by staff, one enrollment
// at a time ("Give new handle").

import Foundation

public enum AvatarHandle {

    /// The three ways to make a handle.
    public enum Scheme: CaseIterable, Sendable {
        /// A positive disposition and a scientist: "Curious Noether".
        case scientist
        /// A science noun and an agent: "Photon Navigator".
        case science
        /// A prefix and a lower-case suffix in one word: "Ionspark".
        case compound
    }

    /// The relative chance of each scheme in a draw.  Equal weights give each
    /// scheme a chance of 1 in 3.
    public static let schemeWeights: [Scheme: Int] = [.scientist: 1, .science: 1, .compound: 1]

    /// The largest course the lists must serve.  If a real course is larger,
    /// append words to the lists and run the review tool again.
    public static let maxExpectedEnrollment = 1_000

    /// The people in the scientist scheme, parsed from `scientistRecords`.
    public static let scientists: [Scientist] = scientistRecordLines.compactMap(Scientist.init(record:))

    /// The data lines of `scientistRecords`: no blank lines and no comments.
    public static var scientistRecordLines: [Substring] {
        scientistRecords.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }
    }

    /// Every handle the current lists can form.  It must stay at least four
    /// times `maxExpectedEnrollment`, so the last students in a large course
    /// still get a random handle rather than the remainder.
    public static var combinationCount: Int {
        dispositions.count * scientists.count + scienceNouns.count * agents.count
            + compoundPrefixes.count * compoundSuffixes.count
    }

    /// Every handle that `scheme` can form, in list order.
    public static func handles(in scheme: Scheme) -> [String] {
        switch scheme {
        case .scientist:
            dispositions.flatMap { disposition in scientists.map { "\(disposition) \($0.handle)" } }
        case .science:
            scienceNouns.flatMap { noun in agents.map { "\(noun) \($0)" } }
        case .compound:
            compoundPrefixes.flatMap { prefix in compoundSuffixes.map { prefix + $0 } }
        }
    }

    /// Every handle the current lists can form, in all three schemes.
    public static let allHandles: [String] = Scheme.allCases.flatMap(handles(in:))

    /// A handle not in `taken`, or nil when the space is exhausted for this
    /// course.
    ///
    /// The scheme is drawn first, by `schemeWeights`.  The scientist scheme
    /// picks a scientist that nobody in the course uses yet, so that two
    /// classmates are not "Bold Noether" and "Keen Noether".  The other two
    /// schemes pick from their unused remainder.  When the drawn scheme has
    /// nothing left (for example, every scientist is in use), the draw falls
    /// back to any free handle.
    ///
    /// Picks from the unused remainder rather than guessing and retrying: a
    /// retry loop degrades exactly when a course is large, which is when it
    /// matters, and its worst case is unbounded.
    ///
    /// The database's unique index stays the authority: two concurrent
    /// enrolments can both see the same remainder, so a caller still handles
    /// the losing insert.
    public static func make<G: RandomNumberGenerator>(
        excluding taken: Set<String>, using generator: inout G
    ) -> String? {
        switch drawScheme(using: &generator) {
        case .scientist:
            let inUse = scientistsInUse(taken)
            let unused = scientists.filter { !inUse.contains($0.handle) }
            if let scientist = unused.randomElement(using: &generator),
                let disposition = dispositions.randomElement(using: &generator)
            {
                return "\(disposition) \(scientist.handle)"
            }
        case let scheme:
            let free = handles(in: scheme).filter { !taken.contains($0) }
            if let handle = free.randomElement(using: &generator) { return handle }
        }
        return allHandles.filter { !taken.contains($0) }.randomElement(using: &generator)
    }

    /// The production path: a handle unused in this course, from the system RNG.
    public static func make(excluding taken: Set<String>) -> String? {
        var generator = SystemRandomNumberGenerator()
        return make(excluding: taken, using: &generator)
    }

    /// Reproducible from `seed`, for tests and fixtures.
    public static func make(fromSeed seed: UInt64, excluding taken: Set<String> = []) -> String? {
        var generator = AvatarSeedGenerator(seed: seed)
        return make(excluding: taken, using: &generator)
    }

    /// The scheme that formed `handle` from the current lists, or nil when
    /// the current lists cannot form it.
    public static func scheme(of handle: String) -> Scheme? {
        if let space = handle.firstIndex(of: " ") {
            let first = String(handle[..<space])
            let rest = String(handle[handle.index(after: space)...])
            if dispositionSet.contains(first) && scientistHandleSet.contains(rest) { return .scientist }
            if scienceNounSet.contains(first) && agentSet.contains(rest) { return .science }
            return nil
        }
        let isCompound = compoundPrefixes.contains { prefix in
            handle.hasPrefix(prefix) && compoundSuffixSet.contains(String(handle.dropFirst(prefix.count)))
        }
        return isCompound ? .compound : nil
    }

    /// Whether `handle` is one the current lists can produce.
    public static func isWellFormed(_ handle: String) -> Bool {
        scheme(of: handle) != nil
    }

    /// Whether a STORED handle is fit to show: one to three words.  Each word
    /// starts with an upper-case letter and holds only letters and single
    /// inner hyphens, so internal capitals (McClintock), hyphens
    /// (Joliot-Curie) and non-ASCII letters (Schrödinger) pass, and an
    /// apostrophe, a digit or a double space does not.
    ///
    /// Deliberately not a list check.  A handle drawn from an earlier list
    /// stays valid, so that a list change never renames a student mid-term;
    /// only a value of the wrong form (a hand-edited row) is redrawn.
    public static func hasHandleShape(_ handle: String) -> Bool {
        let words = handle.split(separator: " ", omittingEmptySubsequences: false)
        return (1...3).contains(words.count) && words.allSatisfy(isHandleWord)
    }

    private static func isHandleWord(_ word: Substring) -> Bool {
        guard let first = word.first, first.isLetter, first.isUppercase, word.last != "-" else { return false }
        return !word.contains("--") && word.allSatisfy { $0.isLetter || $0 == "-" }
    }

    private static func drawScheme<G: RandomNumberGenerator>(using generator: inout G) -> Scheme {
        let total = Scheme.allCases.reduce(0) { $0 + weight(of: $1) }
        var roll = Int.random(in: 0..<max(total, 1), using: &generator)
        for scheme in Scheme.allCases {
            if roll < weight(of: scheme) { return scheme }
            roll -= weight(of: scheme)
        }
        return .scientist
    }

    private static func weight(of scheme: Scheme) -> Int {
        max(schemeWeights[scheme] ?? 0, 0)
    }

    /// The scientists that a handle in `taken` already names.
    private static func scientistsInUse(_ taken: Set<String>) -> Set<String> {
        Set(
            taken.compactMap { handle in
                guard let space = handle.firstIndex(of: " "),
                    dispositionSet.contains(String(handle[..<space]))
                else { return nil }
                return String(handle[handle.index(after: space)...])
            })
    }

    private static let dispositionSet = Set(dispositions)
    private static let scientistHandleSet = Set(scientists.map(\.handle))
    private static let scienceNounSet = Set(scienceNouns)
    private static let agentSet = Set(agents)
    private static let compoundSuffixSet = Set(compoundSuffixes)
}
