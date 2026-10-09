// Core/AvatarHandleWords.swift
//
// The word lists for the class handle.  WORD CHOICE IS THE SAFETY MECHANISM:
// there is no upload, no free text and no moderation queue, so a word on these
// lists, or a pair or compound that they can form, is the only way that
// something unfortunate can reach a page.  Adding a word means asking what it
// can pair with, not only what it means.
//
// Tools/handle-review reads these lists as they are, and checks them against
// the data in Tools/handle-review/data.  AvatarHandleTests reads the same data.
// Run the review tool after every edit:
//
//     node Tools/handle-review/review.mjs > /tmp/handles.html

extension AvatarHandle {

    /// The first word of the scientist scheme: a positive disposition.
    ///
    /// Character only.  No mood words (Cheerful, Hopeful), no body or
    /// mind-state words (Steady, Calm, Lively) and no intelligence words
    /// (Smart, Clever, Wise).  The second word names a real person, some of
    /// whom had illness or were persecuted, so a mood or body word can mock.
    /// Radiant is out because of Curie; Patient because of the physicians.
    /// A disposition may appear only here: in any other position it reads as a
    /// judgement of the student.
    public static let dispositions: [String] = [
        "Ardent", "Bold", "Brave", "Bright", "Candid", "Careful", "Creative", "Curious", "Daring", "Dauntless",
        "Devoted", "Diligent", "Dynamic", "Eager", "Fearless", "Friendly", "Gallant", "Generous", "Genial",
        "Gentle", "Gracious", "Gutsy", "Helpful", "Honest", "Humble", "Ingenious", "Inquisitive", "Inspired",
        "Intrepid", "Inventive", "Keen", "Kind", "Loyal", "Methodical", "Meticulous", "Nifty", "Observant",
        "Persistent", "Playful", "Plucky", "Resolute", "Resourceful", "Spirited", "Stalwart", "Steadfast",
        "Stellar", "Studious", "Tenacious", "Thoughtful", "Tireless", "Trusty", "Valiant", "Vibrant", "Vivid",
        "Warm", "Zealous", "Zesty",
    ]

    /// The first word of the science scheme: things from science, mathematics
    /// and engineering.
    public static let scienceNouns: [String] = [
        "Algorithm", "Argon", "Asteroid", "Atom", "Axiom", "Beaker", "Boron", "Byte", "Carbon", "Catalyst",
        "Cipher", "Circuit", "Cobalt", "Comet", "Compass", "Compiler", "Cosine", "Cosmos", "Dynamo", "Eclipse",
        "Electron", "Enzyme", "Equation", "Equinox", "Flask", "Formula", "Fossil", "Fractal", "Function", "Galaxy",
        "Genome", "Glacier", "Gyro", "Helium", "Helix", "Horizon", "Hydrogen", "Integer", "Isotope", "Kernel",
        "Krypton", "Laser", "Lattice", "Lemma", "Lens", "Lever", "Magma", "Magnet", "Matrix", "Meteor",
        "Microscope", "Mineral", "Molecule", "Nebula", "Neon", "Neuron", "Neutrino", "Nitrogen", "Node", "Orbit",
        "Oxygen", "Packet", "Photon", "Pipette", "Piston", "Pixel", "Plasma", "Polygon", "Polymer", "Prime",
        "Prism", "Probe", "Protein", "Proton", "Pulley", "Pulsar", "Pulse", "Quantum", "Quark", "Quasar", "Radius",
        "Reagent", "Rocket", "Rotor", "Rover", "Satellite", "Sensor", "Sextant", "Signal", "Silicon", "Solstice",
        "Spectrum", "Spiral", "Synapse", "Tangent", "Telescope", "Tensor", "Theorem", "Titanium", "Turbine",
        "Variable", "Vector", "Vertex", "Vortex", "Wave", "Xenon", "Zenith", "Zinc",
    ]

    /// The second word of the science scheme: what a person does.  Actions,
    /// never qualities.  Wrangler is out (a brand); Hunter, Forger, Fixer,
    /// Hacker and Dealer are out.
    public static let agents: [String] = [
        "Alchemist", "Architect", "Artisan", "Builder", "Captain", "Cartographer", "Charter", "Chaser", "Climber",
        "Collector", "Courier", "Decoder", "Diver", "Explorer", "Gardener", "Gatherer", "Glider", "Herald",
        "Inventor", "Juggler", "Keeper", "Listener", "Maker", "Mapper", "Mender", "Messenger", "Navigator", "Pilot",
        "Pioneer", "Ranger", "Rider", "Sailor", "Scout", "Sculptor", "Sentinel", "Sketcher", "Solver", "Spinner",
        "Stargazer", "Tinkerer", "Tracker", "Tuner", "Voyager", "Wanderer", "Warden", "Watcher",
    ]

    /// The first part of a compound word, in title case.
    public static let compoundPrefixes: [String] = [
        "Alpha", "Aqua", "Astro", "Atom", "Beta", "Bio", "Bit", "Byte", "Carbon", "Chrono", "Cipher", "Cloud",
        "Cobalt", "Code", "Comet", "Cosmo", "Cryo", "Crystal", "Data", "Delta", "Eco", "Ember", "Flux", "Frost",
        "Fusion", "Gamma", "Geo", "Giga", "Glow", "Gyro", "Helix", "Hydro", "Ion", "Lambda", "Lumen", "Lunar",
        "Magno", "Matrix", "Mega", "Micro", "Moon", "Nano", "Neon", "Nova", "Omega", "Orbit", "Photon", "Pixel",
        "Plasma", "Prism", "Proton", "Pulse", "Pyro", "Quanta", "Quark", "Quartz", "Radix", "Rain", "Sigma", "Sky",
        "Solar", "Star", "Sun", "Terra", "Theta", "Vector", "Vertex", "Volt", "Wave", "Zeta",
    ]

    /// The second part of a compound word, joined in lower case:
    /// "Ion" + "spark" = "Ionspark".
    public static let compoundSuffixes: [String] = [
        "beam", "bloom", "bolt", "burst", "core", "craft", "crest", "drift", "field", "fire", "flint", "flow",
        "forge", "gleam", "glint", "keeper", "light", "line", "loop", "mark", "path", "port", "quest", "ridge",
        "scope", "shift", "smith", "song", "spark", "spire", "stone", "stream", "thread", "ward", "weave", "wind",
        "works", "wright",
    ]

    /// Words left out on purpose, with the reason, so that nobody "fixes" a
    /// list by adding one back.  AvatarHandleTests asserts that no list holds
    /// any of them.
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
}
