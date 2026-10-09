// Core/AvatarHandle+Words.swift
//
// The word lists of the second and third handle schemes, and the dispositions
// of the first. WORD CHOICE IS THE SAFETY MECHANISM (see AvatarHandle.swift):
// adding a word means asking what it can pair with, not only what it means.
// Tools/handle-review checks every word, pair and compound. Run it after any
// edit here:
//
//     node Tools/handle-review/review.mjs > /tmp/handles.html

extension AvatarHandle {
    /// Scheme 1, first word: a positive disposition. Character only. No mood
    /// words (Cheerful), no body or mind-state words (Steady, Calm), and no
    /// intelligence words (Smart, Clever): the second word names a real person,
    /// and some of them were ill or persecuted, so such a word can mock.
    public static let dispositions: [String] = [
        "Ardent", "Bold", "Brave", "Bright", "Candid", "Careful", "Creative", "Curious", "Daring", "Dauntless",
        "Devoted", "Diligent", "Dynamic", "Eager", "Fearless", "Friendly", "Gallant", "Generous", "Genial",
        "Gentle", "Gracious", "Gutsy", "Helpful", "Honest", "Humble", "Ingenious", "Inquisitive", "Inspired",
        "Intrepid", "Inventive", "Keen", "Kind", "Loyal", "Methodical", "Meticulous", "Nifty", "Observant",
        "Persistent", "Playful", "Plucky", "Resolute", "Resourceful", "Spirited", "Stalwart", "Steadfast",
        "Stellar", "Studious", "Tenacious", "Thoughtful", "Tireless", "Trusty", "Valiant", "Vibrant", "Vivid",
        "Warm", "Zealous", "Zesty",
    ]

    /// Scheme 2, first word: a thing from science, mathematics or engineering.
    public static let scienceWords: [String] = [
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

    /// Scheme 2, second word: what a person does. Actions, never qualities.
    public static let agents: [String] = [
        "Alchemist", "Architect", "Artisan", "Builder", "Captain", "Cartographer", "Charter", "Chaser", "Climber",
        "Collector", "Courier", "Decoder", "Diver", "Explorer", "Gardener", "Gatherer", "Glider", "Herald",
        "Inventor", "Juggler", "Keeper", "Listener", "Maker", "Mapper", "Mender", "Messenger", "Navigator", "Pilot",
        "Pioneer", "Ranger", "Rider", "Sailor", "Scout", "Sculptor", "Sentinel", "Sketcher", "Solver", "Spinner",
        "Stargazer", "Tinkerer", "Tracker", "Tuner", "Voyager", "Wanderer", "Warden", "Watcher",
    ]

    /// Scheme 3, first part of a compound word: "Ion" in "Ionspark".
    public static let compoundPrefixes: [String] = [
        "Alpha", "Aqua", "Astro", "Atom", "Beta", "Bio", "Bit", "Byte", "Carbon", "Chrono", "Cipher", "Cloud",
        "Cobalt", "Code", "Comet", "Cosmo", "Cryo", "Data", "Delta", "Eco", "Ember", "Flux", "Frost",
        "Fusion", "Gamma", "Geo", "Giga", "Glow", "Gyro", "Helix", "Hydro", "Ion", "Lambda", "Lumen", "Lunar",
        "Magno", "Matrix", "Mega", "Micro", "Moon", "Nano", "Neon", "Nova", "Omega", "Orbit", "Photon", "Pixel",
        "Plasma", "Prism", "Proton", "Pulse", "Pyro", "Quanta", "Quark", "Quartz", "Radix", "Rain", "Sigma", "Sky",
        "Solar", "Star", "Sun", "Terra", "Theta", "Vector", "Vertex", "Volt", "Wave", "Zeta",
    ]

    /// Scheme 3, second part of a compound word, joined in lower case.
    public static let compoundSuffixes: [String] = [
        "beam", "bloom", "bolt", "burst", "core", "craft", "crest", "drift", "field", "fire", "flint", "flow",
        "forge", "gleam", "glint", "keeper", "light", "line", "loop", "mark", "path", "port", "quest", "ridge",
        "scope", "shift", "smith", "song", "spark", "spire", "stone", "stream", "thread", "ward", "weave", "wind",
        "works", "wright",
    ]
}
