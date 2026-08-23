// Core/AvatarHandle.swift
//
// The pseudonym beside a student's chickadee: an adjective and a landscape
// noun, "Quiet Cedar".
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
// they can form.  Both lists are therefore deliberately narrow: colour, weather,
// light and texture on one side; landscape and plant on the other.  No traits
// (a handle must never read as a judgement of the student), no body words, no
// animals (every student is already a chickadee), no people, places, brands or
// anything with cultural or political freight.  Adding a word means asking what
// it can pair with, not just what it means.

public enum AvatarHandle {

    /// Colour, weather, light and texture.  No traits: "Clever Brook" would
    /// read as the system's opinion of a student, and its opposite would read
    /// worse.
    public static let adjectives: [String] = [
        "Amber", "Arctic", "Ashen", "Autumn", "Azure", "Balmy", "Boreal", "Brisk",
        "Bronze", "Chalky", "Cinder", "Citrine", "Cobalt", "Copper", "Coral", "Crimson",
        "Crisp", "Dappled", "Dawn", "Dewy", "Drifting", "Dusky", "Dusty", "Ember",
        "Emerald", "Evening", "Fallow", "Flaxen", "Flinty", "Foggy", "Frosted", "Gilded",
        "Glacial", "Golden", "Grassy", "Hazel", "Hazy", "Indigo", "Inland", "Ivory",
        "Jade", "Lilac", "Linen", "Marbled", "Misty", "Mossy", "Muted", "Northern",
        "Ochre", "Olive", "Opal", "Pearly", "Pebbled", "Quiet", "Rainy", "Russet",
        "Rustling", "Sable", "Saffron", "Sandy", "Scarlet", "Shaded", "Silver", "Slate",
        "Smoky", "Snowy", "Sunlit", "Tawny", "Teal", "Tidal", "Twilit", "Umber",
        "Upland", "Velvet", "Verdant", "Violet", "Western", "Windswept", "Wintry", "Woven",
    ]

    /// Landscape and plant.  No animals: the avatar is already a bird, and
    /// "Quiet Heron" beside a chickadee reads as a rendering fault.
    public static let nouns: [String] = [
        "Alder", "Arbor", "Ash", "Aspen", "Beacon", "Bend", "Birch", "Bloom",
        "Bluff", "Bracken", "Bramble", "Brook", "Canopy", "Cedar", "Clearing", "Cliff",
        "Clover", "Cove", "Creek", "Crest", "Dell", "Dune", "Elm", "Fern",
        "Field", "Fir", "Glade", "Glen", "Gorse", "Grove", "Harbour", "Heath",
        "Hedge", "Hemlock", "Hill", "Hollow", "Ivy", "Juniper", "Larch", "Laurel",
        "Ledge", "Lichen", "Lookout", "Maple", "Marsh", "Meadow", "Mesa", "Mist",
        "Moor", "Moss", "Nettle", "Oak", "Orchard", "Pine", "Pond", "Prairie",
        "Quarry", "Reed", "Ridge", "Rowan", "Sedge", "Shore", "Slope", "Sorrel",
        "Spruce", "Summit", "Thicket", "Thistle", "Timber", "Trail", "Vale", "Valley",
        "Willow", "Wharf", "Wildwood", "Yarrow", "Bay", "Basin", "Delta", "Fjord",
    ]

    /// Every handle the two lists can form.
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

    /// Whether `handle` is a pair this generator could have produced.  Used to
    /// keep a stored value that predates a list edit from being read as current
    /// — a word removed from a list is a word that should stop appearing.
    public static func isWellFormed(_ handle: String) -> Bool {
        let parts = handle.split(separator: " ")
        guard parts.count == 2 else { return false }
        return adjectives.contains(String(parts[0])) && nouns.contains(String(parts[1]))
    }
}
