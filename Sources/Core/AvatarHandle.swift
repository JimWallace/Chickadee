// Core/AvatarHandle.swift
//
// The pseudonym beside a student's chickadee: an adjective and a noun,
// "Hazy Cache": the sky over the bird, and a place in its forest.
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
// unfortunate reaches a page is if it is in one of these two lists or in a pair
// they can form.  Both lists are therefore deliberately narrow.  No first names
// or common surnames ("Hazel Marsh" reads as a real person and can match a real
// classmate), no skin-tone words (the avatar bans skin tones, decision 6, and
// the handle must too), no traits (a handle must never read as a judgement of
// the student), no body words, no animals (every student is already a
// chickadee), no slang readings, no testing vocabulary (on a platform that
// grades code, "Null" or "Crash" reads as a verdict), and no brands, titles,
// places or idioms.  Adding a word means asking what it can pair with, not just
// what it means.
//
// Tools/handle-review checks every word and every pair against the lists in
// Tools/handle-review/data, and AvatarHandleTests reads the same files.  Run
// the review tool after any edit here:
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

    /// The sky over the chickadee: weather, light, season, moving air and water.
    /// Never the student.  No first names, no skin-tone words, no traits, no plain
    /// colour words.  Checked by Tools/handle-review; see docs/student-avatars.md §3.
    public static let adjectives: [String] = [
        "Arctic", "Autumnal", "Balmy", "Billowing", "Blustery", "Boreal", "Breezy", "Brisk",
        "Cascading", "Cerulean", "Chilly", "Citrine", "Cloudless", "Cloudy", "Coastal", "Cobalt",
        "Crackling", "Crimson", "Crisp", "Dappled", "Dazzling", "Dewy", "Drifting", "Drizzly",
        "Flickering", "Flowing", "Foamy", "Fogbound", "Foggy", "Frosted", "Gilded", "Glacial",
        "Glassy", "Gleaming", "Glimmering", "Glinting", "Glistening", "Glittering", "Glowing", "Gusty",
        "Hazy", "Highland", "Humming", "Icy", "Leafy", "Lilac", "Luminous", "Lunar",
        "Moonlit", "Mossy", "Muggy", "Northern", "Oceanic", "Overcast", "Pastel", "Pebbled",
        "Polar", "Rainy", "Rippling", "Rolling", "Rumbling", "Rustling", "Shimmering", "Showery",
        "Silken", "Silver", "Sleety", "Snowbound", "Snowy", "Solar", "Sparkling", "Speckled",
        "Splashing", "Starlit", "Starry", "Summery", "Sunlit", "Swirling", "Teal", "Thawing",
        "Thundering", "Tidal", "Torrential", "Trickling", "Tumbling", "Turquoise", "Twilit", "Twinkling",
        "Upland", "Verdant", "Vernal", "Wavy", "Whispering", "Windswept", "Wintry", "Woven",
    ]

    /// Places in the chickadee's forest, many of which are also computing words
    /// (Cache, Fork, Kernel, Stack…).  No first names or common surnames, no body
    /// words, no animals, no testing vocabulary.
    public static let nouns: [String] = [
        "Acorn", "Alder", "Beacon", "Birdbath", "Birdhouse", "Bloom", "Blossom", "Boardwalk",
        "Bough", "Boulder", "Bridge", "Burrow", "Cabin", "Cache", "Cairn", "Campsite",
        "Canopy", "Cedar", "Channel", "Clearing", "Cluster", "Cove", "Crate", "Creek",
        "Current", "Delta", "Dock", "Driftwood", "Estuary", "Feeder", "Footpath", "Fork",
        "Glade", "Grove", "Harbour", "Heap", "Hedgerow", "Hilltop", "Hollow", "Icicle",
        "Kernel", "Lagoon", "Lantern", "Lattice", "Leaf", "Log", "Lookout", "Loop",
        "Maple", "Mesh", "Nest", "Nestbox", "Node", "Orchard", "Outcrop", "Patch",
        "Pebble", "Perch", "Petal", "Pier", "Pine", "Pinecone", "Plateau", "Pond",
        "Pool", "Poplar", "Port", "Prairie", "Rapids", "Ravine", "Redwood", "Relay",
        "Sandbox", "Sapling", "Seed", "Seedling", "Shell", "Signal", "Snowdrift", "Sprig",
        "Spruce", "Stack", "Stem", "Stream", "Summit", "Sycamore", "Thicket", "Thistle",
        "Thread", "Trail", "Trailhead", "Tree", "Treetop", "Twig", "Waterfall", "Web",
    ]

    /// Words left out on purpose, with the reason, so nobody "fixes" a list by
    /// adding one back.  AvatarHandleTests asserts that neither list holds any
    /// of them.
    ///
    /// - Slang or a body word: Root (Australian sexual slang), Trunk, Wood,
    ///   Bush, Hole, Knob, Pole, Hoary (sounds wrong aloud).
    /// - A phrase-maker: Tide ("Crimson Tide").
    /// - Common surnames: Birch, Brook, Reed, Marsh, Branch, Golden.
    /// - First names: Willow, Rowan, Ivy, Hazel, Laurel, Glen, Aspen, Clover,
    ///   Echo, Emerald, Fern, Forest, Meadow, Misty, Ridge, Spring, Velvet.
    /// - Traits: Quiet, Muted.
    /// - A brand with the computing nouns: Azure ("Azure Cache", "Azure Relay").
    public static let excludedWords: [String] = [
        "Root", "Trunk", "Wood", "Bush", "Hole", "Knob", "Pole", "Hoary",
        "Tide",
        "Birch", "Brook", "Reed", "Marsh", "Branch", "Golden",
        "Willow", "Rowan", "Ivy", "Hazel", "Laurel", "Glen", "Aspen", "Clover",
        "Echo", "Emerald", "Fern", "Forest", "Meadow", "Misty", "Ridge", "Spring", "Velvet",
        "Quiet", "Muted",
        "Azure",
    ]

    /// The largest course the lists must serve.  If a real course is larger,
    /// append words to the lists and run the review tool again.
    public static let maxExpectedEnrollment = 1_000

    /// Every handle the two current lists can form.  It must stay at least four
    /// times `maxExpectedEnrollment`, so the last students in a large course
    /// still get a random handle rather than the remainder.
    public static var combinationCount: Int { adjectives.count * nouns.count }

    /// A handle not in `taken`, or nil when the space is exhausted for this
    /// course.
    ///
    /// Picks from the unused remainder rather than guessing and retrying: a
    /// retry loop degrades exactly when a course is large, which is when it
    /// matters, and its worst case is unbounded. `taken` is one course's
    /// handles — a few hundred strings — so materializing the remainder is
    /// cheaper than the query that produced it.
    ///
    /// The database's unique index stays the authority: two concurrent
    /// enrolments can both see the same remainder, so a caller still handles
    /// the losing insert.
    public static func make<G: RandomNumberGenerator>(
        excluding taken: Set<String>, using generator: inout G
    ) -> String? {
        var available: [String] = []
        available.reserveCapacity(max(combinationCount - taken.count, 0))
        for adjective in adjectives {
            for noun in nouns where !taken.contains("\(adjective) \(noun)") {
                available.append("\(adjective) \(noun)")
            }
        }
        guard !available.isEmpty else { return nil }
        return available[Int.random(in: 0..<available.count, using: &generator)]
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

    /// Whether `handle` is a pair the current lists can produce.
    public static func isWellFormed(_ handle: String) -> Bool {
        let parts = handle.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return adjectives.contains(String(parts[0])) && nouns.contains(String(parts[1]))
    }

    /// Whether a STORED handle is fit to show: two title-cased words of letters.
    /// Deliberately not a list check.  A handle drawn from an earlier list stays
    /// valid, so that a list change never renames a student mid-term; only a
    /// value of the wrong form (a hand-edited row) is redrawn.
    public static func hasHandleShape(_ handle: String) -> Bool {
        let parts = handle.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { word in
            guard let first = word.first, first.isUppercase else { return false }
            return word.allSatisfy(\.isLetter) && word.dropFirst().allSatisfy(\.isLowercase)
        }
    }
}
