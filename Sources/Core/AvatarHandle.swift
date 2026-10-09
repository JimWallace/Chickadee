// Core/AvatarHandle.swift
//
// The pseudonym beside a student's chickadee. It comes from one of three
// schemes (`HandleScheme`), each with a chance of 1 in 3:
//
//   - a positive disposition and a scientist: "Curious Noether"
//   - a thing from science and what a person does: "Photon Navigator"
//   - one compound word: "Ionspark"
//
// This — not the picture — is what a leaderboard identifies a student by.  The
// reasoning is in docs/student-avatars.md; the short version is that uniqueness
// has to hold at the granularity a viewer can distinguish at the size they see
// it, and two 24px birds can share every visible slot.  A handle also gives a
// row the text a screen reader needs, and gives a student something they can
// say out loud.
//
// WORD CHOICE IS THE SAFETY MECHANISM.  There is no upload, no free text and no
// moderation queue anywhere in this feature, so the only way something
// unfortunate reaches a page is if it is in one of the lists or in a pair they
// can form.  The lists are therefore deliberately narrow.  No first names or
// common surnames as words ("Hazel Marsh" reads as a real person and can match
// a real classmate), no skin-tone words (the avatar bans skin tones, decision
// 6, and the handle must too), no traits except the positive dispositions that
// stand before a scientist's name, no body words, no animals (every student is
// already a chickadee), no slang readings, no testing vocabulary (on a platform
// that grades code, "Null" or "Crash" reads as a verdict), and no brands,
// titles, places or idioms.  Adding a word means asking what it can pair with,
// not just what it means.  The scientists follow their own rules
// (AvatarHandle+Scientists.swift).
//
// Tools/handle-review checks every word, pair and compound against the lists
// in Tools/handle-review/data, and AvatarHandleTests reads the same files.  Run
// the review tool after any edit to a list:
//
//     node Tools/handle-review/review.mjs > /tmp/handles.html
//
// Lists change between terms, never during one, and a list change renames
// nobody.  A stored handle is kept as it is, whichever list it came from
// (`hasHandleShape` checks only its form): a handle is per (user, course) and
// each term's offering is a new course, so a handle from an older list ages
// out on its own.  A handle that must go is replaced by staff, one enrollment
// at a time ("Give new handle").

public enum AvatarHandle {

    /// Words left out of the word lists on purpose, with the reason, so nobody
    /// "fixes" a list by adding one back.  AvatarHandleTests asserts that no
    /// list holds any of them.
    ///
    /// - Slang or a body word: Root (Australian sexual slang), Trunk, Wood,
    ///   Bush, Hole, Knob, Pole, Hoary (sounds wrong aloud).
    /// - A phrase-maker: Tide ("Crimson Tide").
    /// - Common surnames: Birch, Brook, Reed, Marsh, Branch, Golden, Weaver.
    /// - First names: Willow, Rowan, Ivy, Hazel, Laurel, Glen, Aspen, Clover,
    ///   Echo, Emerald, Fern, Forest, Meadow, Misty, Ridge, Spring, Velvet,
    ///   Aurora, Crystal, Earnest, Sincere.
    /// - Traits that judge, or words about mood, the body or the mind: Quiet,
    ///   Muted, Radiant (beside Curie), Patient (beside the physicians).
    /// - Brands: Azure ("Azure Cache", "Azure Relay"), Wrangler.
    public static let excludedWords: [String] = [
        "Root", "Trunk", "Wood", "Bush", "Hole", "Knob", "Pole", "Hoary",
        "Tide",
        "Birch", "Brook", "Reed", "Marsh", "Branch", "Golden", "Weaver",
        "Willow", "Rowan", "Ivy", "Hazel", "Laurel", "Glen", "Aspen", "Clover",
        "Echo", "Emerald", "Fern", "Forest", "Meadow", "Misty", "Ridge", "Spring", "Velvet",
        "Aurora", "Crystal", "Earnest", "Sincere",
        "Quiet", "Muted", "Radiant", "Patient",
        "Azure", "Wrangler",
    ]

    /// The largest course the lists must serve.  If a real course is larger,
    /// append words to the lists and run the review tool again.
    public static let maxExpectedEnrollment = 1_000

    /// Every handle the current lists can form, across the three schemes.  It
    /// must stay at least four times `maxExpectedEnrollment`, so the last
    /// students in a large course still get a random handle rather than the
    /// remainder.
    public static var combinationCount: Int { HandleScheme.allCases.reduce(0) { $0 + $1.combinationCount } }

    /// Every handle the current lists can form.
    public static var allHandles: Set<String> { Set(HandleScheme.allCases.flatMap(\.allHandles)) }

    /// A handle not in `taken`, or nil when every scheme is exhausted for this
    /// course.
    ///
    /// Draws a scheme by weight, then a handle from it.  A scheme with nothing
    /// left is dropped and the draw repeats, so a course runs out only when
    /// all three do.
    ///
    /// The database's unique index stays the authority: two concurrent
    /// enrolments can both see the same remainder, so a caller still handles
    /// the losing insert.
    public static func make<G: RandomNumberGenerator>(
        excluding taken: Set<String>, using generator: inout G
    ) -> String? {
        var schemes = HandleScheme.allCases
        while !schemes.isEmpty {
            let scheme = pick(from: schemes, using: &generator)
            if let handle = scheme.make(excluding: taken, using: &generator) {
                return handle
            }
            schemes.removeAll { $0 == scheme }
        }
        return nil
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

    /// The scheme that can make `handle` from the current lists, or nil.
    public static func scheme(of handle: String) -> HandleScheme? {
        HandleScheme.allCases.first { $0.canMake(handle) }
    }

    /// Whether `handle` is one the current lists can produce.
    public static func isWellFormed(_ handle: String) -> Bool {
        scheme(of: handle) != nil
    }

    /// Whether a STORED handle is fit to show: one to three words, each a
    /// capital letter followed by letters, with single hyphens between letters
    /// ("Joliot-Curie").  Letters from any script count ("Ōmura"); internal
    /// capitals are allowed ("McClintock"); apostrophes, digits and double
    /// spaces are not.  Deliberately not a list check.  A handle drawn from an
    /// earlier list stays valid, so that a list change never renames a student
    /// mid-term; only a value of the wrong form (a hand-edited row) is redrawn.
    public static func hasHandleShape(_ handle: String) -> Bool {
        let words = handle.split(separator: " ", omittingEmptySubsequences: false)
        guard (1...3).contains(words.count) else { return false }
        return words.allSatisfy(isHandleWord)
    }

    private static func isHandleWord(_ word: Substring) -> Bool {
        guard let first = word.first, first.isLetter, first.isUppercase else { return false }
        return word.split(separator: "-", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isLetter)
        }
    }

    /// One scheme, drawn by weight.  `schemes` is never empty.
    private static func pick<G: RandomNumberGenerator>(
        from schemes: [HandleScheme], using generator: inout G
    ) -> HandleScheme {
        let total = schemes.reduce(0) { $0 + $1.weight }
        var roll = Int.random(in: 0..<total, using: &generator)
        for scheme in schemes {
            if roll < scheme.weight { return scheme }
            roll -= scheme.weight
        }
        return schemes[schemes.count - 1]
    }
}
